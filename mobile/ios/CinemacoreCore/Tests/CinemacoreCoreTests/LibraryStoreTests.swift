import Testing
import Foundation
@testable import CinemacoreCore

/// Both stores are driven through `LibraryStoring` so a divergence between the
/// on-disk and the in-memory implementation has to be written down. Only the
/// cases that are genuinely about the file (the 300-row cap, persistence across
/// instances, corruption) are file-only.
enum StoreKind: String, CaseIterable, Sendable {
    case file
    case memory
}

private func uniqueDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cinemacore-library-\(UUID().uuidString)", isDirectory: true)
}

/// A store of `kind` in a fresh temporary directory (`file`) or detached from
/// disk (`memory`), plus the directory to remove when the test ends.
private func makeStore(_ kind: StoreKind) -> (store: any LibraryStoring, directory: URL?) {
    switch kind {
    case .memory:
        return (InMemoryLibraryStore(), nil)
    case .file:
        let directory = uniqueDirectory()
        return (FileLibraryStore(directory: directory), directory)
    }
}

private func removeDirectory(_ directory: URL?) {
    guard let directory else { return }
    try? FileManager.default.removeItem(at: directory)
}

private func makeSubject(_ id: String, title: String? = nil) -> Subject {
    Subject(id: id, title: title ?? id)
}

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makePoint(
    _ id: String,
    position: Double = 60,
    duration: Double = 600,
    updatedAt: Date
) -> ResumePoint {
    ResumePoint(
        subjectID: id,
        title: id,
        positionSeconds: position,
        durationSeconds: duration,
        updatedAt: updatedAt
    )
}

@Suite("LibraryStoring — shared contract")
struct LibraryStoreContractTests {

    @Test("a fresh store is empty and carries default settings", arguments: StoreKind.allCases)
    func freshStore(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        let watchlist = await store.watchlist()
        let history = await store.history()
        let settings = await store.settings()
        let inWatchlist = await store.isInWatchlist(subjectID: "1")
        let resume = await store.resumePoint(for: "1")

        #expect(watchlist.isEmpty)
        #expect(history.isEmpty)
        #expect(!inWatchlist)
        #expect(resume == nil)
        #expect(settings == LibrarySettings())
        #expect(settings.gatewayURL == nil)
        #expect(settings.hiddenRails.isEmpty)
        #expect(settings.categoryOrder.isEmpty)
        #expect(settings.playbackSpeed == 1.0)
        #expect(settings.autoPlayNext)
    }

    // MARK: - Watchlist

    @Test("watchlist adds, orders newest first, removes and clears", arguments: StoreKind.allCases)
    func watchlistLifecycle(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        let first = makeSubject("1", title: "First")
        let second = makeSubject("2", title: "Second")
        let third = makeSubject("3", title: "Third")

        let addedFirst = await store.toggleWatchlist(first)
        // `toggleWatchlist` timestamps with `Date()`; a tick apart keeps the
        // newest-first ordering a real assertion rather than a tie.
        try? await Task.sleep(for: .milliseconds(2))
        let addedSecond = await store.toggleWatchlist(second)
        try? await Task.sleep(for: .milliseconds(2))
        let addedThird = await store.toggleWatchlist(third)
        #expect(addedFirst && addedSecond && addedThird)

        let hasFirst = await store.isInWatchlist(subjectID: "1")
        let hasThird = await store.isInWatchlist(subjectID: "3")
        #expect(hasFirst)
        #expect(hasThird)

        var entries = await store.watchlist()
        #expect(entries.map(\.subject.id) == ["3", "2", "1"])
        #expect(entries.map(\.subject.title) == ["Third", "Second", "First"])

        await store.removeFromWatchlist(subjectID: "2")
        entries = await store.watchlist()
        #expect(entries.map(\.subject.id) == ["3", "1"])
        let hasSecond = await store.isInWatchlist(subjectID: "2")
        #expect(!hasSecond)

        await store.clearWatchlist()
        entries = await store.watchlist()
        #expect(entries.isEmpty)
    }

    @Test("toggling the same subject twice removes it", arguments: StoreKind.allCases)
    func toggleTwiceRemoves(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        let subject = makeSubject("42", title: "Twice")
        let added = await store.toggleWatchlist(subject)
        let presentAfterAdd = await store.isInWatchlist(subjectID: "42")
        let removed = await store.toggleWatchlist(subject)
        let presentAfterSecondToggle = await store.isInWatchlist(subjectID: "42")

        #expect(added)
        #expect(presentAfterAdd)
        #expect(!removed)
        #expect(!presentAfterSecondToggle)

        let entries = await store.watchlist()
        #expect(entries.isEmpty)
    }

    @Test("removing an id that is not saved is a no-op", arguments: StoreKind.allCases)
    func removingUnknownSubjectIsNoOp(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        await store.toggleWatchlist(makeSubject("1", title: "Kept"))
        await store.removeFromWatchlist(subjectID: "missing")

        let entries = await store.watchlist()
        #expect(entries.map(\.subject.id) == ["1"])
    }

    // MARK: - History

    @Test("history orders newest first, upserts by id and looks up a resume point", arguments: StoreKind.allCases)
    func historyLifecycle(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        let movie = makePoint("movie", updatedAt: baseDate)
        let episodeOne = ResumePoint(
            subjectID: "series", title: "Show", season: 1, episode: 1,
            positionSeconds: 120, durationSeconds: 600,
            updatedAt: baseDate.addingTimeInterval(60)
        )
        let episodeTwo = ResumePoint(
            subjectID: "series", title: "Show", season: 1, episode: 2,
            positionSeconds: 30, durationSeconds: 600,
            updatedAt: baseDate.addingTimeInterval(120)
        )

        await store.record(movie)
        await store.record(episodeOne)
        await store.record(episodeTwo)

        var history = await store.history()
        // Two episodes of one series are two rows: the key is the resume id.
        #expect(history.map(\.id) == ["series-s1e2", "series-s1e1", "movie"])
        #expect(history.first?.season == 1)
        #expect(history.first?.episode == 2)

        // Re-recording the same id replaces the row instead of duplicating it.
        let resumed = ResumePoint(
            subjectID: "series", title: "Show", season: 1, episode: 1,
            positionSeconds: 300, durationSeconds: 600,
            updatedAt: baseDate.addingTimeInterval(180)
        )
        await store.record(resumed)
        history = await store.history()
        #expect(history.count == 3)
        #expect(history.first?.id == "series-s1e1")
        #expect(history.first?.positionSeconds == 300)

        let found = await store.resumePoint(for: "series-s1e1")
        let missing = await store.resumePoint(for: "nope")
        #expect(found == resumed)
        #expect(missing == nil)
    }

    @Test("removeHistory drops one row and clearHistory drops all", arguments: StoreKind.allCases)
    func historyRemoval(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        await store.record(makePoint("a", updatedAt: baseDate))
        await store.record(makePoint("b", updatedAt: baseDate.addingTimeInterval(60)))

        await store.removeHistory(id: "a")
        var history = await store.history()
        #expect(history.map(\.id) == ["b"])

        await store.clearHistory()
        history = await store.history()
        let resume = await store.resumePoint(for: "b")
        #expect(history.isEmpty)
        #expect(resume == nil)
    }

    @Test("a non-resumable record removes the row instead of persisting it", arguments: StoreKind.allCases)
    func nonResumableRecordRemovesRow(kind: StoreKind) async {
        let (store, directory) = makeStore(kind)
        defer { removeDirectory(directory) }

        let resumable = makePoint("film", position: 600, duration: 6000, updatedAt: baseDate)
        await store.record(resumable)
        var history = await store.history()
        #expect(history.count == 1)

        // 99% watched: progress >= 0.98, so `isResumable` is false and the row
        // must go rather than offer to resume a finished title.
        let almostDone = makePoint("film", position: 5940, duration: 6000, updatedAt: baseDate.addingTimeInterval(1))
        #expect(!almostDone.isResumable)
        await store.record(almostDone)
        history = await store.history()
        let afterFinished = await store.resumePoint(for: "film")
        #expect(history.isEmpty)
        #expect(afterFinished == nil)

        // Only two seconds in is equally not worth resuming, so that row goes too.
        await store.record(resumable)
        let barelyStarted = makePoint("film", position: 2, duration: 6000, updatedAt: baseDate.addingTimeInterval(2))
        #expect(!barelyStarted.isResumable)
        await store.record(barelyStarted)
        history = await store.history()
        #expect(history.isEmpty)

        // Recording a non-resumable point for an id that was never saved is a
        // no-op, never an insert.
        await store.record(barelyStarted)
        history = await store.history()
        #expect(history.isEmpty)
    }
}

// MARK: - File-only behaviour

@Suite("FileLibraryStore — disk behaviour")
struct FileLibraryStoreDiskTests {

    @Test("history is capped at the store's 300-entry limit")
    func historyIsCapped() async {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let store = FileLibraryStore(directory: directory)

        // `historyLimit` is private; 300 is the constant declared in
        // LibraryStore.swift.
        let total = 320
        for index in 0..<total {
            await store.record(
                makePoint("id-\(index)", updatedAt: baseDate.addingTimeInterval(Double(index)))
            )
        }

        let history = await store.history()
        #expect(history.count == 300)
        // The 300 newest survive, in order; the 20 oldest are evicted.
        #expect(history.first?.id == "id-319")
        #expect(history.last?.id == "id-20")
        let ids = Set(history.map(\.id))
        #expect(!ids.contains("id-0"))
        #expect(!ids.contains("id-19"))
        #expect(ids.contains("id-20"))
    }

    @Test("the in-memory store does not apply the 300-entry cap")
    func inMemoryHistoryIsUncapped() async {
        // Documents an asymmetry between the two conformers: `record(_:)` in
        // `InMemoryLibraryStore` never trims, so it can grow past the limit the
        // file store enforces.
        let store = InMemoryLibraryStore()
        for index in 0..<320 {
            await store.record(
                makePoint("id-\(index)", updatedAt: baseDate.addingTimeInterval(Double(index)))
            )
        }
        let history = await store.history()
        #expect(history.count == 320)
    }

    @Test("updateSettings round-trips and persists into a fresh FileLibraryStore")
    func settingsPersistAcrossInstances() async {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let fileURL = directory.appendingPathComponent("library.json")

        let writer = FileLibraryStore(fileURL: fileURL)
        await writer.updateSettings { settings in
            settings.gatewayURL = "http://gateway.test:8080"
            settings.preferredLanguage = "Hindi"
            settings.hiddenRails.insert("Continue Watching")
            settings.hiddenRails.insert("Trending Now")
            settings.categoryOrder = ["Action", "Drama"]
            settings.playbackSpeed = 1.5
            settings.autoPlayNext = false
        }

        let written = await writer.settings()
        #expect(written.gatewayURL == "http://gateway.test:8080")
        #expect(written.preferredLanguage == "Hindi")
        #expect(written.hiddenRails == ["Continue Watching", "Trending Now"])
        #expect(written.categoryOrder == ["Action", "Drama"])
        #expect(written.playbackSpeed == 1.5)
        #expect(!written.autoPlayNext)

        // A second instance over the same file proves the file itself changed,
        // not just the in-memory document.
        let reader = FileLibraryStore(fileURL: fileURL)
        let reloaded = await reader.settings()
        #expect(reloaded == written)
    }

    @Test("watchlist and history survive a fresh FileLibraryStore")
    func libraryPersistsAcrossInstances() async {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let fileURL = directory.appendingPathComponent("library.json")

        let writer = FileLibraryStore(fileURL: fileURL)
        await writer.toggleWatchlist(makeSubject("7", title: "Persisted"))
        await writer.record(makePoint("7", position: 300, duration: 600, updatedAt: baseDate))

        let reader = FileLibraryStore(fileURL: fileURL)
        let saved = await reader.isInWatchlist(subjectID: "7")
        let history = await reader.history()
        #expect(saved)
        #expect(history.count == 1)
        #expect(history.first?.positionSeconds == 300)
        // ISO-8601 carries whole seconds, so a whole-second stamp is exact.
        #expect(history.first?.updatedAt == baseDate)
    }

    @Test("a corrupt library.json yields a clean store instead of throwing")
    func corruptDocument() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("library.json")
        try Data("this is not json {{{".utf8).write(to: fileURL)

        let store = FileLibraryStore(fileURL: fileURL)
        let watchlist = await store.watchlist()
        let history = await store.history()
        let settings = await store.settings()
        #expect(watchlist.isEmpty)
        #expect(history.isEmpty)
        #expect(settings == LibrarySettings())

        // Truncated JSON is treated exactly the same way.
        let truncatedDirectory = uniqueDirectory()
        defer { removeDirectory(truncatedDirectory) }
        try FileManager.default.createDirectory(
            at: truncatedDirectory, withIntermediateDirectories: true
        )
        let truncatedURL = truncatedDirectory.appendingPathComponent("library.json")
        try Data(#"{"watchlist":[{"subject""#.utf8).write(to: truncatedURL)

        let truncated = FileLibraryStore(fileURL: truncatedURL)
        let truncatedWatchlist = await truncated.watchlist()
        let truncatedHistory = await truncated.history()
        #expect(truncatedWatchlist.isEmpty)
        #expect(truncatedHistory.isEmpty)
    }

    @Test("a mutation writes library.json to the expected path")
    func writesAtomically() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let store = FileLibraryStore(directory: directory)
        let fileURL = directory.appendingPathComponent("library.json")

        // Nothing is written until the first mutation.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        await store.toggleWatchlist(makeSubject("1", title: "Atomic"))

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        // `.atomic` writes a sibling temporary file and renames it, so a
        // successful mutation leaves exactly one file behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["library.json"])

        let data = try Data(contentsOf: fileURL)
        #expect(!data.isEmpty)
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(document?["watchlist"] != nil)
        #expect(document?["settings"] != nil)
    }

    @Test("updateSettings on an unreadable file still reports defaults")
    func updateSettingsOnCorruptFile() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("library.json")
        try Data("garbage".utf8).write(to: fileURL)

        let store = FileLibraryStore(fileURL: fileURL)
        await store.updateSettings { $0.playbackSpeed = 2.0 }

        // The corrupt prefix is dropped, not merged; the new write is clean and
        // readable by a fresh instance.
        let reader = FileLibraryStore(fileURL: fileURL)
        let settings = await reader.settings()
        let watchlist = await reader.watchlist()
        #expect(settings.playbackSpeed == 2.0)
        #expect(settings.gatewayURL == nil)
        #expect(watchlist.isEmpty)
    }
}
