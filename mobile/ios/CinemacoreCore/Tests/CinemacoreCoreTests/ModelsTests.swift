import Testing
import Foundation
@testable import CinemacoreCore

@Suite("Subject")
struct SubjectTests {
    @Test("a series is detected from kind or season count")
    func seriesDetection() {
        #expect(Subject(id: "1", title: "A", kind: "2").isSeries)
        #expect(Subject(id: "2", title: "B", kind: "tv").isSeries)
        #expect(Subject(id: "3", title: "C", seasonCount: 4).isSeries)
        #expect(!Subject(id: "4", title: "D", kind: "1", seasonCount: 1).isSeries)
    }

    @Test("the live gateway's kind vocabulary is honoured")
    func liveKindVocabulary() {
        // Live responses send "series" rather than the contract's "2", and a
        // one-season series is common — seasonCount alone would call it a movie.
        #expect(Subject(id: "1", title: "A", kind: "series", seasonCount: 1).isSeries)
        #expect(Subject(id: "2", title: "B", kind: "SERIES", seasonCount: 1).isSeries)
        #expect(!Subject(id: "3", title: "C", kind: "movie", seasonCount: 1).isSeries)
        #expect(!Subject(id: "4", title: "D", kind: "film", seasonCount: 1).isSeries)
        // An unrecognised kind still falls back to the season count.
        #expect(Subject(id: "5", title: "E", kind: "docu", seasonCount: 2).isSeries)
        #expect(!Subject(id: "6", title: "F", kind: "docu", seasonCount: 1).isSeries)
    }

    @Test("live quality labels carry no resolution suffix")
    func liveQualityLabels() {
        // Live streams are labelled "1080"/"720"/"480" — no trailing 'p'.
        let info = PlayInfo(streams: [
            StreamRendition(quality: "1080", url: "u"),
            StreamRendition(quality: "720", url: "u"),
            StreamRendition(quality: "480", url: "u"),
        ])
        #expect(info.rankedStreams.map(\.quality) == ["1080", "720", "480"])
        #expect(info.preferredStream?.quality == "1080")
    }

    @Test("duration renders hours and minutes without a zero-minute tail")
    func durationText() {
        #expect(Subject(id: "1", title: "A", durationMinutes: 128).durationText == "2h 8m")
        #expect(Subject(id: "2", title: "B", durationMinutes: 120).durationText == "2h")
        #expect(Subject(id: "3", title: "C", durationMinutes: 48).durationText == "48m")
        #expect(Subject(id: "4", title: "D").durationText == nil)
        #expect(Subject(id: "5", title: "E", durationMinutes: 0).durationText == nil)
    }

    @Test("rating and year hide unusable values")
    func ratingAndYear() {
        #expect(Subject(id: "1", title: "A", rating: 8.456).ratingText == "8.5")
        #expect(Subject(id: "2", title: "B", rating: 0).ratingText == nil)
        #expect(Subject(id: "3", title: "C", year: 2021).yearText == "2021")
        #expect(Subject(id: "4", title: "D", year: 0).yearText == nil)
    }

    @Test("metadata line omits empty parts and never leaves a dangling separator")
    func metadataLine() {
        let full = Subject(
            id: "1", title: "A", year: 2021, rating: 8.0,
            genres: ["Action", "Thriller"], durationMinutes: 120
        )
        #expect(full.metadataLine == "2021 · Action · 2h")

        let series = Subject(id: "2", title: "B", year: 2020, kind: "2", seasonCount: 3)
        #expect(series.metadataLine == "2020 · 3 Seasons")

        let oneSeason = Subject(id: "3", title: "C", kind: "2", seasonCount: 1)
        #expect(oneSeason.metadataLine == "1 Season")

        let bare = Subject(id: "4", title: "D")
        #expect(bare.metadataLine.isEmpty)
    }

    @Test("protocol-relative posters are upgraded to https")
    func posterURL() {
        #expect(
            Subject(id: "1", title: "A", poster: "//img.example/a.jpg").posterURL
                == URL(string: "https://img.example/a.jpg")
        )
        #expect(Subject(id: "2", title: "B", poster: "").posterURL == nil)
        #expect(Subject(id: "3", title: "C").posterURL == nil)
    }

    @Test("subject survives a JSON round trip")
    func codableRoundTrip() throws {
        let subject = Subject(
            id: "42", title: "Dune", poster: "https://x/p.jpg", year: 2021,
            rating: 8.0, kind: "1", synopsis: "Spice.", genres: ["Sci-Fi"],
            dubs: ["English", "Hindi"], durationMinutes: 155,
            cast: [CastMember(name: "Chalamet", role: "Paul", avatar: nil)]
        )
        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(Subject.self, from: data)
        #expect(decoded == subject)
    }

    @Test("subject decodes from the camelCase wire shape")
    func decodesWireShape() throws {
        let json = """
        {"id":"7","title":"Heat","poster":"https://x/h.jpg","year":1995,
         "rating":8.3,"kind":"1","genres":["Crime"],"dubs":["English"],
         "durationMinutes":170,"seasonCount":1,"cast":[]}
        """.data(using: .utf8)!
        let subject = try JSONDecoder().decode(Subject.self, from: json)
        #expect(subject.id == "7")
        #expect(subject.title == "Heat")
        #expect(subject.genres == ["Crime"])
        #expect(subject.durationMinutes == 170)
    }
}

@Suite("CastMember")
struct CastMemberTests {
    @Test("identity is the name so duplicates collapse in a Set")
    func identityIsName() {
        let a = CastMember(name: "Idris Elba", role: "Roland")
        let b = CastMember(name: "Idris Elba", role: "Different role")
        #expect(a.id == b.id)
    }

    @Test("avatar URLs are only produced when usable")
    func avatar() {
        #expect(CastMember(name: "A", avatar: "//x/a.jpg").avatarURL == URL(string: "https://x/a.jpg"))
        #expect(CastMember(name: "B").avatarURL == nil)
        #expect(CastMember(name: "C", avatar: "").avatarURL == nil)
    }
}

@Suite("Episode and Season")
struct EpisodeTests {
    @Test("an empty title falls back to the number")
    func displayTitle() {
        #expect(Episode(subjectID: "1", season: 1, number: 3).displayTitle == "Episode 3")
        #expect(
            Episode(subjectID: "1", season: 1, number: 3, title: "Pilot").displayTitle == "Pilot"
        )
    }

    /// The gateway sends a numeric runtime; the display string is the fallback,
    /// not the other way round.
    @Test("durationText prefers the provider's numeric duration")
    func durationText() {
        #expect(Episode(subjectID: "1", season: 1, number: 1, durationSeconds: 2880).durationText == "48m")
        #expect(Episode(subjectID: "1", season: 1, number: 1, durationSeconds: 3720).durationText == "1h 2m")
        #expect(Episode(subjectID: "1", season: 1, number: 1, durationSeconds: 3600).durationText == "1h")
        #expect(Episode(subjectID: "1", season: 1, number: 1, durationSeconds: 45).durationText == "45s")
        // A nonsense numeric value falls through to whatever the server labelled.
        #expect(Episode(subjectID: "1", season: 1, number: 1, duration: "57 min").durationText == "57 min")
        #expect(Episode(subjectID: "1", season: 1, number: 1).durationText == nil)
        // The numeric field wins when both are present.
        #expect(
            Episode(subjectID: "1", season: 1, number: 1, duration: "wrong", durationSeconds: 600)
                .durationText == "10m"
        )
    }

    @Test("identity is stable and unique per season/episode")
    func identity() {
        let a = Episode(subjectID: "9", season: 2, number: 4)
        let b = Episode(subjectID: "9", season: 2, number: 4)
        let c = Episode(subjectID: "9", season: 2, number: 5)
        #expect(a.id == b.id)
        #expect(a.id != c.id)
    }

    @Test("seasons flatten in order")
    func flatten() {
        let detail = SubjectDetail(
            subject: Subject(id: "1", title: "S", kind: "2", seasonCount: 2),
            seasons: [
                Season(number: 1, episodes: [
                    Episode(subjectID: "1", season: 1, number: 1),
                    Episode(subjectID: "1", season: 1, number: 2),
                ]),
                Season(number: 2, episodes: [
                    Episode(subjectID: "1", season: 2, number: 1),
                ]),
            ]
        )
        #expect(detail.allEpisodes.count == 3)
        #expect(detail.allEpisodes.first?.number == 1)
        #expect(detail.allEpisodes.last?.season == 2)
        #expect(detail.seasons[1].title == "Season 2")
    }
}

@Suite("PlayInfo")
struct PlayInfoTests {
    private func rendition(_ quality: String) -> StreamRendition {
        StreamRendition(quality: quality, url: "https://cdn/\(quality).m3u8")
    }

    @Test("renditions rank by resolution, not lexically")
    func resolutionRank() {
        #expect(rendition("1080p").resolutionRank == 1080)
        #expect(rendition("720p").resolutionRank == 720)
        #expect(rendition("4K").resolutionRank == 2160)
        #expect(rendition("auto").resolutionRank == 0)
    }

    @Test("the preferred stream is the highest quality")
    func preferredStream() {
        let info = PlayInfo(streams: [rendition("720p"), rendition("4K"), rendition("1080p")])
        #expect(info.preferredStream?.quality == "4K")
        #expect(info.rankedStreams.map(\.quality) == ["4K", "1080p", "720p"])
    }

    @Test("an explicit Auto rendition wins over higher labelled qualities")
    func autoIsPreferred() {
        // The provider returns every rendition against one URL and labels the
        // first "Auto"; that is the default the Android build plays.
        let info = PlayInfo(streams: [rendition("Auto"), rendition("1080p"), rendition("720p")])
        #expect(info.preferredStream?.quality == "Auto")
        #expect(info.rankedStreams.first?.quality == "1080p")
    }

    @Test("an empty payload reports empty and offers nothing")
    func empty() {
        let info = PlayInfo()
        #expect(info.isEmpty)
        #expect(info.preferredStream == nil)
    }

    @Test("srt tracks are flagged for conversion, vtt is not")
    func subtitleConversion() {
        #expect(SubtitleTrack(language: "en", url: "u", format: "srt").needsConversion)
        #expect(SubtitleTrack(language: "en", url: "u", format: "SRT").needsConversion)
        #expect(!SubtitleTrack(language: "en", url: "u", format: "vtt").needsConversion)
    }

    @Test("speed options include normal playback and stay ordered")
    func speedOptions() {
        #expect(PlayInfo.speedOptions.contains(1.0))
        #expect(PlayInfo.speedOptions == PlayInfo.speedOptions.sorted())
        #expect(PlayInfo.speedOptions.first == 0.5)
        #expect(PlayInfo.speedOptions.last == 2.0)
    }
}

@Suite("ResumePoint")
struct ResumePointTests {
    private func point(position: Double, duration: Double) -> ResumePoint {
        ResumePoint(
            subjectID: "1", title: "T", season: 2, episode: 4,
            positionSeconds: position, durationSeconds: duration
        )
    }

    @Test("progress is clamped to 0...1")
    func progressClamped() {
        #expect(point(position: 50, duration: 100).progress == 0.5)
        #expect(point(position: 500, duration: 100).progress == 1)
        #expect(point(position: -5, duration: 100).progress == 0)
        #expect(point(position: 50, duration: 0).progress == 0)
    }

    @Test("near-finished titles are not offered for resume")
    func resumable() {
        #expect(point(position: 50, duration: 100).isResumable)
        #expect(!point(position: 99, duration: 100).isResumable)
        #expect(!point(position: 2, duration: 100).isResumable)
    }

    @Test("labels are human readable")
    func labels() {
        #expect(point(position: 0, duration: 600).remainingText == "10m left")
        #expect(point(position: 600, duration: 600).remainingText == "Finished")
        #expect(point(position: 0, duration: 0).remainingText == nil)
        #expect(point(position: 0, duration: 10).episodeLabel == "S2 E4")
    }

    @Test("a movie resume point has no episode label")
    func movieLabel() {
        let movie = ResumePoint(
            subjectID: "1", title: "M", positionSeconds: 10, durationSeconds: 100
        )
        #expect(movie.episodeLabel == nil)
        #expect(movie.id == "1")
    }
}

@Suite("LoadState")
struct LoadStateTests {
    @Test("value is exposed for loaded and partial only")
    func value() {
        #expect(LoadState<Int>.loaded(5).value == 5)
        #expect(LoadState<Int>.partial(5, notice: "stale").value == 5)
        #expect(LoadState<Int>.loading.value == nil)
        #expect(LoadState<Int>.empty.value == nil)
        #expect(LoadState<Int>.failed(.offline).value == nil)
    }

    @Test("settled distinguishes in-flight from renderable")
    func settled() {
        #expect(!LoadState<Int>.idle.isSettled)
        #expect(!LoadState<Int>.loading.isSettled)
        #expect(LoadState<Int>.loaded(1).isSettled)
        #expect(LoadState<Int>.empty.isSettled)
        #expect(LoadState<Int>.failed(.offline).isSettled)
    }

    @Test("map preserves every non-value case")
    func map() {
        #expect(LoadState<Int>.loaded(2).map { $0 * 3 }.value == 6)
        #expect(LoadState<Int>.empty.map { $0 * 3 }.value == nil)

        switch LoadState<Int>.failed(.offline).map({ $0 * 3 }) {
        case .failed(let error):
            #expect(error == .offline)
        // Payloads are spelled out: a bare `.loaded` in a multi-pattern arm
        // makes Swift infer `Any` for the associated value.
        case .idle, .loading, .loaded(_), .empty, .partial(_, _), .locked:
            Issue.record("map should preserve failure")
        }
    }

    @Test("from collapses an empty collection to .empty")
    func fromCollection() {
        // The type is pinned on a local rather than inside `#expect`: the macro
        // re-writes its argument, and a generic static call there leaves the
        // payload type unresolved (`Any`, which is not `Sendable`).
        let empty: LoadState<[Int]> = .from([])
        let two: LoadState<[Int]> = .from([1, 2])
        #expect(empty.value == nil)
        #expect(two.value == [1, 2])

        let withNotice: LoadState<[Int]> = .from([1], notice: "stale")
        #expect(withNotice.value == [1])
        switch withNotice {
        case .partial(let values, let notice):
            #expect(values == [1])
            #expect(notice == "stale")
        case .idle, .loading, .loaded(_), .empty, .failed(_), .locked:
            Issue.record("a notice should produce .partial")
        }
    }
}

@Suite("CinemacoreError")
struct CinemacoreErrorTests {
    @Test("retryable classification")
    func retryable() {
        #expect(CinemacoreError.offline.isRetryable)
        #expect(CinemacoreError.timedOut.isRetryable)
        #expect(CinemacoreError.upstream("x").isRetryable)
        #expect(!CinemacoreError.cancelled.isRetryable)
        #expect(!CinemacoreError.http(status: 404, code: nil, message: nil).isRetryable)
        #expect(!CinemacoreError.locked(reason: "Region").isRetryable)
    }

    /// A download that has moved gigabytes must not be abandoned because the CDN
    /// hiccuped. Permanent statuses stay permanent; transient ones retry.
    @Test("HTTP status decides retryability, not the case alone")
    func httpRetryability() {
        for status in [408, 429, 500, 502, 503, 504] {
            #expect(
                CinemacoreError.http(status: status, code: nil, message: nil).isRetryable,
                "\(status) should be retryable"
            )
        }
        for status in [400, 401, 403, 404, 410, 451] {
            #expect(
                !CinemacoreError.http(status: status, code: nil, message: nil).isRetryable,
                "\(status) should not be retryable"
            )
        }
    }

    @Test("only a lockout asks for the gate")
    func gate() {
        #expect(CinemacoreError.locked(reason: "Region blocked").requiresGate)
        #expect(!CinemacoreError.offline.requiresGate)
    }

    @Test("http messages prefer the server's own text")
    func userMessage() {
        #expect(
            CinemacoreError.http(status: 500, code: "x", message: "Upstream exploded").userMessage
                == "Upstream exploded"
        )
        #expect(
            CinemacoreError.http(status: 500, code: nil, message: nil).userMessage
                == "The server returned an error (500)."
        )
        #expect(CinemacoreError.locked(reason: "Not available here").userMessage == "Not available here")
    }
}
