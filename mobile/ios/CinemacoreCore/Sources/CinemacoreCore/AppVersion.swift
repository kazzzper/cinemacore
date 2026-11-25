import Foundation

/// Release identity baked into the app bundle. Local xtool builds keep the
/// Info.plist fallbacks; CI replaces them from the tag through Version.xcconfig.
public struct AppVersion: Sendable, Equatable {
    public let full: String
    public let build: String
    public let commit: String

    public init(full: String, build: String, commit: String) {
        self.full = full
        self.build = build
        self.commit = commit
    }

    public init(bundle: Bundle = .main) {
        self.init(
            full: Self.value(for: "AppFullVersion", in: bundle) ?? "0.0.0-dev",
            build: Self.value(for: "CFBundleVersion", in: bundle) ?? "0",
            commit: Self.value(for: "AppCommit", in: bundle) ?? "local"
        )
    }

    public var display: String {
        "v\(full) (\(build)) \(commit)"
    }

    private static func value(for key: String, in bundle: Bundle) -> String? {
        guard
            let value = bundle.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty,
            !value.hasPrefix("$(")
        else { return nil }
        return value
    }
}
