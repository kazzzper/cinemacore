import Foundation

/// A typed failure from the catalog layer.
///
/// No stringly-typed errors: every case carries the data a screen needs to
/// decide between "retry", "go offline" and "this needs the user".
public enum CinemacoreError: Error, Equatable, Sendable {
    case offline
    case timedOut
    case cancelled
    case badURL(String)
    case http(status: Int, code: String?, message: String?)
    case decoding(String)
    case upstream(String)
    /// The gateway refused the region/device. Not retryable — needs a gate.
    case locked(reason: String)

    /// Copy safe to show a user. Never leaks a token, URL, or stack.
    public var userMessage: String {
        switch self {
        case .offline:
            "You appear to be offline."
        case .timedOut:
            "The server took too long to respond."
        case .cancelled:
            "Request cancelled."
        case .badURL:
            "That link isn't valid."
        case .http(let status, _, let message):
            message ?? "The server returned an error (\(status))."
        case .decoding:
            "The server sent data we couldn't read."
        case .upstream(let detail):
            detail.isEmpty ? "The provider is unavailable right now." : detail
        case .locked(let reason):
            reason
        }
    }

    /// Whether retrying the same request could plausibly succeed.
    ///
    /// HTTP status matters: a 404 will never become a 200, but a 502/503/504,
    /// a 408 or a 429 is the CDN having a bad moment. Treating every status as
    /// permanent would fail a download on its first attempt after hours of
    /// transfer, which is exactly the case a download manager exists to survive.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .upstream:
            true
        case .http(let status, _, _):
            status == 408 || status == 429 || (500..<600).contains(status)
        case .cancelled, .badURL, .decoding, .locked:
            false
        }
    }

    /// Whether this failure should route the user to the lockout gate instead
    /// of an inline error.
    public var requiresGate: Bool {
        if case .locked = self { return true }
        return false
    }
}
