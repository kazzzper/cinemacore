import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The signed HTTP client for the MovieBox gateway: host failover, request
/// signing, the guest token, and a small GET cache.
///
/// A byte-faithful Swift port of `core/session/session.go` (Go), which is the
/// single source of truth; the signing layer both share is pinned by
/// `contracts/signing-vectors.json`. The app talks to MovieBox directly through
/// this client — no gateway server required.
public actor MovieBoxSession {

    /// The error surface of one session call.
    public enum SessionError: Error, Sendable {
        case noHosts
        case http(status: Int, body: String?)
        /// The wire never answered: DNS, no route, TLS, a timeout. Kept apart
        /// from `.http` because there is no status to report and the error's
        /// own description is a multi-line `NSError` dump — the failing URL,
        /// the CFStream codes and the task id — which must never become a
        /// message on screen.
        case transport(code: URLError.Code)
        case badResponse
    }

    // Identity mirrors the MovieBox/4.0.02 Android client the gateway filters
    // on; these are not cosmetic (Go session.Config defaults).
    public struct Identity: Sendable {
        var userAgent = "MovieBox/4.0.02 (Android 14; Pixel 6)"
        var appID = "4U01pxRu278GqCZKY9"
        var region = "IN"
        var lang = "en"
        var os = "android"
        var appVersion = "4.0.02"
        var signVer = "2.0"
        /// JSON for the `X-Client-Info` header. `device_id` is required for the
        /// guest bootstrap (verified live: 400 PARAMS_ERROR without it).
        var clientInfo = #"{"device_id":"868203051234567","device_type":"android","device_brand":"google","device_model":"Pixel 6","os_version":"14","app_version":"4.0.02","lang":"en","region":"IN"}"#
    }

    private let hosts: [String]
    private let timeout: TimeInterval
    private let session: URLSession
    private let maxResponseBytes = 8 << 20
    private let identity = Identity()
    private let now: @Sendable () -> Int64

    private var hostIndex = 0
    private var token = ""
    /// GET cache. The gateway is aggressively rate-limited, and rails are
    /// re-requested on every tab appearance.
    private var cache: [String: (expires: Date, data: Data)] = [:]
    private let cacheTTL: TimeInterval

    public init(
        hosts: [String],
        timeout: TimeInterval = 20,
        cacheTTL: TimeInterval = 300,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.hosts = hosts
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.now = now
    }

    /// The default host pool, matching the Go client's.
    public static let defaultHosts = [
        "api6.aoneroom.com",
        "api5.aoneroom.com",
        "api.aoneroom.com",
        "api.inmoviebox.com",
    ]

    public init(
        timeout: TimeInterval = 20,
        cacheTTL: TimeInterval = 300,
        session: URLSession? = nil
    ) {
        self.init(
            hosts: Self.defaultHosts,
            timeout: timeout,
            cacheTTL: cacheTTL,
            session: session
        )
    }

    public func currentToken() -> String { token }

    // MARK: - Public call surface

    /// Signs and sends one request, failing over across hosts on 403/429/5xx and
    /// re-bootstrapping the guest session on a missing/expired token (441/401).
    /// GET responses are cached for the configured TTL.
    public func call(
        _ method: String,
        _ path: String,
        body: String? = nil
    ) async throws(SessionError) -> Data {
        let cacheKey = method + " " + path
        if method == "GET", let hit = cache[cacheKey], hit.expires > Date() {
            return hit.data
        }
        guard !hosts.isEmpty else { throw .noHosts }

        var outcome = try await attempt(method, path, body)
        if outcome.status == 441 || outcome.status == 401 {
            // Content endpoints answer 441 until a guest bearer is presented:
            // drop any stale token, mint a fresh one, and replay once.
            token = ""
            if (try? await guestLogin()) != nil {
                outcome = try await attempt(method, path, body)
            }
        }
        if method == "GET" {
            cache[cacheKey] = (Date().addingTimeInterval(cacheTTL), outcome.data)
        }
        return outcome.data
    }

    /// Acquires an anonymous token (visitor-login). Idempotent.
    public func guestLogin() async throws(SessionError) -> String {
        if !token.isEmpty { return token }
        let data = try await attempt(POST, "/wefeed-mobile-bff/user-api/visitor-login", "{}").data
        struct Envelope: Decodable { struct D: Decodable { let token: String? }; let data: D? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let token = envelope.data?.token, !token.isEmpty
        else { throw .badResponse }
        self.token = token
        return token
    }

    // MARK: - Internals

    private struct Outcome {
        var status: Int
        var data: Data
    }

    private func attempt(_ method: String, _ path: String, _ body: String?) async throws(SessionError) -> Outcome {
        var lastError = SessionError.noHosts
        var lastStatus = 0

        for _ in hosts.indices {
            let base = currentBase()
            let rawURL = base + Self.withHost(path, host: Self.hostOf(base))
            let ts = now()
            let signed = Signing.headers(method: method, url: rawURL, body: body ?? "", tsMillis: ts)

            var request = URLRequest(url: URL(string: rawURL) ?? URL(fileURLWithPath: "/"))
            request.httpMethod = method
            request.timeoutInterval = timeout
            if let body, !body.isEmpty {
                request.httpBody = Data(body.utf8)
            }
            applyHeaders(to: &request, base: base, ts: ts, signed: signed)

            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? -1
                // The gateway rotates the guest token via the x-user header.
                if let user = http?.value(forHTTPHeaderField: "x-user"),
                   let token = Self.tokenFromXUser(user) {
                    self.token = token
                }
                if (200..<300).contains(status) {
                    return Outcome(status: status, data: data)
                }
                lastStatus = status
                lastError = .http(status: status, body: String(data: data.prefix(512), encoding: .utf8))
                if Self.retryable(status) {
                    rotate()
                    continue
                }
                throw lastError
            } catch let error as SessionError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                // The caller went away; asking the next host the same question
                // would keep a dismissed screen's request alive.
                throw SessionError.transport(code: .cancelled)
            } catch let error as URLError {
                rotate()
                lastError = .transport(code: error.code)
                continue
            } catch {
                rotate()
                lastError = .transport(code: .unknown)
                continue
            }
        }
        _ = lastStatus
        throw lastError
    }

    private func applyHeaders(to request: inout URLRequest, base: String, ts: Int64, signed: Signing.SignedHeaders) {
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(signed.accept, forHTTPHeaderField: "Accept")
        request.setValue(signed.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(signed.clientToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue(signed.trSignature, forHTTPHeaderField: "x-tr-signature")
        request.setValue(identity.appVersion, forHTTPHeaderField: "X-M-Version")
        request.setValue(identity.signVer, forHTTPHeaderField: "X-Sign-Version")
        request.setValue("2", forHTTPHeaderField: "X-Play-Mode")
        request.setValue(String(ts), forHTTPHeaderField: "X-Timestamp")
        request.setValue("0", forHTTPHeaderField: "X-Client-Status")
        request.setValue(identity.appID, forHTTPHeaderField: "appid")
        request.setValue(identity.region, forHTTPHeaderField: "region")
        request.setValue(identity.lang, forHTTPHeaderField: "lang")
        request.setValue(identity.os, forHTTPHeaderField: "os")
        request.setValue(base + "/", forHTTPHeaderField: "Referer")
        request.setValue(identity.clientInfo, forHTTPHeaderField: "X-Client-Info")
        if !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
    }

    private func currentBase() -> String {
        let host = hosts[hostIndex]
        return host.contains("://") ? host : "https://" + host
    }

    private func rotate() {
        guard !hosts.isEmpty else { return }
        hostIndex = (hostIndex + 1) % hosts.count
    }

    // MARK: - Pure helpers (static so they are testable without the actor)

    /// The gateway's mandatory `host` query parameter, which is also covered by
    /// the request signature.
    static func withHost(_ path: String, host: String) -> String {
        guard !host.isEmpty,
              var components = URLComponents(string: path)
        else { return path }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "host", value: host))
        components.queryItems = items
        return components.url?.absoluteString ?? path
    }

    static func hostOf(_ base: String) -> String {
        guard let url = URL(string: base),
              let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parsed.host
        else { return base }
        return parsed.port.map { "\(host):\($0)" } ?? host
    }

    static func tokenFromXUser(_ raw: String) -> String? {
        struct User: Decodable { let token: String? }
        guard let data = raw.data(using: .utf8),
              let user = try? JSONDecoder().decode(User.self, from: data),
              let token = user.token, !token.isEmpty
        else { return nil }
        return token
    }

    static func retryable(_ status: Int) -> Bool {
        status == 403 || status == 429 || status >= 500
    }

    private let POST = "POST"
    private let GET = "GET"
}
