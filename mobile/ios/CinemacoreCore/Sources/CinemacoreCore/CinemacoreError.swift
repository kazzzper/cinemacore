import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
            if let message, Self.isPresentable(message) {
                message
            } else if status < 100 {
                // A status below 100 is a sentinel for "no response was ever
                // received", so quoting it at the viewer explains nothing.
                "The provider is unavailable right now."
            } else {
                "The server returned an error (\(status))."
            }
        case .decoding:
            "The server sent data we couldn't read."
        case .upstream(let detail):
            Self.isPresentable(detail) ? detail : "The provider is unavailable right now."
        case .locked(let reason):
            reason
        }
    }

    /// Whether a string is a sentence a person can read, as opposed to the
    /// `String(describing:)` of an `NSError`.
    ///
    /// A transport failure stringifies into hundreds of characters across many
    /// lines and embeds the failing URL, the CFStream codes and the URLSession
    /// task id — the reported "Something went wrong" screen was that dump, on
    /// a phone that had simply lost its route. Raw descriptions belong in a
    /// log, never in `userMessage`: this gate keeps any future `describing:`
    /// from reaching a screen even when a caller forgets to classify.
    static func isPresentable(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 180, !trimmed.contains("\n") else { return false }
        // A gateway body is often its own JSON envelope (`.http` keeps the raw
        // body), and quoting that at a viewer is the same mistake as the dump.
        guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return false }
        let lowered = trimmed.lowercased()
        let dumps = ["domain=", "nserror", "nwpath", "underlyingerror", "kcf", "urlsessiontask"]
        return !dumps.contains { lowered.contains($0) }
    }

    /// Classifies a transport failure by its `URLError` code.
    ///
    /// The wire never produced a status here, so the only decision available is
    /// whether the network itself refused (retry once it is back) or the request
    /// was wrong (retrying repeats it verbatim).
    public static func transport(_ code: URLError.Code) -> CinemacoreError {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .callIsActive:
            .offline
        case .timedOut:
            .timedOut
        case .cancelled:
            .cancelled
        default:
            .upstream("Couldn't reach the provider. Check your connection and try again.")
        }
    }

    /// The typed failure behind any thrown error, so a `catch` block never has
    /// to stringify one.
    public static func transport(_ error: any Error) -> CinemacoreError {
        if let error = error as? CinemacoreError { return error }
        if let error = error as? URLError { return transport(error.code) }
        return .upstream("Couldn't reach the provider. Check your connection and try again.")
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
            // Below 100 is the "no response" sentinel: the next attempt is a
            // fresh connection, which is exactly what a dropped one needs.
            status < 100 || status == 408 || status == 429 || (500..<600).contains(status)
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
