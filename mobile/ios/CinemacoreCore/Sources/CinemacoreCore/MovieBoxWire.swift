import Foundation

// The MovieBox gateway's wire shapes, decoded straight into the app's models.
//
// These are `internal` on purpose: they are the private vocabulary of
// `MovieBoxCatalogRepository` and must not leak into the app's public surface.
// The shapes mirror `core/provider/moviebox/moviebox.go`'s `wire*` types, which
// are the reference; field spellings are `camelCase` because that is what the
// gateway sends.

struct Envelope<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
}

struct ItemsPage: Decodable {
    let items: [WireSubject]?
}

// MARK: - Subject

struct WireSubject: Decodable {
    let subjectId: String?
    let subjectType: Int?
    let kind: String?
    let title: String?
    let name: String?
    let description: String?
    let releaseDate: String?
    let duration: String?
    let durationSeconds: Int?
    let seconds: Int?
    let genre: String?
    let cover: WireImage?
    let imdbRatingValue: String?
    let seNum: Int?
    let seasonCount: Int?
    let staffList: [WireStaff]?
    let dubs: [WireDub]?
    let resourceDetectors: [WireDetector]?

    var subject: Subject {
        Subject(
            id: subjectId ?? "",
            title: firstNonEmpty(title, name),
            poster: WireSubject.httpsURL(cover?.url),
            year: WireSubject.year(releaseDate),
            rating: WireSubject.rating(imdbRatingValue),
            kind: firstNonEmpty(kind, WireSubject.kindOf(subjectType)),
            synopsis: description,
            genres: WireSubject.splitList(genre),
            dubs: (dubs ?? []).compactMap { dub in
                guard let name = dub.lanName, !name.isEmpty else { return nil }
                return name
            },
            dubOptions: (dubs ?? []).compactMap { dub in
                guard let name = dub.lanName, !name.isEmpty,
                      let subjectId = dub.subjectId, !subjectId.isEmpty
                else { return nil }
                return Dub(
                    subjectId: subjectId,
                    languageName: name,
                    languageCode: dub.lanCode,
                    isOriginal: dub.original ?? false
                )
            },
            durationMinutes: WireSubject.durationMinutes(totalSeconds, duration),
            seasonCount: seasonCount ?? seNum ?? 1,
            cast: (staffList ?? []).compactMap { staff in
                guard let name = staff.name, !name.isEmpty else { return nil }
                return CastMember(name: name, role: staff.character ?? "", avatar: staff.avatarUrl)
            },
            resourceDetectors: (resourceDetectors ?? []).compactMap { detector in
                guard let rid = detector.resourceId, !rid.isEmpty else { return nil }
                let source = detector.source ?? ""
                return ResourceDetector(
                    resourceId: rid,
                    name: source.isEmpty ? "Resource" : source
                )
            }
        )
    }

    private var totalSeconds: Int {
        if let exact = durationSeconds, exact > 0 { return exact }
        return seconds ?? 0
    }

    /// Promotes the protocol-relative asset URLs some endpoints return ("//pbcdn…").
    static func httpsURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.hasPrefix("//") ? "https:" + raw : raw
    }

    static func year(_ releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4, let y = Int(releaseDate.prefix(4)) else { return nil }
        return y
    }

    static func rating(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value
    }

    static func kindOf(_ subjectType: Int?) -> String? {
        switch subjectType {
        case 1: "movie"
        case 2: "series"
        case 10: "game"
        // The layout feed sends 5/7/9 for titles the app still renders; without
        // a mapping they arrive with no kind and read as movies, hiding the
        // episode tree (provider-gap-analysis.md). Unknown-but-nonzero types
        // that coexist with a season count are treated as series.
        default: nil
        }
    }

    static func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Prefers the exact second count and falls back to the "1h 33m" string.
    static func durationMinutes(_ seconds: Int, _ human: String?) -> Int {
        if seconds > 0 { return seconds / 60 }
        guard let human, !human.isEmpty else { return 0 }
        var total = 0
        var digits = ""
        for character in human {
            if character.isNumber {
                digits.append(character)
            } else if character == "h" || character == "H" {
                total += (Int(digits) ?? 0) * 60
                digits = ""
            } else if character == "m" || character == "M" {
                total += Int(digits) ?? 0
                digits = ""
            }
        }
        return total
    }
}

struct WireImage: Decodable {
    let url: String?
}

struct WireStaff: Decodable {
    let name: String?
    let character: String?
    let avatarUrl: String?
}

struct WireDub: Decodable {
    let lanCode: String?
    let lanName: String?
    let original: Bool?
    let subjectId: String?
}

struct WireDetector: Decodable {
    let type: Int?
    let resourceId: String?
    let source: String?
}

func firstNonEmpty(_ values: String?...) -> String {
    for value in values where !(value ?? "").isEmpty {
        return value ?? ""
    }
    return ""
}

// MARK: - Seasons

struct SeasonInfo: Decodable {
    let seasons: [WireSeason]?
}

struct WireSeason: Decodable {
    let se: Int?
    let maxEp: Int?
    let allEp: String?

    var season: Season? {
        guard let number = se else { return nil }
        let numbers = episodeNumbers(allEp, maxEp ?? 0)
        return Season(
            number: number,
            episodes: numbers.map { n in
                Episode(subjectID: "", season: number, number: n)
            }
        )
    }

    /// `allEp` is the authoritative list when present (it can have gaps);
    /// otherwise every number up to maxEp is present.
    private func episodeNumbers(_ allEp: String?, _ maxEp: Int) -> [Int] {
        if let allEp, !allEp.isEmpty {
            let numbers = allEp
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 > 0 }
            if !numbers.isEmpty { return numbers }
        }
        guard maxEp > 0 else { return [] }
        return Array(1...maxEp)
    }
}

// MARK: - Playback

struct PlayInfoWire: Decodable {
    let streams: [WireStream]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeIfPresent([WireStream].self, forKey: .streams) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case streams
    }
}

struct WireStream: Decodable {
    let url: String?
    let resolutions: String?
    let size: String?
    let signCookie: String?
    /// The gateway's declared container (`"MP4"`, `"M4A"`, …) and codec
    /// (`"hevc"`, `"aac"`, …). Both are optional upstream and are the only
    /// fields that identify an audio-only entry before it is fetched.
    let format: String?
    let codecName: String?
}

struct Suggest: Decodable {
    struct Item: Decodable {
        let word: String?
    }
    let items: [Item]?
}

struct Captions: Decodable {
    struct Caption: Decodable {
        let lan: String?
        let lanName: String?
        let url: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lan = try container.decodeIfPresent(String.self, forKey: .lan)
            lanName = try container.decodeIfPresent(String.self, forKey: .lanName)
            url = try container.decodeIfPresent(String.self, forKey: .url)
        }

        enum CodingKeys: String, CodingKey {
            case lan, lanName, url
        }
    }

    let extCaptions: [Caption]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every entry is decoded on its own: one caption with a wrong shape must
        // not throw away the whole track list. `try?` also covers a payload whose
        // `extCaptions` is not an array at all.
        let entries = try? container.decodeIfPresent([LossyCaption?].self, forKey: .extCaptions)
        extCaptions = (entries ?? []).compactMap { $0?.value }
    }

    /// Keeps a bad element (`null`, a string, a malformed object) out of the
    /// result instead of failing the array.
    private struct LossyCaption: Decodable {
        let value: Caption?

        init(from decoder: any Decoder) throws {
            value = try? Caption(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case extCaptions
    }
}

// MARK: - Recovery wire types

struct UGCFirst: Decodable {
    let ugcVideoId: String?
    let belongToCollection: Collection?

    struct Collection: Decodable {
        let collectionId: String?
    }
}

struct UGCDownload: Decodable {
    let items: [UGCItem]?

    init(from decoder: any Decoder) throws {
        items = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent([UGCItem].self, forKey: .items) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case items
    }
}

struct UGCItem: Decodable {
    let epTitle: String?
    let title: String?
    let resources: [UGCResource]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epTitle = try container.decodeIfPresent(String.self, forKey: .epTitle)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        resources = try container.decodeIfPresent([UGCResource].self, forKey: .resources) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case epTitle, title, resources
    }
}

struct UGCResource: Decodable {
    let url: String?
    let resolutions: String?
    let size: String?
    let duration: Int?
    let signCookie: String?
    /// `"hevc"`/`"h264"`, when the upload names it. Optional upstream.
    let codecName: String?
}

struct ResourcePage: Decodable {
    let list: [ResourceItem]?
    let pager: Pager?

    struct Pager: Decodable {
        let hasMore: Bool?
    }
}

struct ResourceItem: Decodable {
    let se: Int
    let ep: Int
    let duration: Int
    let resolution: Int
    let size: String?
    let resourceLink: String?
    let resourceId: String?
    /// `"hevc"`/`"h264"`, when the listing names it. Optional upstream.
    let codecName: String?
}

// MARK: - Home rails

struct HomeRails: Decodable {
    let items: [HomeRow]?
    let list: [HomeRow]?
}

struct HomeRow: Decodable {
    let title: String?
    let name: String?
    let customData: HomeContainer?
    let banner: HomeContainer?
    let rankingListData: HomeContainer?
    let list: [HomeSubject]?
    let items: [HomeSubject]?
    let subjects: [HomeSubject]?
    let movieList: [HomeSubject]?

    struct HomeContainer: Decodable {
        let items: [HomeSubject]?
        let banners: [HomeSubject]?

        /// A rankingListData entry nests its subjects under "subjects" instead
        /// of being one itself (Go rankSubjects).
        var rankedSubjects: [Subject] {
            var out: [Subject] = []
            for entry in items ?? [] {
                if let nested = entry.subject {
                    out.append(nested.subject)
                } else if let direct = entry.direct {
                    out.append(direct.subject)
                }
            }
            return out
        }

        var plainSubjects: [Subject] {
            var out: [Subject] = []
            for source in [items, banners] {
                for entry in source ?? [] where entry.isSubject {
                    out.append(entry.resolvedSubject)
                }
            }
            return out
        }
    }

    var rowTitle: String {
        firstNonEmpty(title, name)
    }

    /// Collects a row's subjects from every container the gateway uses. postData
    /// / playListData / liveList are deliberately ignored: they carry UGC posts
    /// and live-room entries keyed by ids Detail cannot answer (Go subjects()).
    var allSubjects: [Subject] {
        var out: [Subject] = []
        out.append(contentsOf: customData?.plainSubjects ?? [])
        out.append(contentsOf: banner?.plainSubjects ?? [])
        out.append(contentsOf: rankingListData?.rankedSubjects ?? [])
        for source in [list, items, subjects, movieList] {
            for entry in source ?? [] where entry.isSubject {
                out.append(entry.resolvedSubject)
            }
        }
        return out
    }
}

/// One layout entry: either a wrapper ({"subject":{…}}) or the entry itself.
struct HomeSubject: Decodable {
    let subject: WireSubject?
    let direct: WireSubject?

    private enum CodingKeys: String, CodingKey {
        case subject
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subject = try container.decodeIfPresent(WireSubject.self, forKey: .subject)
        direct = try? WireSubject(from: decoder)
    }

    var isSubject: Bool {
        let value = subject ?? direct
        return value?.subjectId?.isEmpty == false
    }

    var resolved: WireSubject? {
        subject ?? direct
    }

    /// Named apart from the stored `subject` wrapper: a computed property may
    /// not share a name with a stored property of a different type.
    var resolvedSubject: Subject {
        (subject ?? direct)?.subject ?? Subject(id: "", title: "")
    }
}

extension HomeSubject {
    /// The mixed containers (customData, banner) reuse the card shape for
    /// category teasers, cast tiles and UGC posts; those all lack a subjectType
    /// and hand out ids Detail cannot answer (Go tabSubject, cards=true).
    static func cards(_ raws: [HomeSubject]?) -> [Subject] {
        (raws ?? []).filter { $0.isSubject }.map(\.resolvedSubject)
    }
}
