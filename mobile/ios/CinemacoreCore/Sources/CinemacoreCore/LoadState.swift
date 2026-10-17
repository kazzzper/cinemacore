import Foundation

/// The six states every screen must render, plus `idle`.
///
/// `rules/03-swift-ios.md` requires loading, empty, error, partial, success and
/// permission. `partial` covers "usable but degraded" (stale cache, an upstream
/// rail that failed while others loaded), and `locked` is the region/device gate
/// — a state the user must act on, not a transient error to retry.
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    /// Success.
    case loaded(Value)
    /// Success, but there is genuinely nothing to show.
    case empty
    /// Success with a caveat the user should know about.
    case partial(Value, notice: String)
    case failed(CinemacoreError)
    /// Requires user action (region/device gate).
    case locked(CinemacoreError)

    /// The value when one is available, including the degraded case.
    public var value: Value? {
        switch self {
        case .loaded(let value), .partial(let value, _): value
        case .idle, .loading, .empty, .failed, .locked: nil
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// True once the state has settled into something a screen can render.
    public var isSettled: Bool {
        switch self {
        case .idle, .loading: false
        case .loaded, .empty, .partial, .failed, .locked: true
        }
    }

    public var error: CinemacoreError? {
        switch self {
        case .failed(let error), .locked(let error): error
        case .idle, .loading, .loaded, .empty, .partial: nil
        }
    }

    /// Maps the loaded value, preserving every other case.
    public func map<Other: Sendable>(_ transform: (Value) -> Other) -> LoadState<Other> {
        switch self {
        case .idle: .idle
        case .loading: .loading
        case .loaded(let value): .loaded(transform(value))
        case .empty: .empty
        case .partial(let value, let notice): .partial(transform(value), notice: notice)
        case .failed(let error): .failed(error)
        case .locked(let error): .locked(error)
        }
    }

    /// Builds a state from a collection, collapsing an empty result to `.empty`.
    public static func from<Element: Sendable>(
        _ elements: [Element],
        notice: String? = nil
    ) -> LoadState<[Element]> {
        guard !elements.isEmpty else { return .empty }
        if let notice { return .partial(elements, notice: notice) }
        return .loaded(elements)
    }
}
