import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

/// One malformed caption entry used to fail the whole `extCaptions` array.
/// `withCaptions` swallowed that failure with `try?`, so every subtitle track
/// disappeared while playback still looked healthy. These cover the tolerant
/// decode and the caption-format fallback at the repository boundary.
@Suite("Subtitle caption decoding", .serialized)
struct CaptionDecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// `captions` is the `extCaptions` payload, wrapped in the gateway envelope
    /// the repository decodes.
    private func repository(captions: String) -> MovieBoxCatalogRepository {
        CaptionStubURLProtocol.reset()
        CaptionStubURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/get",
            #"{"code":0,"data":{"subjectId":"s1","resourceDetectors":[{"resourceId":"rid-1"}]}}"#
        )
        CaptionStubURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/get-ext-captions",
            #"{"code":0,"data":\#(captions)}"#
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptionStubURLProtocol.self]
        let session = MovieBoxSession(
            hosts: ["http://gateway.test"],
            cacheTTL: 0,
            session: URLSession(configuration: config)
        )
        return MovieBoxCatalogRepository(session: session)
    }

    @Test("a caption missing lanName keeps its lan fallback and the other tracks")
    func missingLanNameIsTolerated() async throws {
        let repository = repository(captions: #"""
        {"extCaptions":[
        {"lan":"en","url":"https://cdn.test/en.srt"},
        {"lan":"fr","lanName":"French","url":"https://cdn.test/fr.vtt"}
        ]}
        """#)

        let tracks = try await repository.subtitleTracks(subjectID: "s1", episode: 1)

        #expect(tracks.map(\.url) == [
            "https://cdn.test/en.srt",
            "https://cdn.test/fr.vtt",
        ])
        #expect(tracks.map(\.language) == ["en", "French"])
    }

    @Test("a caption without a URL is skipped, not fatal")
    func missingURLIsSkipped() async throws {
        let repository = repository(captions: #"""
        {"extCaptions":[
        {"lan":"en","lanName":"English"},
        {"lan":"fr","lanName":"French","url":""},
        {"lan":"de","lanName":"German","url":"https://cdn.test/de.srt"}
        ]}
        """#)

        let tracks = try await repository.subtitleTracks(subjectID: "s1", episode: 1)

        #expect(tracks.map(\.language) == ["German"])
        #expect(tracks.map(\.url) == ["https://cdn.test/de.srt"])
    }

    @Test("a caption without lan uses its lanName")
    func missingLanUsesLanName() async throws {
        let repository = repository(captions: #"""
        {"extCaptions":[{"lanName":"French","url":"https://cdn.test/fr.srt"}]}
        """#)

        let tracks = try await repository.subtitleTracks(subjectID: "s1", episode: nil)

        #expect(tracks.count == 1)
        #expect(tracks.first?.language == "French")
    }

    @Test("a non-object caption entry is skipped instead of failing the array")
    func malformedEntryIsSkipped() throws {
        let captions = try decode(Captions.self, #"""
        {"extCaptions":["not-a-caption",null,{"url":"https://cdn.test/ok.srt"}]}
        """#)

        #expect(captions.extCaptions.count == 1)
        #expect(captions.extCaptions.first?.url == "https://cdn.test/ok.srt")
    }

    @Test("an extCaptions payload that is not an array yields no tracks")
    func nonArrayCaptionsYieldNoTracks() throws {
        let captions = try decode(Captions.self, #"{"extCaptions":"none"}"#)

        #expect(captions.extCaptions.isEmpty)
    }

    @Test("extensionless caption paths fall back to srt conversion")
    func extensionlessCaptionsAreConverted() async throws {
        let repository = repository(captions: #"""
        {"extCaptions":[
        {"lan":"en","url":"https://cdn.test/captions/stream"},
        {"lan":"fr","url":"https://cdn.test/captions/stream?token=a.b"},
        {"lan":"de","url":"https://cdn.test/de.srt"},
        {"lan":"es","url":"https://cdn.test/es.vtt"}
        ]}
        """#)

        let tracks = try await repository.subtitleTracks(subjectID: "s1", episode: 1)

        #expect(tracks.map(\.format) == ["srt", "srt", "srt", "vtt"])
        #expect(tracks.map(\.needsConversion) == [true, true, true, false])
    }
}

/// The caption call has to name both the resource and the season: it is keyed
/// by a resource id and the endpoint documents `se` alongside `episode`.
@Suite("Caption request keying", .serialized)
struct CaptionRequestKeyingTests {

    private func repository(captions: String) -> MovieBoxCatalogRepository {
        CaptionKeyingURLProtocol.reset()
        CaptionKeyingURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/get",
            #"{"code":0,"data":{"subjectId":"s1","resourceDetectors":[{"resourceId":"rid-1"}]}}"#
        )
        CaptionKeyingURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/get-ext-captions",
            #"{"code":0,"data":\#(captions)}"#
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptionKeyingURLProtocol.self]
        let session = MovieBoxSession(
            hosts: ["http://gateway.test"],
            cacheTTL: 0,
            session: URLSession(configuration: config)
        )
        return MovieBoxCatalogRepository(session: session)
    }

    private let captions = #"""
    {"extCaptions":[{"lan":"en","lanName":"English","url":"https://cdn.test/en.srt"}]}
    """#

    @Test("the title's detector resource is the one captions are keyed by")
    func resourceComesFromTheDetector() async throws {
        let repository = repository(captions: captions)
        _ = try await repository.subtitleTracks(subjectID: "s1", season: 1, episode: 1)

        let query = try #require(CaptionKeyingURLProtocol.lastCaptionQuery)
        #expect(query["resourceId"] == "rid-1")
        #expect(query["subjectId"] == "s1")
    }

    /// The endpoint takes `se` as well as `episode`; sending only the episode
    /// left a series ambiguous across seasons.
    @Test("the season is sent alongside the episode")
    func seasonIsSent() async throws {
        let repository = repository(captions: captions)
        _ = try await repository.subtitleTracks(subjectID: "s1", season: 3, episode: 4)

        let query = try #require(CaptionKeyingURLProtocol.lastCaptionQuery)
        #expect(query["se"] == "3")
        #expect(query["episode"] == "4")
    }

    @Test("a movie sends neither a season nor an episode")
    func movieSendsNoEpisodeKeys() async throws {
        let repository = repository(captions: captions)
        _ = try await repository.subtitleTracks(subjectID: "s1")

        let query = try #require(CaptionKeyingURLProtocol.lastCaptionQuery)
        #expect(query["se"] == nil)
        #expect(query["episode"] == nil)
    }

    @Test("provider tracks are labelled as the provider's own")
    func providerTracksAreLabelled() async throws {
        let repository = repository(captions: captions)
        let tracks = try await repository.subtitleTracks(subjectID: "s1", season: 1, episode: 1)

        #expect(tracks.map(\.provider) == [.provider])
        #expect(tracks.first?.detail == "Provider")
    }
}

/// A stub transport private to this suite: the transport suites run in
/// parallel, so the route table must not be shared with them.
final class CaptionStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (status: Int, body: String)] = [:]
    /// The query the caption endpoint was last asked with, so a test can assert
    /// on the parameters the repository built rather than on a rendered path.
    nonisolated(unsafe) private static var captionQuery: [String: String]?

    static var lastCaptionQuery: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return captionQuery
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        captionQuery = nil
    }

    static func stub(_ path: String, _ json: String) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = (200, json)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let entry = Self.routes[request.url?.path ?? ""]
        if request.url?.path.hasSuffix("/get-ext-captions") == true,
           let query = request.url?.query {
            Self.captionQuery = Self.parse(query)
        }
        Self.lock.unlock()

        guard let url = request.url, let entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: entry.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(entry.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            out[String(name)] = parts.count > 1 ? String(parts[1]) : ""
        }
        return out
    }
}

/// A second stub with its own route table. `.serialized` orders the tests
/// inside a suite, not across suites, and the table is process-global — so the
/// keying suite must not share one with the decoding suite or the two overwrite
/// each other's routes.
final class CaptionKeyingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var captionQuery: [String: String]?

    static var lastCaptionQuery: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return captionQuery
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        captionQuery = nil
    }

    static func stub(_ path: String, _ json: String) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = (200, json)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let entry = Self.routes[request.url?.path ?? ""]
        if request.url?.path.hasSuffix("/get-ext-captions") == true,
           let query = request.url?.query {
            Self.captionQuery = Self.parse(query)
        }
        Self.lock.unlock()

        guard let url = request.url, let entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: entry.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(entry.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            out[String(name)] = parts.count > 1 ? String(parts[1]) : ""
        }
        return out
    }
}
