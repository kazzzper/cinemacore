import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One inclusive byte interval. The engine and the background request builder
/// both need the same arithmetic, so it lives once here.
public struct ByteRange: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = max(start, end)
    }

    public var length: Int64 { max(0, end - start + 1) }

    public func contains(_ offset: Int64) -> Bool {
        offset >= start && offset <= end
    }

    public var headerValue: String { "bytes=\(start)-\(end)" }
}

/// The stable identity of one background task.
///
/// `taskDescription` is the only durable channel a background `URLSession`
/// gives back after the process has been relaunched, so the key is encoded
/// rather than delimited: provider quality labels can contain any character.
public struct TransferTaskKey: Codable, Hashable, Sendable {
    public let itemID: String
    public let epoch: UUID
    public let index: Int

    public init(itemID: String, epoch: UUID, index: Int) {
        self.itemID = itemID
        self.epoch = epoch
        self.index = index
    }

    private static let prefix = "cinemacore:"

    public var taskDescription: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString()
    }

    public static func parse(_ description: String?) -> TransferTaskKey? {
        guard let description, description.hasPrefix(prefix) else { return nil }
        let encoded = String(description.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(TransferTaskKey.self, from: data)
    }
}

public struct TransferRequest: Sendable {
    public let key: TransferTaskKey
    public let url: URL
    public let range: ByteRange?
    public let headers: [String: String]
    public let expectedBytes: Int64
    /// Deterministic so a relaunch can find a body the daemon already finished.
    public let stagingURL: URL
    public let timeout: TimeInterval

    public init(
        key: TransferTaskKey,
        url: URL,
        range: ByteRange?,
        headers: [String: String],
        expectedBytes: Int64,
        stagingURL: URL,
        timeout: TimeInterval = 60
    ) {
        self.key = key
        self.url = url
        self.range = range
        self.headers = headers
        self.expectedBytes = expectedBytes
        self.stagingURL = stagingURL
        self.timeout = timeout
    }
}

public struct TransferSnapshot: Hashable, Sendable {
    public let key: TransferTaskKey?
    public let taskIdentifier: Int
    public let url: URL?
    public let bytesReceived: Int64
    public let expectedBytes: Int64
    public let isDownloading: Bool

    public init(
        key: TransferTaskKey?,
        taskIdentifier: Int,
        url: URL?,
        bytesReceived: Int64,
        expectedBytes: Int64,
        isDownloading: Bool
    ) {
        self.key = key
        self.taskIdentifier = taskIdentifier
        self.url = url
        self.bytesReceived = bytesReceived
        self.expectedBytes = expectedBytes
        self.isDownloading = isDownloading
    }
}

public struct TransferResponse: Hashable, Sendable {
    public let status: Int
    public let contentRange: ByteRange?
    public let contentLength: Int64?
    public let contentType: String?
    public let finalURL: URL?

    public init(
        status: Int,
        contentRange: ByteRange? = nil,
        contentLength: Int64? = nil,
        contentType: String? = nil,
        finalURL: URL? = nil
    ) {
        self.status = status
        self.contentRange = contentRange
        self.contentLength = contentLength
        self.contentType = contentType
        self.finalURL = finalURL
    }
}

public enum TransferEvent: Sendable {
    case progress(TransferTaskKey, received: Int64, expected: Int64)
    case finished(TransferTaskKey, stagingURL: URL, response: TransferResponse?)
    case failed(TransferTaskKey, error: CinemacoreError, retryable: Bool)
    /// The background daemon dropped the connection. This is not an item
    /// failure: the session reconnects and the staged files stay authoritative.
    case sessionDisconnected
    case sessionReconnected

    public var itemID: String? {
        switch self {
        case .progress(let key, _, _), .finished(let key, _, _), .failed(let key, _, _):
            key.itemID
        case .sessionDisconnected, .sessionReconnected:
            nil
        }
    }

    public var key: TransferTaskKey? {
        switch self {
        case .progress(let key, _, _), .finished(let key, _, _), .failed(let key, _, _):
            key
        case .sessionDisconnected, .sessionReconnected:
            nil
        }
    }
}

/// The seam between the engine and the OS background daemon.
public protocol BackgroundTransferring: Sendable {
    func snapshot() async -> [TransferSnapshot]
    func enqueue(_ requests: [TransferRequest]) async throws(CinemacoreError)
    func pause(itemID: String) async
    func cancel(itemID: String) async
    func cancel(taskIdentifier: Int) async
    func events() -> AsyncStream<TransferEvent>
}

public struct BackgroundTransferConfiguration: Sendable {
    /// Bounded chunks keep resume granularity useful without creating one task
    /// per HTTP range a player might ask for.
    public var chunkBytes: Int64
    /// Tasks enqueued at once. The default window covers a 10 GB item at the
    /// default chunk size, so suspension does not leave most of the file with no
    /// daemon task to run. The session's connection limit, not this, bounds
    /// actual network concurrency.
    public var maxInflight: Int

    public init(chunkBytes: Int64 = 32 << 20, maxInflight: Int = 512) {
        self.chunkBytes = max(1 << 20, chunkBytes)
        self.maxInflight = max(1, maxInflight)
    }
}

/// What launch-time reconciliation should do with a daemon task.
public struct TransferReconciler: Sendable {
    public enum Action: Sendable, Equatable {
        case reattach
        case pause
        case cancelOrphan
    }

    public struct Decision: Sendable, Equatable {
        public let itemID: String?
        public let taskIdentifier: Int?
        public let action: Action

        public init(itemID: String?, taskIdentifier: Int?, action: Action) {
            self.itemID = itemID
            self.taskIdentifier = taskIdentifier
            self.action = action
        }
    }

    public init() {}

    /// Pure so the launch decision is testable without a `URLSession`.
    ///
    /// - Parameter reattachable: items a previous process left `.downloading`
    ///   before the launch reset demoted them. A user pause is not in this set,
    ///   so its still-running daemon task is an orphan and must be cancelled.
    public func reconcile(
        queue: [DownloadItem],
        snapshots: [TransferSnapshot],
        reattachable: Set<String> = []
    ) -> [Decision] {
        var decisions: [Decision] = []
        let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
        var snapshotsByItem: Set<String> = []

        for snapshot in snapshots {
            guard let key = snapshot.key else {
                decisions.append(.init(
                    itemID: nil,
                    taskIdentifier: snapshot.taskIdentifier,
                    action: .cancelOrphan
                ))
                continue
            }
            snapshotsByItem.insert(key.itemID)
            guard let item = byID[key.itemID] else {
                decisions.append(.init(
                    itemID: key.itemID,
                    taskIdentifier: snapshot.taskIdentifier,
                    action: .cancelOrphan
                ))
                continue
            }
            let canReattach = reattachable.contains(item.id) || item.status == .downloading
            decisions.append(.init(
                itemID: item.id,
                taskIdentifier: snapshot.taskIdentifier,
                action: canReattach ? .reattach : .cancelOrphan
            ))
        }

        for item in queue where item.status == .downloading && !snapshotsByItem.contains(item.id) {
            decisions.append(.init(
                itemID: item.id,
                taskIdentifier: nil,
                action: .pause
            ))
        }
        return decisions
    }
}

/// Deterministic staging paths shared by the engine and the daemon delegate.
public enum TransferStaging {
    public static func itemRoot(root: URL, itemID: String) -> URL {
        root.appendingPathComponent(DownloadItem.sanitise(itemID), isDirectory: true)
    }

    public static func epochDirectory(root: URL, itemID: String, epoch: UUID) -> URL {
        itemRoot(root: root, itemID: itemID)
            .appendingPathComponent(epoch.uuidString, isDirectory: true)
    }

    public static func fileURL(
        root: URL,
        itemID: String,
        epoch: UUID,
        index: Int
    ) -> URL {
        epochDirectory(root: root, itemID: itemID, epoch: epoch)
            .appendingPathComponent(String(format: "chunk-%06d", index))
    }
}

/// Reported after launch reconciliation so the app can log a concrete outcome
/// instead of silently dropping work.
public struct ReconcileReport: Sendable, Equatable {
    public var reattached: Int
    public var paused: Int
    public var canceledOrphans: Int
    public var ingestedBytes: Int64

    public init(
        reattached: Int = 0,
        paused: Int = 0,
        canceledOrphans: Int = 0,
        ingestedBytes: Int64 = 0
    ) {
        self.reattached = reattached
        self.paused = paused
        self.canceledOrphans = canceledOrphans
        self.ingestedBytes = ingestedBytes
    }
}
