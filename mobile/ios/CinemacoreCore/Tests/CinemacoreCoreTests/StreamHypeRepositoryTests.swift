import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

/// Stub transport private to this suite (`MovieBoxStubURLProtocol`'s table is
/// process-global and this suite runs beside it).
final class StreamHypeStubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var body: Data

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(text.utf8))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Response] = [:]

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
    }

    static func stub(_ path: String, _ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        routes[path] = response
    }

    static func requests() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Self.requestLog)
    }

    nonisolated(unsafe) private static var requestLog: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.path ?? ""
        Self.requestLog.append(path)
        // TMDB's v3 base contributes `/3` to the path; tests name the route
        // without it so the fixture stays readable.
        let route = Self.routes[path] ?? Self.routes.first { path.hasSuffix($0.key) }?.value
        let response = route ?? .json(#"{"status_code":34}"#, status: 404)
        Self.lock.unlock()

        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
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

@Suite("StreamHype repository", .serialized)
struct StreamHypeRepositoryTests {
    private func repository() -> StreamHypeCatalogRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamHypeStubURLProtocol.self]
        return StreamHypeCatalogRepository(
            apiKey: "test-key",
            session: URLSession(configuration: config)
        )
    }

    private func stop() {
        StreamHypeStubURLProtocol.reset()
    }

    // MARK: - embed URL builder

    @Test func embedURLOnMoviesAndSeries() throws {
        let movie = try #require(StreamHypeCatalogRepository.embedURL(
            .init(tmdb: 27205, kind: .movie), season: nil, episode: nil
        ))
        #expect(movie == "https://screenfetch4.cyou/embed/movie?tmdb=27205" +
            "&o=streamhype.net")

        let episode = try #require(StreamHypeCatalogRepository.embedURL(
            .init(tmdb: 1399, kind: .tv), season: 1, episode: 2
        ))
        #expect(episode == "https://screenfetch4.cyou/embed/tv?tmdb=1399" +
            "&o=streamhype.net&season=1&episode=2")
    }

    @Test func embedURLPinsDegenerateSeriesToFirstEpisode() throws {
        for (season, episode) in [(0, 0), (nil, nil), (-1, -1)] {
            let url = try #require(StreamHypeCatalogRepository.embedURL(
                .init(tmdb: 1399, kind: .tv), season: season, episode: episode
            ))
            #expect(url.contains("season=1&episode=1"), "url = \(url)")
        }
        // Movies never carry a season/episode parameter at all.
        let movie = try #require(StreamHypeCatalogRepository.embedURL(
            .init(tmdb: 27205, kind: .movie), season: 3, episode: 9
        ))
        #expect(!movie.contains("season"))
    }

    // MARK: - id namespace

    @Test func idRoundTrips() throws {
        let movie = StreamHypeCatalogRepository.id(27205, .movie)
        let tv = StreamHypeCatalogRepository.id(1399, .tv)
        #expect(movie == "tmdb-movie-27205")
        #expect(tv == "tmdb-tv-1399")
        #expect(try #require(StreamHypeCatalogRepository.parse(movie)).tmdb == 27205)
        #expect(try #require(StreamHypeCatalogRepository.parse(tv)).kind == .tv)
    }

    @Test func foreignIdsAreRejected() {
        for id in ["42", "tmdb-person-12", "tmdb-movie-zero", "tmdb-movie-", "series"] {
            #expect(StreamHypeCatalogRepository.parse(id) == nil, "id = \(id)")
        }
    }

    // MARK: - TMDB mapping

    private let searchMulti = #"""
    {"results":[
    {"id":27205,"media_type":"movie","title":"Inception","overview":"Dreams.","poster_path":"/9gk7ps.jpg","vote_average":8.4,"release_date":"2010-07-16"},
    {"id":1234,"media_type":"person","name":"Christopher Nolan"},
    {"id":1399,"media_type":"tv","name":"Game of Thrones","poster_path":"/1sp.jpg","vote_average":8.5,"first_air_date":"2011-04-17"}
    ]}
    """#

    @Test func searchKeepsTypedEntriesOnly() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub("/search/multi", .json(searchMulti))
        defer { stop() }

        let items = try await repository().search("inception")
        #expect(items.count == 2)
        #expect(items[0].id == "tmdb-movie-27205")
        #expect(items[0].title == "Inception")
        #expect(items[0].year == 2010)
        #expect(items[0].rating == 8.4)
        #expect(items[0].poster == "https://image.tmdb.org/t/p/w780/9gk7ps.jpg")
        #expect(items[1].id == "tmdb-tv-1399")
        #expect(items[1].kind == "series")
    }

    @Test func searchSkipsPersonRowsEvenWhenTypedWeirdly() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub(
            "/search/multi",
            .json(#"{"results":[{"id":1,"media_type":"person","name":"A Cast Member"}]}"#)
        )
        defer { stop() }
        #expect(try await repository().search("x").isEmpty)
    }

    @Test func searchEmptyQueryIsAnEmptyResultNotAnError() async {
        // Deliberately no stubs: an empty query must not touch the network.
        let items = try? await repository().search("   ")
        #expect(items != nil && items!.isEmpty)
    }

    @Test func suggestionsKeepTitles() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub("/search/multi", .json(searchMulti))
        defer { stop() }
        #expect(try await repository().suggestions(for: "inc") == ["Inception", "Game of Thrones"])
    }

    @Test func homeSkipsDeadRailsAndKeepsLiveOnes() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub(
            "/trending/movie/week",
            .json(#"{"results":[{"id":1,"title":"Movie 1"}]}"#)
        )
        StreamHypeStubURLProtocol.stub(
            "/movie/popular",
            .json(#"{"results":[{"id":2,"title":"Movie 2"}]}"#)
        )
        defer { stop() }

        let page = try await repository().home()
        #expect(page.sections.map(\.title) == ["Trending Now", "Popular Movies"])
        #expect(page.sections[0].items[0].id == "tmdb-movie-1")
        #expect(page.sections[0].items[0].kind == "movie")
    }

    @Test func homeFailsLoudWhenEveryRailIsDead() async {
        StreamHypeStubURLProtocol.reset()
        defer { stop() }
        do {
            _ = try await repository().home()
            Issue.record("expected all-dead rails to throw")
        } catch {
            #expect(error.isRetryable, "upstream outage should stay retryable")
        }
    }

    @Test func detailReadsMoviePayload() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub("/movie/27205", .json(Self.movieDetail))
        defer { stop() }

        let subject = try await repository().detail(id: "tmdb-movie-27205")
        #expect(subject.title == "Inception")
        #expect(subject.kind == "movie")
        #expect(subject.year == 2010)
        #expect(subject.rating == 8.4)
        #expect(subject.durationMinutes == 148)
        #expect(subject.genres == ["Action", "Sci-Fi"])
        #expect(subject.seasonCount == 1)
    }

    @Test func detailReadsTVPayloadAndSkipsSpecials() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub("/tv/1399", .json(Self.tvDetail))
        defer { stop() }

        let subject = try await repository().detail(id: "tmdb-tv-1399")
        #expect(subject.title == "Game of Thrones")
        #expect(subject.kind == "series")
        #expect(subject.year == 2011)
        #expect(subject.seasonCount == 2)
    }

    @Test func seasonsExpandEpisodesAndSkipSpecials() async throws {
        StreamHypeStubURLProtocol.reset()
        StreamHypeStubURLProtocol.stub("/tv/1399", .json(Self.tvDetail))
        StreamHypeStubURLProtocol.stub("/tv/1399/season/1", .json(Self.seasonOne))
        StreamHypeStubURLProtocol.stub("/tv/1399/season/2", .json(Self.seasonOne))
        defer { stop() }

        let seasons = try await repository().seasons(subjectID: "tmdb-tv-1399")
        #expect(seasons.map(\.number) == [1, 2])
        #expect(seasons[0].episodes.count == 2)
        #expect(seasons[0].episodes[0].title == "Winter Is Coming")
        #expect(seasons[0].episodes[0].durationSeconds == 62 * 60)
        #expect(seasons[0].episodes[0].subjectID == "tmdb-tv-1399")
    }

    @Test func seasonsOfAMovieAreEmpty() async throws {
        StreamHypeStubURLProtocol.reset()
        defer { stop() }
        #expect(try await repository().seasons(subjectID: "tmdb-movie-27205") == [])
    }

    // MARK: - playback

    @Test func playInfoAnswersOneWebKindRenditionForAMovie() async throws {
        StreamHypeStubURLProtocol.reset()
        defer { stop() }

        let info = try await repository().playInfo(subjectID: "tmdb-movie-27205", season: nil, episode: nil)
        #expect(info.streams.count == 1)
        let stream = try #require(info.streams.first)
        #expect(stream.isWebEmbed)
        #expect(stream.quality == "Auto")
        #expect(stream.url == "https://screenfetch4.cyou/embed/movie?tmdb=27205&o=streamhype.net")
        #expect(URL(string: stream.url) != nil)
    }

    @Test func playInfoCarriesSeasonAndEpisodeForSeries() async throws {
        StreamHypeStubURLProtocol.reset()
        defer { stop() }

        let info = try await repository().playInfo(subjectID: "tmdb-tv-1399", season: 2, episode: 7)
        #expect(info.streams.first?.url == "https://screenfetch4.cyou/embed/tv?tmdb=1399&o=streamhype.net&season=2&episode=7")
    }

    @Test func playInfoRejectsForeignSubjects() async {
        StreamHypeStubURLProtocol.reset()
        defer { stop() }
        do {
            _ = try await repository().playInfo(subjectID: "12345", season: nil, episode: nil)
            Issue.record("expected a foreign id to throw")
        } catch {
            #expect(!error.userMessage.isEmpty)
        }
    }

    // MARK: - fixtures

    static let movieDetail = #"""
    {"id":27205,"title":"Inception","name":"WRONG NAME","overview":"A thief who steals corporate secrets.","poster_path":"/9gk7ps.jpg","vote_average":8.4,"runtime":148,"release_date":"2010-07-16","genres":[{"name":"Action"},{"name":"Sci-Fi"}]}
    """#

    static let tvDetail = #"""
    {"id":1399,"title":"WRONG TITLE","name":"Game of Thrones","overview":"Seven noble families.","poster_path":"/1sp.jpg","vote_average":8.5,"first_air_date":"2011-04-17","genres":[{"name":"Drama"},{"name":"Fantasy"}],"seasons":[{"season_number":0,"episode_count":0,"name":"Specials"},{"season_number":1,"episode_count":10,"name":"Season 1"},{"season_number":2,"episode_count":10,"name":"Season 2"}]}
    """#

    static let seasonOne = #"""
    {"episodes":[{"episode_number":1,"name":"Winter Is Coming","runtime":62},{"episode_number":2,"name":"The Kingsroad","runtime":56}]}
    """#

    @Test func tvTitlePrefersNameOverMovieTitleField() {
        #expect(StreamHypeCatalogRepository.TMDBMediaType.tv.title("WRONG", "Right") == "Right")
        #expect(StreamHypeCatalogRepository.TMDBMediaType.movie.title("Right", "WRONG") == "Right")
    }
}
