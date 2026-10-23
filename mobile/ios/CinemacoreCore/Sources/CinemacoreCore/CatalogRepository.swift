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

/// Picks the catalog source at launch.
///
/// Built-in is the default and involves no gateway at all: the app talks to
/// MovieBox directly in native Swift. The gateway is a deliberate override for a
/// user running the Go core on purpose — a failed probe in built-in mode is not
/// a fault, so it must not be worded like one.
public struct CatalogResolver: Sendable {
    public struct Resolution: Sendable {
        public let repository: any CatalogRepository
        /// Human-readable reason, surfaced in Settings.
        public let note: String
    }

    /// How the app gets its catalog.
    public enum SourceMode: String, Codable, Sendable, CaseIterable {
        /// Native Swift, direct to MovieBox. Default.
        case builtIn
        /// Native Swift, direct to StreamHype's sources (TMDB + web embeds).
        case streamHype
        /// The HTTP gateway, chosen deliberately by the user.
        case gateway
    }

    private let mode: SourceMode
    private let gatewayURL: URL?
    private let probe: @Sendable (URL) async -> Bool
    private let fallback: @Sendable () -> any CatalogRepository

    public init(
        mode: SourceMode = .builtIn,
        gatewayURL: URL? = nil,
        probe: @escaping @Sendable (URL) async -> Bool = { url in
            await APIClient(baseURL: url, timeout: 4).isReachable()
        },
        fallback: @escaping @Sendable () -> any CatalogRepository
    ) {
        self.mode = mode
        self.gatewayURL = gatewayURL
        self.probe = probe
        self.fallback = fallback
    }

    public func resolve() async -> Resolution {
        switch mode {
        case .gateway:
            guard let gatewayURL else {
                return Resolution(repository: fallback(), note: "Demo data — no gateway URL set")
            }
            let reachable = await probe(gatewayURL)
            // `isReachable()` folds a cancelled probe into "unreachable";
            // committing that would install the demo catalog for a launch the
            // user already interrupted.
            if Task.isCancelled {
                return Resolution(repository: fallback(), note: "Catalog probe cancelled")
            }
            if reachable {
                return Resolution(
                    repository: RemoteCatalogRepository(
                        client: APIClient(baseURL: gatewayURL, timeout: 4)
                    ),
                    note: "Gateway · \(gatewayURL.host() ?? gatewayURL.absoluteString)"
                )
            }
            return Resolution(
                repository: fallback(),
                note: "Demo data — gateway not answering"
            )

        case .builtIn:
            // The native provider needs no probe: it fails over hosts itself
            // and surfaces its own errors. Only when it cannot even bootstrap
            // does the bundled catalog step in, and that is stated as demo
            // data rather than as a broken gateway.
            let session = MovieBoxSession(timeout: 6)
            do {
                _ = try await session.guestLogin()
                return Resolution(repository: MovieBoxCatalogRepository(), note: "MovieBox")
            } catch {
                return Resolution(
                    repository: fallback(),
                    note: "Demo data — connect to the internet to load the catalog"
                )
            }

        case .streamHype:
            // TMDB needs no probe either: every call surfaces its own error,
            // and playback resolves to a web embed without a network round
            // trip, so the resolution cannot half-fail at launch. A missing
            // key is the one thing that *would* fail every call, so it is
            // reported here rather than as an empty catalog.
            guard let apiKey = StreamHypeCatalogRepository.configuredAPIKey else {
                return Resolution(
                    repository: fallback(),
                    note: "Demo data — StreamHype needs a TMDB API key"
                )
            }
            return Resolution(
                repository: StreamHypeCatalogRepository(apiKey: apiKey),
                note: "StreamHype · TMDB · web playback"
            )
        }
    }
}
