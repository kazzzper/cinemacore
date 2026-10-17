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
}
