import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

/// A caption host private to this suite. `CaptionStubURLProtocol` belongs to
/// another suite that runs in parallel, so sharing it would reset its routes.
final class ArchiveCaptionProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        requests = []
    }

    static func stub(_ path: String, status: Int = 200, body: String) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = (status, body)
    }

    static var sentRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let route = Self.routes[request.url?.path ?? ""] ?? (404, "missing")
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: route.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/plain"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Captions saved beside a download are what make a saved episode complete:
/// the picture plus the subtitles, with nothing left to fetch.
@Suite("Subtitle archive", .serialized)
struct SubtitleArchiveTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cinemacore-subtitles-\(UUID().uuidString)", isDirectory: true)
    }

    private let srt = """
    1
    00:00:01,000 --> 00:00:03,000
    Hello there

    2
    00:00:04,000 --> 00:00:06,000
    General Kenobi
    """

    @Test("an SRT caption is saved as WebVTT beside the episode")
    func convertsAndSaves() async throws {
        ArchiveCaptionProtocol.reset()
        ArchiveCaptionProtocol.stub("/en.srt", body: srt)
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SubtitleArchive(directory: directory, session: ArchiveCaptionProtocol.session())

        let saved = await archive.store([
            SubtitleTrack(language: "English", url: "https://caption.test/en.srt", format: "srt"),
        ])

        let subtitle = try #require(saved.first)
        #expect(subtitle.language == "English")
        #expect(subtitle.fileName.hasSuffix(".vtt"))
        let file = directory.appendingPathComponent(subtitle.fileName)
        let body = try String(contentsOf: file, encoding: .utf8)
        #expect(body.hasPrefix("WEBVTT"))
        // The cues survived the conversion, including the comma decimal.
        #expect(body.contains("Hello there"))
        #expect(body.contains("00:00:01.000 --> 00:00:03.000"))

        // What the picker is handed points at the file, not the host.
        let track = subtitle.track(in: directory)
        #expect(track.url.hasPrefix("file://"))
        #expect(track.provider == .downloaded)
        #expect(track.format == "vtt")
    }

    @Test("one dead track loses its language, never the caption that worked")
    func partialFailure() async throws {
        ArchiveCaptionProtocol.reset()
        ArchiveCaptionProtocol.stub("/en.srt", body: srt)
        ArchiveCaptionProtocol.stub("/fr.vtt", status: 404, body: "gone")
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SubtitleArchive(directory: directory, session: ArchiveCaptionProtocol.session())

        let saved = await archive.store([
            SubtitleTrack(language: "English", url: "https://caption.test/en.srt", format: "srt"),
            SubtitleTrack(language: "French", url: "https://caption.test/fr.vtt", format: "vtt"),
        ])

        #expect(saved.map(\.language) == ["English"])
    }

    @Test("the media cookie is sent, because a caption is behind the same door")
    func sendsHeaders() async throws {
        ArchiveCaptionProtocol.reset()
        ArchiveCaptionProtocol.stub("/en.vtt", body: "WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n")
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SubtitleArchive(directory: directory, session: ArchiveCaptionProtocol.session())

        _ = await archive.store(
            [SubtitleTrack(language: "English", url: "https://caption.test/en.vtt")],
            headers: ["Cookie": "a=b", "User-Agent": "Cinema"]
        )

        let request = try #require(ArchiveCaptionProtocol.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "a=b")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Cinema")
    }

    @Test("the same track listed twice is saved once and the page size is honoured")
    func dedupesAndCaps() async throws {
        ArchiveCaptionProtocol.reset()
        ArchiveCaptionProtocol.stub("/en.vtt", body: "WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n")
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SubtitleArchive(directory: directory, session: ArchiveCaptionProtocol.session())
        let track = SubtitleTrack(language: "English", url: "https://caption.test/en.vtt")

        let saved = await archive.store([track, track])
        #expect(saved.count == 1)

        // The provider lists one caption per release it matched; the cap is the
        // difference between a finished download and a stalled one.
        let many = (0..<20).map {
            SubtitleTrack(language: "English", url: "https://caption.test/en.vtt?n=\($0)")
        }
        let capped = await archive.store(many, limit: 3)
        #expect(capped.count == 3)
    }

    @Test("an empty body is not saved as a broken track")
    func emptyBody() async {
        ArchiveCaptionProtocol.reset()
        ArchiveCaptionProtocol.stub("/en.vtt", body: "   \n")
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SubtitleArchive(directory: directory, session: ArchiveCaptionProtocol.session())

        let saved = await archive.store([
            SubtitleTrack(language: "English", url: "https://caption.test/en.vtt"),
        ])
        #expect(saved.isEmpty)
    }
}

private extension ArchiveCaptionProtocol {
    /// The one place this suite builds its session, so it cannot drift from the
    /// protocol class it registered.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArchiveCaptionProtocol.self]
        return URLSession(configuration: config)
    }
}
