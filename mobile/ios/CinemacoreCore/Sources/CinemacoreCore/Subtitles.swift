import Foundation

/// Playback transport helpers.
///
/// Media and subtitle requests are deliberately **not** signed: the Genga-World
/// implementation attaches only a `User-Agent` and the per-rendition `Cookie`
/// (the gateway's `signCookie`). Signing belongs to API calls alone, so this
/// stays a pure function of the cookie and is trivially testable.
public enum MediaRequest {
    /// The user agent the CDN expects. Not user-configurable.
    public static let userAgent = "MovieBoxPro/16.2.1 (Android 14; com.community.mbox.in)"

    /// Headers for a media or subtitle fetch.
    public static func headers(cookie: String? = nil) -> [String: String] {
        var headers = ["User-Agent": userAgent]
        if let cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }
}

/// Converts SubRip (`.srt`) captions to WebVTT.
///
/// `AVPlayer` renders WebVTT, not SubRip — an `.srt` track handed to it fails,
/// which is the whole reason this conversion exists. The provider serves most
/// tracks as `.srt`, and rather than trust the response's `Content-Type`, every
/// non-VTT track is converted locally and side-loaded from a file URL.
public enum SubtitleConverter {

    /// Rewrites an SRT document as WebVTT.
    ///
    /// Tolerates CRLF, a UTF-8 BOM, missing index lines, and stray blank lines.
    /// Malformed cues are dropped rather than emitted as broken WebVTT.
    public static func webVTT(fromSRT srt: String) -> String {
        let normalised = normalise(srt)
        var cues: [String] = []

        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }

            // A leading integer is the SRT cue index; WebVTT does not need it.
            var index = 0
            if let first = lines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil {
                index = 1
            }
            guard lines.count > index else { continue }

            let timeline = lines[index]
            guard let convertedTimeline = convertTimeline(timeline) else { continue }

            let text = lines[(index + 1)...].joined(separator: "\n")
            guard !text.isEmpty else { continue }

            cues.append(convertedTimeline + "\n" + text)
        }

        // A WebVTT file must open with the signature; an empty cue list is a
        // valid, empty track.
        guard !cues.isEmpty else { return "WEBVTT\n" }
        return "WEBVTT\n\n" + cues.joined(separator: "\n\n") + "\n"
    }

    /// Converts `00:00:01,000 --> 00:00:04,000` to the WebVTT spelling, or
    /// returns `nil` when the line is not a usable SRT timeline.
    static func convertTimeline(_ line: String) -> String? {
        let halves = line.components(separatedBy: "-->")
        guard halves.count == 2 else { return nil }

        let start = webVTTTimestamp(halves[0])
        let end = webVTTTimestamp(halves[1])
        guard let start, let end else { return nil }
        return "\(start) --> \(end)"
    }

    /// `HH:MM:SS,mmm` → `HH:MM:SS.mmm`. SRT uses a comma, WebVTT a period.
    static func webVTTTimestamp(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Position/alignment settings may trail the timestamp; keep them.
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let stamp = String(parts[0]).replacingOccurrences(of: ",", with: ".")
        guard stamp.contains(":") else { return nil }
        // WebVTT requires at least HH:MM:SS.mmm; SRT sometimes omits hours.
        let components = stamp.components(separatedBy: ":")
        let normalisedStamp: String
        switch components.count {
        case 2: normalisedStamp = "00:" + stamp
        case 3: normalisedStamp = stamp
        default: return nil
        }
        return parts.count > 1
            ? normalisedStamp + " " + parts[1]
            : normalisedStamp
    }

    private static func normalise(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        // Collapse runs of blank lines so the block split is reliable.
        while value.contains("\n\n\n") {
            value = value.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapes caption text that would otherwise be read as WebVTT markup.
    public static func escapeCueText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// A caption track materialised on disk.
public struct PreparedSubtitle: Hashable, Sendable {
    public let language: String
    public let fileURL: URL

    public init(language: String, fileURL: URL) {
        self.language = language
        self.fileURL = fileURL
    }
}

/// Writes converted caption tracks to a cache directory.
///
/// Kept free of AVFoundation so it runs (and is tested) on Linux.
///
/// `FileManager` is not `Sendable` on Apple platforms, so this holds only the
/// directory and takes the shared instance at the point of use — which Apple
/// documents as safe to call from multiple threads.
public struct SubtitleCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A stable on-disk name, so repeated playback reuses the converted file
    /// instead of re-fetching and re-converting.
    public func fileURL(for track: SubtitleTrack) -> URL {
        let stem = track.id
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(stem).vtt")
    }

    /// Returns a WebVTT file URL for `track`, converting and caching as needed.
    @discardableResult
    public func prepare(track: SubtitleTrack, contents: String) throws -> URL {
        let fileManager = FileManager.default
        let destination = fileURL(for: track)
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = track.needsConversion
            ? SubtitleConverter.webVTT(fromSRT: contents)
            : contents
        try body.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}
