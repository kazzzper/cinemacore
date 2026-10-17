import Foundation

/// The catalog boundary every screen talks to.
///
/// The app never knows whether it is reading from the Go gateway or the bundled
/// catalog. That is what lets the whole UI be built and verified on device
/// before the provider layer (T-003/T-004) is finished, and it is the seam the
/// tests replace.
public protocol CatalogRepository: Sendable {
    /// Landing rails.
    func home() async throws(CinemacoreError) -> Page
    /// Free-text search.
    func search(_ query: String) async throws(CinemacoreError) -> [Subject]
    /// One title, without its episode tree.
    func detail(id: String) async throws(CinemacoreError) -> Subject
    /// The season/episode tree for a series.
    func seasons(subjectID: String) async throws(CinemacoreError) -> [Season]
    /// Resolved playback sources for one episode (or a movie when both are nil).
    func playInfo(subjectID: String, season: Int?, episode: Int?) async throws(CinemacoreError) -> PlayInfo
    /// Type-ahead terms.
    func suggestions(for query: String) async throws(CinemacoreError) -> [String]

    /// Where the data came from, shown in Settings and on the demo banner.
    var sourceName: String { get }
    /// `true` when backed by the live gateway, `false` for the bundled catalog.
    var isLive: Bool { get }
}

/// Reads the Cinemacore contract over HTTP.
public struct RemoteCatalogRepository: CatalogRepository {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public init(baseURL: URL) {
        self.client = APIClient(baseURL: baseURL)
    }

    public var sourceName: String { client.baseURL.host() ?? client.baseURL.absoluteString }
    public var isLive: Bool { true }

    public func home() async throws(CinemacoreError) -> Page {
        try await client.send(APIRequest(path: "/v1/home"))
    }

    public func search(_ query: String) async throws(CinemacoreError) -> [Subject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: SearchResponse = try await client.send(
            APIRequest(path: "/v1/search", query: ["q": trimmed])
        )
        return response.items
    }

    public func detail(id: String) async throws(CinemacoreError) -> Subject {
        try await client.send(APIRequest(path: "/v1/detail/\(id)"))
    }

    public func seasons(subjectID: String) async throws(CinemacoreError) -> [Season] {
        let response: SeasonsResponse = try await client.send(
            APIRequest(path: "/v1/detail/\(subjectID)/seasons")
        )
        return response.seasons
    }

    public func playInfo(
        subjectID: String,
        season: Int?,
        episode: Int?
    ) async throws(CinemacoreError) -> PlayInfo {
        var query = ["subjectId": subjectID]
        if let season { query["season"] = String(season) }
        if let episode { query["episode"] = String(episode) }
        return try await client.send(APIRequest(path: "/v1/play", query: query))
    }

    public func suggestions(for query: String) async throws(CinemacoreError) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: SuggestionsResponse = try await client.send(
            APIRequest(path: "/v1/search/suggestions", query: ["q": trimmed])
        )
        return response.items
    }

    // Wire envelopes.

    struct SearchResponse: Decodable, Sendable { let items: [Subject] }
    struct SeasonsResponse: Decodable, Sendable { let seasons: [Season] }
    struct SuggestionsResponse: Decodable, Sendable { let items: [String] }
}

/// Picks the live gateway when it answers, and the bundled catalog otherwise.
///
/// Resolution happens once at launch: a health probe decides, and the choice is
/// reported to the UI so a demo session is never mistaken for live data.
public struct CatalogResolver: Sendable {
    public struct Resolution: Sendable {
        public let repository: any CatalogRepository
        /// Human-readable reason, surfaced in Settings.
        public let note: String
    }

    private let liveURL: URL?
    private let fallback: @Sendable () -> any CatalogRepository

    public init(liveURL: URL?, fallback: @escaping @Sendable () -> any CatalogRepository) {
        self.liveURL = liveURL
        self.fallback = fallback
    }

    public func resolve() async -> Resolution {
        if let liveURL {
            let client = APIClient(baseURL: liveURL, timeout: 4)
            if await client.isReachable() {
                return Resolution(
                    repository: RemoteCatalogRepository(client: client),
                    note: "Live · \(liveURL.host() ?? liveURL.absoluteString)"
                )
            }
            return Resolution(
                repository: fallback(),
                note: "Gateway unreachable — showing the bundled catalog"
            )
        }
        return Resolution(repository: fallback(), note: "Bundled catalog")
    }
}
