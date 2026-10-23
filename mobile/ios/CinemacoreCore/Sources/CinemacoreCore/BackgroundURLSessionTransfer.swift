#if canImport(Darwin)
import Foundation

/// The iOS background daemon, exposed through the engine's transfer seam.
///
/// One session per process with a stable identifier: creating a second session
/// with the same identifier splits delegate callbacks and loses tasks. The
/// session is deliberately not invalidated while downloads may be active; a
/// process-lifetime singleton owns it.
public final class BackgroundURLSessionTransfer: NSObject, BackgroundTransferring,
    URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    public static let defaultIdentifier = "com.cinemacore.app.downloads"

    private let stagingDirectory: URL
    private let lock = NSLock()
    private let delegateQueue: OperationQueue
    private var session: URLSession!
    private let eventStream: AsyncStream<TransferEvent>
    private let eventContinuation: AsyncStream<TransferEvent>.Continuation
    private var requests: [TransferTaskKey: TransferRequest] = [:]
    private var keysByTask: [Int: TransferTaskKey] = [:]
    private var completionHandler: (() -> Void)?

    public init(
        stagingDirectory: URL,
        identifier: String = BackgroundURLSessionTransfer.defaultIdentifier
    ) {
        self.stagingDirectory = stagingDirectory
        let (stream, continuation) = AsyncStream.makeStream(of: TransferEvent.self)
        self.eventStream = stream
        self.eventContinuation = continuation
        let queue = OperationQueue()
        queue.name = "com.cinemacore.downloads.delegate"
        queue.maxConcurrentOperationCount = 1
        self.delegateQueue = queue
        super.init()

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        self.session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        ensureDirectory(stagingDirectory)
    }

    // MARK: - Protocol

    public func events() -> AsyncStream<TransferEvent> { eventStream }

    public func snapshot() async -> [TransferSnapshot] {
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            let key = TransferTaskKey.parse(task.taskDescription) ?? key(for: task.taskIdentifier)
            return TransferSnapshot(
                key: key,
                taskIdentifier: task.taskIdentifier,
                url: task.originalRequest?.url,
                bytesReceived: task.countOfBytesReceived,
                expectedBytes: task.countOfBytesExpectedToReceive,
                isDownloading: task.state == .running
            )
        }
    }

    public func enqueue(_ requests: [TransferRequest]) async throws(CinemacoreError) {
        for request in requests {
            guard withLock({ self.requests[request.key] == nil }) else { continue }
            ensureDirectory(request.stagingURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: request.stagingURL)

            var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
            for (field, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
            if let range = request.range {
                urlRequest.setValue(range.headerValue, forHTTPHeaderField: "Range")
            }

            let task = session.downloadTask(with: urlRequest)
            task.taskDescription = request.key.taskDescription
            task.countOfBytesClientExpectsToReceive = request.expectedBytes
            withLock {
                self.requests[request.key] = request
                self.keysByTask[task.taskIdentifier] = request.key
            }
            task.resume()
        }
    }

    public func pause(itemID: String) async {
        await cancelTasks(itemID: itemID, removeStaging: false)
    }

    public func cancel(itemID: String) async {
        await cancelTasks(itemID: itemID, removeStaging: true)
    }

    public func cancel(taskIdentifier: Int) async {
        let tasks = await session.allTasks
        guard let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) else {
            return
        }
        let key = TransferTaskKey.parse(task.taskDescription) ?? key(for: taskIdentifier)
        task.cancel()
        if let key {
            withLock { self.requests[key] = nil }
        }
        withLock { self.keysByTask[taskIdentifier] = nil }
    }

    /// Called by the app delegate before the background session is recreated.
    public func storeBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        withLock { self.completionHandler = handler }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = key(for: downloadTask.taskIdentifier) else { return }
        emit(.progress(key, received: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = key(for: downloadTask.taskIdentifier) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        let response = transferResponse(from: downloadTask.response)
        if let status = response?.status, !(200...299).contains(status) {
            try? FileManager.default.removeItem(at: location)
            emit(.failed(
                key,
                error: httpError(status: status),
                retryable: status == 408 || status == 429 || (500...599).contains(status)
            ))
            return
        }

        let destination = stagingURL(for: key)
        ensureDirectory(destination.deletingLastPathComponent())
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            emit(.finished(key, stagingURL: destination, response: response))
        } catch {
            try? FileManager.default.removeItem(at: location)
            emit(.failed(
                key,
                error: .upstream("Could not stage the background download."),
                retryable: true
            ))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let key = key(for: task.taskIdentifier)
        if let key {
            withLock { self.requests[key] = nil }
        }
        withLock { self.keysByTask[task.taskIdentifier] = nil }

        guard let error else { return }
        if (error as? URLError)?.code == .cancelled { return }
        guard let key else {
            if isConnectivityError(error) {
                emit(.sessionDisconnected)
            }
            return
        }
        let mapped = map(error)
        emit(.failed(key, error: mapped, retryable: mapped.isRetryable))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler: (() -> Void)? = withLock { self.completionHandler }
        withLock { self.completionHandler = nil }
        handler?()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        let originalHost = task.originalRequest?.url?.host
        if let originalHost, originalHost != request.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(redirected)
    }

    // MARK: - State

    private func cancelTasks(itemID: String, removeStaging: Bool) async {
        let tasks = await session.allTasks
        for task in tasks {
            let key = TransferTaskKey.parse(task.taskDescription) ?? key(for: task.taskIdentifier)
            guard key?.itemID == itemID else { continue }
            task.cancel()
            if let key {
                withLock { self.requests[key] = nil }
            }
            withLock { self.keysByTask[task.taskIdentifier] = nil }
        }
        if removeStaging {
            try? FileManager.default.removeItem(
                at: TransferStaging.itemRoot(root: stagingDirectory, itemID: itemID)
            )
        }
    }

    private func key(for taskIdentifier: Int) -> TransferTaskKey? {
        withLock { keysByTask[taskIdentifier] }
    }

    private func request(for key: TransferTaskKey) -> TransferRequest? {
        withLock { requests[key] }
    }

    private func stagingURL(for key: TransferTaskKey) -> URL {
        request(for: key)?.stagingURL
            ?? TransferStaging.fileURL(
                root: stagingDirectory,
                itemID: key.itemID,
                epoch: key.epoch,
                index: key.index
            )
    }

    private func emit(_ event: TransferEvent) {
        let continuation: AsyncStream<TransferEvent>.Continuation? = withLock { eventContinuation }
        continuation?.yield(event)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func ensureDirectory(_ url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        #if os(iOS)
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func transferResponse(from response: URLResponse?) -> TransferResponse? {
        guard let http = response as? HTTPURLResponse else { return nil }
        return TransferResponse(
            status: http.statusCode,
            contentRange: parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
            contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            finalURL: http.url
        )
    }

    private func parseContentRange(_ raw: String?) -> ByteRange? {
        guard let raw else { return nil }
        let parts = raw.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let span = parts[1].split(separator: "/", maxSplits: 1)[0]
        let bounds = span.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1])
        else { return nil }
        return ByteRange(start: start, end: end)
    }

    private func httpError(status: Int) -> CinemacoreError {
        switch status {
        case 403, 410:
            .http(status: status, code: "expired", message: "The download link expired.")
        case 404:
            .http(status: status, code: "not_found", message: "That download is no longer available.")
        default:
            .http(status: status, code: nil, message: nil)
        }
    }

    private func map(_ error: any Error) -> CinemacoreError {
        guard let urlError = error as? URLError else {
            return .upstream(error.localizedDescription)
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost:
            return .offline
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        default:
            return .upstream(urlError.localizedDescription)
        }
    }

    private func isConnectivityError(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
#endif
