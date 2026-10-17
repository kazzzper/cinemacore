import Foundation

/// Transport-agnostic domain types shared by every screen.
///
/// These mirror `core/models/models.go` and `contracts/openapi.yaml` field for
/// field (`camelCase` on the wire), extended with the presentation fields the
/// Genga-World UI needs — cast, season counts, per-episode art. Extensions are
/// additive; the contract is versioned, never mutated in place.

// MARK: - Catalog

/// A movie, series, or other catalog entry.
public struct Subject: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let poster: String?
    public let year: Int?
    public let rating: Double?
    /// Provider subject type: `1` movie, `2` series.
    public let kind: String?
    public let synopsis: String?
    public let genres: [String]
    public let dubs: [String]
    public let durationMinutes: Int?
    public let seasonCount: Int
    public let cast: [CastMember]
    /// Provider playable resources (dub/sub variants) offered for this title.
    public let resourceDetectors: [ResourceDetector]

    public init(
        id: String,
        title: String,
        poster: String? = nil,
        year: Int? = nil,
        rating: Double? = nil,
        kind: String? = nil,
        synopsis: String? = nil,
        genres: [String] = [],
        dubs: [String] = [],
        durationMinutes: Int? = nil,
        seasonCount: Int = 1,
        cast: [CastMember] = [],
        resourceDetectors: [ResourceDetector] = []
    ) {
        self.id = id
        self.title = title
        self.poster = poster
        self.year = year
        self.rating = rating
        self.kind = kind
        self.synopsis = synopsis
        self.genres = genres
        self.dubs = dubs
        self.durationMinutes = durationMinutes
        self.seasonCount = seasonCount
        self.cast = cast
        self.resourceDetectors = resourceDetectors
    }

    /// A series is anything the provider flags as multi-episode.
    public var isSeries: Bool {
        kind == "2" || kind?.lowercased() == "tv" || seasonCount > 1
    }

    /// `"2021"`, or `nil` when the provider gave us nothing usable.
    public var yearText: String? {
        guard let year, year > 0 else { return nil }
        return String(year)
    }

    /// `"8.5"`, or `nil` when unrated.
    public var ratingText: String? {
        guard let rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }

    /// `"2h 8m"` / `"48m"`, or `nil`.
    public var durationText: String? {
        guard let minutes = durationMinutes, minutes > 0 else { return nil }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        return "\(minutes)m"
    }

    /// The subtitle line on a card: year · genres · duration, without empties.
    public var metadataLine: String {
        var parts: [String] = []
        if let yearText { parts.append(yearText) }
        if let first = genres.first { parts.append(first) }
        if isSeries {
            parts.append(seasonCount == 1 ? "1 Season" : "\(seasonCount) Seasons")
        } else if let durationText {
            parts.append(durationText)
        }
        return parts.joined(separator: " · ")
    }

    /// A poster URL, upgrading the protocol-relative form the provider emits.
    public var posterURL: URL? {
        guard let poster, !poster.isEmpty else { return nil }
        if poster.hasPrefix("//") { return URL(string: "https:" + poster) }
        return URL(string: poster)
    }

    /// URL for the native iOS poster aspect (2:3), when the provider supports it.
    public var widePosterURL: URL? { posterURL }
}

/// One selectable playback resource the provider offers (a dub or sub variant).
public struct ResourceDetector: Identifiable, Hashable, Sendable, Codable {
    public let resourceId: String
    public let name: String

    public init(resourceId: String, name: String) {
        self.resourceId = resourceId
        self.name = name
    }

    public var id: String { resourceId }

    /// The provider marks dubs in the identifier, not reliably in the label.
    public var isDub: Bool {
        resourceId.lowercased().hasPrefix("dub_") || name.lowercased().contains("dub")
    }
}

/// One credited person.
public struct CastMember: Identifiable, Hashable, Sendable, Codable {
    public let name: String
    public let role: String
    public let avatar: String?

    public init(name: String, role: String = "", avatar: String? = nil) {
        self.name = name
        self.role = role
        self.avatar = avatar
    }

    public var id: String { name }

    public var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        return URL(string: avatar.hasPrefix("//") ? "https:" + avatar : avatar)
    }
}

/// A titled row of subjects on the home screen.
public struct Section: Identifiable, Hashable, Sendable, Codable {
    public let title: String
    public let items: [Subject]

    public init(title: String, items: [Subject]) {
        self.title = title
        self.items = items
    }

    /// Titles are unique per page in the provider response.
    public var id: String { title }
}

/// The home payload: an ordered list of rails.
public struct Page: Hashable, Sendable, Codable {
    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }
}

// MARK: - Episodes

/// One season of a series.
public struct Season: Identifiable, Hashable, Sendable, Codable {
    public let number: Int
    public let episodes: [Episode]

    public init(number: Int, episodes: [Episode]) {
        self.number = number
        self.episodes = episodes
    }

    public var id: Int { number }

    public var title: String { "Season \(number)" }
}

/// One episode of a series.
public struct Episode: Identifiable, Hashable, Sendable, Codable {
    public let subjectID: String
    public let season: Int
    public let number: Int
    public let title: String
    public let duration: String
    public let still: String?

    public init(
        subjectID: String,
        season: Int,
        number: Int,
        title: String = "",
        duration: String = "",
        still: String? = nil
    ) {
        self.subjectID = subjectID
        self.season = season
        self.number = number
        self.title = title
        self.duration = duration
        self.still = still
    }

    public var id: String { "\(subjectID)-s\(season)e\(number)" }

    /// Never renders an empty row.
    public var displayTitle: String {
        title.isEmpty ? "Episode \(number)" : title
    }

    public var stillURL: URL? {
        guard let still, !still.isEmpty else { return nil }
        return URL(string: still.hasPrefix("//") ? "https:" + still : still)
    }
}

/// A subject with its full season/episode tree, as returned by the detail call.
public struct SubjectDetail: Hashable, Sendable, Codable {
    public let subject: Subject
    public let seasons: [Season]

    public init(subject: Subject, seasons: [Season]) {
        self.subject = subject
        self.seasons = seasons
    }

    /// All episodes across every season, in order.
    public var allEpisodes: [Episode] { seasons.flatMap(\.episodes) }
}

// MARK: - Playback

/// One selectable stream rendition.
public struct StreamRendition: Identifiable, Hashable, Sendable, Codable {
    /// Provider label, e.g. `"1080p"`.
    public let quality: String
    public let url: String
    public let size: String?
    /// Per-rendition cookie the CDN expects, when the provider supplies one.
    public let cookie: String?

    public init(quality: String, url: String, size: String? = nil, cookie: String? = nil) {
        self.quality = quality
        self.url = url
        self.size = size
        self.cookie = cookie
    }

    public var id: String { "\(quality)-\(url)" }

    /// Sort key so `1080p` outranks `720p` rather than sorting lexically.
    public var resolutionRank: Int {
        let digits = quality.prefix { $0.isNumber }
        if let value = Int(digits) { return value }
        return quality.lowercased().contains("4k") ? 2160 : 0
    }

    public var urlValue: URL? { URL(string: url) }
}

/// One subtitle track.
public struct SubtitleTrack: Identifiable, Hashable, Sendable, Codable {
    public let language: String
    public let url: String
    /// `"vtt"` or `"srt"`.
    public let format: String

    public init(language: String, url: String, format: String = "vtt") {
        self.language = language
        self.url = url
        self.format = format
    }

    public var id: String { "\(language)-\(url)" }

    /// AVPlayer only renders WebVTT, so SRT has to be converted first.
    public var needsConversion: Bool {
        format.lowercased() == "srt"
    }
}

/// The resolved playback payload for one episode (or movie).
public struct PlayInfo: Hashable, Sendable, Codable {
    public let streams: [StreamRendition]
    public let subtitles: [SubtitleTrack]

    public init(streams: [StreamRendition] = [], subtitles: [SubtitleTrack] = []) {
        self.streams = streams
        self.subtitles = subtitles
    }

    public var isEmpty: Bool { streams.isEmpty }

    /// Renditions best-first, so the default pick is the highest quality.
    public var rankedStreams: [StreamRendition] {
        streams.sorted { $0.resolutionRank > $1.resolutionRank }
    }

    /// The rendition a fresh playback session should start on.
    ///
    /// The provider returns an explicit `"Auto"` entry first and lets adaptive
    /// bitrate do the work; an explicit quality is a *hint*, not a different
    /// URL (all renditions share one URL). Only when no `Auto` entry exists do
    /// we fall back to the highest labelled resolution.
    public var preferredStream: StreamRendition? {
        streams.first { $0.quality.caseInsensitiveCompare("Auto") == .orderedSame }
            ?? rankedStreams.first
    }

    /// Playback speeds offered by the player sheet, matching the Android build
    /// exactly (`0.5x … 2.0x`, six steps, no 1.75x).
    public static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
}

// MARK: - Local data

/// A saved watchlist row.
public struct WatchlistEntry: Identifiable, Hashable, Sendable, Codable {
    public let subject: Subject
    public let addedAt: Date

    public init(subject: Subject, addedAt: Date = Date()) {
        self.subject = subject
        self.addedAt = addedAt
    }

    public var id: String { subject.id }
}

/// One "continue watching" row.
public struct ResumePoint: Identifiable, Hashable, Sendable, Codable {
    public let subjectID: String
    public let title: String
    public let poster: String?
    public let season: Int?
    public let episode: Int?
    public let positionSeconds: Double
    public let durationSeconds: Double
    public let updatedAt: Date

    public init(
        subjectID: String,
        title: String,
        poster: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        positionSeconds: Double,
        durationSeconds: Double,
        updatedAt: Date = Date()
    ) {
        self.subjectID = subjectID
        self.title = title
        self.poster = poster
        self.season = season
        self.episode = episode
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.updatedAt = updatedAt
    }

    public var id: String {
        guard let season, let episode else { return subjectID }
        return "\(subjectID)-s\(season)e\(episode)"
    }

    /// Clamped 0...1 for progress indicators.
    public var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    /// `"12m left"`, or `nil` when the duration is unknown.
    public var remainingText: String? {
        guard durationSeconds > 0 else { return nil }
        let remaining = Int((durationSeconds - positionSeconds) / 60)
        guard remaining > 0 else { return "Finished" }
        return "\(remaining)m left"
    }

    /// `"S2 E4"`, or `nil` for a movie.
    public var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return "S\(season) E\(episode)"
    }

    /// A resume point within 30 seconds of the end is not worth offering.
    public var isResumable: Bool {
        progress < 0.98 && positionSeconds > 5
    }
}

/// The search payload, which the provider returns under either key.
public struct SearchResults: Hashable, Sendable, Codable {
    public let items: [Subject]

    public init(items: [Subject]) {
        self.items = items
    }
}
