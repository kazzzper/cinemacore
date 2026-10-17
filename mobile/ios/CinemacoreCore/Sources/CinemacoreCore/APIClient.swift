import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One typed API call, independent of transport.
public struct APIRequest: Sendable, Hashable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Data?

    public init(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }

    /// The gateway's typed error envelope (`contracts/openapi.yaml`).
    struct ErrorEnvelope: Decodable, Sendable {
        let code: String?
        let message: String?
    }
}

/// A thin `URLSession` client over the Cinemacore contract.
///
/// No third-party HTTP: `rules/03-swift-ios.md` forbids hand-built request
/// shapes. Generating a client from `contracts/openapi.yaml` is still pending,
/// so the request paths in `RemoteCatalogRepository` are hand-written literals
/// and the spec and the code must be kept in step by hand. Every failure is
/// funnelled into ``CinemacoreError`` so screens never see a `URLError`.
public struct APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL, session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    /// Performs the request and decodes the body.
    public func send<T: Decodable & Sendable>(
        _ request: APIRequest,
        as type: T.Type = T.self
    ) async throws(CinemacoreError) -> T {
        let data = try await data(for: request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    /// Performs the request and returns the raw body, for endpoints that answer
    /// `204` or whose body the caller decodes itself.
    @discardableResult
    public func data(for request: APIRequest) async throws(CinemacoreError) -> Data {
        guard let url = makeURL(for: request) else {
            throw .badURL(request.path)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(Signing.defaultAccept, forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue(Signing.defaultContentType, forHTTPHeaderField: "Content-Type")
        }

        let payload: Data
        let response: URLResponse
        do {
            (payload, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .offline
        }

        guard let http = response as? HTTPURLResponse else {
            throw .http(status: -1, code: nil, message: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The server may send a typed envelope even on failure; prefer its
            // message over a generic status string.
            let envelope = try? JSONDecoder().decode(APIRequest.ErrorEnvelope.self, from: payload)
            if http.statusCode == 403 || http.statusCode == 451 {
                throw .locked(
                    reason: envelope?.message ?? "This title isn't available in your region."
                )
            }
            throw .http(status: http.statusCode, code: envelope?.code, message: envelope?.message)
        }
        return payload
    }

    /// Probes `/health`, used to decide between the live and bundled catalog.
    public func isReachable() async -> Bool {
        do {
            let _: Health = try await send(APIRequest(path: "/health"))
            return true
        } catch {
            return false
        }
    }

    public struct Health: Decodable, Sendable {
        public let status: String
    }

    public struct Version: Decodable, Sendable {
        public let version: String
    }

    // MARK: - Internals

    private func makeURL(for request: APIRequest) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let root = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = root + request.path
        if !request.query.isEmpty {
            // Deterministic ordering keeps URLs (and logs) stable.
            components.queryItems = request.query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    static func map(_ error: URLError) -> CinemacoreError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .offline
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        case .badURL, .unsupportedURL:
            .badURL(error.failingURL?.absoluteString ?? "")
        default:
            .upstream(error.localizedDescription)
        }
    }
}
