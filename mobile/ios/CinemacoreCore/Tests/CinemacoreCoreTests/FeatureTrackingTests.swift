import Foundation
import Testing
@testable import CinemacoreCore

private func uniqueDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cinemacore-features-\(UUID().uuidString)", isDirectory: true)
}

private func removeDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func makeTracker() -> (tracker: FeatureTracker, directory: URL) {
    let directory = uniqueDirectory()
    return (FeatureTracker(directory: directory), directory)
}

@Suite("FeatureTracker — registry")
struct FeatureRegistryTests {

    @Test("every registry feature carries a name, a category and a default")
    func registryIsComplete() {
        for feature in Feature.allCases {
            #expect(!feature.displayName.isEmpty)
            #expect(!feature.rawValue.isEmpty)
        }
        #expect(Set(Feature.allCases.map(\.category)) == Set(Feature.Category.allCases))
    }

    @Test("a fresh tracker exposes the default enabled set")
    func defaults() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        let enabled = await tracker.enabledFeatures()
        #expect(enabled == Feature.allCases.filter(\.isEnabledByDefault))
        #expect(enabled.contains(.playback))
        #expect(enabled.contains(.downloads))
        // The one capability the build does not have must not claim to be on.
        #expect(!enabled.contains(.chromecast))
        #expect(await tracker.isEnabled(.chromecast) == false)
        #expect(await tracker.isEnabled(.playback))
    }

    @Test("every category is represented, so no section of the report is empty")
    func categoriesArePopulated() {
        for category in Feature.Category.allCases {
            #expect(Feature.allCases.contains { $0.category == category })
        }
    }
}

@Suite("FeatureTracker — persistence")
struct FeaturePersistenceTests {

    @Test("usage and toggles survive a reload from disk")
    func roundTrip() async {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let first = FeatureTracker(directory: directory)
        await first.record(.playback, kind: .used, detail: "1080p")
        await first.record(.playback, kind: .used)
        await first.record(.subtitlesProvider, kind: .failed, detail: "srt")
        await first.setEnabled(.chromecast, true)
        await first.setEnabled(.search, false)
        await first.flush()

        let reloaded = FeatureTracker(directory: directory)
        let playback = await reloaded.usage().first { $0.feature == .playback }
        #expect(playback?.useCount == 2)
        #expect(await reloaded.usage().first { $0.feature == .subtitlesProvider }?.failureCount == 1)
        #expect(await reloaded.isEnabled(.chromecast))
        #expect(await reloaded.isEnabled(.search) == false)
        // A default that was never touched still reads as its default.
        #expect(await reloaded.isEnabled(.downloads))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("features.json").path
        ))
    }

    @Test("a document from an older build keeps what it has and defaults the rest")
    func tolerantDecode() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Deliberately missing `events`, an unknown feature id, and a usage row
        // for a feature this build does not have.
        let older = """
        {
          "enabled": { "playback": false, "retiredFeature": true },
          "usage": {
            "downloads": { "useCount": 4, "firstUsed": "2024-01-02T03:04:05Z" }
          }
        }
        """
        try Data(older.utf8).write(to: directory.appendingPathComponent("features.json"))

        let tracker = FeatureTracker(directory: directory)
        #expect(await tracker.isEnabled(.playback) == false)
        #expect(await tracker.isEnabled(.watchlist))
        let downloads = await tracker.usage().first { $0.feature == .downloads }
        #expect(downloads?.useCount == 4)
        #expect(downloads?.failureCount == 0)
        #expect(downloads?.lastUsed == nil)
        #expect(await tracker.events().isEmpty)
        // A row with no matching case is dropped rather than surfaced nameless.
        #expect(await tracker.usage().count == 1)
    }

    @Test("an unknown event does not discard the events around it")
    func lossyEventDecoding() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let document = """
        {
          "events": [
            { "feature": "playback", "kind": "used", "timestamp": "2024-01-01T00:00:00Z" },
            { "feature": "notAFeature", "kind": "used", "timestamp": "2024-01-01T00:00:01Z" },
            { "feature": "downloads", "kind": "failed", "timestamp": "2024-01-01T00:00:02Z" }
          ]
        }
        """
        try Data(document.utf8).write(to: directory.appendingPathComponent("features.json"))

        let tracker = FeatureTracker(directory: directory)
        let events = await tracker.events(limit: 10)
        #expect(events.map(\.feature) == [.downloads, .playback])
    }

    @Test("a corrupt document is not fatal")
    func corruptDocument() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: directory.appendingPathComponent("features.json"))

        let tracker = FeatureTracker(directory: directory)
        #expect(await tracker.isEnabled(.playback))
        #expect(await tracker.usage().isEmpty)
    }
}

@Suite("FeatureTracker — events and usage")
struct FeatureEventTests {

    @Test("the event log is capped and keeps the newest entries")
    func eventCap() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        for index in 0..<520 {
            await tracker.record(.playback, kind: .used, detail: "tick \(index)")
        }

        let events = await tracker.events(limit: 1_000)
        #expect(events.count == 500)
        #expect(events.first?.detail == "tick 519")
        #expect(events.last?.detail == "tick 20")
        // The cap trims the log, not the totals.
        #expect(await tracker.usage().first { $0.feature == .playback }?.useCount == 520)
    }

    @Test("events come back newest first and honour the limit")
    func eventOrdering() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        await tracker.record(.search, kind: .used)
        await tracker.record(.downloads, kind: .used)
        await tracker.record(.playback, kind: .used)

        let all = await tracker.events(limit: 10)
        #expect(all.map(\.feature) == [.playback, .downloads, .search])
        #expect(await tracker.events(limit: 2).map(\.feature) == [.playback, .downloads])
        #expect(await tracker.events(limit: 0).isEmpty)
    }

    @Test("usage aggregates uses, failures and the first and last activity")
    func usageAggregation() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        await tracker.record(.qualitySelection, kind: .used, detail: "1080p")
        await tracker.record(.qualitySelection, kind: .failed, detail: "timeout")
        await tracker.record(.qualitySelection, kind: .used, detail: "720p")
        await tracker.record(.watchlist, kind: .enabled)

        let usage = await tracker.usage()
        let quality = usage.first { $0.feature == .qualitySelection }
        #expect(quality?.useCount == 2)
        #expect(quality?.failureCount == 1)
        #expect(quality?.firstUsed != nil)
        #expect(quality?.lastUsed != nil)
        #expect((quality?.lastUsed ?? .distantPast) >= (quality?.firstUsed ?? .distantFuture))

        // A toggle is activity without being adoption: counted in the window,
        // not in `useCount`.
        let watchlist = usage.first { $0.feature == .watchlist }
        #expect(watchlist?.useCount == 0)
        #expect(watchlist?.lastUsed != nil)
        // Ordered by use count, so the report's first rows are the live features.
        #expect(usage.first?.feature == .qualitySelection)
    }

    @Test("a snapshot covers every feature, including untouched ones")
    func snapshot() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        await tracker.record(.playback, kind: .used)
        await tracker.setEnabled(.chromecast, true)

        let snapshot = await tracker.snapshot()
        #expect(snapshot.entries.count == Feature.allCases.count)
        #expect(snapshot.enabledCount == Feature.allCases.filter(\.isEnabledByDefault).count + 1)
        #expect(snapshot.entry(for: .playback)?.usage.useCount == 1)
        #expect(snapshot.entry(for: .chromecast)?.isEnabled == true)
        #expect(snapshot.entry(for: .airPlay)?.usage.useCount == 0)
        #expect(snapshot.unusedCount == Feature.allCases.count - 1)
    }

    @Test("reset clears the log, the totals and the overrides")
    func reset() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        await tracker.record(.playback, kind: .used)
        await tracker.setEnabled(.playback, false)
        await tracker.reset()

        #expect(await tracker.events().isEmpty)
        #expect(await tracker.usage().isEmpty)
        #expect(await tracker.isEnabled(.playback))
        #expect(await tracker.enabledFeatures() == Feature.allCases.filter(\.isEnabledByDefault))

        // The cleared state is on disk, not just in memory.
        let reloaded = FeatureTracker(directory: directory)
        #expect(await reloaded.usage().isEmpty)
        #expect(await reloaded.isEnabled(.playback))
    }
}

@Suite("FeatureReport — rendering")
struct FeatureReportTests {

    @Test("the text report lists every feature under its category")
    func reportRendering() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        await tracker.record(.playback, kind: .used, detail: "1080p")
        await tracker.record(.subtitlesCommunity, kind: .failed)
        await tracker.setEnabled(.chromecast, true)

        let text = await tracker.report().text()
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.first == "Cinemacore feature report")
        for category in Feature.Category.allCases {
            #expect(lines.contains(category.displayName.uppercased()))
        }
        for feature in Feature.allCases {
            #expect(lines.contains { $0.hasPrefix(feature.rawValue) }, "missing \(feature.rawValue)")
        }

        let playback = lines.first { $0.hasPrefix("playback ") }
        #expect(playback?.contains(" on ") == true)
        #expect(playback?.contains(" 1 ") == true)
        let chromecast = lines.first { $0.hasPrefix("chromecast ") }
        #expect(chromecast?.contains(" on ") == true)
        let community = lines.first { $0.hasPrefix("subtitlesCommunity ") }
        #expect(community?.contains(" 1 ") == true)
        #expect(text.contains("Recorded on this device only"))
    }

    @Test("an untouched tracker still renders a complete table")
    func emptyReport() async {
        let (tracker, directory) = makeTracker()
        defer { removeDirectory(directory) }

        let text = await tracker.report().text()
        #expect(text.contains("\(Feature.allCases.filter(\.isEnabledByDefault).count)/\(Feature.allCases.count) enabled"))
        #expect(text.contains("0/\(Feature.allCases.count) enabled") == false)
        #expect(text.contains("never used"))
        // The unused rows are the point of the report, so they are present.
        #expect(text.contains("airPlay"))
        #expect(text.split(separator: "\n").count > Feature.allCases.count)
    }
}
