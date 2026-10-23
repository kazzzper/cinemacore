import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a download sits in its lifecycle.
public enum DownloadStatus: String, Codable, Sendable, CaseIterable {
    case queued, downloading, paused, completed, failed

    /// User-facing label, also the section title when the list is grouped by
    /// status.
    public var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    /// Presentation order: what is happening now first, what is settled last.
    /// Not the declaration order, which only exists for `Codable`.
    var rank: Int {
        switch self {
        case .downloading: 0
        case .queued: 1
        case .paused: 2
        case .failed: 3
        case .completed: 4
        }
    }
}

/// One queued, in-flight or finished download.
public struct DownloadItem: Identifiable, Codable, Hashable, Sendable {
    /// Stable across relaunches: `"<subjectID>-s<S>e<E>-<quality>"` (a movie
    /// omits the season and episode).
    public let id: String
    public let subjectID: String
    public let title: String
    public let poster: String?
    public let season: Int?
    public let episode: Int?
    public let episodeTitle: String?
    public let quality: String
    public let remoteURL: URL
    public let cookie: String?
    /// What the URL points at. A manifest is not a file; the engine must route
    /// HLS and DASH to a container downloader rather than renaming a playlist.
    public let container: MediaContainer
    /// 1 is the legacy chunked-file layout; 2 is the planned container layout.
    /// Older documents default to 1 so a playlist saved by a previous build can
    /// be repaired once without demoting a real container download later.
    public var layoutVersion: Int
    /// Identifies one background transfer generation. A pause keeps it so the
    /// daemon's staged chunks stay valid; a cancel rotates it so late events
    /// from the old generation are ignored.
    public var transferEpoch: UUID?
    public var status: DownloadStatus
    public var totalBytes: Int64
    public var bytesWritten: Int64
    public var attempts: Int
    public var failure: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Final file name, no directory. Set by the caller so the extension can
    /// match the container (`.mp4` today).
    public var localFileName: String
    /// Caption tracks saved beside the file when it finished.
    ///
    /// Filled after the media lands, so an episode plays with its subtitles and
    /// no connection. Empty is the normal state for a title that has none, and
    /// the reason the field decodes tolerantly.
    public var subtitles: [DownloadedSubtitle]

    public init(
        id: String,
        subjectID: String,
        title: String,
        poster: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodeTitle: String? = nil,
        quality: String,
        remoteURL: URL,
        cookie: String? = nil,
        container: MediaContainer = .mp4,
        layoutVersion: Int = 2,
        transferEpoch: UUID? = nil,
        status: DownloadStatus = .queued,
        totalBytes: Int64 = 0,
        bytesWritten: Int64 = 0,
        attempts: Int = 0,
        failure: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        localFileName: String,
        subtitles: [DownloadedSubtitle] = []
    ) {
        self.id = id
        self.subjectID = subjectID
        self.title = title
        self.poster = poster
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.quality = quality
        self.remoteURL = remoteURL
        self.cookie = cookie
        self.container = container
        self.layoutVersion = layoutVersion
        self.transferEpoch = transferEpoch
        self.status = status
        self.totalBytes = totalBytes
        self.bytesWritten = bytesWritten
        self.attempts = attempts
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.localFileName = localFileName
        self.subtitles = subtitles
    }

    private enum CodingKeys: String, CodingKey {
        case id, subjectID, title, poster, season, episode, episodeTitle, quality,
             remoteURL, cookie, container, layoutVersion, transferEpoch, status, totalBytes,
             bytesWritten, attempts, failure, createdAt, updatedAt, localFileName, subtitles
    }

    /// Tolerant decoding, for the reason ``LibrarySettings/init(from:)`` gives:
    /// a queue written by an older build is missing the keys added since, and
    /// one absent key must not discard the user's downloads. Only `id`,
    /// `remoteURL` and the identity of the item are unrecoverable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subjectID = try container.decodeIfPresent(String.self, forKey: .subjectID) ?? id
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)
        episodeTitle = try container.decodeIfPresent(String.self, forKey: .episodeTitle)
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? ""
        remoteURL = try container.decode(URL.self, forKey: .remoteURL)
        cookie = try container.decodeIfPresent(String.self, forKey: .cookie)
        self.container = try container.decodeIfPresent(MediaContainer.self, forKey: .container)
            ?? MediaContainer.classify(url: remoteURL)
        layoutVersion = try container.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 1
        transferEpoch = try container.decodeIfPresent(UUID.self, forKey: .transferEpoch)
        status = try container.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .queued
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        bytesWritten = try container.decodeIfPresent(Int64.self, forKey: .bytesWritten) ?? 0
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        localFileName = try container.decodeIfPresent(String.self, forKey: .localFileName)
            ?? DownloadItem.defaultLocalFileName(for: id, container: self.container)
        subtitles = try container.decodeIfPresent([DownloadedSubtitle].self, forKey: .subtitles) ?? []
    }

    /// The name a download falls back to when the document predates
    /// `localFileName`. Progressive MP4 is the only container the legacy
    /// downloader could finish, so `.mp4` remains the safe default for a row
    /// written by an older build.
    static func defaultLocalFileName(for id: String) -> String {
        defaultLocalFileName(for: id, container: .mp4)
    }

    static func defaultLocalFileName(for id: String, container: MediaContainer) -> String {
        "\(sanitise(id)).\(container.assetExtension)"
    }

    /// Provider ids contain `-` and `.` but never a path separator; stripping
    /// separators keeps a hostile id from escaping the downloads directory.
    static func sanitise(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// 0...1, and 0 while the total is unknown so a bar never jumps to 100%.
    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesWritten) / Double(totalBytes), 0), 1)
    }

    public var isFinished: Bool { status == .completed }

    /// A manifest describes other files; it is never a playable offline asset
    /// on its own.
    public var isManifestDownload: Bool { container.isManifest }

    public var isActive: Bool { status == .downloading }

    public var canResume: Bool {
        status == .queued || status == .paused || status == .failed
    }

    /// `"S2 E4"`, or `nil` for a movie.
    public var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return "S\(season) E\(episode)"
    }

    public var remainingBytes: Int64 { max(totalBytes - bytesWritten, 0) }

    /// `"1.4 GB"`, or `nil` while the size is unknown.
    public var sizeText: String? {
        guard totalBytes > 0 else { return nil }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(totalBytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? "\(totalBytes) B"
            : String(format: "%.1f", value) + " " + units[unit]
    }
}

/// How the Downloads list is ordered.
public enum DownloadSortKey: String, Codable, Sendable, CaseIterable, Identifiable {
    case dateAdded, title, size, progress, status

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dateAdded: "Date Added"
        case .title: "Title"
        case .size: "Size"
        case .progress: "Progress"
        case .status: "Status"
        }
    }
}

public struct DownloadSortOrder: Codable, Hashable, Sendable {
    public var key: DownloadSortKey
    public var ascending: Bool

    public init(key: DownloadSortKey = .dateAdded, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }
}

/// How the Downloads list is split into sections.
public enum DownloadGrouping: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, title, status

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .title: "Title"
        case .status: "Status"
        }
    }
}

public struct DownloadSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let items: [DownloadItem]
}

/// Ordering and grouping for the Downloads list.
///
/// Every comparator is total: equal keys fall through to the item id, so the
/// list cannot jitter between two equal elements from one render to the next.
public enum DownloadList {

    public static func sorted(
        _ items: [DownloadItem],
        by order: DownloadSortOrder
    ) -> [DownloadItem] {
        let ascending = items.sorted { precedes($0, $1, by: order.key) }
        // `descending` is exactly `!ascending`, ties included, so a reversed
        // order is the mirror of the forward one rather than a second ranking.
        return order.ascending ? ascending : ascending.reversed()
    }

    public static func grouped(
        _ items: [DownloadItem],
        by grouping: DownloadGrouping,
        order: DownloadSortOrder
    ) -> [DownloadSection] {
        // No items, no sections: an empty "All" header is not a state a screen
        // can render, and the two other groupings already collapse to nothing.
        guard !items.isEmpty else { return [] }

        switch grouping {
        case .none:
            return [DownloadSection(id: "all", title: "All", items: sorted(items, by: order))]

        case .title:
            var buckets: [String: [DownloadItem]] = [:]
            for item in items {
                buckets[item.title, default: []].append(item)
            }
            return buckets.keys
                .sorted { titleOrder($0, $1) == .orderedAscending }
                .map { title in
                    DownloadSection(
                        id: title,
                        title: title,
                        items: sorted(buckets[title] ?? [], by: order)
                    )
                }

        case .status:
            return DownloadStatus.allCases
                .sorted { $0.rank < $1.rank }
                .compactMap { status in
                    let members = items.filter { $0.status == status }
                    guard !members.isEmpty else { return nil }
                    return DownloadSection(
                        id: status.rawValue,
                        title: status.label,
                        items: sorted(members, by: order)
                    )
                }
        }
    }

    private static func precedes(
        _ lhs: DownloadItem,
        _ rhs: DownloadItem,
        by key: DownloadSortKey
    ) -> Bool {
        switch key {
        case .dateAdded:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        case .title:
            let order = titleOrder(lhs.title, rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
            // The spec's tie-break for equal titles.
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        case .size:
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes < rhs.totalBytes }
        case .progress:
            if lhs.progress != rhs.progress { return lhs.progress < rhs.progress }
        case .status:
            if lhs.status.rank != rhs.status.rank { return lhs.status.rank < rhs.status.rank }
        }
        return lhs.id < rhs.id
    }

    /// Case-insensitive, but never `.orderedSame` for two different strings:
    /// `"A"` and `"a"` must still have a defined order between them.
    private static func titleOrder(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        if left != right { return left < right ? .orderedAscending : .orderedDescending }
        if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}

/// What a `HEAD` (or one-byte ranged `GET`) says about a remote file.
public struct RemoteFileInfo: Hashable, Sendable {
    public let totalBytes: Int64
    public let supportsRanges: Bool

    public init(totalBytes: Int64, supportsRanges: Bool) {
        self.totalBytes = totalBytes
        self.supportsRanges = supportsRanges
    }
}

/// The seam that makes the engine testable on Linux.
///
/// The stream's failure is `any Error`, not `CinemacoreError`: the standard
/// library only exposes `AsyncThrowingStream`'s constructing initializers and
/// `makeStream` under `where Failure == any Error`, so a stream with a concrete
/// failure type cannot be built at all. The eager call still throws
/// `CinemacoreError` only, and the engine funnels every mid-stream failure back
/// through the same `isRetryable` policy, so nothing downstream can tell.
public protocol DownloadTransport: Sendable {
    func probe(url: URL, headers: [String: String]) async throws(CinemacoreError) -> RemoteFileInfo
    /// Streams bytes from `from` (inclusive) to the end. Throwing mid-stream is
    /// what a network jitter looks like; the engine must resume from the last
    /// committed offset rather than restarting.
    func content(
        url: URL,
        headers: [String: String],
        from: Int64
    ) async throws(CinemacoreError) -> AsyncThrowingStream<Data, any Error>
}

public struct DownloadConfiguration: Sendable {
    /// Items allowed to be `.downloading` at once.
    public var maxConcurrent: Int
    /// Attempts per item before it is marked `.failed`.
    public var maxAttempts: Int
    /// First retry delay; doubles per attempt up to `maxBackoff`.
    public var initialBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    /// Bytes between two queue writes. Never per byte: a film would rewrite the
    /// JSON thousands of times a second.
    public var progressFlushBytes: Int64

    public init(
        maxConcurrent: Int = 3,
        maxAttempts: Int = 5,
        initialBackoff: TimeInterval = 1.0,
        maxBackoff: TimeInterval = 30,
        progressFlushBytes: Int64 = 1 << 20
    ) {
        self.maxConcurrent = maxConcurrent
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.progressFlushBytes = progressFlushBytes
    }
}

/// The queue, its scheduler and its on-disk state.
///
/// An actor because every screen can mutate it and every item runs
/// concurrently; the scheduler never lets more than `maxConcurrent` items be
/// `.downloading`, and a runner that dies mid-stream resumes from the bytes
/// already committed to the `.part` file.
public actor DownloadEngine {
    private let directory: URL
    private let transport: any DownloadTransport
    private let configuration: DownloadConfiguration
    private let transfer: (any BackgroundTransferring)?
    private let backgroundConfiguration: BackgroundTransferConfiguration
    private let fileManager = FileManager.default
    /// Resolves the caption tracks a finished item should keep. Injected by the
    /// app because it needs the catalog repository, which the queue has no
    /// business knowing about.
    private var captionProvider: (@Sendable (DownloadItem) async -> [DownloadedSubtitle])?

    private var queue: [DownloadItem] = []
    private var isLoaded = false
    private var isRunning = false
    /// Items with a live runner. The single source of truth for the concurrency
    /// limit: an item is `.downloading` in the queue exactly while it is here.
    private var active: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<[DownloadItem]>.Continuation] = [:]
    /// Runtime hint only, never persisted: a server that cannot resume would
    /// otherwise be re-probed — and re-downloaded from zero — on every attempt.
    private var rangeSupport: [String: Bool] = [:]
    /// Items a relaunch demoted from `.downloading`. They are the only paused
    /// rows whose still-running daemon tasks should be reattached.
    private var interrupted: Set<String> = []
    private var transferPump: Task<Void, Never>?
    private var transferWaiters: [String: AsyncStream<TransferEvent>.Continuation] = [:]
    private var transferWaiterTokens: [String: UUID] = [:]
    private var didReconcile = false
    /// Last launch reconciliation, so the app can log a concrete outcome.
    public private(set) var reconcileReport = ReconcileReport()

    public init(
        directory: URL,
        transport: any DownloadTransport,
        configuration: DownloadConfiguration = .init(),
        transfer: (any BackgroundTransferring)? = nil,
        backgroundConfiguration: BackgroundTransferConfiguration = .init()
    ) {
        self.directory = directory
        self.transport = transport
        self.configuration = configuration
        self.transfer = transfer
        self.backgroundConfiguration = backgroundConfiguration
    }

    private var stagingRoot: URL {
        directory.appendingPathComponent(".staging", isDirectory: true)
    }

    private var documentURL: URL { directory.appendingPathComponent("downloads.json") }

    // MARK: - Reading

    public func load() async -> [DownloadItem] {
        ensureLoaded()
        return queue
    }

    public func items() async -> [DownloadItem] {
        ensureLoaded()
        return queue
    }

    public func item(_ id: String) async -> DownloadItem? {
        ensureLoaded()
        return queue.first { $0.id == id }
    }

    /// Emits the whole list on every observable change and finishes when the
    /// consumer's task is cancelled.
    public func updates() -> AsyncStream<[DownloadItem]> {
        ensureLoaded()
        let token = UUID()
        return AsyncStream { continuation in
            continuations[token] = continuation
            continuation.yield(queue)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(token) }
            }
        }
    }

    // MARK: - Paths

    public nonisolated func fileURL(for item: DownloadItem) -> URL {
        directory.appendingPathComponent(item.localFileName)
    }

    /// The caption tracks this download carries, as pickable tracks.
    ///
    /// Answerable without the actor: the paths are a pure function of the item
    /// and the directory, and the player asks on the main actor while it builds
    /// the payload it is about to play.
    public nonisolated func subtitleTracks(for item: DownloadItem) -> [SubtitleTrack] {
        item.subtitles.map { $0.track(in: directory) }
    }

    /// `"<name>.part"`. A `.part` file is never valid to hand a player.
    public nonisolated func partialURL(for item: DownloadItem) -> URL {
        directory.appendingPathComponent(item.localFileName + ".part")
    }

    public func bytesOnDisk() async -> Int64 {
        ensureLoaded()
        var total = queue.reduce(into: Int64(0)) { total, item in
            total += fileSize(fileURL(for: item))
            total += fileSize(partialURL(for: item))
        }
        // Staged chunks are real bytes on disk until the contiguous prefix
        // absorbs them, so omitting them would under-report storage pressure.
        total += fileSize(stagingRoot)
        return total
    }

    // MARK: - Mutation

    /// Adds items whose id is not already queued. Returns how many were added;
    /// a duplicate is skipped, never replaced.
    @discardableResult
    public func enqueue(_ items: [DownloadItem]) async -> Int {
        ensureLoaded()
        var added = 0
        for item in items {
            guard !queue.contains(where: { $0.id == item.id }) else { continue }
            queue.append(item)
            added += 1
        }
        guard added > 0 else { return 0 }
        persist()
        emit()
        schedule()
        return added
    }

    /// Begins, or restarts, the scheduler. Calling it twice is a no-op for items
    /// that already have a runner.
    public func start() async {
        ensureLoaded()
        isRunning = true
        ensureTransferPump()
        await reconcileOnce()
        schedule()
    }

    public func pause(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].status == .downloading || queue[index].status == .queued else { return }
        stopTask(id)
        interrupted.remove(id)
        queue[index].status = .paused
        queue[index].updatedAt = Date()
        persist()
        emit()
        if let transfer { await transfer.pause(itemID: id) }
    }

    public func pauseAll() async {
        ensureLoaded()
        var changed = false
        var paused: [String] = []
        for index in queue.indices
        where queue[index].status == .downloading || queue[index].status == .queued {
            stopTask(queue[index].id)
            interrupted.remove(queue[index].id)
            queue[index].status = .paused
            queue[index].updatedAt = Date()
            paused.append(queue[index].id)
            changed = true
        }
        guard changed else { return }
        persist()
        emit()
        if let transfer {
            for id in paused { await transfer.pause(itemID: id) }
        }
    }

    /// Queues a paused, failed or waiting item and lets the scheduler pick it
    /// up; a failed item's attempt budget is reset so it can actually succeed.
    public func resume(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].canResume else { return }
        interrupted.remove(id)
        queue[index].status = .queued
        queue[index].failure = nil
        queue[index].updatedAt = Date()
        isRunning = true
        persist()
        emit()
        schedule()
    }

    public func resumeAll() async {
        ensureLoaded()
        var changed = false
        for index in queue.indices where queue[index].canResume {
            interrupted.remove(queue[index].id)
            queue[index].status = .queued
            queue[index].failure = nil
            queue[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        isRunning = true
        persist()
        emit()
        schedule()
    }

    /// Starts a finished-or-stalled item over. Keeps the bytes already on disk:
    /// a retry is another attempt, not a reason to re-download a prefix.
    public func retry(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].status != .completed, queue[index].status != .downloading else { return }
        interrupted.remove(id)
        queue[index].attempts = 0
        queue[index].failure = nil
        queue[index].status = .queued
        queue[index].updatedAt = Date()
        isRunning = true
        persist()
        emit()
        schedule()
    }

    /// Stops an item and drops its partial file. The row stays, paused, and can
    /// be resumed from zero.
    public func cancel(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].status != .completed else { return }
        stopTask(id)
        interrupted.remove(id)
        try? fileManager.removeItem(at: partialURL(for: queue[index]))
        rangeSupport[id] = nil
        // A fresh epoch makes every event still in flight from the old
        // generation unrecognisable, so a late chunk cannot land in a new run.
        queue[index].transferEpoch = UUID()
        queue[index].status = .paused
        queue[index].bytesWritten = 0
        queue[index].failure = nil
        queue[index].updatedAt = Date()
        persist()
        emit()
        if let transfer { await transfer.cancel(itemID: id) }
        try? fileManager.removeItem(
            at: TransferStaging.itemRoot(root: stagingRoot, itemID: id)
        )
    }

    /// Supplies the caption tracks a finished download should keep.
    ///
    /// Captions live on a different endpoint and are best effort: the lookup
    /// runs once the media is already saved, so a host that is down costs the
    /// subtitles and never the episode.
    public func setCaptionProvider(
        _ provider: (@Sendable (DownloadItem) async -> [DownloadedSubtitle])?
    ) {
        captionProvider = provider
    }

    public func remove(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        stopTask(id)
        interrupted.remove(id)
        let item = queue.remove(at: index)
        try? fileManager.removeItem(at: partialURL(for: item))
        try? fileManager.removeItem(at: fileURL(for: item))
        removeSubtitleFiles(for: item)
        rangeSupport[id] = nil
        persist()
        emit()
        if let transfer { await transfer.cancel(itemID: id) }
        try? fileManager.removeItem(
            at: TransferStaging.itemRoot(root: stagingRoot, itemID: id)
        )
    }

    public func removeCompleted() async {
        ensureLoaded()
        let finished = queue.filter { $0.status == .completed }
        guard !finished.isEmpty else { return }
        for item in finished {
            try? fileManager.removeItem(at: fileURL(for: item))
            removeSubtitleFiles(for: item)
            try? fileManager.removeItem(
                at: TransferStaging.itemRoot(root: stagingRoot, itemID: item.id)
            )
            rangeSupport[item.id] = nil
        }
        queue.removeAll { $0.status == .completed }
        persist()
        emit()
    }

    public func removeAll() async {
        ensureLoaded()
        let removed = queue
        for item in removed {
            stopTask(item.id)
            try? fileManager.removeItem(at: partialURL(for: item))
            try? fileManager.removeItem(at: fileURL(for: item))
            removeSubtitleFiles(for: item)
        }
        rangeSupport.removeAll()
        interrupted.removeAll()
        queue.removeAll()
        persist()
        emit()
        if let transfer {
            for item in removed { await transfer.cancel(itemID: item.id) }
        }
        try? fileManager.removeItem(at: stagingRoot)
    }

    // MARK: - Scheduling

    private func schedule() {
        guard isRunning else { return }
        let limit = max(1, configuration.maxConcurrent)
        var promoted = false
        while active.count < limit {
            // A queued item whose runner is still unwinding from a cancellation
            // is skipped; that runner's defer schedules again.
            guard let index = queue.firstIndex(where: { $0.status == .queued && tasks[$0.id] == nil })
            else { break }
            let id = queue[index].id
            queue[index].status = .downloading
            queue[index].updatedAt = Date()
            promoted = true
            startTask(id)
        }
        guard promoted else { return }
        persist()
        emit()
    }

    private func startTask(_ id: String) {
        guard tasks[id] == nil else { return }
        active.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.runItem(id)
        }
    }

    private func stopTask(_ id: String) {
        // The slot is released by the runner's own defer, so the engine never
        // has to guess when the item stopped touching the disk.
        tasks[id]?.cancel()
        // Ending the waiter wakes a runner that is parked on an event that will
        // never arrive after the daemon task was cancelled.
        finishWaiter(id)
    }

    private func taskFinished(_ id: String) {
        tasks[id] = nil
        active.remove(id)
        schedule()
    }

    private func runItem(_ id: String) async {
        defer { taskFinished(id) }
        while !Task.isCancelled {
            guard let current = queue.first(where: { $0.id == id }), current.status == .downloading
            else { return }
            do {
                let classified = MediaContainer.classify(url: current.remoteURL)
                let container = classified == .unknown ? current.container : classified
                if transfer != nil, container.isDirectDownload {
                    try await attemptBackground(id)
                } else {
                    try await attempt(id)
                }
                // A completed item must not leave daemon tasks or staged chunks
                // behind, especially when a whole-file 200 made the rest of the
                // planned ranges redundant.
                if let transfer { await transfer.cancel(itemID: id) }
                complete(id)
                return
            } catch let failure as AttemptFailure {
                if Task.isCancelled {
                    persist()
                    return
                }
                if case .rangeIgnored = failure, let transfer {
                    // Every ranged task in this generation asked for bytes the
                    // server is about to resend as one body; cancel them before
                    // the retry so they cannot race the fresh prefix.
                    await transfer.cancel(itemID: id)
                }
                guard recover(failure, id: id) else {
                    // A terminal failure stops the wire but keeps the staged
                    // chunks and .part for a later retry.
                    if let transfer { await transfer.pause(itemID: id) }
                    return
                }
                // A restart after an ignored range spends no attempt, so it also
                // waits no backoff.
                let spent = queue.first(where: { $0.id == id })?.attempts ?? 0
                let delay = spent > 0 ? backoff(afterAttempt: spent) : 0
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            } catch is CancellationError {
                persist()
                return
            } catch {
                fail(id, with: .transport(error))
                if let transfer { await transfer.pause(itemID: id) }
                return
            }
        }
    }

    /// One attempt at the wire. Every failure leaves the committed bytes on disk
    /// untouched, so the next attempt can pick them up.
    private func attempt(_ id: String) async throws {
        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            throw AttemptFailure.transport(.cancelled)
        }
        let remoteURL = queue[index].remoteURL
        let classified = MediaContainer.classify(url: remoteURL)
        let container = classified == .unknown ? queue[index].container : classified
        // A manifest is a recipe, not a file. Until the container downloader
        // owns this item, failing before the first byte is the only outcome
        // that cannot leave an unplayable playlist marked completed.
        guard container.isDirectDownload else {
            throw AttemptFailure.transport(.http(
                status: 415,
                code: "unsupported_container",
                message: "The \(container.displayName) downloader is not enabled in this build."
            ))
        }
        let headers = MediaRequest.headers(cookie: queue[index].cookie)
        let partial = partialURL(for: queue[index])
        let destination = fileURL(for: queue[index])

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: partial.path) {
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw AttemptFailure.transport(.upstream("Could not create the download file."))
            }
        }

        // The file is the last committed offset, not the in-memory counter: a
        // chunk written after the last flush is still real data.
        var offset = fileSize(partial)
        queue[index].bytesWritten = offset

        if rangeSupport[id] == nil, offset > 0 || queue[index].totalBytes <= 0 {
            let info: RemoteFileInfo
            do {
                info = try await transport.probe(url: remoteURL, headers: headers)
            } catch {
                throw attempted(error, from: offset)
            }
            // Everything below runs after a suspension, so the queue may have
            // changed under us: the index has to be looked up again.
            if Task.isCancelled { throw CancellationError() }
            guard let current = queue.firstIndex(where: { $0.id == id }),
                  queue[current].status == .downloading
            else { throw CancellationError() }
            rangeSupport[id] = info.supportsRanges
            if info.totalBytes > 0 { queue[current].totalBytes = info.totalBytes }
        }

        // A server that cannot resume must not have our prefix glued to a fresh
        // copy of the whole file.
        if offset > 0, rangeSupport[id] == false {
            guard let current = queue.firstIndex(where: { $0.id == id }),
                  queue[current].status == .downloading
            else { throw CancellationError() }
            try restart(partial)
            offset = 0
            queue[current].bytesWritten = 0
        }

        let stream: AsyncThrowingStream<Data, any Error>
        do {
            stream = try await transport.content(url: remoteURL, headers: headers, from: offset)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw attempted(error, from: offset)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
        } catch {
            throw AttemptFailure.transport(.upstream("Could not open the download file."))
        }
        defer { try? handle.close() }

        let flushBytes = max(1, configuration.progressFlushBytes)
        var sinceFlush: Int64 = 0
        do {
            for try await chunk in stream {
                if Task.isCancelled { throw CancellationError() }
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                guard let current = queue.firstIndex(where: { $0.id == id }),
                      queue[current].status == .downloading
                else { throw CancellationError() }
                queue[current].bytesWritten = offset
                sinceFlush += Int64(chunk.count)
                if sinceFlush >= flushBytes {
                    sinceFlush = 0
                    persist()
                    emit()
                }
            }
        } catch let error as CinemacoreError {
            if Task.isCancelled { throw CancellationError() }
            throw attempted(error, from: offset)
        } catch is CancellationError {
            persist()
            throw CancellationError()
        } catch {
            throw AttemptFailure.transport(.transport(error))
        }

        if Task.isCancelled {
            persist()
            throw CancellationError()
        }
        guard let current = queue.firstIndex(where: { $0.id == id }),
              queue[current].status == .downloading
        else {
            persist()
            throw CancellationError()
        }
        // A stream that ends without an error is still a truncated file when the
        // server promised more bytes than it delivered.
        if queue[current].totalBytes > 0, offset < queue[current].totalBytes {
            persist()
            throw AttemptFailure.transport(
                .upstream("The connection closed before the download finished.")
            )
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            throw AttemptFailure.transport(.upstream("Could not finish the download file."))
        }
        queue[current].bytesWritten = offset
        if queue[current].totalBytes <= 0 { queue[current].totalBytes = offset }
    }

    // MARK: - Background transfer

    private func ensureTransferPump() {
        guard transfer != nil, transferPump == nil else { return }
        guard let transfer else { return }
        // Detached so the pump is not tied to whichever actor-isolated call
        // started it, and weak so the stream cannot keep the engine alive.
        transferPump = Task.detached { [weak self] in
            for await event in transfer.events() {
                guard let self else { return }
                await self.route(event)
            }
        }
    }

    private func route(_ event: TransferEvent) {
        switch event {
        case .sessionDisconnected, .sessionReconnected:
            // The daemon dropping its connection is not an item failure: the
            // per-item waiter and the staged files remain authoritative.
            return
        case .progress(let key, _, _), .finished(let key, _, _), .failed(let key, _, _):
            transferWaiters[key.itemID]?.yield(event)
        }
    }

    private func finishWaiter(_ id: String) {
        transferWaiters.removeValue(forKey: id)?.finish()
        transferWaiterTokens[id] = nil
    }

    private func reconcileOnce() async {
        guard let transfer, !didReconcile else { return }
        didReconcile = true
        let snapshots = await transfer.snapshot()
        let decisions = TransferReconciler().reconcile(
            queue: queue,
            snapshots: snapshots,
            reattachable: interrupted
        )
        var report = ReconcileReport()
        var changed = false

        for decision in decisions {
            switch decision.action {
            case .reattach:
                // `interrupted` is the authority, not the status in the
                // snapshot: a user pause during the await must win.
                guard let id = decision.itemID,
                      interrupted.contains(id),
                      let index = queue.firstIndex(where: { $0.id == id }),
                      queue[index].status != .completed
                else { continue }
                queue[index].status = .queued
                queue[index].failure = nil
                queue[index].updatedAt = Date()
                interrupted.remove(id)
                report.reattached += 1
                changed = true

            case .pause:
                guard let id = decision.itemID,
                      let index = queue.firstIndex(where: { $0.id == id })
                else { continue }
                if queue[index].status == .downloading {
                    queue[index].status = .paused
                    queue[index].updatedAt = Date()
                    changed = true
                }
                interrupted.remove(id)
                report.paused += 1

            case .cancelOrphan:
                guard let taskIdentifier = decision.taskIdentifier else { continue }
                await transfer.cancel(taskIdentifier: taskIdentifier)
                report.canceledOrphans += 1
            }
        }

        // A demoted row whose daemon task is gone is already paused; it only
        // needs to stop pretending it can be reattached.
        let snapshotted = Set(snapshots.compactMap { $0.key?.itemID })
        for id in Array(interrupted) where !snapshotted.contains(id) {
            interrupted.remove(id)
            report.paused += 1
        }

        reconcileReport = report
        if changed {
            persist()
            emit()
        }
    }

    private func downloadingIndex(_ id: String) -> Int? {
        guard let index = queue.firstIndex(where: { $0.id == id }),
              queue[index].status == .downloading
        else { return nil }
        return index
    }

    /// Deterministic chunks. Absolute indices make a relaunch with the same
    /// committed prefix land on the same staging filenames, so a body the
    /// daemon finished before the process died is not paid for twice.
    private func transferChunks(
        from offset: Int64,
        total: Int64,
        chunkBytes: Int64,
        supportsRanges: Bool
    ) -> [TransferChunk] {
        guard offset < total, chunkBytes > 0 else { return [] }
        // A server that ignores Range can still deliver the whole body in one
        // daemon task; asking for more than one chunk would only repeat it.
        if !supportsRanges {
            return [TransferChunk(index: 0, range: ByteRange(start: 0, end: total - 1))]
        }
        let first = Int(offset / chunkBytes)
        let last = Int((total - 1) / chunkBytes)
        guard first <= last else { return [] }
        return (first...last).map { index in
            let start = max(offset, Int64(index) * chunkBytes)
            let end = min(total, Int64(index + 1) * chunkBytes) - 1
            return TransferChunk(index: index, range: ByteRange(start: start, end: end))
        }
    }

    private func backgroundRequest(
        id: String,
        epoch: UUID,
        chunk: TransferChunk,
        url: URL,
        headers: [String: String]
    ) -> TransferRequest {
        TransferRequest(
            key: TransferTaskKey(itemID: id, epoch: epoch, index: chunk.index),
            url: url,
            range: chunk.range,
            headers: headers,
            expectedBytes: chunk.range.length,
            stagingURL: TransferStaging.fileURL(
                root: stagingRoot,
                itemID: id,
                epoch: epoch,
                index: chunk.index
            )
        )
    }

    /// Appends every staged chunk that starts at `offset`, verifying each body
    /// against the range it was requested for before it becomes committed.
    @discardableResult
    private func drainBackgroundChunks(
        id: String,
        epoch: UUID,
        total: Int64,
        chunkBytes: Int64,
        supportsRanges: Bool,
        partial: URL,
        offset: inout Int64,
        staged: inout [Int: Int64]
    ) throws -> Int64 {
        let plans = Dictionary(uniqueKeysWithValues: transferChunks(
            from: offset,
            total: total,
            chunkBytes: chunkBytes,
            supportsRanges: supportsRanges
        ).map { ($0.index, $0) })
        var drained: Int64 = 0
        while offset < total {
            let index = Int(offset / chunkBytes)
            guard let plan = plans[index] else { break }
            let start = max(offset, plan.range.start)
            let expected = plan.range.end - start + 1
            let staging = TransferStaging.fileURL(
                root: stagingRoot,
                itemID: id,
                epoch: epoch,
                index: index
            )
            let size = fileSize(staging)
            guard size > 0 else { break }
            guard size == expected else {
                // A body for a different prefix cannot be committed at this
                // offset; discard it and let the scheduler ask again.
                try? fileManager.removeItem(at: staging)
                staged[index] = nil
                break
            }
            try appendContents(of: staging, to: partial)
            try? fileManager.removeItem(at: staging)
            staged[index] = nil
            offset += expected
            drained += expected
        }
        return drained
    }

    private func appendContents(of source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try output.write(contentsOf: data)
        }
    }

    private func backgroundReported(
        offset: Int64,
        total: Int64,
        staged: [Int: Int64],
        inFlight: [Int: Int64],
        plans: [Int: TransferChunk]
    ) -> Int64 {
        var reported = offset
        for (index, size) in staged {
            guard let plan = plans[index] else { continue }
            reported += min(max(size, 0), plan.range.length)
        }
        for (index, received) in inFlight {
            guard let plan = plans[index] else { continue }
            reported += min(max(received, 0), plan.range.length)
        }
        return min(max(reported, offset), total)
    }

    private func flushBackgroundProgress(
        id: String,
        total: Int64,
        reported: Int64,
        lastReported: inout Int64
    ) {
        let flushBytes = max(1, configuration.progressFlushBytes)
        let clamped = min(total, max(reported, 0))
        guard clamped >= total || clamped - lastReported >= flushBytes else { return }
        guard let index = downloadingIndex(id) else { return }
        queue[index].bytesWritten = max(queue[index].bytesWritten, clamped)
        queue[index].updatedAt = Date()
        lastReported = clamped
        persist()
        emit()
    }

    /// One attempt through the background daemon. `.part` stays the contiguous
    /// committed prefix; out-of-order daemon bodies wait in the staging epoch
    /// until every gap before them has arrived.
    private func attemptBackground(_ id: String) async throws {
        guard let transfer else { return try await attempt(id) }
        ensureTransferPump()

        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            throw AttemptFailure.transport(.cancelled)
        }
        let remoteURL = queue[index].remoteURL
        let classified = MediaContainer.classify(url: remoteURL)
        let container = classified == .unknown ? queue[index].container : classified
        guard container.isDirectDownload else {
            throw AttemptFailure.transport(.http(
                status: 415,
                code: "unsupported_container",
                message: "The \(container.displayName) downloader is not enabled in this build."
            ))
        }
        let headers = MediaRequest.headers(cookie: queue[index].cookie)
        let partial = partialURL(for: queue[index])
        let destination = fileURL(for: queue[index])

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: partial.path) {
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw AttemptFailure.transport(.upstream("Could not create the download file."))
            }
        }

        // Registered before the first suspension: a daemon task that finishes
        // while the probe or enqueue is in flight must still reach this attempt.
        let waiterToken = UUID()
        let (events, continuation) = AsyncStream.makeStream(of: TransferEvent.self)
        finishWaiter(id)
        transferWaiters[id] = continuation
        transferWaiterTokens[id] = waiterToken
        defer {
            if transferWaiterTokens[id] == waiterToken {
                transferWaiters[id] = nil
                transferWaiterTokens[id] = nil
            }
            continuation.finish()
        }

        var offset = fileSize(partial)
        queue[index].bytesWritten = offset

        if rangeSupport[id] == nil, offset > 0 || queue[index].totalBytes <= 0 {
            let info: RemoteFileInfo
            do {
                info = try await transport.probe(url: remoteURL, headers: headers)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw attempted(error, from: offset)
            }
            if Task.isCancelled { throw CancellationError() }
            guard let current = downloadingIndex(id) else { throw CancellationError() }
            rangeSupport[id] = info.supportsRanges
            if info.totalBytes > 0 { queue[current].totalBytes = info.totalBytes }
            persist()
        }

        if offset > 0, rangeSupport[id] == false {
            guard let current = downloadingIndex(id) else { throw CancellationError() }
            try restart(partial)
            offset = 0
            queue[current].bytesWritten = 0
            persist()
        }

        guard let current = downloadingIndex(id) else { throw CancellationError() }
        let total = queue[current].totalBytes
        guard total > 0 else { return try await attempt(id) }
        let chunkBytes = backgroundConfiguration.chunkBytes
        let supportsRanges = rangeSupport[id] ?? true

        // Snapshot once, then reuse it: an adopted epoch keeps the daemon's
        // existing chunks reachable, while a fresh one is the normal case.
        let snapshots = await transfer.snapshot()
        if Task.isCancelled { throw CancellationError() }
        guard let epochIndex = downloadingIndex(id) else { throw CancellationError() }
        let activeKeys = snapshots.compactMap(\.key).filter { $0.itemID == id }
        let epoch: UUID
        if let existing = queue[epochIndex].transferEpoch {
            epoch = existing
        } else if let adopted = activeKeys.first?.epoch {
            epoch = adopted
            queue[epochIndex].transferEpoch = adopted
            persist()
        } else {
            let created = UUID()
            epoch = created
            queue[epochIndex].transferEpoch = created
            persist()
        }
        var activeIndices = Set(activeKeys.filter { $0.epoch == epoch }.map(\.index))

        var plans = transferChunks(
            from: offset,
            total: total,
            chunkBytes: chunkBytes,
            supportsRanges: supportsRanges
        )
        var plansByIndex = Dictionary(uniqueKeysWithValues: plans.map { ($0.index, $0) })
        var staged: [Int: Int64] = [:]
        for plan in plans {
            let staging = TransferStaging.fileURL(
                root: stagingRoot,
                itemID: id,
                epoch: epoch,
                index: plan.index
            )
            let size = fileSize(staging)
            if size == plan.range.length {
                staged[plan.index] = size
            } else if size > 0 {
                try? fileManager.removeItem(at: staging)
            }
        }

        var lastReported = offset
        try drainBackgroundChunks(
            id: id,
            epoch: epoch,
            total: total,
            chunkBytes: chunkBytes,
            supportsRanges: supportsRanges,
            partial: partial,
            offset: &offset,
            staged: &staged
        )
        plans = transferChunks(
            from: offset,
            total: total,
            chunkBytes: chunkBytes,
            supportsRanges: supportsRanges
        )
        plansByIndex = Dictionary(uniqueKeysWithValues: plans.map { ($0.index, $0) })
        activeIndices = activeIndices.filter { plansByIndex[$0] != nil }
        var pending = plans
            .filter { !activeIndices.contains($0.index) && staged[$0.index] == nil }
            .sorted { $0.index < $1.index }
            .map(\.index)

        if let current = downloadingIndex(id) {
            queue[current].bytesWritten = max(queue[current].bytesWritten, offset)
        }
        flushBackgroundProgress(
            id: id,
            total: total,
            reported: backgroundReported(
                offset: offset, total: total, staged: staged,
                inFlight: [:], plans: plansByIndex
            ),
            lastReported: &lastReported
        )

        let limit = max(1, backgroundConfiguration.maxInflight)
        var requests: [TransferRequest] = []
        while activeIndices.count < limit, !pending.isEmpty {
            let index = pending.removeFirst()
            guard let plan = plansByIndex[index] else { continue }
            activeIndices.insert(index)
            requests.append(backgroundRequest(
                id: id, epoch: epoch, chunk: plan, url: remoteURL, headers: headers
            ))
        }
        if !requests.isEmpty {
            do {
                try await transfer.enqueue(requests)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw attempted(error, from: offset)
            }
            if Task.isCancelled { throw CancellationError() }
            guard downloadingIndex(id) != nil else { throw CancellationError() }
        }
        guard offset >= total || !pending.isEmpty || !activeIndices.isEmpty || !staged.isEmpty else {
            throw AttemptFailure.transport(
                .upstream("No background chunks could be scheduled.")
            )
        }

        var inFlight: [Int: Int64] = [:]
        var failure: AttemptFailure?
        var iterator = events.makeAsyncIterator()
        events: while offset < total {
            guard let event = await iterator.next() else { break events }
            if Task.isCancelled { throw CancellationError() }
            switch event {
            case .sessionDisconnected, .sessionReconnected:
                continue

            case .progress(let key, let received, _):
                guard key.itemID == id, key.epoch == epoch,
                      let plan = plansByIndex[key.index], plan.range.end >= offset
                else { continue }
                inFlight[key.index] = min(
                    plan.range.length,
                    max(inFlight[key.index] ?? 0, received)
                )
                flushBackgroundProgress(
                    id: id,
                    total: total,
                    reported: backgroundReported(
                        offset: offset, total: total, staged: staged,
                        inFlight: inFlight, plans: plansByIndex
                    ),
                    lastReported: &lastReported
                )

            case .finished(let key, let stagingURL, let response):
                guard key.itemID == id, key.epoch == epoch,
                      let plan = plansByIndex[key.index]
                else { continue }
                activeIndices.remove(key.index)
                inFlight[key.index] = nil
                if plan.range.end < offset { continue }

                let size = fileSize(stagingURL)
                let status = response?.status ?? 206
                if !(200..<300).contains(status) {
                    failure = attempted(
                        .http(status: status, code: nil, message: nil),
                        from: plan.range.start
                    )
                    break events
                }
                if status == 200, plan.range.start > 0 {
                    failure = .rangeIgnored
                    break events
                }
                if status == 200, plan.range.start == 0, offset == 0, size == total {
                    // A `200` is the whole file, not this chunk: accept it once
                    // instead of paying for every remaining range.
                    do {
                        try appendContents(of: stagingURL, to: partial)
                    } catch {
                        failure = .transport(.upstream("Could not write the download file."))
                        break events
                    }
                    try? fileManager.removeItem(at: stagingURL)
                    staged[plan.index] = nil
                    offset = total
                    if let current = downloadingIndex(id) {
                        queue[current].bytesWritten = total
                    }
                    persist()
                    emit()
                    break events
                }
                guard size == plan.range.length else {
                    // A short body is a cut connection, not a finished chunk.
                    failure = .transport(.upstream("The server sent an incomplete chunk."))
                    break events
                }
                if let contentRange = response?.contentRange,
                   contentRange.start != plan.range.start {
                    failure = .transport(.upstream("The server sent the wrong byte range."))
                    break events
                }
                staged[plan.index] = size

                do {
                    try drainBackgroundChunks(
                        id: id,
                        epoch: epoch,
                        total: total,
                        chunkBytes: chunkBytes,
                        supportsRanges: supportsRanges,
                        partial: partial,
                        offset: &offset,
                        staged: &staged
                    )
                } catch {
                    failure = .transport(.upstream("Could not write the download file."))
                    break events
                }
                guard downloadingIndex(id) != nil else { throw CancellationError() }

                if let current = downloadingIndex(id) {
                    queue[current].bytesWritten = max(queue[current].bytesWritten, offset)
                }
                flushBackgroundProgress(
                    id: id,
                    total: total,
                    reported: backgroundReported(
                        offset: offset, total: total, staged: staged,
                        inFlight: inFlight, plans: plansByIndex
                    ),
                    lastReported: &lastReported
                )
                if offset >= total { break events }

                var more: [TransferRequest] = []
                while activeIndices.count < limit, !pending.isEmpty {
                    let index = pending.removeFirst()
                    guard let next = plansByIndex[index], next.range.end >= offset else { continue }
                    activeIndices.insert(index)
                    more.append(backgroundRequest(
                        id: id, epoch: epoch, chunk: next, url: remoteURL, headers: headers
                    ))
                }
                if !more.isEmpty {
                    do {
                        try await transfer.enqueue(more)
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        failure = attempted(error, from: offset)
                        break events
                    }
                }

            case .failed(let key, let error, _):
                guard key.itemID == id, key.epoch == epoch else { continue }
                activeIndices.remove(key.index)
                inFlight[key.index] = nil
                if case .cancelled = error, Task.isCancelled { throw CancellationError() }
                failure = attempted(
                    error,
                    from: plansByIndex[key.index]?.range.start ?? offset
                )
                break events
            }
        }

        if Task.isCancelled { throw CancellationError() }
        if let failure { throw failure }
        guard offset >= total else {
            throw AttemptFailure.transport(
                .upstream("The background transfer stopped before it finished.")
            )
        }
        guard let finishedIndex = downloadingIndex(id) else { throw CancellationError() }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            throw AttemptFailure.transport(.upstream("Could not finish the download file."))
        }
        let finalSize = fileSize(destination)
        queue[finishedIndex].bytesWritten = finalSize
        if queue[finishedIndex].totalBytes <= 0 { queue[finishedIndex].totalBytes = finalSize }
        try? fileManager.removeItem(
            at: TransferStaging.epochDirectory(root: stagingRoot, itemID: id, epoch: epoch)
        )
    }

    private func complete(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = .completed
        queue[index].failure = nil
        queue[index].updatedAt = Date()
        persist()
        emit()
        scheduleSubtitles(for: queue[index])
    }

    /// Saves an item's captions once its media is on disk.
    ///
    /// Detached from `complete`, so a slow caption host cannot hold the queue
    /// or delay the next item starting. The row is emitted again when the
    /// tracks land, which is what makes them appear without reopening the app.
    private func scheduleSubtitles(for item: DownloadItem) {
        guard captionProvider != nil, item.subtitles.isEmpty else { return }
        Task { [weak self] in await self?.attachSubtitles(to: item) }
    }

    private func attachSubtitles(to item: DownloadItem) async {
        guard let captionProvider else { return }
        let saved = await captionProvider(item)
        guard !saved.isEmpty,
              let index = queue.firstIndex(where: { $0.id == item.id }),
              queue[index].status == .completed
        else { return }
        queue[index].subtitles = saved
        queue[index].updatedAt = Date()
        persist()
        emit()
    }

    /// Captions belong to the episode they were fetched for; leaving them behind
    /// would grow the downloads directory with files nothing references.
    private func removeSubtitleFiles(for item: DownloadItem) {
        for subtitle in item.subtitles {
            try? fileManager.removeItem(at: directory.appendingPathComponent(subtitle.fileName))
        }
    }

    private func fail(_ id: String, with error: CinemacoreError) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].attempts += 1
        queue[index].failure = error.userMessage
        queue[index].status = .failed
        queue[index].updatedAt = Date()
        persist()
        emit()
    }

    /// Records a failure and answers whether another attempt is worth making.
    private func recover(_ failure: AttemptFailure, id: String) -> Bool {
        guard let index = queue.firstIndex(where: { $0.id == id }),
              queue[index].status == .downloading
        else { return false }

        if case .rangeIgnored = failure {
            // The server answered a ranged request with the whole file. That is
            // a protocol downgrade, not the item's fault: drop the prefix, note
            // it so the next attempt does not ask again, and go again at once.
            try? restart(partialURL(for: queue[index]))
            rangeSupport[id] = false
            queue[index].bytesWritten = 0
            queue[index].updatedAt = Date()
            persist()
            emit()
            return true
        }

        guard case .transport(let error) = failure else { return false }
        queue[index].attempts += 1
        queue[index].failure = error.userMessage
        queue[index].updatedAt = Date()
        if !error.isRetryable || queue[index].attempts >= max(1, configuration.maxAttempts) {
            queue[index].status = .failed
            persist()
            emit()
            return false
        }
        persist()
        emit()
        return true
    }

    /// `initialBackoff * 2^(attempts-1)`, capped. `attempt` is 1 for the first
    /// retry, which waits exactly `initialBackoff`.
    nonisolated func backoff(afterAttempt attempt: Int) -> TimeInterval {
        let initial = max(0, configuration.initialBackoff)
        let ceiling = max(0, configuration.maxBackoff)
        guard attempt > 1 else { return min(initial, ceiling) }
        return min(initial * pow(2, Double(attempt - 1)), ceiling)
    }

    private func attempted(_ error: CinemacoreError, from offset: Int64) -> AttemptFailure {
        // A `200` answer to a request that asked to start mid-file means the
        // server ignored `Range`. There is no `CinemacoreError` case for that,
        // and the frozen error surface cannot grow one, so the status is the
        // signal the transport and the engine agree on.
        if offset > 0, case .http(let status, _, _) = error, status == 200 {
            return .rangeIgnored
        }
        return .transport(error)
    }

    /// Empties `partial` so the next byte written to it is byte zero.
    private func restart(_ partial: URL) throws {
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw AttemptFailure.transport(.upstream("Could not restart the download file."))
        }
    }

    // MARK: - State

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: documentURL),
              let document = try? JSONDecoder.library.decode(DownloadDocument.self, from: data)
        else { return }
        queue = document.items
        var recovered = false
        // A pre-planned build treated the manifest itself as the finished file.
        // That row can never play offline, so repair it once: drop the playlist
        // bytes, keep the user's row, and let the container downloader resume it.
        for index in queue.indices where queue[index].layoutVersion < 2 && queue[index].isManifestDownload {
            try? fileManager.removeItem(at: fileURL(for: queue[index]))
            try? fileManager.removeItem(at: partialURL(for: queue[index]))
            // The repair is our decision, not a daemon interruption, so this
            // row must never be reattached to a previous generation's task.
            interrupted.remove(queue[index].id)
            queue[index].layoutVersion = 2
            queue[index].status = .paused
            queue[index].bytesWritten = 0
            queue[index].totalBytes = 0
            queue[index].failure = "This download was a playlist, not a video. Resume it to download the title."
            queue[index].updatedAt = Date()
            recovered = true
        }
        // A process that died cannot still be downloading; whatever was in flight
        // is only as complete as the bytes already on disk.
        for index in queue.indices where queue[index].status == .downloading {
            queue[index].status = .paused
            interrupted.insert(queue[index].id)
            recovered = true
        }
        if recovered { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder.library.encode(DownloadDocument(items: queue)) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: documentURL, options: .atomic)
    }

    private func emit() {
        for continuation in continuations.values {
            continuation.yield(queue)
        }
    }

    private func dropContinuation(_ token: UUID) {
        continuations[token] = nil
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return 0
        }
        if values.isDirectory == true {
            guard let children = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for case let child as URL in children {
                guard let childValues = try? child.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ), childValues.isRegularFile == true else { continue }
                total += Int64(childValues.fileSize ?? 0)
            }
            return total
        }
        return Int64(values.fileSize ?? 0)
    }
}

/// What a runner needs to know that ``CinemacoreError`` cannot express.
private enum AttemptFailure: Error {
    case transport(CinemacoreError)
    /// The server sent the whole file in answer to a ranged request.
    case rangeIgnored
}

/// One deterministic background range. `index` is absolute, so the staging
/// filename survives a relaunch at the same committed offset.
private struct TransferChunk: Sendable {
    let index: Int
    let range: ByteRange
}

/// The on-disk queue. One file keeps the write path atomic.
private struct DownloadDocument: Codable, Sendable {
    var items: [DownloadItem] = []

    private enum CodingKeys: String, CodingKey { case items }

    init(items: [DownloadItem] = []) {
        self.items = items
    }

    /// See ``DownloadItem/init(from:)``: a missing key must not destroy the
    /// queue.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([DownloadItem].self, forKey: .items) ?? []
    }
}

/// `URLSession`-backed ``DownloadTransport``.
///
/// Foundation-only so the download engine stays testable on Linux, and a
/// sibling of ``APIClient``: errors funnel into the same ``CinemacoreError``
/// surface, and requests carry exactly the headers the caller passes. The
/// engine builds those from ``MediaRequest/headers(cookie:)``, so nothing here
/// ever adds a signing header to a media request.
public struct URLSessionDownloadTransport: DownloadTransport {
    public init(session: URLSession = .shared) {
        self.session = session
    }

    private let session: URLSession

    /// One ranged request asks for at most this many bytes.
    ///
    /// `URLSession.bytes(for:)` does not exist in this toolchain's Linux
    /// Foundation, so a download cannot ride a single streaming connection: the
    /// stream below issues a bounded ranged request per chunk instead. Bounding
    /// the request is what keeps a whole film out of memory and what lets the
    /// engine flush progress as the bytes arrive; the trade-off is one HTTP
    /// round trip per chunk rather than one connection for the whole file, which
    /// a CDN with keep-alive absorbs.
    static let chunkBytes: Int64 = 1 << 20

    /// Chunks are handed to the engine in slices of at most this size so a
    /// progress bar advances at least every 256 KB even when the transport read
    /// a larger block at once.
    static let sliceBytes = 256 * 1024

    private static let timeout: TimeInterval = 60

    public func probe(url: URL, headers: [String: String]) async throws(CinemacoreError) -> RemoteFileInfo {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = Self.timeout
        head.allHTTPHeaderFields = headers

        let (_, headResponse) = try await fetchRaw(head)
        if (200..<300).contains(headResponse.statusCode) {
            return Self.fileInfo(from: headResponse)
        }

        // A CDN that rejects HEAD usually still answers a ranged GET, and one
        // byte is enough to read `Content-Range` and `Accept-Ranges` — unless it
        // ignores `Range` too, in which case this response carries the whole
        // file. That costs one wasted body the first time an item is probed.
        var ranged = URLRequest(url: url)
        ranged.timeoutInterval = Self.timeout
        ranged.allHTTPHeaderFields = headers
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (rangedBody, rangedResponse) = try await fetchRaw(ranged)
        try Self.validate(rangedResponse, body: rangedBody)
        return Self.fileInfo(from: rangedResponse)
    }

    public func content(
        url: URL,
        headers: [String: String],
        from: Int64
    ) async throws(CinemacoreError) -> AsyncThrowingStream<Data, any Error> {
        // The first request is eager so a 404, a lockout or an offline host is a
        // typed throw from this call, not a surprise inside the stream.
        let first = try await fetch(url: url, headers: headers, from: from)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let task = Task {
            var offset = from
            var buffered = first.data
            var cursor = buffered.startIndex
            var isLast = first.isLast
            while true {
                if cursor < buffered.endIndex {
                    let limit = buffered.index(cursor, offsetBy: Self.sliceBytes, limitedBy: buffered.endIndex)
                    let end = limit ?? buffered.endIndex
                    if case .terminated = continuation.yield(Data(buffered[cursor..<end])) { return }
                    offset += Int64(end - cursor)
                    cursor = end
                    continue
                }
                if isLast { break }
                do {
                    let next = try await fetch(url: url, headers: headers, from: offset)
                    buffered = next.data
                    isLast = next.isLast
                    cursor = buffered.startIndex
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                if buffered.isEmpty, !isLast {
                    continuation.finish(throwing: CinemacoreError.upstream("The server sent an empty range."))
                    return
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Response handling

    private struct Chunk {
        let data: Data
        let isLast: Bool
    }

    private func fetch(url: URL, headers: [String: String], from: Int64) async throws(CinemacoreError) -> Chunk {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.allHTTPHeaderFields = headers
        request.setValue("bytes=\(from)-\(from + Self.chunkBytes - 1)", forHTTPHeaderField: "Range")

        let (payload, response) = try await fetchRaw(request)

        // A range that starts past the end is how a server says "you already
        // have all of it", and it is the only reliable end-of-file signal when
        // the total is unknown.
        if response.statusCode == 416 {
            return Chunk(data: Data(), isLast: true)
        }
        try Self.validate(response, body: payload)

        guard response.statusCode == 206 else {
            // A `200` to a bounded ranged request means the whole file arrived.
            // Only a request that asked for the start of the file can accept it.
            guard from == 0 else { throw Self.rangeIgnored() }
            return Chunk(data: payload, isLast: true)
        }

        guard let range = Self.contentRange(response.value(forHTTPHeaderField: "Content-Range")),
              from == 0 || range.start == from
        else {
            // Without a usable `Content-Range` the bytes cannot be placed in the
            // file; treating it as an ignored range makes the caller restart
            // rather than append at the wrong offset.
            throw Self.rangeIgnored()
        }
        let requested = Self.chunkBytes
        let isLast = range.total > 0
            ? range.end + 1 >= range.total
            : Int64(payload.count) < requested
        return Chunk(data: payload, isLast: isLast)
    }

    /// One session round trip, as a result value rather than a throw.
    ///
    /// An async function that both declares a typed `throws(Error)` and contains
    /// a `do/catch` crashes the Swift 6.4.1 frontend during SIL lowering on
    /// Linux (reproduced minimally), so the typed error is carried as a value
    /// here and re-thrown by the caller.
    private struct RawOutcome {
        let payload: Data?
        let response: URLResponse?
        let failure: CinemacoreError?
    }

    private func raw(_ request: URLRequest) async -> RawOutcome {
        do {
            let (payload, response) = try await session.data(for: request)
            return RawOutcome(payload: payload, response: response, failure: nil)
        } catch let error as URLError {
            return RawOutcome(payload: nil, response: nil, failure: APIClient.map(error))
        } catch is CancellationError {
            return RawOutcome(payload: nil, response: nil, failure: .cancelled)
        } catch {
            return RawOutcome(payload: nil, response: nil, failure: .offline)
        }
    }

    private func fetchRaw(_ request: URLRequest) async throws(CinemacoreError) -> (Data, HTTPURLResponse) {
        let outcome = await raw(request)
        guard let payload = outcome.payload, let response = outcome.response else {
            throw outcome.failure ?? .offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw .http(status: -1, code: nil, message: nil)
        }
        return (payload, http)
    }

    private static func validate(_ response: HTTPURLResponse, body: Data) throws(CinemacoreError) {
        guard !(200..<300).contains(response.statusCode) else { return }
        let envelope = try? JSONDecoder().decode(APIRequest.ErrorEnvelope.self, from: body)
        // The gateway's typed envelope, when there is one, is the only thing that
        // makes a 403 a regional lockout rather than a stale media cookie.
        if let message = envelope?.message, response.statusCode == 403 || response.statusCode == 451 {
            throw .locked(reason: message)
        }
        throw .http(status: response.statusCode, code: envelope?.code, message: envelope?.message)
    }

    private static func rangeIgnored() -> CinemacoreError {
        .http(status: 200, code: nil, message: "The server ignored the resume request.")
    }

    /// Reads the size and the range support out of a response. A `206` carries
    /// the total in `Content-Range`; a `200` only has `Content-Length`, and
    /// `Accept-Ranges` is the server's promise that a later request may resume.
    static func fileInfo(from response: HTTPURLResponse) -> RemoteFileInfo {
        if let range = contentRange(response.value(forHTTPHeaderField: "Content-Range")) {
            return RemoteFileInfo(totalBytes: range.total, supportsRanges: true)
        }
        let length = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        let accept = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
        return RemoteFileInfo(totalBytes: max(length, 0), supportsRanges: accept.contains("bytes"))
    }

    /// Parses `Content-Range: bytes 100-999/1000`. A total of `*` becomes 0,
    /// which callers read as "unknown".
    static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let halves = parts[1].split(separator: "/")
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1])
        else { return nil }
        return (start, end, Int64(halves[1]) ?? 0)
    }
}
