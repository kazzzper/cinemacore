import Foundation

/// The stream-recovery ladder.
///
/// A byte-faithful Swift port of `core/provider/moviebox/recovery.go`, which is
/// the reference. The gateway deliberately answers unofficial clients with a
/// 23-second "please update your app" decoy; the real manifest survives only in
/// response metadata. Rungs run cheapest and strongest first, and **a decoy is
/// never returned as a stream** — if every rung fails, callers throw
/// ``CinemacoreError/upstream(_:)`` instead of handing the decoy to a player.
public enum StreamRecovery {

    /// The only media header besides the rendition cookie (player-spec.md §8).
    public static let streamUserAgent = "ExoPlayerLib/2.19.1"

    /// Bounds resource pagination so a broken pager cannot loop.
    static let resourcePageLimit = 20

    // MARK: - Decoy detection (rung gate)

    /// Whether `raw` is the anti-piracy placeholder instead of content.
    ///
    /// Slugs, `/notice.mp4` and the macdn.aoneroom.com/other/ shape are from the
    /// Rust TUI (`adapt.rs:564-571`, `is_deprecation_notice_url`); the
    /// `please_update`/`update_app` markers are from the Kotlin proxy
    /// (`LocalMovieBoxServer.kt:835-846`).
    public static func isDecoy(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        let markers = [
            "1c7de0bd3393702d9191801f15f88f8d",
            "9a0461bc39da389663bf3dbb17091d3f",
            "b164fbfb43",
            "/notice.mp4",
            "please_update",
            "update_app",
        ]
        for marker in markers where lower.contains(marker) {
            return true
        }
        return lower.contains("macdn.aoneroom.com") && lower.contains("/other/")
    }

    public static func isUsable(_ raw: String) -> Bool {
        !raw.isEmpty && raw.hasPrefix("http") && !isDecoy(raw)
    }

    // MARK: - Rung 1: signed-cookie manifest

    /// Decodes the CDN's signed cookie into a real manifest URL.
    ///
    /// The cookie is a ";"-separated key=value list whose real base path is
    /// base64url-encoded after `urlprefix=`; CloudFront carries the same prefix
    /// inside a signed policy. A `/dash/` tree gets `index.mpd` and any other
    /// http prefix gets `index.m3u8`.
    public static func manifest(fromSignCookie cookie: String) -> String? {
        for part in cookie.split(separator: ";") {
            let field = part.trimmingCharacters(in: .whitespaces)
            if let range = field.range(of: "urlprefix=") {
                var token = String(field[range.upperBound...])
                // The value ends at the next separator.
                if let cut = token.firstIndex(where: { $0 == ":" || $0 == ";" }) {
                    token = String(token[..<cut])
                }
                if let decoded = decodeBase64(token), !isDecoy(decoded) {
                    if let mpd = dashManifest(decoded) { return mpd }
                    if let hls = hlsManifest(decoded) { return hls }
                }
            }
            if field.hasPrefix("CloudFront-Policy=") {
                let policy = String(field.dropFirst("CloudFront-Policy=".count))
                if let decoded = decodeBase64(cloudFrontAlphabet(policy)),
                   let resource = cloudFrontResource(decoded),
                   !isDecoy(resource),
                   let mpd = dashManifest(resource) {
                    return mpd
                }
            }
        }
        return nil
    }

    /// Accepts the standard and URL-safe alphabets and restores omitted padding
    /// (adapt.rs:585-592).
    static func decodeBase64(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        value = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - value.count % 4) % 4
        if pad > 0 {
            value += String(repeating: "=", count: pad)
        }
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Only a `/dash/` tree under an absolute http(s) prefix resolves
    /// (to_dash_mpd, adapt.rs:573-583).
    static func dashManifest(_ raw: String) -> String? {
        var base = raw.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("*") || base.hasSuffix("/") {
            base.removeLast()
        }
        guard base.hasPrefix("http://") || base.hasPrefix("https://"),
              base.contains("/dash/")
        else { return nil }
        return base + "/index.mpd"
    }

    /// The Kotlin construction (LocalMovieBoxServer.kt:1000-1004).
    static func hlsManifest(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        return value.hasSuffix("/") ? value + "index.m3u8" : value + "/index.m3u8"
    }

    /// Restores CloudFront's non-standard policy alphabet (adapt.rs:627-635).
    static func cloudFrontAlphabet(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "=")
            .replacingOccurrences(of: "~", with: "/")
    }

    /// `Statement[0].Resource` out of a decoded policy.
    static func cloudFrontResource(_ policy: String) -> String? {
        struct Document: Decodable {
            let Statement: [Statement]
            struct Statement: Decodable { let Resource: String? }
        }
        guard let data = policy.data(using: .utf8),
              let doc = try? JSONDecoder().decode(Document.self, from: data),
              let resource = doc.Statement.first?.Resource, !resource.isEmpty
        else { return nil }
        return resource
    }

    // MARK: - Rendition expansion

    /// Expands one stream entry into one rendition per advertised resolution,
    /// carrying that entry's size, cookie and declared codec (adapt.rs:751-778).
    public static func renditions(
        url: String,
        resolutions: String,
        size: String?,
        cookie: String?,
        codec: String? = nil
    ) -> [StreamRendition] {
        splitList(resolutions).map { label in
            StreamRendition(quality: label, url: url, size: size, cookie: cookie, codec: codec)
        }
    }

    static func splitList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Sort key so `1080` outranks `720` rather than sorting lexically; live
    /// labels arrive without a trailing `p`.
    public static func resolutionRank(_ label: String) -> Int {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespaces)
        let digits = lowered.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    /// Media headers: `User-Agent` plus the rendition cookie, and never a
    /// signing header (media requests are unsigned by design).
    public static func headers(cookie: String?) -> [String: String] {
        var headers = ["User-Agent": streamUserAgent]
        if let cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }
}
