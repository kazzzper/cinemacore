import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

/// A stub transport private to this suite.
///
/// `StubURLProtocol` in `CatalogRepositoryTests` is process-global and its
/// suite runs in parallel with this one, so sharing it would reset each other's
/// routes. This table is only touched by the serialized suite below.
final class MovieBoxStubURLProtocol: URLProtocol {
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
    nonisolated(unsafe) private static var failures: [String: URLError.Code] = [:]

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        failures = [:]
    }

    static func stub(_ path: String, _ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = response
    }

    /// Answers the route the way a dead network does: no HTTP response at all.
    static func fail(_ path: String, _ code: URLError.Code) {
        lock.lock()
        defer { lock.unlock() }
        failures[path] = code
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        let failure = Self.failures[path]
        let response = Self.routes[path]
            ?? .json(#"{"code":"not_found","message":"no stub route"}"#, status: 404)
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }

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

/// Episode selection through the real repository and wire decoding.
///
/// The gateway's resource listing is deliberately unfiltered by `se`/`ep` on the
/// live cluster, so these fixtures carry every episode in one list. Serialized
/// because `MovieBoxStubURLProtocol`'s route table is process-global.
@Suite("MovieBox episode selection", .serialized)
struct MovieBoxEpisodeSelectionTests {
    private func repository() -> MovieBoxCatalogRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MovieBoxStubURLProtocol.self]
        let session = MovieBoxSession(
            hosts: ["http://gateway.test"],
            cacheTTL: 0,
            session: URLSession(configuration: config)
        )
        return MovieBoxCatalogRepository(session: session)
    }

    /// Two resolutions for episode 2 prove the filter keeps the whole episode,
    /// while episodes 1 and 3 stay out of the result.
    private let unfilteredResources = #"""
    {"code":0,"message":"ok","data":{"pager":{"hasMore":false,"page":"1"},"list":[
    {"se":1,"ep":1,"duration":2700,"resolution":1080,"size":"1","resourceLink":"https://cdn.test/e1-1080.mp4","resourceId":"r1a"},
    {"se":1,"ep":2,"duration":2700,"resolution":720,"size":"2","resourceLink":"https://cdn.test/e2-720.mp4","resourceId":"r2a"},
    {"se":1,"ep":2,"duration":2700,"resolution":1080,"size":"3","resourceLink":"https://cdn.test/e2-1080.mp4","resourceId":"r2b"},
    {"se":1,"ep":3,"duration":2700,"resolution":1080,"size":"4","resourceLink":"https://cdn.test/e3-1080.mp4","resourceId":"r3a"},
    {"se":2,"ep":2,"duration":2700,"resolution":1080,"size":"5","resourceLink":"https://cdn.test/s2-e2-1080.mp4","resourceId":"r4a"}
    ]}}
    """#

    private let emptyResources = #"{"code":0,"data":{"pager":{"hasMore":false},"list":[]}}"#

    private func stubEmptyPlayInfo() {
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/play-info",
            .json(#"{"code":0,"data":{"streams":[]}}"#)
        )
    }

    private func stubUnfilteredResources() {
        stubEmptyPlayInfo()
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/ugc/video/first-by-subject",
            .json(#"{"code":0,"data":{}}"#)
        )
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/resource",
            .json(unfilteredResources)
        )
    }

    @Test("episode 2 resolves only episode 2's resources, highest resolution first")
    func episodeTwoResources() async throws {
        MovieBoxStubURLProtocol.reset()
        stubUnfilteredResources()

        let info = try await repository().playInfo(
            subjectID: "series-one",
            season: 1,
            episode: 2
        )

        #expect(info.streams.map(\.url) == [
            "https://cdn.test/e2-1080.mp4",
            "https://cdn.test/e2-720.mp4",
        ])
    }

    @Test("episode 3 does not fall back to the listing's first episode")
    func episodeThreeResources() async throws {
        MovieBoxStubURLProtocol.reset()
        stubUnfilteredResources()

        let info = try await repository().playInfo(
            subjectID: "series-two",
            season: 1,
            episode: 3
        )

        #expect(info.streams.map(\.url) == ["https://cdn.test/e3-1080.mp4"])
        #expect(info.streams.allSatisfy { $0.url.contains("/e1-") == false })
    }

    @Test("a movie request keeps every resource in the listing")
    func movieResources() async throws {
        MovieBoxStubURLProtocol.reset()
        stubUnfilteredResources()

        let info = try await repository().playInfo(
            subjectID: "movie-one",
            season: nil,
            episode: nil
        )

        #expect(Set(info.streams.map(\.url)) == [
            "https://cdn.test/e1-1080.mp4",
            "https://cdn.test/e2-720.mp4",
            "https://cdn.test/e2-1080.mp4",
            "https://cdn.test/e3-1080.mp4",
            "https://cdn.test/s2-e2-1080.mp4",
        ])
    }

    @Test("an episode missing from the listing yields no rung-4 source")
    func missingEpisodeDoesNotUseEpisodeOne() async {
        MovieBoxStubURLProtocol.reset()
        stubUnfilteredResources()

        do {
            _ = try await repository().playInfo(
                subjectID: "series-three",
                season: 1,
                episode: 4
            )
            Issue.record("expected no source for a missing episode, got success")
        } catch {
            if case .upstream = error {} else {
                Issue.record("expected .upstream, got \(error)")
            }
        }
    }

    /// The reported failure: a phone answered `play-info` with
    /// `NSURLErrorDomain Code=-1009`, and the whole `NSError` dump — URL,
    /// CFStream codes, task id — was shown as the reason, with no way to retry.
    @Test("a dead route is reported as offline, not as a raw NSError dump")
    func transportFailureIsOffline() async {
        MovieBoxStubURLProtocol.reset()
        MovieBoxStubURLProtocol.fail(
            "/wefeed-mobile-bff/subject-api/play-info",
            .notConnectedToInternet
        )

        do {
            _ = try await repository().playInfo(subjectID: "4631758689819579160", season: 1, episode: 1)
            Issue.record("expected a transport failure, got success")
        } catch {
            #expect(error == .offline)
            #expect(error.userMessage == "You appear to be offline.")
            #expect(error.isRetryable)
        }
    }

    // MARK: - UGC collection matcher

    private let ugcCollection = #"""
    {"code":0,"data":{"items":[
    {"epTitle":"S1EP10","title":"Dune S1E10","resources":[{"url":"https://cdn.test/ugc-e10.mp4","resolutions":"1080","size":"10","duration":5700,"signCookie":""}]},
    {"epTitle":"S1EP2","title":"Dune S1E2","resources":[{"url":"https://cdn.test/ugc-e2.mp4","resolutions":"1080","size":"2","duration":5900,"signCookie":""}]},
    {"epTitle":"S1EP1","title":"Dune S1E1","resources":[{"url":"https://cdn.test/ugc-e1.mp4","resolutions":"1080","size":"1","duration":5750,"signCookie":""}]},
    {"epTitle":"S1EP20","title":"Dune S1E20","resources":[{"url":"https://cdn.test/ugc-e20.mp4","resolutions":"1080","size":"20","duration":5900,"signCookie":""}]}
    ]}}
    """#

    private func stubUGCCollection(_ collection: String, videoID: String? = nil) {
        stubEmptyPlayInfo()
        let first = videoID.map {
            #"{"code":0,"data":{"ugcVideoId":"\#($0)","belongToCollection":{"collectionId":"c1"}}}"#
        } ?? #"{"code":0,"data":{"belongToCollection":{"collectionId":"c1"}}}"#
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/ugc/video/first-by-subject",
            .json(first)
        )
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/ugc/collection/download-list",
            .json(collection)
        )
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/subject-api/resource",
            .json(emptyResources)
        )
    }

    @Test("UGC markers do not match a longer episode number")
    func ugcMarkerBoundaries() {
        #expect(MovieBoxCatalogRepository.ugcMarkerRank(
            epTitle: "S1EP10",
            title: "Dune S1E10",
            season: 1,
            episode: 1
        ) == 0)
        #expect(MovieBoxCatalogRepository.ugcMarkerRank(
            epTitle: "S1EP20",
            title: "Dune S1E20",
            season: 1,
            episode: 2
        ) == 0)
        #expect(MovieBoxCatalogRepository.ugcMarkerRank(
            epTitle: "S1EP2",
            title: "Dune S1E2",
            season: 1,
            episode: 2
        ) == 2)
        #expect(MovieBoxCatalogRepository.ugcMarkerRank(
            epTitle: nil,
            title: "Dune S1E2",
            season: 1,
            episode: 2
        ) == 1)
        // A conflicting title cannot override an epTitle that names a different
        // episode.
        #expect(MovieBoxCatalogRepository.ugcMarkerRank(
            epTitle: "S1EP10",
            title: "Dune S1E2",
            season: 1,
            episode: 2
        ) == 0)
        #expect(MovieBoxCatalogRepository.ugcHasEpisodeMarker(
            epTitle: "S1EP10",
            title: nil
        ))
        #expect(MovieBoxCatalogRepository.ugcHasEpisodeMarker(
            epTitle: nil,
            title: "Dune"
        ) == false)
    }

    @Test("UGC episode 1 skips S1EP10 and plays S1EP1")
    func ugcEpisodeOneSkipsTen() async throws {
        MovieBoxStubURLProtocol.reset()
        stubUGCCollection(ugcCollection)

        let info = try await repository().playInfo(
            subjectID: "ugc-series-one",
            season: 1,
            episode: 1
        )

        #expect(info.streams.map(\.url) == ["https://cdn.test/ugc-e1.mp4"])
    }

    @Test("UGC episode 2 picks the exact S1EP2 item, not S1EP20")
    func ugcEpisodeTwoExactMatch() async throws {
        MovieBoxStubURLProtocol.reset()
        stubUGCCollection(ugcCollection)

        let info = try await repository().playInfo(
            subjectID: "ugc-series-two",
            season: 1,
            episode: 2
        )

        #expect(info.streams.map(\.url) == ["https://cdn.test/ugc-e2.mp4"])
    }

    @Test("a marked UGC collection with no matching episode never plays episode 1")
    func ugcMismatchDoesNotFallBackToFirstItem() async {
        MovieBoxStubURLProtocol.reset()
        stubUGCCollection(
            #"""
            {"code":0,"data":{"items":[
            {"epTitle":"S1EP1","title":"Dune S1E1","resources":[{"url":"https://cdn.test/ugc-video-e1.mp4","resolutions":"1080","size":"1","duration":5750,"signCookie":""}]}
            ]}}
            """#,
            videoID: "episode-one-video"
        )
        MovieBoxStubURLProtocol.stub(
            "/wefeed-mobile-bff/ugc/video/download",
            .json(#"""
            {"code":0,"data":{"items":[
            {"resources":[{"url":"https://cdn.test/ugc-video-e1.mp4","resolutions":"1080","size":"1","duration":5750,"signCookie":""}]}
            ]}}
            """#)
        )

        do {
            _ = try await repository().playInfo(
                subjectID: "ugc-series-three",
                season: 1,
                episode: 2
            )
            Issue.record("expected no source for a mismatched episode, got success")
        } catch {
            if case .upstream = error {} else {
                Issue.record("expected .upstream, got \(error)")
            }
        }
    }

    @Test("an unlabelled collection keeps episode 1's first-item fallback")
    func ugcUnlabelledEpisodeOneFallback() async throws {
        MovieBoxStubURLProtocol.reset()
        stubUGCCollection(#"""
        {"code":0,"data":{"items":[
        {"title":"Dune","resources":[{"url":"https://cdn.test/ugc-unlabelled.mp4","resolutions":"1080","size":"1","duration":5750,"signCookie":""}]}
        ]}}
        """#)

        let info = try await repository().playInfo(
            subjectID: "ugc-series-four",
            season: 1,
            episode: 1
        )

        #expect(info.streams.map(\.url) == ["https://cdn.test/ugc-unlabelled.mp4"])
    }
}
