import Testing
import Foundation
@testable import CinemacoreCore

/// Regression cover for the wire mismatches found when the Swift models were
/// first decoded against contract-shaped JSON. Swift's synthesised
/// `init(from:)` ignores property defaults, so each of these payloads used to
/// fail with `keyNotFound`; the tolerant decoders in `Models+Decoding.swift`
/// are what make them pass.
@Suite("Wire decoding")
struct DecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("a Subject with only the required keys decodes with defaults")
    func minimalSubject() throws {
        let subject = try decode(Subject.self, #"{"id":"7","title":"Heat"}"#)
        #expect(subject.id == "7")
        #expect(subject.title == "Heat")
        #expect(subject.genres == [])
        #expect(subject.dubs == [])
        #expect(subject.seasonCount == 1)
        #expect(subject.cast == [])
        #expect(subject.resourceDetectors == [])
        #expect(subject.poster == nil)
        #expect(subject.rating == nil)
        #expect(subject.durationMinutes == nil)
    }

    @Test("a Subject without cast or resourceDetectors still decodes")
    func subjectWithoutOptionalCollections() throws {
        // This exact shape failed before the tolerant decoders existed.
        let subject = try decode(Subject.self, """
        {"id":"7","title":"Heat","seasonCount":1}
        """)
        #expect(subject.cast == [])
        #expect(subject.resourceDetectors == [])
    }

    @Test("Episode reads the gateway's subjectId spelling")
    func episodeSubjectId() throws {
        let episode = try decode(Episode.self, #"{"subjectId":"42","season":2,"number":5}"#)
        #expect(episode.subjectID == "42")
        #expect(episode.season == 2)
        #expect(episode.number == 5)
        // Both are absent from the payload, so the defaults must hold.
        #expect(episode.title == "")
        #expect(episode.duration == "")
        #expect(episode.still == nil)
        #expect(episode.displayTitle == "Episode 5")
    }

    @Test("Episode encodes back under the gateway's key")
    func episodeEncodesWireKey() throws {
        let episode = Episode(subjectID: "42", season: 1, number: 3, title: "Pilot")
        let data = try JSONEncoder().encode(episode)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["subjectId"] as? String == "42")
        #expect(object["subjectID"] == nil)
        #expect(object["number"] as? Int == 3)
    }

    @Test("CastMember tolerates a missing role")
    func castMemberWithoutRole() throws {
        let member = try decode(CastMember.self, #"{"name":"Chalamet"}"#)
        #expect(member.name == "Chalamet")
        #expect(member.role == "")
        #expect(member.avatar == nil)
    }

    @Test("SubtitleTrack defaults its format to vtt")
    func subtitleWithoutFormat() throws {
        let track = try decode(SubtitleTrack.self, #"{"language":"English","url":"u.vtt"}"#)
        #expect(track.format == "vtt")
        #expect(!track.needsConversion)
    }

    @Test("ResourceDetector tolerates a missing name")
    func resourceDetectorWithoutName() throws {
        let detector = try decode(ResourceDetector.self, #"{"resourceId":"dub_hindi"}"#)
        #expect(detector.resourceId == "dub_hindi")
        #expect(detector.name == "")
        #expect(detector.isDub)
    }

    @Test("Season and Page tolerate empty collections")
    func emptyCollections() throws {
        let season = try decode(Season.self, #"{"number":3}"#)
        #expect(season.number == 3)
        #expect(season.episodes == [])
        #expect(season.title == "Season 3")

        let page = try decode(Page.self, "{}")
        #expect(page.sections == [])
        #expect(page.isEmpty)
    }

    @Test("PlayInfo tolerates an empty payload")
    func emptyPlayInfo() throws {
        let info = try decode(PlayInfo.self, "{}")
        #expect(info.isEmpty)
        #expect(info.preferredStream == nil)
        #expect(info.subtitles == [])
    }

    @Test("a nested detail payload decodes end to end")
    func nestedDetail() throws {
        let json = """
        {
          "subject": {"id":"9","title":"Severance","kind":"2","seasonCount":2,
                      "cast":[{"name":"Adam Scott"}]},
          "seasons": [
            {"number":1,"episodes":[
              {"subjectId":"9","season":1,"number":1,"title":"Good News About Hell",
               "duration":"57 min"}
            ]}
          ]
        }
        """
        let detail = try decode(SubjectDetail.self, json)
        #expect(detail.subject.isSeries)
        #expect(detail.subject.cast.first?.name == "Adam Scott")
        #expect(detail.seasons.count == 1)
        #expect(detail.allEpisodes.first?.displayTitle == "Good News About Hell")
    }

    @Test("a Section tolerates a missing items array")
    func sectionWithoutItems() throws {
        let section = try decode(Section.self, #"{"title":"Trending Now"}"#)
        #expect(section.title == "Trending Now")
        #expect(section.items == [])
    }

    @Test("a full Subject still round-trips through encode and decode")
    func roundTrip() throws {
        let subject = Subject(
            id: "42", title: "Dune", poster: "https://x/p.jpg", year: 2021,
            rating: 8.0, kind: "1", synopsis: "Spice.", genres: ["Sci-Fi"],
            dubs: ["English"], durationMinutes: 155, seasonCount: 1,
            cast: [CastMember(name: "Chalamet", role: "Paul", avatar: nil)],
            resourceDetectors: [ResourceDetector(resourceId: "res_1", name: "English")]
        )
        let data = try JSONEncoder().encode(subject)
        #expect(try JSONDecoder().decode(Subject.self, from: data) == subject)
    }
}
