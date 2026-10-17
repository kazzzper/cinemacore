import Foundation

// Tolerant wire decoding.
//
// Swift's synthesised `init(from:)` **ignores property defaults**, so a
// non-optional stored property is a hard requirement even when the contract
// marks it optional. The provider omits fields freely (`genres`, `cast`,
// `seasonCount`, subtitle `format`, episode `duration`), so every
// network-facing type decodes through `decodeIfPresent` and falls back to the
// same default its initialiser advertises.
//
// The synthesised memberwise initialisers remain the public, non-optional API:
// only the decoding path is forgiving.
//
// Supplying `init(from:)` suppresses the compiler's synthesised `CodingKeys`,
// so each type declares them explicitly here.

extension Subject {
    public enum CodingKeys: String, CodingKey {
        case id, title, poster, year, rating, kind, synopsis, genres, dubs
        case durationMinutes, seasonCount, cast, resourceDetectors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        synopsis = try container.decodeIfPresent(String.self, forKey: .synopsis)
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        dubs = try container.decodeIfPresent([String].self, forKey: .dubs) ?? []
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        seasonCount = try container.decodeIfPresent(Int.self, forKey: .seasonCount) ?? 1
        cast = try container.decodeIfPresent([CastMember].self, forKey: .cast) ?? []
        resourceDetectors = try container
            .decodeIfPresent([ResourceDetector].self, forKey: .resourceDetectors) ?? []
    }
}

extension CastMember {
    public enum CodingKeys: String, CodingKey {
        case name, role, avatar
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
    }
}

extension ResourceDetector {
    public enum CodingKeys: String, CodingKey {
        case resourceId, name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceId = try container.decode(String.self, forKey: .resourceId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

extension Episode {
    /// The gateway spells this `subjectId` (`core/models/models.go`), so the
    /// wire key is pinned rather than derived from the property name.
    public enum CodingKeys: String, CodingKey {
        case subjectId, season, number, title, duration, still
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subjectID = try container.decode(String.self, forKey: .subjectId)
        season = try container.decode(Int.self, forKey: .season)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        duration = try container.decodeIfPresent(String.self, forKey: .duration) ?? ""
        still = try container.decodeIfPresent(String.self, forKey: .still)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subjectID, forKey: .subjectId)
        try container.encode(season, forKey: .season)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(still, forKey: .still)
    }
}

extension Season {
    public enum CodingKeys: String, CodingKey {
        case number, episodes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        episodes = try container.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
    }
}

extension SubjectDetail {
    public enum CodingKeys: String, CodingKey {
        case subject, seasons
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subject = try container.decode(Subject.self, forKey: .subject)
        seasons = try container.decodeIfPresent([Season].self, forKey: .seasons) ?? []
    }
}

extension Section {
    public enum CodingKeys: String, CodingKey {
        case title, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        items = try container.decodeIfPresent([Subject].self, forKey: .items) ?? []
    }
}

extension Page {
    public enum CodingKeys: String, CodingKey {
        case sections
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
    }
}

extension StreamRendition {
    public enum CodingKeys: String, CodingKey {
        case quality, url, size, cookie
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decode(String.self, forKey: .quality)
        url = try container.decode(String.self, forKey: .url)
        size = try container.decodeIfPresent(String.self, forKey: .size)
        cookie = try container.decodeIfPresent(String.self, forKey: .cookie)
    }
}

extension SubtitleTrack {
    public enum CodingKeys: String, CodingKey {
        case language, url, format
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        url = try container.decode(String.self, forKey: .url)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "vtt"
    }
}

extension PlayInfo {
    public enum CodingKeys: String, CodingKey {
        case streams, subtitles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeIfPresent([StreamRendition].self, forKey: .streams) ?? []
        subtitles = try container.decodeIfPresent([SubtitleTrack].self, forKey: .subtitles) ?? []
    }
}
