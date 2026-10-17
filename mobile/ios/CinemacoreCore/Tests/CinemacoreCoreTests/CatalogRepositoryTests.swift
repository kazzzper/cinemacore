import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

/// Serves canned HTTP responses so `RemoteCatalogRepository` can be exercised
/// against contract-shaped payloads without a live gateway.
///
/// The suite is `.serialized` because the route table is process-global: two
/// tests mutating it concurrently would interfere.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(
                status: status,
                body: Data(text.utf8),
                headers: ["Content-Type": "application/json"]
            )
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Response] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        requests = []
    }

    static func stub(_ path: String, _ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = response
    }

    static var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let response = Self.routes[request.url?.path ?? ""]
            ?? .json(#"{"code":"not_found","message":"no stub route"}"#, status: 404)
        Self.lock.unlock()

        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("RemoteCatalogRepository wire", .serialized)
struct CatalogRepositoryTests {
    private let base = URL(string: "http://gateway.test")!

    private func repository() -> RemoteCatalogRepository {
        RemoteCatalogRepository(client: APIClient(baseURL: base, session: stubSession()))
    }

    @Test("home decodes the section rails")
    func home() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub(
            "/v1/home",
            .json(#"{"sections":[{"title":"Trending","items":[{"id":"1","title":"Dune"}]}]}"#)
        )

        let page = try await repository().home()

        #expect(page.sections.map(\.title) == ["Trending"])
        #expect(page.sections.first?.items.first?.title == "Dune")
    }

    @Test("search trims the query onto the request and decodes items")
    func search() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/v1/search", .json(#"{"items":[{"id":"7","title":"Heat"}]}"#))

        let items = try await repository().search("  heat  ")

        #expect(items.map(\.id) == ["7"])
        let url = try #require(StubURLProtocol.recordedRequests.first?.url)
        #expect(url.path == "/v1/search")
        #expect(url.query == "q=heat")
    }

    @Test("a blank search never reaches the network")
    func blankSearch() async throws {
        StubURLProtocol.reset()

        let items = try await repository().search("   ")

        #expect(items.isEmpty)
        #expect(StubURLProtocol.recordedRequests.isEmpty)
    }

    @Test("detail decodes one subject")
    func detail() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/v1/detail/9", .json(#"{"id":"9","title":"Severance","kind":"2"}"#))

        let subject = try await repository().detail(id: "9")

        #expect(subject.id == "9")
        #expect(subject.isSeries)
        #expect(StubURLProtocol.recordedRequests.first?.url?.path == "/v1/detail/9")
    }

    @Test("seasons decodes the episode tree")
    func seasons() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub(
            "/v1/detail/9/seasons",
            .json(#"{"seasons":[{"number":1,"episodes":[{"subjectId":"9","season":1,"number":1}]}]}"#)
        )

        let seasons = try await repository().seasons(subjectID: "9")

        #expect(seasons.count == 1)
        #expect(seasons.first?.episodes.first?.subjectID == "9")
    }

    @Test("play builds the episode query and decodes renditions and tracks")
    func playInfo() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub(
            "/v1/play",
            .json(
                #"{"streams":[{"quality":"Auto","url":"https://cdn/master.m3u8"}],"subtitles":[{"language":"English","url":"https://cdn/en.vtt"}]}"#
            )
        )

        let info = try await repository().playInfo(subjectID: "9", season: 2, episode: 5)

        #expect(info.preferredStream?.url == "https://cdn/master.m3u8")
        #expect(info.subtitles.first?.language == "English")
        let url = try #require(StubURLProtocol.recordedRequests.first?.url)
        #expect(url.query?.contains("subjectId=9") == true)
        #expect(url.query?.contains("season=2") == true)
        #expect(url.query?.contains("episode=5") == true)
    }

    @Test("a movie play omits season and episode")
    func moviePlayInfo() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/v1/play", .json(#"{"streams":[{"quality":"Auto","url":"u"}],"subtitles":[]}"#))

        _ = try await repository().playInfo(subjectID: "1", season: nil, episode: nil)

        let query = try #require(StubURLProtocol.recordedRequests.first?.url?.query)
        #expect(query == "subjectId=1")
    }

    @Test("suggestions decode the term list")
    func suggestions() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/v1/search/suggestions", .json(#"{"items":["Dune Part Two","Dune Messiah"]}"#))

        let terms = try await repository().suggestions(for: "dune")

        #expect(terms == ["Dune Part Two", "Dune Messiah"])
        #expect(StubURLProtocol.recordedRequests.first?.url?.query == "q=dune")
    }

    @Test("a 403 with a message becomes the region gate")
    func lockedRegion() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(
            "/v1/detail/1",
            .json(#"{"code":"region_blocked","message":"Not available in your region"}"#, status: 403)
        )

        do {
            _ = try await repository().detail(id: "1")
            Issue.record("expected a lockout, got success")
        } catch {
            #expect(error == .locked(reason: "Not available in your region"))
            #expect(error.requiresGate)
        }
    }

    @Test("a 502 typed envelope becomes .http with the server's message")
    func upstreamError() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(
            "/v1/home",
            .json(#"{"code":"upstream_error","message":"provider down"}"#, status: 502)
        )

        do {
            _ = try await repository().home()
            Issue.record("expected a failure, got success")
        } catch {
            #expect(error == .http(status: 502, code: "upstream_error", message: "provider down"))
        }
    }

    @Test("a malformed body becomes .decoding, not a crash")
    func malformedBody() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/v1/home", .json("not json"))

        do {
            _ = try await repository().home()
            Issue.record("expected a decode failure, got success")
        } catch {
            if case .decoding = error {} else {
                Issue.record("expected .decoding, got \(error)")
            }
        }
    }

    @Test("isReachable follows the health endpoint")
    func reachability() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub("/health", .json(#"{"status":"ok"}"#))
        let client = APIClient(baseURL: base, session: stubSession())
        #expect(await client.isReachable())

        StubURLProtocol.reset()
        StubURLProtocol.stub("/health", .json(#"{"code":"down"}"#, status: 500))
        let down = APIClient(baseURL: base, session: stubSession())
        #expect(await down.isReachable() == false)
    }
}

@Suite("CatalogResolver", .serialized)
struct CatalogResolverTests {
    @Test("no live URL resolves to the bundled catalog")
    func bundledFallback() async {
        let resolver = CatalogResolver(liveURL: nil, fallback: { FixtureCatalogRepository() })

        let resolution = await resolver.resolve()

        #expect(resolution.repository.isLive == false)
        #expect(resolution.note == "Bundled catalog")
    }
}
