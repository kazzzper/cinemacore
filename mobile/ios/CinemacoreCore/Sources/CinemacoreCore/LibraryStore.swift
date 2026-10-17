import Foundation

/// Persistent user state: watchlist, resume positions, and settings.
///
/// Kept behind a protocol so screens are testable without touching the disk,
/// and implemented on `Foundation` only so it runs under `swift test` on Linux.
/// Secrets never live here — the library holds catalog state, nothing more.
public protocol LibraryStoring: Sendable {
    func watchlist() async -> [WatchlistEntry]
    func isInWatchlist(subjectID: String) async -> Bool
    /// Toggling keeps the UI's single "bookmark" affordance honest.
    func toggleWatchlist(_ subject: Subject) async -> Bool
    func removeFromWatchlist(subjectID: String) async
    func clearWatchlist() async

    func history() async -> [ResumePoint]
    func resumePoint(for id: String) async -> ResumePoint?
    /// Records playback progress, ignoring non-resumable positions.
    func record(_ point: ResumePoint) async
    func removeHistory(id: String) async
    func clearHistory() async

    func settings() async -> LibrarySettings
    func updateSettings(_ transform: @Sendable (inout LibrarySettings) -> Void) async
}

/// User-adjustable settings. Mirrors the Android app's `PreferencesManager`
/// surface, minus the reverse-engineering knobs the Lab screen hides.
public struct LibrarySettings: Codable, Hashable, Sendable {
    /// Base URL of the Cinemacore gateway. `nil` uses the bundled catalog.
    public var gatewayURL: String?
    /// Preferred dub language label, when the title offers it.
    public var preferredLanguage: String?
    /// Rail titles the user hid on Home.
    public var hiddenRails: Set<String>
    /// Order of the user's own categories, mirroring Manage Categories.
    public var categoryOrder: [String]
    /// Playback speed persisted across sessions.
    public var playbackSpeed: Double
    /// Autoplay the next episode when one finishes.
    public var autoPlayNext: Bool

    public init(
        gatewayURL: String? = nil,
        preferredLanguage: String? = nil,
        hiddenRails: Set<String> = [],
        categoryOrder: [String] = [],
        playbackSpeed: Double = 1.0,
        autoPlayNext: Bool = true
    ) {
        self.gatewayURL = gatewayURL
        self.preferredLanguage = preferredLanguage
        self.hiddenRails = hiddenRails
        self.categoryOrder = categoryOrder
        self.playbackSpeed = playbackSpeed
        self.autoPlayNext = autoPlayNext
    }

    /// The default gateway probed at launch when the user has not chosen one.
    public static let defaultGatewayURL = "http://127.0.0.1:8080"
}

/// The on-disk document. One file keeps the write path atomic and the whole
/// state trivially inspectable.
private struct LibraryDocument: Codable, Sendable {
    var watchlist: [WatchlistEntry] = []
    var history: [ResumePoint] = []
    var settings = LibrarySettings()
}

/// JSON-file backed ``LibraryStoring``.
///
/// An actor because every screen can mutate it; writes are coalesced behind a
/// single serialized context rather than scattered across call sites.
public actor FileLibraryStore: LibraryStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private var document: LibraryDocument
    private var isLoaded = false

    /// History is capped so a long-lived install cannot grow without bound.
    private let historyLimit = 300

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.document = LibraryDocument()
    }

    public init(directory: URL, fileManager: FileManager = .default) {
        self.init(
            fileURL: directory.appendingPathComponent("library.json"),
            fileManager: fileManager
        )
    }

    // MARK: - Watchlist

    public func watchlist() -> [WatchlistEntry] {
        load()
        return document.watchlist.sorted { $0.addedAt > $1.addedAt }
    }

    public func isInWatchlist(subjectID: String) -> Bool {
        load()
        return document.watchlist.contains { $0.subject.id == subjectID }
    }

    @discardableResult
    public func toggleWatchlist(_ subject: Subject) -> Bool {
        load()
        if let index = document.watchlist.firstIndex(where: { $0.subject.id == subject.id }) {
            document.watchlist.remove(at: index)
            persist()
            return false
        }
        document.watchlist.append(WatchlistEntry(subject: subject))
        persist()
        return true
    }

    public func removeFromWatchlist(subjectID: String) {
        load()
        document.watchlist.removeAll { $0.subject.id == subjectID }
        persist()
    }

    public func clearWatchlist() {
        load()
        document.watchlist.removeAll()
        persist()
    }

    // MARK: - History

    public func history() -> [ResumePoint] {
        load()
        return document.history.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func resumePoint(for id: String) -> ResumePoint? {
        load()
        return document.history.first { $0.id == id }
    }

    public func record(_ point: ResumePoint) {
        load()
        guard point.isResumable else {
            // A finished title should stop offering to resume, so drop the row
            // rather than persisting a 99%-complete position.
            document.history.removeAll { $0.id == point.id }
            persist()
            return
        }
        if let index = document.history.firstIndex(where: { $0.id == point.id }) {
            document.history[index] = point
        } else {
            document.history.append(point)
        }
        if document.history.count > historyLimit {
            document.history.sort { $0.updatedAt > $1.updatedAt }
            document.history.removeLast(document.history.count - historyLimit)
        }
        persist()
    }

    public func removeHistory(id: String) {
        load()
        document.history.removeAll { $0.id == id }
        persist()
    }

    public func clearHistory() {
        load()
        document.history.removeAll()
        persist()
    }

    // MARK: - Settings

    public func settings() -> LibrarySettings {
        load()
        return document.settings
    }

    public func updateSettings(_ transform: @Sendable (inout LibrarySettings) -> Void) {
        load()
        transform(&document.settings)
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // A corrupt or older document must not take the app down; start clean.
        guard let decoded = try? JSONDecoder.library.decode(LibraryDocument.self, from: data) else {
            return
        }
        document = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.library.encode(document) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Non-persistent store for tests and SwiftUI previews.
public actor InMemoryLibraryStore: LibraryStoring {
    private var document = LibraryDocument()

    public init(settings: LibrarySettings = LibrarySettings()) {
        document.settings = settings
    }

    public func watchlist() -> [WatchlistEntry] {
        document.watchlist.sorted { $0.addedAt > $1.addedAt }
    }

    public func isInWatchlist(subjectID: String) -> Bool {
        document.watchlist.contains { $0.subject.id == subjectID }
    }

    @discardableResult
    public func toggleWatchlist(_ subject: Subject) -> Bool {
        if let index = document.watchlist.firstIndex(where: { $0.subject.id == subject.id }) {
            document.watchlist.remove(at: index)
            return false
        }
        document.watchlist.append(WatchlistEntry(subject: subject))
        return true
    }

    public func removeFromWatchlist(subjectID: String) {
        document.watchlist.removeAll { $0.subject.id == subjectID }
    }

    public func clearWatchlist() { document.watchlist.removeAll() }

    public func history() -> [ResumePoint] {
        document.history.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func resumePoint(for id: String) -> ResumePoint? {
        document.history.first { $0.id == id }
    }

    public func record(_ point: ResumePoint) {
        guard point.isResumable else {
            document.history.removeAll { $0.id == point.id }
            return
        }
        if let index = document.history.firstIndex(where: { $0.id == point.id }) {
            document.history[index] = point
        } else {
            document.history.append(point)
        }
    }

    public func removeHistory(id: String) { document.history.removeAll { $0.id == id } }
    public func clearHistory() { document.history.removeAll() }

    public func settings() -> LibrarySettings { document.settings }

    public func updateSettings(_ transform: @Sendable (inout LibrarySettings) -> Void) {
        transform(&document.settings)
    }
}

extension JSONEncoder {
    static let library: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let library: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
