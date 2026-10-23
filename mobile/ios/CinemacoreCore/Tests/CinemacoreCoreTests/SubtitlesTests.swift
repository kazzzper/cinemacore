import Testing
import Foundation
@testable import CinemacoreCore

@Suite("SubtitleConverter")
struct SubtitleConverterTests {

    @Test("a basic SRT document becomes WebVTT")
    func basicConversion() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello there

        2
        00:00:05,500 --> 00:00:07,250
        General Kenobi
        """
        let vtt = SubtitleConverter.webVTT(fromSRT: srt)
        #expect(vtt == """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Hello there

        00:00:05.500 --> 00:00:07.250
        General Kenobi
        """ + "\n")
    }

    @Test("the file always opens with the WebVTT signature")
    func signature() {
        #expect(SubtitleConverter.webVTT(fromSRT: "").hasPrefix("WEBVTT"))
        #expect(SubtitleConverter.webVTT(fromSRT: "garbage").hasPrefix("WEBVTT"))
    }

    @Test("an empty or unusable document still yields a valid empty track")
    func emptyDocument() {
        #expect(SubtitleConverter.webVTT(fromSRT: "") == "WEBVTT\n")
        #expect(SubtitleConverter.webVTT(fromSRT: "\n\n\n") == "WEBVTT\n")
    }

    @Test("CRLF and a UTF-8 BOM are tolerated")
    func windowsLineEndings() {
        let srt = "\u{FEFF}1\r\n00:00:02,000 --> 00:00:03,000\r\nHi\r\n"
        let vtt = SubtitleConverter.webVTT(fromSRT: srt)
        #expect(vtt.contains("00:00:02.000 --> 00:00:03.000"))
        #expect(vtt.contains("Hi"))
        #expect(!vtt.contains(","))
        #expect(!vtt.contains("\r"))
    }

    @Test("cues without an index line are still converted")
    func missingIndex() {
        let vtt = SubtitleConverter.webVTT(fromSRT: "00:00:01,000 --> 00:00:02,000\nNo index")
        #expect(vtt.contains("00:00:01.000 --> 00:00:02.000"))
        #expect(vtt.contains("No index"))
    }

    @Test("index lines are dropped because WebVTT does not need them")
    func indexDropped() {
        let vtt = SubtitleConverter.webVTT(fromSRT: "42\n00:00:01,000 --> 00:00:02,000\nText")
        #expect(!vtt.contains("\n42\n"))
    }

    @Test("multi-line cue text is preserved")
    func multiLineCue() {
        let vtt = SubtitleConverter.webVTT(
            fromSRT: "1\n00:00:01,000 --> 00:00:02,000\nFirst line\nSecond line"
        )
        #expect(vtt.contains("First line\nSecond line"))
    }

    @Test("a malformed timeline drops the cue rather than emitting broken WebVTT")
    func malformedTimeline() {
        let vtt = SubtitleConverter.webVTT(
            fromSRT: "1\nnot-a-timestamp\nText\n\n2\n00:00:01,000 --> 00:00:02,000\nGood"
        )
        #expect(!vtt.contains("not-a-timestamp"))
        #expect(!vtt.contains("Text"))
        #expect(vtt.contains("Good"))
    }

    @Test("timestamps without hours are normalised")
    func shortTimestamps() {
        #expect(SubtitleConverter.webVTTTimestamp("01:02,500") == "00:01:02.500")
        #expect(SubtitleConverter.webVTTTimestamp("00:01:02,500") == "00:01:02.500")
        #expect(SubtitleConverter.webVTTTimestamp("") == nil)
        #expect(SubtitleConverter.webVTTTimestamp("nope") == nil)
    }

    @Test("a timeline keeps trailing position settings")
    func timelineSettings() {
        let converted = SubtitleConverter.convertTimeline(
            "00:00:01,000 --> 00:00:02,000 align:start position:10%"
        )
        #expect(converted == "00:00:01.000 --> 00:00:02.000 align:start position:10%")
    }

    @Test("cue text escaping protects WebVTT markup")
    func escaping()  {
        #expect(SubtitleConverter.escapeCueText("Tom & Jerry") == "Tom &amp; Jerry")
        #expect(SubtitleConverter.escapeCueText("<b>bold</b>") == "&lt;b>bold&lt;/b>")
        #expect(SubtitleConverter.escapeCueText("plain") == "plain")
    }
}

@Suite("MediaRequest")
struct MediaRequestTests {
    @Test("media requests carry only the user agent and an optional cookie")
    func headers() {
        let bare = MediaRequest.headers()
        #expect(bare["User-Agent"] == "MovieBoxPro/16.2.1 (Android 14; com.community.mbox.in)")
        #expect(bare["Cookie"] == nil)
        #expect(bare.count == 1)

        let withCookie = MediaRequest.headers(cookie: "signCookie=abc")
        #expect(withCookie["Cookie"] == "signCookie=abc")

        // An empty cookie must not produce an empty header.
        #expect(MediaRequest.headers(cookie: "")["Cookie"] == nil)
    }

    @Test("no signing header ever reaches a media request")
    func noSigningHeaders() {
        let headers = MediaRequest.headers(cookie: "c")
        #expect(headers["x-tr-signature"] == nil)
        #expect(headers["X-Client-Token"] == nil)
        #expect(headers["Authorization"] == nil)
    }
}

@Suite("SubtitleTracks merging")
struct SubtitleTracksTests {
    private func track(
        _ language: String,
        _ url: String,
        _ provider: SubtitleSource = .provider,
        source: String? = nil
    ) -> SubtitleTrack {
        SubtitleTrack(language: language, url: url, format: "srt", source: source, provider: provider)
    }

    /// The provider payload and the community lookup answer independently. The
    /// community one lands second here — and must not take the list away from
    /// the viewer, nor duplicate a track both sources happen to name.
    @Test("a late second source is appended, never substituted")
    func lateSourceIsAppended() {
        let provider = [track("English", "https://cdn.test/en.srt")]
        let community = [
            track("English", "https://subs.test/a.srt", .community, source: "Release A"),
            track("English", "https://subs.test/b.srt", .community, source: "Release B"),
        ]

        let merged = SubtitleTracks.merging(provider, with: community)

        #expect(merged.count == 3)
        #expect(merged.first?.url == "https://cdn.test/en.srt")
        #expect(merged.map(\.provider) == [.provider, .community, .community])
    }

    @Test("the list already on screen keeps its order")
    func existingOrderWins() {
        let existing = [
            track("English", "https://subs.test/b.srt", .community, source: "B"),
            track("English", "https://subs.test/a.srt", .community, source: "A"),
        ]
        let incoming = [track("English", "https://cdn.test/en.srt")]
        let merged = SubtitleTracks.merging(existing, with: incoming)

        #expect(merged.prefix(2).map(\.url) == existing.map(\.url))
    }

    @Test("a track both sources list appears once")
    func duplicatesCollapse() {
        let shared = "https://cdn.test/en.srt"
        let merged = SubtitleTracks.merging(
            [track("English", shared)],
            with: [track("English", shared), track("English", "https://x/other.srt")]
        )
        #expect(merged.count == 2)
        #expect(merged.filter { $0.url == shared }.count == 1)
    }

    @Test("merging an empty side changes nothing")
    func emptySidesAreNeutral() {
        let tracks = [track("English", "https://x/a.srt")]
        #expect(SubtitleTracks.merging(tracks, with: []) == tracks)
        #expect(SubtitleTracks.merging([], with: tracks) == tracks)
        #expect(SubtitleTracks.merging([], with: []).isEmpty)
    }

    @Test("a viewer who has chosen keeps that choice")
    func chosenTrackSurvives() {
        let chosen = track("English", "https://subs.test/pick.srt", .community, source: "Pick")
        let late = [track("English", "https://cdn.test/en.srt")]

        let result = SubtitleTracks.defaultTrack(
            in: late,
            isOriginalAudio: true,
            chosen: chosen
        )
        #expect(result == chosen)
    }

    @Test("with no choice the first track is the default")
    func defaultIsFirst() {
        let tracks = [
            track("English", "https://cdn.test/en.srt"),
            track("English", "https://subs.test/a.srt", .community),
        ]
        #expect(SubtitleTracks.defaultTrack(in: tracks, isOriginalAudio: true, chosen: nil)
            == tracks.first)
    }

    /// A dub already speaks the requested language, so an original-language
    /// caption is not a default there — but it stays in the list to be picked.
    @Test("a dub starts with captions off")
    func dubStartsOff() {
        let tracks = [track("English", "https://cdn.test/en.srt")]
        #expect(SubtitleTracks.defaultTrack(in: tracks, isOriginalAudio: false, chosen: nil) == nil)
    }
}

@Suite("SubtitleCache")
struct SubtitleCacheTests {
    private func makeCache() -> (SubtitleCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cinemacore-subtests-\(UUID().uuidString)")
        return (SubtitleCache(directory: directory), directory)
    }

    @Test("an SRT track is written as converted WebVTT")
    func convertsSRT() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = SubtitleTrack(language: "English", url: "https://x/a.srt", format: "srt")
        let url = try cache.prepare(track: track, contents: "1\n00:00:01,000 --> 00:00:02,000\nHi")
        #expect(url.pathExtension == "vtt")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.hasPrefix("WEBVTT"))
        #expect(written.contains("00:00:01.000 --> 00:00:02.000"))
    }

    @Test("a VTT track is written through unchanged")
    func passesVTTThrough() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = SubtitleTrack(language: "Hindi", url: "https://x/a.vtt", format: "vtt")
        let original = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nNamaste"
        let url = try cache.prepare(track: track, contents: original)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test("a prepared track is reused on the second call")
    func reusesExistingFile() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = SubtitleTrack(language: "English", url: "https://x/a.srt", format: "srt")
        let first = try cache.prepare(track: track, contents: "1\n00:00:01,000 --> 00:00:02,000\nOne")
        let second = try cache.prepare(track: track, contents: "1\n00:00:09,000 --> 00:00:10,000\nTwo")

        #expect(first == second)
        // The cached body wins, proving the file was not rewritten.
        #expect(try String(contentsOf: second, encoding: .utf8).contains("One"))
    }

    @Test("the file name is stable and filesystem-safe")
    func stableNames() {
        let (cache, _) = makeCache()
        let track = SubtitleTrack(language: "en", url: "https://x/a/b:c.srt", format: "srt")
        #expect(cache.fileURL(for: track) == cache.fileURL(for: track))
        #expect(!cache.fileURL(for: track).lastPathComponent.contains("/"))
        #expect(!cache.fileURL(for: track).lastPathComponent.contains(":"))
    }

    /// The live provider URL is 642 characters; used verbatim it exceeded the
    /// filesystem's 255-byte limit and `prepare` failed with "File name too
    /// long".
    private static let longURL = "https://cacdn.hakunaymatata.com/subtitle/"
        + "1e74b02332afd851f6c2fc01a99377b6.srt?Policy="
        + String(repeating: "signed-policy-segment-", count: 24)
        + "&Signature=" + String(repeating: "x", count: 180)
        + "&Key-Pair-Id=KMHN1LQ1HEUPL"

    @Test("a long signed URL still yields a short, separator-free file name")
    func longURLNameIsBounded() {
        let (cache, _) = makeCache()
        let name = cache.fileURL(
            for: SubtitleTrack(language: "English", url: Self.longURL, format: "srt")
        ).lastPathComponent

        #expect(name.count <= 120)
        #expect(!name.contains("/"))
        #expect(!name.contains("\\"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".vtt"))
    }

    @Test("different URLs in the same language do not collide")
    func sameLanguageDifferentURLs() {
        let (cache, _) = makeCache()
        let first = SubtitleTrack(language: "English", url: "https://x/a.srt", format: "srt")
        let second = SubtitleTrack(
            language: "English",
            url: "https://x/a.srt?Policy=one&Signature=two",
            format: "srt"
        )
        #expect(cache.fileURL(for: first) != cache.fileURL(for: second))
    }

    @Test("the same track always maps to the same path")
    func stablePath() {
        let (cache, _) = makeCache()
        for language in ["English", "Español (Latinoamérica)", "日本語", "English/Sub:1"] {
            let track = SubtitleTrack(language: language, url: Self.longURL, format: "srt")
            let path = cache.fileURL(for: track)
            #expect(path == cache.fileURL(for: track))
            #expect(!path.lastPathComponent.contains("/"))
            #expect(!path.lastPathComponent.contains(":"))
            #expect(path.lastPathComponent.count <= 120)
        }
    }

    @Test("prepare writes a readable WebVTT file for a long URL")
    func longURLSRTPrepares() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = SubtitleTrack(language: "English", url: Self.longURL, format: "srt")
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n"
        let url = try cache.prepare(track: track, contents: srt)

        #expect(url == cache.fileURL(for: track))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.hasPrefix("WEBVTT"))
        #expect(written.contains("00:00:01.000 --> 00:00:02.000"))
        #expect(written.contains("Hello"))
    }

    @Test("an empty or malformed cache file is rewritten")
    func repairsBrokenCache() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = SubtitleTrack(language: "English", url: "https://x/a.srt", format: "srt")
        let destination = cache.fileURL(for: track)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for broken in ["", "not a subtitle file"] {
            try broken.write(to: destination, atomically: true, encoding: .utf8)
            let url = try cache.prepare(track: track, contents: "1\n00:00:01,000 --> 00:00:02,000\nHi")
            #expect(url == destination)
            #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("WEBVTT"))
        }
    }

    @Test("a cache that cannot be created falls back to a temporary file")
    func writeFailureFallsBack() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A regular file where the cache directory should be makes every write
        // to the cache fail.
        #expect(FileManager.default.createFile(atPath: directory.path, contents: Data()))
        let track = SubtitleTrack(language: "English", url: Self.longURL, format: "srt")
        let url = try cache.prepare(track: track, contents: "1\n00:00:01,000 --> 00:00:02,000\nFallback")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url != cache.fileURL(for: track))
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.hasPrefix("WEBVTT"))
        #expect(written.contains("Fallback"))
    }

    /// A CRLF SubRip document with the shape the provider actually serves,
    /// carried through conversion, caching and parsing in one pass.
    private static let providerSRT = [
        "1",
        "00:00:47,220 --> 00:00:51,920",
        "A beginning",
        "is a very delicate time.",
        "",
        "2",
        "00:00:51,970 --> 00:00:57,220",
        "Know then, that it is",
        "the year 10,191.",
        "",
        "3",
        "00:00:57,300 --> 00:01:02,170",
        "The known universe is ruled by the",
        "Padishah Emperor Shaddam the Fourth,",
        "",
    ].joined(separator: "\r\n")

    @Test("a provider SRT becomes a document with active cues at known times")
    func endToEndCRLFFixture() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let track = SubtitleTrack(language: "English", url: Self.longURL, format: "srt")
        let url = try cache.prepare(track: track, contents: Self.providerSRT)
        let webVTT = try String(contentsOf: url, encoding: .utf8)

        #expect(webVTT.contains("00:00:47.220 --> 00:00:51.920"))
        #expect(!webVTT.contains("\r"))

        let document = SubtitleDocument(webVTT: webVTT)
        #expect(document.activeCue(at: 0) == nil)
        #expect(document.activeCue(at: 48)?.text == "A beginning\nis a very delicate time.")
        #expect(document.activeCue(at: 51.95) == nil)
        #expect(document.activeCue(at: 52.5)?.text == "Know then, that it is\nthe year 10,191.")
        #expect(document.activeCue(at: 60)?.text.contains("Padishah Emperor") == true)
        #expect(document.activeCue(at: 63) == nil)
    }
}
