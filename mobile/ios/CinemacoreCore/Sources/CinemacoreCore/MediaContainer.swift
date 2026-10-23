import Foundation

/// What the bytes at a stream URL actually are.
///
/// The provider does not label containers consistently: the same title can be
/// an HLS master, a DASH manifest, or one MP4. A manifest is a recipe, not a
/// file, so the download queue has to know which one it holds before it writes
/// anything. Unknown stays distinct from MP4: the engine still treats it as a
/// direct file for old queues, but the UI must not claim it is a manifest.
public enum MediaContainer: String, Codable, Sendable, CaseIterable {
    case mp4
    case hls
    case dash
    case unknown

    /// Classifies a URL by its path extension, preferring an explicit response
    /// content type when one is available.
    public static func classify(url: URL, contentType: String? = nil) -> MediaContainer {
        if let contentType, let byType = classify(contentType: contentType) {
            return byType
        }
        return classify(pathExtension: url.pathExtension)
    }

    public static func classify(pathExtension: String) -> MediaContainer {
        switch pathExtension.lowercased() {
        case "mp4", "m4v", "mov":
            .mp4
        case "m3u8":
            .hls
        case "mpd":
            .dash
        default:
            .unknown
        }
    }

    /// Returns `nil` for a type that says nothing useful, so a generic
    /// `application/octet-stream` cannot overwrite a good extension-based
    /// classification.
    public static func classify(contentType raw: String) -> MediaContainer? {
        let type = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch type {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl",
             "audio/mpegurl", "audio/x-mpegurl":
            return .hls
        case "application/dash+xml":
            return .dash
        case "video/mp4", "application/mp4", "video/quicktime":
            return .mp4
        default:
            return nil
        }
    }

    /// A manifest must be resolved into segments; saving it as a finished file
    /// produces a download that no player can open.
    public var isManifest: Bool { self == .hls || self == .dash }

    /// The legacy chunked engine can only write a direct file. HLS and DASH
    /// need their own transfer path, so this is the gate that keeps a playlist
    /// out of the completed list until that path exists.
    public var isDirectDownload: Bool { !isManifest }

    public var displayName: String {
        switch self {
        case .mp4: "MP4"
        case .hls: "HLS"
        case .dash: "DASH"
        case .unknown: "stream"
        }
    }

    /// The suffix for the local asset. HLS and DASH assets are directories, not
    /// files, but the suffix still tells the engine which downloader owns them.
    public var assetExtension: String {
        switch self {
        case .mp4, .unknown: "mp4"
        case .hls: "hls"
        case .dash: "dash"
        }
    }
}
