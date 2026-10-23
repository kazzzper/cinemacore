import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `CatalogRepository` that serves the StreamHype ecosystem: TMDB for the
/// catalog, the vidsrc-family embed players for playback, all in native Swift
/// with no gateway involved.
///
/// A port of `core/provider/streamhype/streamhype.go`, which is the reference
/// this must stay in step with. The split the Go adapter documents holds here:
/// the catalog is a clean REST API, while playback answers with a `web`-kind
/// rendition — an embed page the app opens in a web view, never a media URL
/// for `AVPlayer`.
///
/// Subject ids are namespaced `tmdb-movie-<id>` / `tmdb-tv-<id>`, the same
/// spelling the Go core uses, so a history row or watchlist entry written by a
/// gateway session still resolves here.
public struct StreamHypeCatalogRepository: CatalogRepository, @unchecked Sendable {
    /// Where a deployment's TMDB v3 key comes from, in precedence order.
    ///
    /// `TMDB_API_KEY` in the environment (tests, simulator runs from a shell)
    /// then `TMDBAPIKey` in the app's `Info.plist`. There is deliberately no
    /// bundled default: the key belongs to whoever registers the app with TMDB,
    /// and a copy checked into source cannot be rotated without a release — or
    /// revoked from under every installed copy at once.
    public static var configuredAPIKey: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["TMDB_API_KEY"],
            Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String,
        ]
        for candidate in candidates {
            let key = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// `true` when a TMDB key is configured, so the UI can explain a missing
    /// one instead of failing every request.
    public static var isConfigured: Bool { configuredAPIKey != nil }

    static let apiBase = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p"
    /// The vidsrc-family façade StreamHype's own Play button opens first. Both
    /// known front-ends are the same backend; only this one is kept.
    static let embedBase = "https://screenfetch4.cyou/"
    /// The `?o=` attribution parameter StreamHype's own embed URLs carry.
    static let attribution = "streamhype.net"

    private let apiKey: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(apiKey: String) {
        // Timeout chosen for TMDB's normal latency; everything here is a
        // couple of small JSON requests per screen.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.init(apiKey: apiKey, session: URLSession(configuration: config))
    }

    /// Internal for tests: `swift test` runs the suite without network.
    init(apiKey: String, session: URLSession) {
        self.apiKey = apiKey
        self.session = session
    }

    public var sourceName: String { "StreamHype" }
    public var isLive: Bool { true }

    // MARK: - Catalog

    public func home() async throws(CinemacoreError) -> Page {
        let rails: [(title: String, path: String, media: TMDBMediaType)] = [
            ("Trending Now", "/trending/movie/week", .movie),
            ("Popular Movies", "/movie/popular", .movie),
            ("Popular TV", "/tv/popular", .tv),
            ("Top Rated", "/movie/top_rated", .movie),
        ]
        var sections: [Section] = []
        for rail in rails {
            // One dead rail must not kill the page; only all-dead fails below.
            if let items = try? await list(media: rail.media, rail.path), !items.isEmpty {
                sections.append(Section(title: rail.title, items: items))
            }
        }
        guard !sections.isEmpty else {
            throw CinemacoreError.upstream("StreamHype catalog unavailable.")
        }
        return Page(sections: sections)
    }

    public func search(_ query: String) async throws(CinemacoreError) -> [Subject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let page: TMDBList<TMDBEntry> = try await get(path: "/search/multi", ["query": trimmed])
        let items = page.results.compactMap { entry -> Subject? in
            guard let kind = entry.mediaType else { return nil } // person results
            return kind.subject(id: entry.id, entry: entry)
        }
        return items
    }

    public func suggestions(for query: String) async throws(CinemacoreError) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let page: TMDBList<TMDBEntry> = try await get(path: "/search/multi", ["query": trimmed])
        return page.results.compactMap { entry in
            guard let kind = entry.mediaType else { return nil }
            return kind.title(entry.title, entry.name)
        }
    }

    public func detail(id: String) async throws(CinemacoreError) -> Subject {
        guard let ref = SubjectID(id) else {
            throw CinemacoreError.upstream("Not a StreamHype title.")
        }
        let entry: TMDBDetail = try await get(path: "/\(ref.kind.rawValue)/\(ref.tmdb)")
        return Subject(
            id: id,
            title: ref.kind.title(entry.title, entry.name),
            poster: Self.image(entry.posterPath),
            year: Self.year(entry.releaseDate ?? entry.firstAirDate),
            rating: entry.voteAverage,
            kind: ref.kind.kindLabel,
            synopsis: entry.overview,
            genres: entry.genres?.compactMap(\.name) ?? [],
            durationMinutes: entry.runtime,
            seasonCount: ref.kind.seasonCount(entry.seasons)
        )
    }

    public func seasons(subjectID: String) async throws(CinemacoreError) -> [Season] {
        guard let ref = SubjectID(subjectID), ref.kind == .tv else { return [] }
        let detail: TMDBDetail = try await get(path: "/tv/\(ref.tmdb)")
        let numbers = (detail.seasons ?? [])
            .filter { $0.seasonNumber > 0 && $0.episodeCount > 0 }
            .map(\.seasonNumber)
        var out: [Season] = []
        for number in numbers {
            let season: TMDBDetail = try await get(path: "/tv/\(ref.tmdb)/season/\(number)")
            let episodes = (season.episodes ?? []).compactMap { ep -> Episode? in
                guard ep.episodeNumber > 0 else { return nil }
                return Episode(
                    subjectID: subjectID,
                    season: number,
                    number: ep.episodeNumber,
                    title: ep.name ?? "",
                    durationSeconds: ep.runtime.map { $0 * 60 }
                )
            }
            out.append(Season(number: number, episodes: episodes))
        }
        return out
    }

    // MARK: - Playback

    /// One web-embed rendition. The resolution is a pure URL build: the embed
    /// is addressed by the same TMDB id the catalog uses, so playback needs no
    /// token minting, no WASM crypto and no network round trip at all.
    public func playInfo(
        subjectID: String,
        season: Int?,
        episode: Int?
    ) async throws(CinemacoreError) -> PlayInfo {
        guard let ref = SubjectID(subjectID) else {
            throw CinemacoreError.upstream("Not a StreamHype title.")
        }
        guard let embed = Self.embedURL(ref, season: season, episode: episode),
              URL(string: embed) != nil
        else {
            throw CinemacoreError.badURL(subjectID)
        }
        return PlayInfo(
            streams: [StreamRendition(
                quality: "Auto",
                url: embed,
                kind: StreamRendition.webKind
            )],
            subtitles: []
        )
    }

    /// Builds one embed URL, mirroring Go `embedURL`:
    /// `<base>/embed/movie?tmdb=<id>&o=<attribution>`
    /// `<base>/embed/tv?tmdb=<id>&season=<s>&episode=<e>&o=<attribution>`
    ///
    /// A series asked without season/episode numbers still points at the
    /// first episode of the first season rather than an unparameterised embed
    /// that would strand the viewer on the player's own picker.
    static func embedURL(_ ref: SubjectID, season: Int?, episode: Int?) -> String? {
        guard var components = URLComponents(string: embedBase + "embed/" + ref.kind.rawValue) else {
            return nil
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "tmdb", value: String(ref.tmdb)),
            URLQueryItem(name: "o", value: attribution),
        ]
        if ref.kind == .tv {
            query.append(URLQueryItem(name: "season", value: String(max(season ?? 0, 1))))
            query.append(URLQueryItem(name: "episode", value: String(max(episode ?? 0, 1))))
        }
        components.queryItems = query
        return components.string
    }

    // MARK: - id namespace (mirrors Go parseID/idOf)

    /// The parsed subject id: TMDB id plus media type.
    struct SubjectID: Equatable, Sendable {
        let tmdb: Int
        let kind: TMDBMediaType

        init?(_ id: String) {
            guard let parsed = StreamHypeCatalogRepository.parse(id) else { return nil }
            self = parsed
        }

        init(tmdb: Int, kind: TMDBMediaType) {
            self.tmdb = tmdb
            self.kind = kind
        }
    }

    /// Parses `"tmdb-movie-27205"` (and its tv spelling). A foreign id answers
    /// unavailable, never a silent wrong-source lookup.
    static func parse(_ id: String) -> SubjectID? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "tmdb",
              let kind = TMDBMediaType(rawValue: String(parts[1])),
              let tmdb = Int(parts[2]), tmdb > 0
        else { return nil }
        return SubjectID(tmdb: tmdb, kind: kind)
    }

    static func id(_ tmdb: Int, _ kind: TMDBMediaType) -> String {
        "tmdb-\(kind.rawValue)-\(tmdb)"
    }

    // MARK: - TMDB access

    /// TMDB's movie/tv discriminator.
    enum TMDBMediaType: String, Sendable {
        case movie
        case tv

        /// The wire kind vocabulary ("movie"/"series").
        var kindLabel: String { self == .tv ? "series" : "movie" }

        /// The field the media type actually carries: movies use `title`, TV
        /// uses `name`.
        func title(_ title: String?, _ name: String?) -> String {
            self == .tv ? (name ?? title ?? "") : (title ?? name ?? "")
        }

        /// Season count with the special (season 0) TMDB entry excluded.
        func seasonCount(_ seasons: [TMDBSeason]?) -> Int {
            guard self == .tv else { return 1 }
            return (seasons ?? []).filter { $0.seasonNumber > 0 }.count
        }

        func subject(id: Int, entry: TMDBEntry) -> Subject {
            Subject(
                id: StreamHypeCatalogRepository.id(id, self),
                title: title(entry.title, entry.name),
                poster: StreamHypeCatalogRepository.image(entry.posterPath),
                year: StreamHypeCatalogRepository.year(entry.releaseDate ?? entry.firstAirDate),
                rating: entry.voteAverage,
                kind: kindLabel,
                synopsis: entry.overview
            )
        }
    }

    struct TMDBList<Result: Decodable>: Decodable {
        let results: [Result]
    }

    /// One search/list entry.
    ///
    /// `mediaType` is decoded as a raw string, not the enum: multi-search
    /// carries values the enum cannot represent ("person"), and an unknown raw
    /// value on an optional enum *throws* during decode, which would fail the
    /// whole page over one cast row.
    struct TMDBEntry: Decodable, Sendable {
        let id: Int
        let mediaTypeRaw: String?
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let voteAverage: Double?
        let releaseDate: String?
        let firstAirDate: String?

        var mediaType: TMDBMediaType? {
            mediaTypeRaw.flatMap(TMDBMediaType.init(rawValue:))
        }

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview
            case mediaTypeRaw = "media_type"
            case posterPath = "poster_path"
            case voteAverage = "vote_average"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
        }
    }

    /// The movie/tv/season detail payload, unioned across the three shapes.
    struct TMDBDetail: Decodable, Sendable {
        let id: Int?
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let voteAverage: Double?
        let runtime: Int?
        let releaseDate: String?
        let firstAirDate: String?
        let genres: [TMDBGenre]?
        let seasons: [TMDBSeason]?
        let episodes: [TMDBSeasonEpisode]?

        enum CodingKeys: String, CodingKey {
            case id, title, name, overview, runtime, genres, seasons, episodes
            case posterPath = "poster_path"
            case voteAverage = "vote_average"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
        }
    }

    struct TMDBGenre: Decodable, Sendable { let name: String? }

    struct TMDBSeason: Decodable, Sendable {
        let seasonNumber: Int
        let episodeCount: Int

        enum CodingKeys: String, CodingKey {
            case seasonNumber = "season_number"
            case episodeCount = "episode_count"
        }
    }

    struct TMDBSeasonEpisode: Decodable, Sendable {
        let episodeNumber: Int
        let name: String?
        let runtime: Int?

        enum CodingKeys: String, CodingKey {
            case name, runtime
            case episodeNumber = "episode_number"
        }
    }

    /// `list` reads one fixed-type endpoint: rows are untyped on the wire, so
    /// the endpoint's own kind stands in for the absent `media_type`.
    private func list(media: TMDBMediaType, _ path: String) async throws(CinemacoreError) -> [Subject] {
        let page: TMDBList<TMDBEntry> = try await get(path: path)
        return page.results
            .filter { entry in entry.mediaTypeRaw == nil || entry.mediaType == media }
            .map { entry in media.subject(id: entry.id, entry: entry) }
    }

    private func get<Result: Decodable>(
        path: String, _ extra: [String: String]? = nil
    ) async throws(CinemacoreError) -> Result {
        guard var components = URLComponents(string: Self.apiBase + path) else {
            throw CinemacoreError.badURL(path)
        }
        var query = [URLQueryItem(name: "api_key", value: apiKey)]
        for (key, value) in extra ?? [:] {
            query.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw CinemacoreError.badURL(path)
        }

        let data: Data
        let response: URLResponse?
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw CinemacoreError.offline
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 404 {
                throw CinemacoreError.upstream("That title is not on TMDB.")
            }
            throw CinemacoreError.http(status: status, code: nil, message: nil)
        }
        do {
            return try decoder.decode(Result.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    static func map(_ error: URLError) -> CinemacoreError {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .timedOut
        case .cancelled:
            .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            .offline
        default:
            .offline
        }
    }

    /// Expands TMDB's relative poster path.
    static func image(_ rawPath: String?) -> String? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        return imageBase + "/w780" + rawPath
    }

    /// Reads a TMDB date's leading year, `nil` when unusable.
    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4, let value = Int(date.prefix(4)) else { return nil }
        return value
    }
}
