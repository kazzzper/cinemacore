import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

// MARK: - Fixtures

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cinemacore-progressive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}

/// Starts a real loopback server for the duration of `body`; every test that
/// needs a socket goes through here so no test can leak a listener.
private func withRunningServer<T>(
    store: ProgressiveAssetStore,
    _ body: (ProgressiveAssetServer) async throws -> T
) async throws -> T {
    let server = ProgressiveAssetServer(store: store)
    try await server.start()
    do {
        let value = try await body(server)
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

private func request(
    _ url: URL,
    method: String = "GET",
    range: String? = nil,
    session: URLSession
) async throws -> (HTTPURLResponse, Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let (data, response) = try await session.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return (http, data)
}

private func write(_ string: String, to url: URL) throws {
    try Data(string.utf8).write(to: url)
}

private func append(_ string: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(string.utf8))
}

// MARK: - HTTP behavior

@Test func servesHeadPrefixAndRanges() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("partial.part")
        let complete = directory.appendingPathComponent("complete.mp4")
        try write("0123456789", to: partial)
        try write("abcdefghij", to: complete)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "partial",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("partial.mp4"),
            totalBytes: 100
        ))
        await store.register(ProgressiveAsset(
            id: "complete",
            partialURL: directory.appendingPathComponent("complete.part"),
            completeURL: complete,
            totalBytes: 10,
            contentType: "video/mp4"
        ))

        try await withRunningServer(store: store) { server in
            let session = makeSession()
            defer { session.invalidateAndCancel() }

            let partialBase = try #require(await server.url(for: "partial"))

            let (head, headBody) = try await request(partialBase, method: "HEAD", session: session)
            #expect(head.statusCode == 200)
            #expect(head.value(forHTTPHeaderField: "Content-Length") == "100")
            #expect(head.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
            #expect(head.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
            #expect(head.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(headBody.isEmpty)

            // No Range: the growing prefix is all that exists, so it is a 206
            // with a Content-Range naming the eventual total.
            let (prefix, prefixBody) = try await request(partialBase, session: session)
            #expect(prefix.statusCode == 206)
            #expect(prefix.value(forHTTPHeaderField: "Content-Range") == "bytes 0-9/100")
            #expect(prefixBody == Data("0123456789".utf8))

            let (middle, middleBody) = try await request(partialBase, range: "bytes=4-9", session: session)
            #expect(middle.statusCode == 206)
            #expect(middle.value(forHTTPHeaderField: "Content-Range") == "bytes 4-9/100")
            #expect(middleBody == Data("456789".utf8))

            // Open-ended ranges are clamped to the committed prefix.
            let (openEnded, openBody) = try await request(partialBase, range: "bytes=4-", session: session)
            #expect(openEnded.statusCode == 206)
            #expect(openEnded.value(forHTTPHeaderField: "Content-Range") == "bytes 4-9/100")
            #expect(openBody == Data("456789".utf8))

            let completeBase = try #require(await server.url(for: "complete"))
            let (full, fullBody) = try await request(completeBase, session: session)
            #expect(full.statusCode == 200)
            #expect(full.value(forHTTPHeaderField: "Content-Length") == "10")
            #expect(fullBody == Data("abcdefghij".utf8))

            let (suffix, suffixBody) = try await request(completeBase, range: "bytes=-3", session: session)
            #expect(suffix.statusCode == 206)
            #expect(suffix.value(forHTTPHeaderField: "Content-Range") == "bytes 7-9/10")
            #expect(suffixBody == Data("hij".utf8))

            let (invalid, invalidBody) = try await request(partialBase, range: "bytes=5-1", session: session)
            #expect(invalid.statusCode == 416)
            #expect(invalid.value(forHTTPHeaderField: "Content-Range") == "bytes */100")
            #expect(invalidBody.isEmpty)

            let (multi, _) = try await request(partialBase, range: "bytes=0-1,3-4", session: session)
            #expect(multi.statusCode == 416)
        }
    }
}

@Test func rejectsUnknownAssetsAndWrongTokens() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("asset.part")
        try write("0123456789", to: partial)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "known",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("asset.mp4"),
            totalBytes: 100
        ))

        try await withRunningServer(store: store) { server in
            let session = makeSession()
            defer { session.invalidateAndCancel() }

            let base = try #require(await server.url(for: "known"))
            var components = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))

            components.path = "/asset/not-the-token/known"
            let wrongToken = try #require(components.url)
            let (wrongTokenResponse, _) = try await request(wrongToken, session: session)
            #expect(wrongTokenResponse.statusCode == 404)

            components.path = "/asset"
            let wrongPath = try #require(components.url)
            let (wrongPathResponse, _) = try await request(wrongPath, session: session)
            #expect(wrongPathResponse.statusCode == 404)

            components.path = "/asset/not-the-token/missing"
            let unknown = try #require(components.url)
            let (unknownResponse, _) = try await request(unknown, session: session)
            #expect(unknownResponse.statusCode == 404)

            let knownUnknown = base.deletingLastPathComponent().appendingPathComponent("missing")
            let (storeUnknown, _) = try await request(knownUnknown, session: session)
            #expect(storeUnknown.statusCode == 404)

            let (post, _) = try await request(base, method: "POST", session: session)
            #expect(post.statusCode == 405)
            #expect(post.value(forHTTPHeaderField: "Allow") == "GET, HEAD")
        }
    }
}

@Test func appendedBytesAreVisibleToTheNextRequest() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("growing.part")
        try write("0123456789", to: partial)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "growing",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("growing.mp4"),
            totalBytes: 100
        ))

        try await withRunningServer(store: store) { server in
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let url = try #require(await server.url(for: "growing"))

            let (before, beforeBody) = try await request(url, session: session)
            #expect(before.statusCode == 206)
            #expect(before.value(forHTTPHeaderField: "Content-Range") == "bytes 0-9/100")
            #expect(beforeBody.count == 10)

            try append("abcdefghij", to: partial)

            let (after, afterBody) = try await request(url, session: session)
            #expect(after.statusCode == 206)
            #expect(after.value(forHTTPHeaderField: "Content-Range") == "bytes 0-19/100")
            #expect(afterBody == Data("0123456789abcdefghij".utf8))
        }
    }
}

@Test func rangeBeyondThePrefixAsksThePlayerToRetry() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("short.part")
        try write("0123456789", to: partial)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "short",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("short.mp4"),
            totalBytes: 100
        ))

        try await withRunningServer(store: store) { server in
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let url = try #require(await server.url(for: "short"))

            let (response, body) = try await request(url, range: "bytes=50-59", session: session)
            #expect(response.statusCode == 503)
            #expect(response.value(forHTTPHeaderField: "Retry-After") == "1")
            #expect(body.isEmpty)

            // A suffix names bytes at the end of the eventual file, which are
            // still ahead of the committed prefix.
            let (suffix, suffixBody) = try await request(url, range: "bytes=-4", session: session)
            #expect(suffix.statusCode == 503)
            #expect(suffix.value(forHTTPHeaderField: "Retry-After") == "1")
            #expect(suffixBody.isEmpty)

            // Past the advertised total is unsatisfiable, not retryable.
            let (pastEnd, _) = try await request(url, range: "bytes=100-", session: session)
            #expect(pastEnd.statusCode == 416)
            #expect(pastEnd.value(forHTTPHeaderField: "Content-Range") == "bytes */100")
        }
    }
}

@Test func prefetchedMoovIsServedAheadOfThePrefix() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("moov.part")
        let moov = directory.appendingPathComponent("moov.bin")
        try write("0123456789", to: partial)
        try write("MOOVDATA!!", to: moov)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "moov",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("moov.mp4"),
            totalBytes: 100,
            moovRange: ByteRange(start: 50, end: 59),
            moovURL: moov
        ))

        try await withRunningServer(store: store) { server in
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let url = try #require(await server.url(for: "moov"))

            let (fullMoov, fullMoovBody) = try await request(url, range: "bytes=50-59", session: session)
            #expect(fullMoov.statusCode == 206)
            #expect(fullMoov.value(forHTTPHeaderField: "Content-Range") == "bytes 50-59/100")
            #expect(fullMoovBody == Data("MOOVDATA!!".utf8))

            let (sliced, slicedBody) = try await request(url, range: "bytes=56-59", session: session)
            #expect(sliced.statusCode == 206)
            #expect(sliced.value(forHTTPHeaderField: "Content-Range") == "bytes 56-59/100")
            #expect(slicedBody == Data("TA!!".utf8))

            // The hole between the prefix (0-9) and the moov (50-59) is not
            // readable yet, so the player must retry.
            let (gap, _) = try await request(url, range: "bytes=30-39", session: session)
            #expect(gap.statusCode == 503)
            #expect(gap.value(forHTTPHeaderField: "Retry-After") == "1")
        }
    }
}

@Test func startIsIdempotentAndURLsRequireRegistration() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("idempotent.part")
        try write("0123456789", to: partial)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "idempotent",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("idempotent.mp4"),
            totalBytes: 100
        ))

        let server = ProgressiveAssetServer(store: store)
        #expect(await server.url(for: "idempotent") == nil)

        try await server.start()
        let first = try #require(await server.url(for: "idempotent"))
        // A second start must reuse the bound listener, not bind another port.
        try await server.start()
        #expect(await server.url(for: "idempotent") == first)
        #expect(await server.url(for: "absent") == nil)

        await server.stop()
        #expect(await server.url(for: "idempotent") == nil)

        // A stopped server can start again with a fresh token.
        try await server.start()
        let restarted = try #require(await server.url(for: "idempotent"))
        #expect(restarted != first)
        await server.stop()
    }
}

@Test func stopRefusesFurtherURLs() async throws {
    try await withTemporaryDirectory { directory in
        let partial = directory.appendingPathComponent("stop.part")
        try write("0123456789", to: partial)

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "stop",
            partialURL: partial,
            completeURL: directory.appendingPathComponent("stop.mp4"),
            totalBytes: 100
        ))

        let server = ProgressiveAssetServer(store: store)
        try await server.start()
        let started = await server.url(for: "stop")
        #expect(started != nil)

        await server.stop()
        let stopped = await server.url(for: "stop")
        #expect(stopped == nil)

        // Stopping twice stays a no-op.
        await server.stop()
        #expect(await server.url(for: "stop") == nil)
    }
}

// MARK: - Readiness

@Test func isReadyRespectsThresholdAndPrefetchedMoov() async throws {
    try await withTemporaryDirectory { directory in
        let thresholdPart = directory.appendingPathComponent("threshold.part")
        try write("0123", to: thresholdPart)
        let moovPart = directory.appendingPathComponent("moov-ready.part")
        try write("01", to: moovPart)
        let moov = directory.appendingPathComponent("moov-ready.bin")

        let store = ProgressiveAssetStore()
        await store.register(ProgressiveAsset(
            id: "threshold",
            partialURL: thresholdPart,
            completeURL: directory.appendingPathComponent("threshold.mp4"),
            totalBytes: 100,
            readyThreshold: 5
        ))
        await store.register(ProgressiveAsset(
            id: "moov-ready",
            partialURL: moovPart,
            completeURL: directory.appendingPathComponent("moov-ready.mp4"),
            totalBytes: 100,
            moovRange: ByteRange(start: 50, end: 59),
            moovURL: moov,
            readyThreshold: 2
        ))

        let belowThreshold = await store.isReady("threshold")
        #expect(!belowThreshold)

        try append("4", to: thresholdPart)
        let atThreshold = await store.isReady("threshold")
        #expect(atThreshold)

        let moovMissing = await store.isReady("moov-ready")
        #expect(!moovMissing)

        try write("MOOVDATA!!", to: moov)
        let moovPresent = await store.isReady("moov-ready")
        #expect(moovPresent)

        // A renamed download is complete even when the prefetched moov file is
        // gone; there is no gap left for the threshold to gate.
        let finished = directory.appendingPathComponent("finished.mp4")
        try write("0123456789", to: finished)
        await store.register(ProgressiveAsset(
            id: "finished",
            partialURL: directory.appendingPathComponent("finished.part"),
            completeURL: finished,
            totalBytes: 10,
            moovRange: ByteRange(start: 50, end: 59),
            moovURL: directory.appendingPathComponent("finished-moov.bin"),
            readyThreshold: 100
        ))
        #expect(await store.isReady("finished"))

        let unknown = await store.isReady("absent")
        #expect(!unknown)
    }
}
