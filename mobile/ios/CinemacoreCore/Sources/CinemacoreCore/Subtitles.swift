import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// Combining the two caption sources without losing a viewer's pick.
///
/// The provider and the community addon answer independently and either can land
/// second. Replacing one list with the other is what made a chosen track vanish
/// from the picker while it was still playing, so the merge keeps the list that
/// is already on screen first and appends only what is genuinely new.
public enum SubtitleTracks {
    /// `existing` first, then whatever `incoming` adds.
    ///
    /// Order is deliberate: the existing list is what the picker is showing, and
    /// re-sorting it under the viewer's finger on a late response would move the
    /// row they are about to tap.
    public static func merging(
        _ existing: [SubtitleTrack],
        with incoming: [SubtitleTrack]
    ) -> [SubtitleTrack] {
        var seen = Set(existing.map(\.id))
        return existing + incoming.filter { seen.insert($0.id).inserted }
    }

    /// The track a fresh playback should start on.
    ///
    /// A dub already speaks the requested language, so an original-language
    /// caption is not a default there — the picker still offers it. `chosen`
    /// being non-nil means the viewer has picked and the answer is never a new
    /// default.
    public static func defaultTrack(
        in tracks: [SubtitleTrack],
        isOriginalAudio: Bool,
        chosen: SubtitleTrack?
    ) -> SubtitleTrack? {
        guard chosen == nil, isOriginalAudio else { return chosen }
        return tracks.first
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
    ///
    /// Provider tracks are signed URLs hundreds of characters long, which
    /// exceeds the filesystem's 255-byte name limit when used verbatim. The
    /// language keeps the name readable; the FNV-1a digest of the track id keeps
    /// it unique without a random UUID, so the same track always maps to the
    /// same file across launches.
    public func fileURL(for track: SubtitleTrack) -> URL {
        directory.appendingPathComponent(Self.fileName(for: track))
    }

    /// Returns a WebVTT file URL for `track`, converting and caching as needed.
    ///
    /// A cache that cannot be read or written falls back to the temporary
    /// directory: a caption track that is slow or unavailable is still better
    /// than silently rendering nothing.
    @discardableResult
    public func prepare(track: SubtitleTrack, contents: String) throws -> URL {
        let fileManager = FileManager.default
        let destination = fileURL(for: track)
        if Self.isUsableCacheFile(at: destination, fileManager: fileManager) {
            return destination
        }

        let body = track.needsConversion
            ? SubtitleConverter.webVTT(fromSRT: contents)
            : contents

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // An empty or malformed leftover must not keep poisoning playback.
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try body.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            return try Self.writeFallback(body, fileName: destination.lastPathComponent)
        }
    }

    /// Language plus digest: at most 32 ASCII characters, a hyphen and 16 hex
    /// digits, so the component stays far below the 255-byte limit.
    static func fileName(for track: SubtitleTrack) -> String {
        "\(languageStem(track.language))-\(String(fnv1a64(track.id), radix: 16)).vtt"
    }

    /// Keeps a readable prefix while dropping path separators, punctuation and
    /// non-ASCII scalars that a filesystem or archive could treat specially.
    private static func languageStem(_ language: String) -> String {
        var stem = ""
        for scalar in language.unicodeScalars {
            guard stem.count < 32 else { break }
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                stem.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == "_" || scalar == " " || scalar == "." {
                if !stem.isEmpty, stem.last != "-" { stem.append("-") }
            }
        }
        let trimmed = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "sub" : trimmed
    }

    /// FNV-1a, 64-bit. Chosen because it is tiny, deterministic and dependency
    /// free, and Linux tests must compile without CryptoKit.
    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Empty, unreadable or non-WebVTT files are treated as absent so `prepare`
    /// rewrites them instead of handing the player a broken track.
    private static func isUsableCacheFile(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              var probe = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        if probe.hasPrefix("\u{FEFF}") { probe.removeFirst() }
        return probe.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
    }

    private static func writeFallback(_ body: String, fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinemacore-\(fileName)")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// A caption track that travelled with a download.
///
/// Saved as WebVTT beside the media file, so a completed episode carries its
/// captions too. Without it an offline copy plays the picture and offers no
/// subtitles at all, which is the one thing a download is supposed to be
/// complete about.
public struct DownloadedSubtitle: Codable, Hashable, Sendable, Identifiable {
    public let language: String
    /// File name inside the downloads directory, where the engine wrote it. A
    /// name rather than a path: the container can move between launches.
    public let fileName: String
    /// The release or file label the track came with, when the source had one.
    public let source: String?

    public init(language: String, fileName: String, source: String? = nil) {
        self.language = language
        self.fileName = fileName
        self.source = source
    }

    public var id: String { fileName }

    /// The picker's own type, pointed at the saved file.
    ///
    /// The URL is a real `file:` URL, so the player never asks the network for
    /// a caption that is already on disk — which is the whole reason this type
    /// exists.
    public func track(in directory: URL) -> SubtitleTrack {
        SubtitleTrack(
            language: language,
            url: directory.appendingPathComponent(fileName).absoluteString,
            format: "vtt",
            source: source,
            provider: .downloaded
        )
    }
}

/// Fetches caption tracks and writes them beside a download.
///
/// Injected into the download engine, so an episode leaves with its captions.
/// Best effort per track: a dead host costs that language, never the file that
/// has already finished downloading.
public struct SubtitleArchive: Sendable {
    private let directory: URL
    private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
    }

    /// The saved tracks, in the order the source listed them.
    ///
    /// A track that cannot be fetched, decoded or written is skipped: subtitles
    /// are an addition to the download, not a condition of it. The page size is
    /// capped because the provider lists one caption per release it matched,
    /// and a whole shelf of them is not worth the wait.
    public func store(
        _ tracks: [SubtitleTrack],
        headers: [String: String] = [:],
        limit: Int = 12
    ) async -> [DownloadedSubtitle] {
        let cache = SubtitleCache(directory: directory)
        var saved: [DownloadedSubtitle] = []
        var seen = Set<String>()
        for track in tracks.prefix(max(0, limit)) {
            guard let url = URL(string: track.url) else { continue }
            var request = URLRequest(url: url)
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let body = String(data: data, encoding: .utf8),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let fileURL = try? cache.prepare(track: track, contents: body)
            else { continue }
            // Two releases can share a language but never a file, and the cache
            // name is keyed on the track id, so the digest keeps them apart.
            let fileName = fileURL.lastPathComponent
            guard seen.insert(fileName).inserted else { continue }
            saved.append(
                DownloadedSubtitle(language: track.language, fileName: fileName, source: track.source)
            )
        }
        return saved
    }
}
