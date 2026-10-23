import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

// MARK: - Box fixtures

private func bigEndian32(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}

private func bigEndian64(_ value: UInt64) -> Data {
    var data = Data()
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
    return data
}

private func joined(_ parts: Data...) -> Data {
    var data = Data()
    for part in parts { data.append(part) }
    return data
}

private func box(_ type: String, _ payload: Data, extended: Bool = false) -> Data {
    var data = Data()
    if extended {
        data.append(bigEndian32(1))
        data.append(Data(type.utf8))
        data.append(bigEndian64(UInt64(payload.count + 16)))
    } else {
        data.append(bigEndian32(UInt32(payload.count + 8)))
        data.append(Data(type.utf8))
    }
    data.append(payload)
    return data
}

/// A box whose size field is 0, meaning "to EOF".
private func openEndedBox(_ type: String, _ payload: Data) -> Data {
    joined(bigEndian32(0), Data(type.utf8), payload)
}

private func moovPayload(_ size: Int = 64) -> Data {
    Data(repeating: 0x11, count: size)
}

private let ftyp = box("ftyp", Data("isom".utf8) + Data([0, 0, 0, 0]))

private func makeURL(_ path: String) -> URL {
    guard let url = URL(string: "https://cdn.test\(path)") else {
        preconditionFailure("the test URL builder produced an invalid URL for \(path)")
    }
    return url
}

private func uniqueDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cinemacore-moov-\(UUID().uuidString)", isDirectory: true)
}

private func removeDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Ranged HTTP stub

/// Serves one synthetic file per path and honours `Range`, so the prefetch can
/// be exercised without a live CDN. The route table is process-global, hence
/// the `.serialized` suites below.
final class RangeStubURLProtocol: URLProtocol {
    struct Route: Sendable {
        var bytes: Data
        var honorsRange: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        recorded = []
    }

    static func serve(path: String, bytes: Data, honorsRange: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = Route(bytes: bytes, honorsRange: honorsRange)
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let route = Self.routes[request.url?.path ?? ""]
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let route else {
            respond(url: url, status: 404, body: Data(), headers: [:])
            return
        }
        guard route.honorsRange else {
            respond(
                url: url,
                status: 200,
                body: route.bytes,
                headers: [
                    "Content-Length": "\(route.bytes.count)",
                    "Accept-Ranges": "none",
                ]
            )
            return
        }
        guard let bounds = Self.parseRange(request.value(forHTTPHeaderField: "Range")),
              bounds.start < route.bytes.count
        else {
            respond(url: url, status: 416, body: Data(), headers: [:])
            return
        }
        let end = min(bounds.end, route.bytes.count - 1)
        let body = route.bytes.subdata(in: bounds.start..<(end + 1))
        respond(
            url: url,
            status: 206,
            body: body,
            headers: [
                "Content-Range": "bytes \(bounds.start)-\(end)/\(route.bytes.count)",
                "Content-Length": "\(body.count)",
            ]
        )
    }

    override func stopLoading() {}

    private func respond(url: URL, status: Int, body: Data, headers: [String: String]) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func parseRange(_ value: String?) -> (start: Int, end: Int)? {
        guard let value, value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst("bytes=".count).split(separator: "-")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1])
        else { return nil }
        return (start, end)
    }
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeStubURLProtocol.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}

// MARK: - Parser

@Suite("MP4 moov parsing")
struct MP4ProgressiveParserTests {

    @Test("finds a moov at the head with an exact inclusive range")
    func headMoov() throws {
        let moov = box("moov", moovPayload(128))
        let file = joined(ftyp, moov)

        let range = try #require(MP4Progressive.moovRange(
            prefix: file,
            suffix: Data(),
            totalBytes: Int64(file.count)
        ))

        #expect(range == ByteRange(start: Int64(ftyp.count), end: Int64(file.count) - 1))
    }

    @Test("finds a moov at the tail across the prefix and suffix probes")
    func tailMoov() throws {
        let mdat = box("mdat", Data(repeating: 0xAB, count: 6_000))
        let moov = box("moov", moovPayload(256))
        let file = joined(ftyp, mdat, moov)
        let prefix = Data(file.prefix(1_024))
        let suffix = Data(file.suffix(1_024))

        let range = try #require(MP4Progressive.moovRange(
            prefix: prefix,
            suffix: suffix,
            totalBytes: Int64(file.count)
        ))

        #expect(range == ByteRange(
            start: Int64(file.count - moov.count),
            end: Int64(file.count) - 1
        ))
        // The prefix alone stops inside mdat, so it cannot invent the box.
        #expect(MP4Progressive.moovRange(
            prefix: prefix,
            suffix: Data(),
            totalBytes: Int64(file.count)
        ) == nil)
    }

    @Test("reads a 64-bit box size")
    func extendedSize() throws {
        let moov = box("moov", moovPayload(200), extended: true)
        let file = joined(ftyp, moov)

        let range = try #require(MP4Progressive.moovRange(
            prefix: file,
            suffix: Data(),
            totalBytes: Int64(file.count)
        ))

        #expect(range == ByteRange(start: Int64(ftyp.count), end: Int64(file.count) - 1))
    }

    @Test("treats a size-0 moov as running to EOF")
    func openEndedSize() throws {
        let moov = openEndedBox("moov", moovPayload(96))
        let file = joined(ftyp, moov)

        let range = try #require(MP4Progressive.moovRange(
            prefix: file,
            suffix: Data(),
            totalBytes: Int64(file.count)
        ))

        #expect(range == ByteRange(start: Int64(ftyp.count), end: Int64(file.count) - 1))
    }

    @Test("rejects a size that runs past the advertised total")
    func sizePastTotal() {
        let file = joined(ftyp, box("moov", moovPayload(32)))
        #expect(MP4Progressive.moovRange(
            prefix: file,
            suffix: Data(),
            totalBytes: Int64(file.count - 1)
        ) == nil)
    }

    @Test("rejects a header truncated by the probe")
    func truncatedHeader() {
        let file = joined(ftyp, bigEndian32(200), Data("mo".utf8))
        #expect(MP4Progressive.moovRange(
            prefix: file,
            suffix: Data(),
            totalBytes: 1_000
        ) == nil)
        #expect(MP4Progressive.moovRange(
            prefix: Data([0, 0, 0, 1]),
            suffix: Data(),
            totalBytes: 1_000
        ) == nil)
    }

    @Test("returns nil for garbage")
    func garbage() {
        #expect(MP4Progressive.moovRange(
            prefix: Data([0x00, 0x01, 0x02, 0x03]),
            suffix: Data(),
            totalBytes: 4
        ) == nil)
        #expect(MP4Progressive.moovRange(
            prefix: Data(repeating: 0xFF, count: 64),
            suffix: Data(),
            totalBytes: 64
        ) == nil)
        #expect(MP4Progressive.moovRange(
            prefix: Data(),
            suffix: Data(),
            totalBytes: 0
        ) == nil)
    }

    @Test("ignores moov bytes spelled inside an mdat payload")
    func mdatFalsePositive() throws {
        // The fake has a plausible header and size, but the bytes after it are
        // 0xFF, so its box walk cannot reach EOF. Only the real moov can.
        let fakeMoov = box("moov", Data(repeating: 0xFF, count: 24))
        var payload = Data(repeating: 0xFF, count: 2 << 20)
        payload.replaceSubrange(
            (payload.count - 300_000)..<(payload.count - 300_000 + fakeMoov.count),
            with: fakeMoov
        )
        let mdat = box("mdat", payload)
        let moov = box("moov", moovPayload(128))
        let file = joined(ftyp, mdat, moov)
        let suffix = Data(file.suffix(1 << 20))

        // An empty prefix forces the unaligned suffix scanner.
        let range = try #require(MP4Progressive.moovRange(
            prefix: Data(),
            suffix: suffix,
            totalBytes: Int64(file.count)
        ))

        #expect(range == ByteRange(
            start: Int64(file.count - moov.count),
            end: Int64(file.count) - 1
        ))
        // The real prefix proves the mdat boundary, so the same answer comes
        // from the aligned path without ever reading the payload.
        #expect(MP4Progressive.moovRange(
            prefix: Data(file.prefix(1 << 20)),
            suffix: suffix,
            totalBytes: Int64(file.count)
        ) == range)
    }
}

// MARK: - Prefetch

@Suite("MP4 progressive metadata", .serialized)
struct MP4ProgressiveMetadataTests {

    private func metadata(
        for path: String = "/movie.mp4",
        headers: [String: String] = [:],
        totalBytes: Int64,
        cacheDirectory: URL
    ) async throws -> MP4ProgressiveMetadata {
        try await MP4Progressive.metadata(
            url: makeURL(path),
            headers: headers,
            totalBytes: totalBytes,
            cacheDirectory: cacheDirectory,
            session: stubSession()
        )
    }

    @Test("prefetches exactly the head moov and caches it")
    func headMoov() async throws {
        RangeStubURLProtocol.reset()
        let moov = box("moov", moovPayload(512))
        let file = joined(ftyp, moov)
        RangeStubURLProtocol.serve(path: "/movie.mp4", bytes: file)
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let result = try await metadata(
            headers: ["Cookie": "session=abc"],
            totalBytes: Int64(file.count),
            cacheDirectory: directory
        )

        let range = try #require(result.moovRange)
        #expect(range == ByteRange(start: Int64(ftyp.count), end: Int64(file.count) - 1))
        // A file smaller than the default floor is ready only when whole.
        #expect(result.readyThreshold == Int64(file.count))

        let moovURL = try #require(result.moovURL)
        #expect(try Data(contentsOf: moovURL) == moov)
        #expect(moovURL.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL)

        // One probe (the prefix covered the file) plus one exact moov request.
        let requests = RangeStubURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "Range")
            == "bytes=\(range.start)-\(range.end)")
        // Caller headers pass through untouched and no signing header is added.
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "session=abc"
        })
    }

    @Test("a tail moov keeps the default threshold and is fetched alone")
    func tailMoov() async throws {
        RangeStubURLProtocol.reset()
        let moov = box("moov", moovPayload(4_096))
        let total = Int64(9 << 20)
        let mdatBytes = Int(total) - ftyp.count - moov.count - 8
        let file = joined(ftyp, box("mdat", Data(repeating: 0xAB, count: mdatBytes)), moov)
        #expect(Int64(file.count) == total)
        RangeStubURLProtocol.serve(path: "/movie.mp4", bytes: file)
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let result = try await metadata(totalBytes: total, cacheDirectory: directory)

        let range = try #require(result.moovRange)
        #expect(range == ByteRange(
            start: Int64(file.count - moov.count),
            end: Int64(file.count) - 1
        ))
        // A tail moov must not force the player to wait for the whole film.
        #expect(result.readyThreshold == MP4Progressive.defaultReadyBytes)
        let moovURL = try #require(result.moovURL)
        #expect(try Data(contentsOf: moovURL) == moov)

        let moovHeader = "bytes=\(range.start)-\(range.end)"
        let firstRequests = RangeStubURLProtocol.requests
        #expect(firstRequests.contains { $0.value(forHTTPHeaderField: "Range") == moovHeader })
        #expect(firstRequests.allSatisfy {
            guard let header = $0.value(forHTTPHeaderField: "Range") else { return true }
            // Every request is bounded by one probe or the moov itself.
            return header == moovHeader
                || header == "bytes=0-\(MP4Progressive.probeBytes - 1)"
                || header == "bytes=\(total - MP4Progressive.probeBytes)-\(total - 1)"
        })

        // The second call still probes for the box, but the bytes are reused.
        let second = try await metadata(totalBytes: total, cacheDirectory: directory)
        #expect(second.moovRange == range)
        #expect(second.moovURL == moovURL)
        #expect(RangeStubURLProtocol.requests.filter {
            $0.value(forHTTPHeaderField: "Range") == moovHeader
        }.count == 1)
    }

    @Test("a corrupt cache file is replaced")
    func corruptCache() async throws {
        RangeStubURLProtocol.reset()
        let moov = box("moov", moovPayload(64))
        let file = joined(ftyp, moov)
        RangeStubURLProtocol.serve(path: "/movie.mp4", bytes: file)
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let first = try await metadata(totalBytes: Int64(file.count), cacheDirectory: directory)
        let moovURL = try #require(first.moovURL)
        try Data("garbage".utf8).write(to: moovURL)

        let second = try await metadata(totalBytes: Int64(file.count), cacheDirectory: directory)
        #expect(second.moovURL == moovURL)
        #expect(try Data(contentsOf: moovURL) == moov)
    }

    @Test("a range-ignoring server yields the fallback and writes nothing")
    func rangeIgnored() async throws {
        RangeStubURLProtocol.reset()
        let moov = box("moov", moovPayload(128))
        let file = joined(ftyp, box("mdat", Data(repeating: 0xCD, count: 2 << 20)), moov)
        RangeStubURLProtocol.serve(path: "/movie.mp4", bytes: file, honorsRange: false)
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let result = try await metadata(totalBytes: Int64(file.count), cacheDirectory: directory)

        #expect(result.moovRange == nil)
        #expect(result.moovURL == nil)
        #expect(result.readyThreshold == min(Int64(file.count), MP4Progressive.defaultReadyBytes))
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test("a failing server yields the fallback without throwing")
    func serverFailure() async throws {
        RangeStubURLProtocol.reset()
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let total: Int64 = 4 << 20
        let result = try await metadata(totalBytes: total, cacheDirectory: directory)

        #expect(result.moovRange == nil)
        #expect(result.moovURL == nil)
        #expect(result.readyThreshold == min(total, MP4Progressive.defaultReadyBytes))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("an unknown total uses the default threshold without any request")
    func unknownTotal() async throws {
        RangeStubURLProtocol.reset()
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }

        let result = try await metadata(totalBytes: 0, cacheDirectory: directory)

        #expect(result.moovRange == nil)
        #expect(result.moovURL == nil)
        #expect(result.readyThreshold == MP4Progressive.defaultReadyBytes)
        #expect(RangeStubURLProtocol.requests.isEmpty)
    }
}
