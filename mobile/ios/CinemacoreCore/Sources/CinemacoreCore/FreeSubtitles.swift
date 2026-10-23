import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a free caption lookup needs in order to identify a title.
public struct FreeSubtitleRequest: Sendable, Hashable {
    public let title: String
    public let year: Int?
    public let isSeries: Bool
    public let season: Int?
    public let episode: Int?
    /// ISO-639-1 code or a language name; `nil` ranks English first.
    public let language: String?

    public init(
        title: String,
        year: Int? = nil,
        isSeries: Bool = false,
        season: Int? = nil,
        episode: Int? = nil,
        language: String? = nil
    ) {
        self.title = title
        self.year = year
        self.isSeries = isSeries
        self.season = season
        self.episode = episode
        self.language = language
    }
}

/// Keyless community captions for the titles the provider publishes none for.
///
/// The built-in provider carries external captions only for the titles it holds
/// them for; the rest report none at all, which is why most videos looked
/// captionless. Stremio's OpenSubtitles v3 addon is the one free source that
/// needs no API key, no account and no server-side proxy — every other option
/// (Wyzie, Subdl, OpenSubtitles.com) requires a key that must not ship inside an
/// app binary — and it serves UTF-8 SRT that is already unzipped.
///
/// It matches on an IMDb id, which the gateway does not publish, so Cinemeta —
/// the same operator's metadata addon — resolves the title to one first. Both
/// calls are plain HTTPS JSON, so no App Transport Security exception is
/// involved and `URLSession`'s own cache honours the addon's `max-age` headers.
///
/// The lookup sends the title (and, for a series, the episode number) to
/// Stremio's addon. It runs only when the provider returned no captions, and it
/// is best effort: any failure leaves playback exactly as it was.
public struct FreeSubtitles: Sendable {
    private let session: URLSession
    /// The addon returns dozens of tracks per title; a handful is all a picker
    /// can show and all a viewer will scroll.
    private let limit: Int
    /// The addon listing, injectable so the episode-label guard can be exercised
    /// without a network round trip.
    private let addon: (@Sendable (URL) async -> Data?)?

    public init(session: URLSession = .shared, limit: Int = 10) {
        self.session = session
        self.limit = limit
        self.addon = nil
    }

    init(
        session: URLSession = .shared,
        limit: Int = 10,
        addon: (@Sendable (URL) async -> Data?)?
    ) {
        self.session = session
        self.limit = limit
        self.addon = addon
    }

    /// Caption tracks for the request, the viewer's language first. Empty when
    /// the title cannot be identified or has no community tracks.
    public func tracks(for request: FreeSubtitleRequest) async -> [SubtitleTrack] {
        guard let imdb = await imdbID(for: request) else { return [] }
        guard let url = Self.addonURL(imdbID: imdb, request: request) else { return [] }
        let fetch = addon ?? { await Self.fetch(session, $0) }
        guard let data = await fetch(url) else { return [] }
        return Self.tracks(fromAddon: data, request: request, limit: limit)
    }

    /// The IMDb id Cinemeta resolves the title to.
    ///
    /// A search is by name, so the year breaks ties between a remake and its
    /// original — and Cinemeta's `releaseInfo` is a year or a year range, which
    /// is why the comparison is a prefix.
    func imdbID(for request: FreeSubtitleRequest) async -> String? {
        guard let url = Self.cinemetaURL(request),
              let data = await Self.fetch(session, url)
        else { return nil }
        return Self.imdbID(fromCinemeta: data, year: request.year)
    }

    // MARK: - URLs

    static func cinemetaURL(_ request: FreeSubtitleRequest) -> URL? {
        let type = request.isSeries ? "series" : "movie"
        guard let query = encoded(request.title) else { return nil }
        return URL(string: "https://v3-cinemeta.strem.io/catalog/\(type)/top/search=\(query).json")
    }

    static func addonURL(imdbID: String, request: FreeSubtitleRequest) -> URL? {
        guard request.isSeries else {
            return URL(string: "https://opensubtitles-v3.strem.io/subtitles/movie/\(imdbID).json")
        }
        let season = max(request.season ?? 1, 1)
        let episode = max(request.episode ?? 1, 1)
        return URL(string: "https://opensubtitles-v3.strem.io/subtitles/series/\(imdbID):\(season):\(episode).json")
    }

    /// The title sits in a path segment rather than a query value, so the
    /// characters that would end or re-parse that segment are escaped by hand.
    static func encoded(_ raw: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&+=")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    static func fetch(_ session: URLSession, _ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    // MARK: - Decoding

    struct Cinemeta: Decodable {
        let metas: [Meta]?

        struct Meta: Decodable {
            let imdbID: String?
            let releaseInfo: String?

            enum CodingKeys: String, CodingKey {
                case imdbID = "imdb_id"
                case releaseInfo
            }
        }
    }

    struct Addon: Decodable {
        let subtitles: [Entry]?

        struct Entry: Decodable {
            let url: String?
            let lang: String?
            /// The file the addon matched, and the release it belongs to. Both
            /// are what a "source" label is built from; either may be absent.
            let subtitleFileName: String?
            let movieReleaseName: String?
            let releaseGroup: String?
            let releaseFormat: String?
            /// The addon echoes the season and episode it answered for. It is
            /// not a guarantee — entries naming another episode do appear — but
            /// it is the only per-entry hint of what the file actually covers.
            let season: Int?
            let episode: Int?
        }
    }

    static func imdbID(fromCinemeta data: Data, year: Int?) -> String? {
        guard let page = try? JSONDecoder().decode(Cinemeta.self, from: data) else { return nil }
        let metas = (page.metas ?? []).filter { ($0.imdbID ?? "").hasPrefix("tt") }
        guard let fallback = metas.first else { return nil }
        guard let year else { return fallback.imdbID }
        let match = metas.first { ($0.releaseInfo ?? "").hasPrefix(String(year)) }
        return (match ?? fallback).imdbID
    }

    /// Best match first: the viewer's language, then English, then the addon's
    /// own order. One file is listed once per release name it matched, so the
    /// URL is the identity.
    static func tracks(
        fromAddon data: Data,
        request: FreeSubtitleRequest,
        limit: Int
    ) -> [SubtitleTrack] {
        guard let page = try? JSONDecoder().decode(Addon.self, from: data) else { return [] }
        var seen = Set<String>()
        var candidates: [(rank: Int, offset: Int, track: SubtitleTrack)] = []
        for (offset, entry) in (page.subtitles ?? []).enumerated() {
            guard let url = entry.url, url.hasPrefix("http"), seen.insert(url).inserted else { continue }
            guard namesRequestedEpisode(entry, request: request) else { continue }
            let code = (entry.lang ?? "").lowercased()
            candidates.append((
                rank(code, request.language),
                offset,
                SubtitleTrack(
                    language: displayName(code),
                    url: url,
                    format: "srt",
                    source: releaseLabel(entry),
                    provider: .community
                )
            ))
        }
        candidates.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.offset < rhs.offset : lhs.rank < rhs.rank
        }
        return candidates.prefix(max(limit, 0)).map(\.track)
    }

    /// Whether an addon entry actually covers the requested episode.
    ///
    /// The listing is a fuzzy match: a lookup for S01E01 of Game of Thrones
    /// returns an S08E02 file and one from an unrelated series. Nothing in the
    /// entry marks it as wrong except the release name, so an entry whose name
    /// spells a *different* season/episode is dropped. An entry with no
    /// recognisable marker is kept — most bare `S01E01.srt` names are right, and
    /// dropping them would empty the picker for titles the addon spells loosely.
    static func namesRequestedEpisode(_ entry: Addon.Entry, request: FreeSubtitleRequest) -> Bool {
        guard request.isSeries else { return true }
        let marker = episodeMarker(in: [entry.subtitleFileName, entry.movieReleaseName])
        guard let marker else { return true }
        // A nil season/episode means "the player had no number to send"; the
        // addon was asked for S1E1, so that is what was requested.
        return marker == (max(request.season ?? 1, 1), max(request.episode ?? 1, 1))
    }

    /// The first `S<n>E<n>` (or `1x01`) marker in any of `names`.
    static func episodeMarker(in names: [String?]) -> (season: Int, episode: Int)? {
        for name in names {
            guard let name, !name.isEmpty else { continue }
            let scalars = Array(name.lowercased())
            var index = 0
            while index < scalars.count {
                defer { index += 1 }
                guard scalars[index] == "s" else { continue }
                let before = index > 0 ? scalars[index - 1] : " "
                guard !before.isNumber, before != "s" else { continue }
                guard let season = digits(scalars, from: index + 1) else { continue }
                var cursor = season.end
                if cursor < scalars.count, scalars[cursor] == "." || scalars[cursor] == "_" {
                    cursor += 1
                }
                guard cursor < scalars.count, scalars[cursor] == "e" else { continue }
                guard let episode = digits(scalars, from: cursor + 1) else { continue }
                return (season.value, episode.value)
            }
        }
        return nil
    }

    /// A run of digits as a number, plus the index just past it.
    private static func digits(
        _ scalars: [Character],
        from start: Int
    ) -> (value: Int, end: Int)? {
        var cursor = start
        var value = 0
        while cursor < scalars.count, let digit = scalars[cursor].wholeNumberValue {
            value = value * 10 + digit
            cursor += 1
        }
        guard cursor > start else { return nil }
        return (value, cursor)
    }

    /// The release an entry belongs to, most specific first.
    ///
    /// The release name is the file's own title; the file name is the next best
    /// thing and the group/format the last, for the many entries that ship
    /// neither. Without a per-entry label two English tracks would draw
    /// identically in the picker, which is the defect this exists to fix.
    static func releaseLabel(_ entry: Addon.Entry) -> String? {
        for candidate in [entry.movieReleaseName, entry.subtitleFileName] {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let parts = [entry.releaseGroup, entry.releaseFormat]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 0 for the viewer's language, 1 for English, 2 for everything else.
    static func rank(_ code: String, _ language: String?) -> Int {
        if let language, matches(code, language) { return 0 }
        return matches(code, "en") ? 1 : 2
    }

    /// The addon speaks ISO-639-2 (`"eng"`) while a stored preference is usually
    /// ISO-639-1 (`"en"`), so either spelling being a prefix of the other is the
    /// match they share.
    static func matches(_ code: String, _ wanted: String) -> Bool {
        let lhs = code.lowercased()
        let rhs = wanted.lowercased()
        guard lhs.count >= 2, rhs.count >= 2 else { return false }
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    /// Legacy ISO-639-2/B codes the addon still emits and Foundation no longer
    /// resolves. Kept to the codes seen in real listings rather than to the
    /// whole deprecated table, so an unmapped code is visible rather than
    /// silently mistranslated.
    private static let legacyLanguageAliases: [String: String] = [
        "pob": "pt",   // Brazilian Portuguese
        "scc": "sr",   // Serbian (old)
        "scr": "hr",   // Croatian (old)
        "mol": "ro",   // Moldavian
        "tgl": "fil",  // Tagalog
        "iw": "he",    // Hebrew (old)
        "in": "id",    // Indonesian (old)
        "ji": "yi",    // Yiddish (old)
    ]

    /// The addon's code as a readable language. Foundation resolves ISO-639-2
    /// directly, but not every legacy code: Brazilian Portuguese `"pob"` has no
    /// name of its own, so it falls back to the base language rather than
    /// showing a bare tag in the picker.
    static func displayName(_ code: String) -> String {
        guard !code.isEmpty else { return "Subtitle" }
        let locale = Locale(identifier: "en_US")
        let lowered = code.lowercased()
        let candidates = [lowered, legacyLanguageAliases[lowered]].compactMap { $0 }
        for candidate in candidates {
            if let name = locale.localizedString(forLanguageCode: candidate) {
                return name.capitalized
            }
        }
        // A regional variant shares the first two letters of its base language;
        // a code shorter than that is not worth guessing at.
        let base = String(lowered.prefix(2))
        if base.count == 2, let name = locale.localizedString(forLanguageCode: base) {
            return name.capitalized
        }
        return code.uppercased()
    }
}
