import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A loopback-only HTTP/1.1 server for growing download files.
///
/// The public surface is intentionally small: the app registers an asset, asks
/// for its URL, and stops the server when it leaves the foreground. Range
/// parsing and response selection live behind this seam.
public actor ProgressiveAssetServer {
    private let store: ProgressiveAssetStore
    private let host: String
    private var baseURL: URL?
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var token: String?
    /// An actor is re-entrant across `await`, so the `channel == nil` guard alone
    /// lets two concurrent callers bind two listeners. Sharing the in-flight
    /// bind keeps `start()` idempotent for both sequential and concurrent calls.
    private var startTask: Task<Void, Error>?

    public init(store: ProgressiveAssetStore, host: String = "127.0.0.1") {
        self.store = store
        self.host = host
    }

    /// Binds an ephemeral loopback port. Calling it twice is a no-op.
    public func start() async throws {
        guard channel == nil else { return }
        if let startTask {
            try await startTask.value
            return
        }

        let task = Task { try await self.bind() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func bind() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let token = UUID().uuidString.lowercased()
        let store = self.store

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProgressiveAssetHTTPHandler(store: store, token: token))
                }
            }

        var bound: Channel?
        do {
            let channel = try await bootstrap.bind(host: host, port: 0).get()
            bound = channel
            guard let port = channel.localAddress?.port,
                  let baseURL = URL(string: "http://\(host):\(port)")
            else {
                throw CinemacoreError.upstream("The progressive asset server bound an address it cannot express as a URL.")
            }
            self.channel = channel
            self.group = group
            self.token = token
            self.baseURL = baseURL
        } catch {
            // A failed start must not leave the listener or its event loop behind.
            if let bound { try? await bound.close().get() }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async {
        let channel = self.channel
        let group = self.group

        // Clear first: a caller asking for a URL while shutdown awaits must see
        // the server as stopped, and the actor is re-entrant across the awaits.
        self.channel = nil
        self.group = nil
        self.token = nil
        self.baseURL = nil

        if let channel { try? await channel.close().get() }
        if let group { try? await group.shutdownGracefully() }
    }

    /// The URL the player should hand to `AVURLAsset`. `nil` until the server
    /// has started or when the asset is not registered.
    public func url(for assetID: String) async -> URL? {
        guard let baseURL, let token else { return nil }
        guard await store.asset(assetID) != nil else { return nil }
        // `stop()` may have run while the store hop was in flight.
        guard self.baseURL == baseURL, self.token == token else { return nil }
        return baseURL
            .appendingPathComponent("asset", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
            .appendingPathComponent(assetID)
    }
}

/// One request at a time per connection; NIO confines a handler to its channel's
/// event loop, so the mutable head slot needs no lock.
private final class ProgressiveAssetHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: ProgressiveAssetStore
    private let token: String
    private var pendingHead: HTTPRequestHead?
    /// Keeps pipelined responses in request order. The store call itself may
    /// finish out of order, but the writes are chained.
    private var lastWrite: EventLoopFuture<Void>?

    init(store: ProgressiveAssetStore, token: String) {
        self.store = store
        self.token = token
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
        case .body:
            break
        case .end:
            guard let head = pendingHead else { return }
            pendingHead = nil

            let channel = context.channel
            let eventLoop = context.eventLoop
            let store = self.store
            let token = self.token
            let method = head.method.rawValue
            let uri = head.uri
            let rangeHeader = head.headers.first(name: "Range")

            let response = eventLoop.makeFutureWithTask {
                await Self.response(
                    store: store,
                    token: token,
                    method: method,
                    uri: uri,
                    rangeHeader: rangeHeader
                )
            }
            let previous = lastWrite ?? eventLoop.makeSucceededVoidFuture()
            let write = previous
                .always { _ in }
                .flatMap { _ in response }
                .flatMap { response in
                    Self.write(response, to: channel)
                }
            lastWrite = write
        }
    }

    private static func response(
        store: ProgressiveAssetStore,
        token: String,
        method: String,
        uri: String,
        rangeHeader: String?
    ) async -> ProgressiveAssetResponse {
        guard method == "GET" || method == "HEAD" else {
            return ProgressiveAssetResponse(
                status: 405,
                headers: ["Allow": "GET, HEAD", "Content-Length": "0", "Cache-Control": "no-store"]
            )
        }
        guard let assetID = assetID(from: uri, token: token) else {
            return ProgressiveAssetResponse(
                status: 404,
                headers: ["Content-Length": "0", "Cache-Control": "no-store"]
            )
        }
        return await store.response(for: assetID, method: method, rangeHeader: rangeHeader)
    }

    /// `/asset/<token>/<assetID>`; anything else is indistinguishable from a
    /// missing asset so a stale token cannot probe the registry.
    private static func assetID(from uri: String, token: String) -> String? {
        let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? uri
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].isEmpty,
              parts[1] == "asset",
              parts[2] == Substring(token)
        else { return nil }
        let raw = String(parts[3])
        return raw.removingPercentEncoding ?? raw
    }

    private static func write(
        _ response: ProgressiveAssetResponse,
        to channel: Channel
    ) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        let httpStatus = HTTPResponseStatus(statusCode: response.status)

        switch response.body {
        case .empty:
            channel.write(HTTPServerResponsePart.head(HTTPResponseHead(
                version: .http1_1,
                status: httpStatus,
                headers: headers
            )), promise: nil)
            return channel.writeAndFlush(HTTPServerResponsePart.end(nil))

        case .bytes(let data):
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.write(HTTPServerResponsePart.head(HTTPResponseHead(
                version: .http1_1,
                status: httpStatus,
                headers: headers
            )), promise: nil)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            return channel.writeAndFlush(HTTPServerResponsePart.end(nil))

        case .file(let url, let range):
            // The store only produces a file body for bytes it has already
            // counted, so an open failure is a race with a truncating writer.
            guard range.start >= 0, range.end < Int64(Int.max) else {
                return write(Self.retryResponse(), to: channel)
            }
            guard let handle = openHandle(at: url) else {
                return write(Self.retryResponse(), to: channel)
            }

            let region = FileRegion(
                fileHandle: handle,
                readerIndex: Int(range.start),
                endIndex: Int(range.end) + 1
            )
            channel.write(HTTPServerResponsePart.head(HTTPResponseHead(
                version: .http1_1,
                status: httpStatus,
                headers: headers
            )), promise: nil)
            channel.write(HTTPServerResponsePart.body(.fileRegion(region)), promise: nil)
            let flushed = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            // FileRegion does not own the descriptor's lifetime; the write must
            // finish before the handle is closed.
            flushed.whenComplete { _ in try? handle.close() }
            return flushed
        }
    }

    private static func openHandle(at url: URL) -> NIOFileHandle? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        return NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: descriptor)
    }

    private static func retryResponse() -> ProgressiveAssetResponse {
        ProgressiveAssetResponse(
            status: 503,
            headers: [
                "Content-Length": "0",
                "Cache-Control": "no-store",
                "Retry-After": "1",
            ]
        )
    }
}
