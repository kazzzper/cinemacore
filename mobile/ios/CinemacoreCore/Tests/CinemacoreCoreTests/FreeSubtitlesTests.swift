import Foundation
import Testing
@testable import CinemacoreCore

/// The keyless caption fallback, exercised on the two shapes it has to read:
/// Cinemeta's id lookup and the addon's subtitle listing. Both payloads are
/// trimmed copies of live responses.
@Suite("FreeSubtitles")
struct FreeSubtitlesTests {
    private let cinemeta = Data(#"""
    {"query":"inception","metas":[
      {"id":"tt1375666","imdb_id":"tt1375666","type":"movie","name":"Inception","releaseInfo":"2010"},
      {"id":"tt1790736","imdb_id":"tt1790736","type":"movie","name":"Inception: The Cobol Job","releaseInfo":"2010"}
    ]}
    """#.utf8)

    private let addon = Data(#"""
    {"subtitles":[
      {"id":"1","url":"https://subs.test/hi/1","lang":"hin"},
      {"id":"2","url":"https://subs.test/en/1","lang":"eng"},
      {"id":"3","url":"https://subs.test/en/1","lang":"eng"},
      {"id":"4","url":"https://subs.test/pt/1","lang":"pob"},
      {"id":"5","url":"https://subs.test/es/1","lang":"spa"}
    ]}
    """#.utf8)

    @Test("the year picks between a title and its same-year tie")
    func imdbLookup() {
        #expect(FreeSubtitles.imdbID(fromCinemeta: cinemeta, year: 2010) == "tt1375666")
        #expect(FreeSubtitles.imdbID(fromCinemeta: cinemeta, year: nil) == "tt1375666")
    }

    @Test("an unparsable or empty lookup has no id")
    func imdbLookupFailures() {
        #expect(FreeSubtitles.imdbID(fromCinemeta: Data("{}".utf8), year: 2010) == nil)
        #expect(FreeSubtitles.imdbID(fromCinemeta: Data("not json".utf8), year: nil) == nil)
        // A numeric TMDB id is not an imdb id; the addon would answer empty.
        let numeric = Data(#"{"metas":[{"id":"27205"}]}"#.utf8)
        #expect(FreeSubtitles.imdbID(fromCinemeta: numeric, year: nil) == nil)
    }

    @Test("the viewer's language leads, then English, then the rest")
    func ranking() {
        let hindi = FreeSubtitles.tracks(
            fromAddon: addon,
            request: FreeSubtitleRequest(title: "Inception", language: "hi"),
            limit: 10
        )
        #expect(hindi.map(\.language) == ["Hindi", "English", "Portuguese", "Spanish"])

        let french = FreeSubtitles.tracks(
            fromAddon: addon,
            request: FreeSubtitleRequest(title: "Inception", language: "fr"),
            limit: 10
        )
        #expect(french.map(\.language) == ["English", "Hindi", "Portuguese", "Spanish"])
    }

    @Test("one file listed under several releases appears once")
    func duplicatesCollapse() {
        let tracks = FreeSubtitles.tracks(
            fromAddon: addon,
            request: FreeSubtitleRequest(title: "Inception", language: "en"),
            limit: 10
        )
        #expect(tracks.map(\.url).count == Set(tracks.map(\.url)).count)
        #expect(tracks.count == 4)
    }

    @Test("the addon's tracks are SRT and capped")
    func format() {
        let tracks = FreeSubtitles.tracks(
            fromAddon: addon,
            request: FreeSubtitleRequest(title: "Inception", language: "en"),
            limit: 2
        )
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.needsConversion })
        #expect(tracks.allSatisfy { $0.format == "srt" })
        #expect(tracks.allSatisfy { $0.provider == .community })
        // A code Foundation does not know is still shown rather than dropped.
        #expect(FreeSubtitles.tracks(
            fromAddon: addon,
            request: FreeSubtitleRequest(title: "Inception", language: "pt"),
            limit: 10
        ).contains { $0.language == "Portuguese" })
    }

    @Test("a broken listing yields nothing instead of throwing")
    func brokenListing() {
        let request = FreeSubtitleRequest(title: "Inception", language: "en")
        #expect(FreeSubtitles.tracks(fromAddon: Data("<html>".utf8), request: request, limit: 5).isEmpty)
        #expect(FreeSubtitles.tracks(
            fromAddon: Data(#"{"subtitles":[]}"#.utf8),
            request: request,
            limit: 5
        ).isEmpty)
    }

    @Test("ISO-639-2 and ISO-639-1 spellings match each other")
    func languageMatching() {
        #expect(FreeSubtitles.matches("eng", "en"))
        #expect(FreeSubtitles.matches("en", "eng"))
        #expect(FreeSubtitles.matches("hin", "hi"))
        #expect(!FreeSubtitles.matches("eng", "hi"))
        #expect(!FreeSubtitles.matches("e", "en"))
    }

    @Test("URLs address the movie and series shapes the addon documents")
    func urls() throws {
        let movie = FreeSubtitleRequest(title: "Inception", year: 2010)
        let movieURL = try #require(FreeSubtitles.addonURL(imdbID: "tt1375666", request: movie))
        #expect(movieURL.absoluteString == "https://opensubtitles-v3.strem.io/subtitles/movie/tt1375666.json")

        let episode = FreeSubtitleRequest(title: "Breaking Bad", isSeries: true, season: 2, episode: 7)
        let seriesURL = try #require(FreeSubtitles.addonURL(imdbID: "tt0903747", request: episode))
        #expect(seriesURL.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:2:7.json")

        // A series with no season yet still asks for episode one rather than
        // sending an empty path component.
        let bare = FreeSubtitleRequest(title: "Breaking Bad", isSeries: true)
        #expect(FreeSubtitles.addonURL(imdbID: "tt0903747", request: bare)?.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:1:1.json")
    }

    @Test("a title with spaces and punctuation survives the path")
    func titleEncoding() throws {
        let request = FreeSubtitleRequest(title: "El Camino: A Breaking Bad Movie / Part 2")
        let url = try #require(FreeSubtitles.cinemetaURL(request))
        #expect(!url.absoluteString.contains(" "))
        #expect(url.absoluteString.hasPrefix("https://v3-cinemeta.strem.io/catalog/movie/top/search="))
        // The colon and slash that would re-parse the path are escaped.
        #expect(!url.absoluteString.dropFirst("https://v3-cinemeta.strem.io".count).contains("/Part"))
    }
}

/// The addon answers a series lookup with a fuzzy match, and the entries it
/// returns carry the release/file they came from. These cover the two things the
/// player does with that: address the right episode, and label each track so two
/// English files are distinguishable.
@Suite("FreeSubtitles episode keying")
struct FreeSubtitleEpisodeTests {

    /// Trimmed from a live `tt0944947:1:1` response. It contains the real
    /// defect: an S08E02 file and a file from an unrelated series are listed
    /// under season 1, episode 1.
    private let listing = Data(#"""
    {"subtitles":[
      {"url":"https://subs.test/en/s01e01-hdtv","lang":"eng",
       "subtitleFileName":"Game.of.Thrones.S01E01.720p.HDTV.DD5.1.x264-EbP.srt",
       "movieReleaseName":"Game.of.Thrones.S01E01.720p.HDTV.DD5.1.x264-EbP",
       "releaseGroup":"EbP","releaseFormat":"HDTV","season":1,"episode":1},
      {"url":"https://subs.test/en/s08e02","lang":"eng",
       "subtitleFileName":"Game of Thrones S08E02 WEB x264-NogroupL.srt",
       "movieReleaseName":"Game of Thrones S08E02 WEB x264-NogroupL",
       "releaseGroup":"NogroupL","releaseFormat":"WEB-DL","season":1,"episode":1},
      {"url":"https://subs.test/en/bluray","lang":"eng",
       "subtitleFileName":"Game.of.Thrones.S01E01.720p.BluRay.X264-REWARD.eng.srt",
       "movieReleaseName":"Game.Of.Thrones.S01.720p.BluRay.x264-MIXED",
       "releaseGroup":"REWARD","releaseFormat":"BluRay","season":1,"episode":1},
      {"url":"https://subs.test/en/bare","lang":"eng","subtitleFileName":"S01E01.srt","season":1,"episode":1},
      {"url":"https://subs.test/en/unmarked","lang":"eng"}
    ]}
    """#.utf8)

    private func tracks(season: Int?, episode: Int?) -> [SubtitleTrack] {
        FreeSubtitles.tracks(
            fromAddon: listing,
            request: FreeSubtitleRequest(
                title: "Game of Thrones",
                isSeries: true,
                season: season,
                episode: episode,
                language: "en"
            ),
            limit: 10
        )
    }

    @Test("the requested season and episode reach the addon path")
    func urlCarriesTheRequestedEpisode() throws {
        let request = FreeSubtitleRequest(
            title: "Game of Thrones", isSeries: true, season: 3, episode: 9
        )
        let url = try #require(FreeSubtitles.addonURL(imdbID: "tt0944947", request: request))
        #expect(url.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:3:9.json")
    }

    /// The numbers are one-based on both sides: the gateway's `allEp` list is
    /// `1…maxEp` and the addon's path is one-based too, so episode 1 must not be
    /// requested as 0 and episode 9 must not become 8.
    @Test("an episode number is never shifted by one")
    func noOffByOne() throws {
        for number in 1...12 {
            let request = FreeSubtitleRequest(
                title: "Game of Thrones", isSeries: true, season: 2, episode: number
            )
            let url = try #require(FreeSubtitles.addonURL(imdbID: "tt0944947", request: request))
            #expect(url.absoluteString.hasSuffix(":2:\(number).json"))
            #expect(!url.absoluteString.hasSuffix(":2:\(number - 1).json"))
        }
    }

    @Test("a missing season or episode falls back to the first, never zero")
    func missingNumbersFallBackToOne() throws {
        let both = FreeSubtitleRequest(title: "Game of Thrones", isSeries: true)
        #expect(FreeSubtitles.addonURL(imdbID: "tt0944947", request: both)?.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:1:1.json")

        let noEpisode = FreeSubtitleRequest(title: "Game of Thrones", isSeries: true, season: 4)
        #expect(FreeSubtitles.addonURL(imdbID: "tt0944947", request: noEpisode)?.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:4:1.json")

        let noSeason = FreeSubtitleRequest(title: "Game of Thrones", isSeries: true, episode: 6)
        #expect(FreeSubtitles.addonURL(imdbID: "tt0944947", request: noSeason)?.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:1:6.json")

        // A player that reports 0 rather than nil must not send `:0:0`.
        let zeroed = FreeSubtitleRequest(
            title: "Game of Thrones", isSeries: true, season: 0, episode: 0
        )
        #expect(FreeSubtitles.addonURL(imdbID: "tt0944947", request: zeroed)?.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:1:1.json")
    }

    @Test("a film has no episode component in its path")
    func moviePathHasNoEpisode() throws {
        let request = FreeSubtitleRequest(title: "Inception", year: 2010, season: 1, episode: 1)
        #expect(FreeSubtitles.addonURL(imdbID: "tt1375666", request: request)?.absoluteString
            == "https://opensubtitles-v3.strem.io/subtitles/movie/tt1375666.json")
    }

    @Test("a file that names another episode is dropped")
    func foreignEpisodeIsDropped() {
        let urls = tracks(season: 1, episode: 1).map(\.url)
        #expect(!urls.contains("https://subs.test/en/s08e02"))
    }

    @Test("the same episode is kept whatever spelling the file uses")
    func requestedEpisodeIsKept() {
        let urls = tracks(season: 1, episode: 1).map(\.url)
        #expect(urls.contains("https://subs.test/en/s01e01-hdtv"))
        #expect(urls.contains("https://subs.test/en/bluray"))
    }

    @Test("an entry with no recognisable marker is kept, not silently lost")
    func unmarkedEntriesSurvive() {
        let urls = tracks(season: 1, episode: 1).map(\.url)
        #expect(urls.contains("https://subs.test/en/bare"))
        #expect(urls.contains("https://subs.test/en/unmarked"))
    }

    @Test("the marker reader understands the spellings files actually use")
    func markerSpellings() {
        func marker(_ name: String) -> String? {
            guard let found = FreeSubtitles.episodeMarker(in: [name]) else { return nil }
            return "\(found.season)x\(found.episode)"
        }
        #expect(marker("Game.of.Thrones.S01E01.720p.HDTV.srt") == "1x1")
        #expect(marker("game.of.thrones.s02e07.dvdrip.srt") == "2x7")
        #expect(marker("Game Of Thrones S1E01.srt") == "1x1")
        #expect(marker("GoT.S01.E01.Winter.srt") == "1x1")
        #expect(marker("Show_S03_E10.srt") == "3x10")
        #expect(marker("lycan-gots1e0.srt") == "1x0")
        #expect(marker("Breaking Bad Season 2 Episode 07.srt") == nil)
        #expect(marker("1x01.srt") == nil)
        #expect(marker("S01E01.srt") == "1x1")
    }

    @Test("two English releases are distinguishable in the picker")
    func labelsDisambiguate() throws {
        let english = tracks(season: 1, episode: 1).filter { $0.language == "English" }
        #expect(english.count >= 2)
        // Every row the picker draws must read differently from its siblings.
        #expect(Set(english.map(\.detail)).count == english.count)

        let bluray = try #require(english.first { $0.url == "https://subs.test/en/bluray" })
        #expect(bluray.detail.contains("BluRay") || bluray.detail.contains("MIXED"))
        #expect(bluray.detail.hasPrefix("Community"))
        #expect(bluray.source == "Game.Of.Thrones.S01.720p.BluRay.x264-MIXED")
    }

    @Test("an entry with no release name falls back to its group and format")
    func labelFallsBackToGroup() {
        let bare = Data(#"""
        {"subtitles":[
          {"url":"https://subs.test/a","lang":"eng","releaseGroup":"EbP","releaseFormat":"HDTV"},
          {"url":"https://subs.test/b","lang":"eng"}
        ]}
        """#.utf8)
        let found = FreeSubtitles.tracks(
            fromAddon: bare,
            request: FreeSubtitleRequest(title: "X", isSeries: true, season: 1, episode: 1),
            limit: 10
        )
        #expect(found.first { $0.url == "https://subs.test/a" }?.source == "EbP · HDTV")
        #expect(found.first { $0.url == "https://subs.test/b" }?.source == nil)
        // With no label at all the row still names its source rather than
        // rendering an empty detail line.
        #expect(found.first { $0.url == "https://subs.test/b" }?.detail == "Community")
    }
}
