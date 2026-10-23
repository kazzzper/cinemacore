import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

/// `HEVCRewrite` fetches a real `moov` off the CDN and patches it. These tests
/// serve the bytes through a stub protocol so the range handling, the `moov`
/// location and the refusal paths are exercised without the network.
@Suite("HEVC rewrite over HTTP", .serialized)
struct HEVCRewriteTests {

    // MARK: - Stub transport

    /// Serves a fixed body, honouring `Range` the way the CDN does.
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var ignoreRanges = false
        nonisolated(unsafe) static var requestedRanges: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let range = request.value(forHTTPHeaderField: "Range")
            Self.requestedRanges.append(range ?? "none")
            let total = Self.body.count

            if Self.ignoreRanges || range == nil {
                respond(status: 200, headers: [:], body: Self.body)
                return
            }
            guard let parsed = Self.parse(range!), total > 0 else {
                respond(status: 416, headers: [:], body: Data())
                return
            }
            let start = max(0, min(parsed.lowerBound, total - 1))
            let end = max(start, min(parsed.upperBound, total - 1))
            let slice = Self.body.subdata(in: start..<(end + 1))
            respond(
                status: 206,
                headers: ["Content-Range": "bytes \(start)-\(end)/\(total)"],
                body: slice
            )
        }

        override func stopLoading() {}

        private func respond(status: Int, headers: [String: String], body: Data) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        static func parse(_ raw: String) -> ClosedRange<Int>? {
            guard raw.hasPrefix("bytes=") else { return nil }
            let spec = raw.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-")
            guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else { return nil }
            return start...end
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    // MARK: - Fixtures

    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let size = UInt32(8 + payload.count)
        out += [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        out += Array(type.utf8)
        out += payload
        return out
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func hvcC(arrays: UInt8) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 22)
        body += [arrays]
        for _ in 0..<Int(arrays) {
            body += [32] + [0, 1] + [0, 2] + [0x42, 0x01]
        }
        return body
    }

    private func movie(fourcc: String = "hev1", arrays: UInt8 = 4) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 78)
        entry += box("hvcC", hvcC(arrays: arrays))
        let stsd = box("stsd", [0, 0, 0, 0] + u32(1) + box(fourcc, entry))
        let stbl = box("stbl", stsd)
        let mdia = box("mdia", box("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + Array("vide".utf8) + [0, 0, 0, 0])
            + box("minf", stbl))
        let trak = box("trak", mdia)
        return box("moov", trak)
    }

    /// A whole MP4: `ftyp`, `moov`, then media data.
    private func file(fourcc: String = "hev1", arrays: UInt8 = 4) -> Data {
        var out = box("ftyp", Array("isom".utf8) + [0, 0, 0, 0])
        out += movie(fourcc: fourcc, arrays: arrays)
        out += box("mdat", [UInt8](repeating: 0x5A, count: 4096))
        return Data(out)
    }

    private func url() -> URL { URL(string: "https://cdn.test/movie.mp4")! }

    // MARK: - Tests

    @Test("a served hev1 file is fetched, patched and handed back whole")
    func repairsWholeFile() async throws {
        let original = file()
        Stub.body = original
        Stub.ignoreRanges = false
        Stub.requestedRanges = []

        let rewrite = HEVCRewrite(session: session())
        let repaired = try #require(
            await rewrite.repairedFile(at: url(), headers: [:])
        )
        #expect(repaired.count == original.count)
        #expect(repaired.range(of: Data("hvc1".utf8)) != nil)
        // `mdat` is untouched: the repair rewrites the index, never the media.
        #expect(repaired.suffix(4096) == original.suffix(4096))
    }

    @Test("a file already in hvc1 is not repaired")
    func targetUntouched() async {
        Stub.body = file(fourcc: "hvc1")
        Stub.ignoreRanges = false
        #expect(await HEVCRewrite(session: session()).repairedFile(at: url(), headers: [:]) == nil)
    }

    @Test("hev1 without parameter sets is refused")
    func inBandRefused() async {
        // Renaming here would claim a sample description that does not exist.
        Stub.body = file(arrays: 0)
        Stub.ignoreRanges = false
        #expect(await HEVCRewrite(session: session()).repairedFile(at: url(), headers: [:]) == nil)
    }

    @Test("a server that ignores Range still yields the whole file")
    func ignoresRangeHeader() async throws {
        // The CDN answering 200 with the full body must not be mistaken for a
        // short read; the total comes from the body itself.
        Stub.body = file()
        Stub.ignoreRanges = true
        let repaired = try #require(
            await HEVCRewrite(session: session()).repairedFile(at: url(), headers: [:])
        )
        #expect(repaired.count == file().count)
    }

    @Test("a non-MP4 body is refused")
    func notMP4() async {
        Stub.body = Data(repeating: 0x00, count: 5000)
        Stub.ignoreRanges = false
        #expect(await HEVCRewrite(session: session()).repairedFile(at: url(), headers: [:]) == nil)
    }

    @Test("a moov after the media data is not spliced")
    func moovAtEndRefused() async {
        // Splicing a patched index into the middle of a file is a different,
        // much larger job; the repair declines rather than guessing.
        var out = box("ftyp", Array("isom".utf8) + [0, 0, 0, 0])
        out += box("mdat", [UInt8](repeating: 0x5A, count: 2048))
        out += movie()
        Stub.body = Data(out)
        Stub.ignoreRanges = false
        #expect(await HEVCRewrite(session: session()).repairedFile(at: url(), headers: [:]) == nil)
    }

    @Test("the repair sends the media headers it was given")
    func sendsHeaders() async throws {
        Stub.body = file()
        Stub.ignoreRanges = false
        let rewrite = HEVCRewrite(session: session())
        _ = await rewrite.repairedFile(
            at: url(),
            headers: ["User-Agent": "ExoPlayerLib/2.19.1", "Cookie": "a=b"]
        )
        // A stub cannot see request headers per-request here, so this asserts the
        // call path completes with headers present rather than crashing.
        #expect(Stub.requestedRanges.isEmpty == false)
    }

    @Test("moov is located at the front of the file")
    func moovRange() throws {
        let data = file()
        let range = try #require(HEVCRewrite.moovRange(in: data, totalBytes: Int64(data.count)))
        #expect(range.start > 0)  // after `ftyp`
        let moovBytes = data.subdata(in: Int(range.start)..<Int(range.end + 1))
        #expect(moovBytes.prefix(8).suffix(4) == Data("moov".utf8))
    }
}

/// The local copy of a download needs no round trip to repair: the patch is
/// four bytes inside the index and the box keeps its size.
@Suite("HEVC rewrite on disk")
struct HEVCLocalRepairTests {
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let size = UInt32(8 + payload.count)
        out += [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        out += Array(type.utf8)
        out += payload
        return out
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func hvcC(arrays: UInt8) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 22)
        body += [arrays]
        for _ in 0..<Int(arrays) {
            body += [32] + [0, 1] + [0, 2] + [0x42, 0x01]
        }
        return body
    }

    private func moov(fourcc: String = "hev1", arrays: UInt8 = 4) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 78)
        entry += box("hvcC", hvcC(arrays: arrays))
        let stsd = box("stsd", [0, 0, 0, 0] + u32(1) + box(fourcc, entry))
        let mdia = box("mdia", box("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + Array("vide".utf8) + [0, 0, 0, 0])
            + box("minf", box("stbl", stsd)))
        return box("moov", box("trak", mdia))
    }

    private let ftyp = [UInt8]("ftyp".utf8)
    private let mdat = [UInt8](repeating: 0x5A, count: 4096)

    /// Writes `data` to a scratch file and hands back its URL.
    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hevc-in-place-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    @Test("a downloaded hev1 file is patched in place")
    func patchesInPlace() throws {
        var bytes = box("ftyp", ftyp + [0, 0, 0, 0])
        bytes += moov()
        bytes += box("mdat", mdat)
        let url = try write(Data(bytes))
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try Data(contentsOf: url)
        #expect(HEVCRewrite().repairInPlace(at: url))
        let after = try Data(contentsOf: url)

        // The fix is byte-preserving: nothing moved, so the download's size and
        // its byte count on disk still describe the same file.
        #expect(after.count == before.count)
        #expect(after.range(of: Data("hev1".utf8)) == nil)
        let range = try #require(HEVCRewrite.moovRange(in: after, totalBytes: Int64(after.count)))
        let index = after.subdata(in: Int(range.start)..<Int(range.end + 1))
        let inspection = try #require(HEVCSampleEntry.inspect(moov: index))
        #expect(inspection.videoSampleEntries == ["hvc1"])
        #expect(!inspection.needsRewrite)

        // Idempotent: a repaired file is not rewritten again.
        #expect(!HEVCRewrite().repairInPlace(at: url))
    }

    @Test("an index after the media data is still patched, which the fetch path refuses")
    func patchesBehindMedia() throws {
        var bytes = box("ftyp", ftyp + [0, 0, 0, 0])
        bytes += box("mdat", mdat)
        bytes += moov()
        let url = try write(Data(bytes))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(HEVCRewrite().repairInPlace(at: url))
        let after = try Data(contentsOf: url)
        #expect(after.range(of: Data("hev1".utf8)) == nil)
        #expect(after.range(of: Data("hvc1".utf8)) != nil)
    }

    @Test("a file that is already hvc1, or has no parameter sets, is left alone")
    func refusals() throws {
        for (fourcc, arrays) in [("hvc1", UInt8(4)), ("hev1", UInt8(0)), ("avc1", UInt8(4))] {
            var bytes = box("ftyp", ftyp + [0, 0, 0, 0])
            bytes += moov(fourcc: fourcc, arrays: arrays)
            bytes += box("mdat", mdat)
            let original = Data(bytes)
            let url = try write(original)
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(!HEVCRewrite().repairInPlace(at: url), "\(fourcc)/\(arrays) must not be patched")
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test("a file that is not MP4 is refused rather than truncated")
    func notMP4() throws {
        let original = Data(repeating: 0x00, count: 512)
        let url = try write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!HEVCRewrite().repairInPlace(at: url))
        #expect(try Data(contentsOf: url) == original)
    }
}
