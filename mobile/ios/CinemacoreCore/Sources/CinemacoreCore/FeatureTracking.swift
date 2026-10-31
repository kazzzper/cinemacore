import Foundation

/// The product features this build can offer, as a closed registry.
///
/// A typed list rather than free-form strings so a typo in a call site is a
/// compile error, and so the report has a fixed set of rows to compare against:
/// a feature that never appears in the event log is a dead feature, which is
/// the one question this subsystem exists to answer.
public enum Feature: String, CaseIterable, Codable, Sendable {
    // Playback
    case playback
    case resumePlayback
    case autoPlayNext
    case progressivePlayback
    case offlinePlayback
    case subtitlesProvider
    case subtitlesCommunity
    case subtitleSearch
    // Library
    case downloads
    case backgroundDownloads
    case watchlist
    case history
    // Source
    case gatewaySource
    case builtInSource
    case streamHypeSource
    case hevcRepair
    // Player
    case episodePicker
    case seasonSwitcher
    case dubSwitching
    case qualitySelection
    case audioTrackSelection
    case speedControl
    case pictureInPicture
    case airPlay
    case chromecast
    case playerLock
    case edgeGestures
    // Discovery
    case search
    case suggestions
    case categories

    /// The section a feature is reported under.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case playback
        case library
        case source
        case player
        case discovery

        public var displayName: String {
            switch self {
            case .playback: "Playback"
            case .library: "Library"
            case .source: "Source"
            case .player: "Player"
            case .discovery: "Discovery"
            }
        }
    }

    public var displayName: String {
        switch self {
        case .playback: "Playback"
        case .resumePlayback: "Resume playback"
        case .autoPlayNext: "Autoplay next"
        case .progressivePlayback: "Progressive playback"
        case .offlinePlayback: "Offline playback"
        case .subtitlesProvider: "Provider subtitles"
        case .subtitlesCommunity: "Community subtitles"
        case .subtitleSearch: "Subtitle search"
        case .downloads: "Downloads"
        case .backgroundDownloads: "Background downloads"
        case .watchlist: "Watchlist"
        case .history: "History"
        case .gatewaySource: "Gateway source"
        case .builtInSource: "Built-in source"
        case .streamHypeSource: "StreamHype source"
        case .hevcRepair: "HEVC repair"
        case .episodePicker: "Episode picker"
        case .seasonSwitcher: "Season switcher"
        case .dubSwitching: "Dub switching"
        case .qualitySelection: "Quality selection"
        case .audioTrackSelection: "Audio track selection"
        case .speedControl: "Speed control"
        case .pictureInPicture: "Picture in Picture"
        case .airPlay: "AirPlay"
        case .chromecast: "Chromecast"
        case .playerLock: "Player lock"
        case .edgeGestures: "Edge gestures"
        case .search: "Search"
        case .suggestions: "Search suggestions"
        case .categories: "Categories"
        }
    }

    public var category: Category {
        switch self {
        case .playback, .resumePlayback, .autoPlayNext, .progressivePlayback, .offlinePlayback,
             .subtitlesProvider, .subtitlesCommunity, .subtitleSearch:
            .playback
        case .downloads, .backgroundDownloads, .watchlist, .history:
            .library
        case .gatewaySource, .builtInSource, .streamHypeSource, .hevcRepair:
            .source
        case .episodePicker, .seasonSwitcher, .dubSwitching, .qualitySelection,
             .audioTrackSelection, .speedControl, .pictureInPicture, .airPlay, .chromecast,
             .playerLock, .edgeGestures:
            .player
        case .search, .suggestions, .categories:
            .discovery
        }
    }

    /// Chromecast is the only off-by-default feature: the build has no sender,
    /// and an "enabled" row would claim a capability the app cannot honour.
    public var isEnabledByDefault: Bool { self != .chromecast }
}

/// One thing that happened to one feature.
///
/// `detail` is deliberately a short, non-identifying label (a quality name, a
/// language tag). No user ids, titles, or URLs: this file is copied off the
/// device by the debug screen, and a report that names what someone watched is
/// a privacy problem, not telemetry.
public struct FeatureEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case used
        case enabled
        case disabled
        case failed
    }

    public let feature: Feature
    public let kind: Kind
    public let timestamp: Date
    public let detail: String?

    public init(feature: Feature, kind: Kind, timestamp: Date = Date(), detail: String? = nil) {
        self.feature = feature
        self.kind = kind
        self.timestamp = timestamp
        self.detail = detail
    }
}

/// Per-feature totals, so a report does not have to re-scan the event log.
public struct FeatureUsage: Codable, Sendable, Hashable {
    public let feature: Feature
    /// `.used` events only; a failure is not adoption.
    public var useCount: Int
    public var failureCount: Int
    /// First and last activity of any kind — a feature that is switched on and
    /// off but never used is still alive, and hiding that would be wrong.
    public var firstUsed: Date?
    public var lastUsed: Date?

    public init(
        feature: Feature,
        useCount: Int = 0,
        failureCount: Int = 0,
        firstUsed: Date? = nil,
        lastUsed: Date? = nil
    ) {
        self.feature = feature
        self.useCount = useCount
        self.failureCount = failureCount
        self.firstUsed = firstUsed
        self.lastUsed = lastUsed
    }
}

/// One renderable row: the feature, whether it is on, and what it has done.
public struct FeatureSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let feature: Feature
        public let isEnabled: Bool
        public let usage: FeatureUsage

        public var id: String { feature.rawValue }

        public init(feature: Feature, isEnabled: Bool, usage: FeatureUsage) {
            self.feature = feature
            self.isEnabled = isEnabled
            self.usage = usage
        }
    }

    /// Every registered feature, in registry order, so the screen can render a
    /// complete list without a second lookup.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var enabledCount: Int { entries.filter(\.isEnabled).count }

    public var unusedCount: Int { entries.filter { $0.usage.useCount == 0 }.count }

    public func entry(for feature: Feature) -> Entry? {
        entries.first { $0.feature == feature }
    }
}

/// A plain-text rendering of a snapshot.
///
/// Plain text because its two consumers are a monospaced debug view and the
/// clipboard: it survives a paste into a bug report, and it can be asserted on
/// without a snapshot-testing dependency.
public struct FeatureReport: Sendable, Equatable {
    public let snapshot: FeatureSnapshot
    public let generatedAt: Date

    public init(snapshot: FeatureSnapshot, generatedAt: Date = Date()) {
        self.snapshot = snapshot
        self.generatedAt = generatedAt
    }

    public func text() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime]

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        stamp.dateFormat = "yyyy-MM-dd HH:mm"

        let width = max(snapshot.entries.map(\.feature.rawValue.count).max() ?? 0, 7) + 2

        var lines = [
            "Cinemacore feature report",
            "generated \(iso.string(from: generatedAt))",
            "\(snapshot.enabledCount)/\(snapshot.entries.count) enabled · "
                + "\(snapshot.unusedCount) never used",
            "",
        ]

        for category in Feature.Category.allCases {
            let rows = snapshot.entries.filter { $0.feature.category == category }
            guard !rows.isEmpty else { continue }
            lines.append(category.displayName.uppercased())
            lines.append(
                pad("feature", width) + pad("state", 6) + pad("uses", 6)
                    + pad("fails", 7) + "last used"
            )
            for row in rows {
                lines.append(
                    pad(row.feature.rawValue, width)
                        + pad(row.isEnabled ? "on" : "off", 6)
                        + pad(String(row.usage.useCount), 6)
                        + pad(String(row.usage.failureCount), 7)
                        + (row.usage.lastUsed.map { stamp.string(from: $0) } ?? "-")
                )
            }
            lines.append("")
        }

        lines.append("Recorded on this device only. No identifiers, titles, or URLs.")
        return lines.joined(separator: "\n")
    }

    /// Width-pads without ever truncating: a long id must widen its column, not
    /// lose characters the reader needs.
    private func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(text.count, width), withPad: " ", startingAt: 0)
    }
}

/// The on-disk document.
///
/// `enabled` holds only explicit overrides, so a feature that ships on by
/// default stays on when a later build flips the default; the rest of the
/// registry is implied.
private struct FeatureDocument: Codable, Sendable {
    var enabled: [String: Bool] = [:]
    var usage: [String: UsageRecord] = [:]
    var events: [FeatureEvent] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, usage, events }

    /// See ``LibrarySettings/init(from:)``: one missing key must not discard the
    /// whole document, and the document predates any key added since.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent([String: Bool].self, forKey: .enabled)) ?? [:]
        usage = (try? container.decodeIfPresent([String: UsageRecord].self, forKey: .usage)) ?? [:]
        // Lossy per element: a document written by a build that knew a feature
        // this one does not must keep its other events rather than lose them all.
        let rawEvents = (try? container.decodeIfPresent([Lossy<FeatureEvent>].self, forKey: .events)) ?? []
        events = rawEvents.compactMap(\.value)
    }
}

/// Decodes a value, or `nil` when it cannot be decoded, without failing the
/// array that contains it.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct UsageRecord: Codable, Sendable {
    var useCount = 0
    var failureCount = 0
    var firstUsed: Date?
    var lastUsed: Date?

    private enum CodingKeys: String, CodingKey { case useCount, failureCount, firstUsed, lastUsed }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useCount = (try? container.decodeIfPresent(Int.self, forKey: .useCount)) ?? 0
        failureCount = (try? container.decodeIfPresent(Int.self, forKey: .failureCount)) ?? 0
        firstUsed = try? container.decodeIfPresent(Date.self, forKey: .firstUsed)
        lastUsed = try? container.decodeIfPresent(Date.self, forKey: .lastUsed)
    }
}

/// Local, private feature telemetry: what exists, what is on, and what is used.
///
/// An actor, matching ``FileLibraryStore``: every screen and the player can
/// record, and serialising the document behind one owner is cheaper and less
/// error-prone than a lock every call site has to remember. Nothing leaves the
/// device — there is no network path in this type at all.
public actor FeatureTracker {
    private let fileURL: URL
    private let fileManager: FileManager
    private var document: FeatureDocument
    private var isLoaded = false
    private var isDirty = false
    private var pendingWrite: Task<Void, Never>?

    /// The event log is capped so a long-lived install cannot grow without
    /// bound; usage totals live outside the log and stay exact.
    private let eventLimit = 500

    /// Writes are coalesced on a short trailing edge.
    ///
    /// The player ticks four times a second, and every tick that records would
    /// otherwise rewrite the whole document; 400 ms is long enough to collapse a
    /// burst and short enough that a crash loses at most the last few events.
    /// The write itself is atomic, so a kill mid-write cannot corrupt the file.
    private static let persistDelay = Duration.milliseconds(400)

    public init(directory: URL, fileManager: FileManager = .default) {
        fileURL = directory.appendingPathComponent("features.json")
        self.fileManager = fileManager
        document = FeatureDocument()
    }

    // MARK: - Reading

    public func isEnabled(_ feature: Feature) -> Bool {
        load()
        return document.enabled[feature.rawValue] ?? feature.isEnabledByDefault
    }

    public func enabledFeatures() -> [Feature] {
        load()
        return Feature.allCases.filter { document.enabled[$0.rawValue] ?? $0.isEnabledByDefault }
    }

    /// Only features with recorded activity, most used first; the report fills
    /// in the zero rows from the registry.
    public func usage() -> [FeatureUsage] {
        load()
        return document.usage.compactMap { rawValue, record in
            Feature(rawValue: rawValue).map { feature in
                FeatureUsage(
                    feature: feature,
                    useCount: record.useCount,
                    failureCount: record.failureCount,
                    firstUsed: record.firstUsed,
                    lastUsed: record.lastUsed
                )
            }
        }
        .sorted { lhs, rhs in
            lhs.useCount == rhs.useCount
                ? lhs.feature.rawValue < rhs.feature.rawValue
                : lhs.useCount > rhs.useCount
        }
    }

    /// Newest first, capped at `limit`.
    public func events(limit: Int = 50) -> [FeatureEvent] {
        load()
        guard limit > 0 else { return [] }
        return Array(document.events.suffix(limit).reversed())
    }

    public func snapshot() -> FeatureSnapshot {
        load()
        return FeatureSnapshot(entries: Feature.allCases.map { feature in
            let record = document.usage[feature.rawValue]
            return FeatureSnapshot.Entry(
                feature: feature,
                isEnabled: document.enabled[feature.rawValue] ?? feature.isEnabledByDefault,
                usage: FeatureUsage(
                    feature: feature,
                    useCount: record?.useCount ?? 0,
                    failureCount: record?.failureCount ?? 0,
                    firstUsed: record?.firstUsed,
                    lastUsed: record?.lastUsed
                )
            )
        })
    }

    public func report() -> FeatureReport {
        FeatureReport(snapshot: snapshot())
    }

    // MARK: - Writing

    public func record(_ feature: Feature, kind: FeatureEvent.Kind, detail: String? = nil) {
        load()
        append(FeatureEvent(feature: feature, kind: kind, detail: detail))
        schedulePersist()
    }

    public func setEnabled(_ feature: Feature, _ enabled: Bool) {
        load()
        // Storing the default explicitly is harmless and keeps the "off" case
        // representable, which a missing key cannot express.
        document.enabled[feature.rawValue] = enabled
        append(FeatureEvent(feature: feature, kind: enabled ? .enabled : .disabled))
        schedulePersist()
    }

    public func reset() {
        load()
        pendingWrite?.cancel()
        pendingWrite = nil
        document = FeatureDocument()
        isDirty = true
        // Reset is destructive and rare, so it is written through immediately
        // rather than left in the coalescing window.
        persist()
    }

    /// Writes anything the coalescing window is still holding.
    ///
    /// Tests and the debug screen's copy button need the file to be current
    /// without sleeping.
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        persist()
    }

    // MARK: - Internals

    private func append(_ event: FeatureEvent) {
        document.events.append(event)
        if document.events.count > eventLimit {
            document.events.removeFirst(document.events.count - eventLimit)
        }

        var record = document.usage[event.feature.rawValue] ?? UsageRecord()
        switch event.kind {
        case .used: record.useCount += 1
        case .failed: record.failureCount += 1
        case .enabled, .disabled: break
        }
        record.firstUsed = record.firstUsed ?? event.timestamp
        record.lastUsed = event.timestamp
        document.usage[event.feature.rawValue] = record

        isDirty = true
    }

    private func schedulePersist() {
        pendingWrite?.cancel()
        // The delay is a constant: reading an actor property from inside a task
        // that outlives this call would need its own `await` hop for no gain.
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: FeatureTracker.persistDelay)
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        guard isDirty else { return }
        guard let data = try? JSONEncoder.library.encode(document) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // A corrupt or newer document must not take the app down; the registry
        // defaults are a usable empty state.
        guard let decoded = try? JSONDecoder.library.decode(FeatureDocument.self, from: data) else {
            return
        }
        document = decoded
        // Drop rows for features this build does not have, so the report cannot
        // show a row with no name and no toggle.
        document.enabled = document.enabled.filter { Feature(rawValue: $0.key) != nil }
        document.usage = document.usage.filter { Feature(rawValue: $0.key) != nil }
    }
}
