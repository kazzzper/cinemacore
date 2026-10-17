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
        status: DownloadStatus = .queued,
        totalBytes: Int64 = 0,
        bytesWritten: Int64 = 0,
        attempts: Int = 0,
        failure: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        localFileName: String
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
        self.status = status
        self.totalBytes = totalBytes
        self.bytesWritten = bytesWritten
        self.attempts = attempts
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.localFileName = localFileName
    }

    private enum CodingKeys: String, CodingKey {
        case id, subjectID, title, poster, season, episode, episodeTitle, quality,
             remoteURL, cookie, status, totalBytes, bytesWritten, attempts, failure,
             createdAt, updatedAt, localFileName
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
        status = try container.decodeIfPresent(DownloadStatus.self, forKey: .status) ?? .queued
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        bytesWritten = try container.decodeIfPresent(Int64.self, forKey: .bytesWritten) ?? 0
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        localFileName = try container.decodeIfPresent(String.self, forKey: .localFileName)
            ?? DownloadItem.defaultLocalFileName(for: id)
    }

    /// The name a download falls back to when the document predates
    /// `localFileName`. Progressive MP4 is the only container the gateway
    /// serves, so `.mp4` is the only honest guess.
    static func defaultLocalFileName(for id: String) -> String {
        "\(sanitise(id)).mp4"
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
    private let fileManager = FileManager.default

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

    public init(
        directory: URL,
        transport: any DownloadTransport,
        configuration: DownloadConfiguration = .init()
    ) {
        self.directory = directory
        self.transport = transport
        self.configuration = configuration
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

    /// `"<name>.part"`. A `.part` file is never valid to hand a player.
    public nonisolated func partialURL(for item: DownloadItem) -> URL {
        directory.appendingPathComponent(item.localFileName + ".part")
    }

    public func bytesOnDisk() async -> Int64 {
        ensureLoaded()
        return queue.reduce(into: Int64(0)) { total, item in
            total += fileSize(fileURL(for: item))
            total += fileSize(partialURL(for: item))
        }
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
        schedule()
    }

    public func pause(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].status == .downloading || queue[index].status == .queued else { return }
        stopTask(id)
        queue[index].status = .paused
        queue[index].updatedAt = Date()
        persist()
        emit()
    }

    public func pauseAll() async {
        ensureLoaded()
        var changed = false
        for index in queue.indices
        where queue[index].status == .downloading || queue[index].status == .queued {
            stopTask(queue[index].id)
            queue[index].status = .paused
            queue[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        persist()
        emit()
    }

    /// Queues a paused, failed or waiting item and lets the scheduler pick it
    /// up; a failed item's attempt budget is reset so it can actually succeed.
    public func resume(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        guard queue[index].canResume else { return }
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
        try? fileManager.removeItem(at: partialURL(for: queue[index]))
        rangeSupport[id] = nil
        queue[index].status = .paused
        queue[index].bytesWritten = 0
        queue[index].failure = nil
        queue[index].updatedAt = Date()
        persist()
        emit()
    }

    public func remove(_ id: String) async {
        ensureLoaded()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        stopTask(id)
        let item = queue.remove(at: index)
        try? fileManager.removeItem(at: partialURL(for: item))
        try? fileManager.removeItem(at: fileURL(for: item))
        rangeSupport[id] = nil
        persist()
        emit()
    }

    public func removeCompleted() async {
        ensureLoaded()
        let finished = queue.filter { $0.status == .completed }
        guard !finished.isEmpty else { return }
        for item in finished {
            try? fileManager.removeItem(at: fileURL(for: item))
            rangeSupport[item.id] = nil
        }
        queue.removeAll { $0.status == .completed }
        persist()
        emit()
    }

    public func removeAll() async {
        ensureLoaded()
        for item in queue {
            stopTask(item.id)
            try? fileManager.removeItem(at: partialURL(for: item))
            try? fileManager.removeItem(at: fileURL(for: item))
        }
        rangeSupport.removeAll()
        queue.removeAll()
        persist()
        emit()
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
                try await attempt(id)
                complete(id)
                return
            } catch let failure as AttemptFailure {
                if Task.isCancelled {
                    persist()
                    return
                }
                guard recover(failure, id: id) else { return }
                // A restart after an ignored range spends no attempt, so it also
                // waits no backoff.
                let spent = queue.first(where: { $0.id == id })?.attempts ?? 0
                let delay = spent > 0 ? backoff(afterAttempt: spent) : 0
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            } catch is CancellationError {
                persist()
                return
            } catch {
                fail(id, with: .upstream(String(describing: error)))
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
            throw AttemptFailure.transport(.upstream(String(describing: error)))
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

    private func complete(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].status = .completed
        queue[index].failure = nil
        queue[index].updatedAt = Date()
        persist()
        emit()
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
        // A process that died cannot still be downloading; whatever was in flight
        // is only as complete as the bytes already on disk.
        var recovered = false
        for index in queue.indices where queue[index].status == .downloading {
            queue[index].status = .paused
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
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }
}

/// What a runner needs to know that ``CinemacoreError`` cannot express.
private enum AttemptFailure: Error {
    case transport(CinemacoreError)
    /// The server sent the whole file in answer to a ranged request.
    case rangeIgnored
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

        let (_, headResponse) = try await raw(head)
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

        let (rangedBody, rangedResponse) = try await raw(ranged)
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

        let (payload, response) = try await raw(request)

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

    private func raw(_ request: URLRequest) async throws(CinemacoreError) -> (Data, HTTPURLResponse) {
        let payload: Data
        let response: URLResponse
        do {
            (payload, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIClient.map(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .offline
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
