import Testing
import Foundation
@testable import CinemacoreCore

@Suite("SubtitleDocument")
struct SubtitleDocumentTests {

    @Test("a bare WEBVTT header parses")
    func bareHeader() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Hello there
        """)

        #expect(document.cues.count == 1)
        #expect(document.cues.first?.start == 1)
        #expect(document.cues.first?.end == 4)
        #expect(document.cues.first?.text == "Hello there")
    }

    @Test("a titled header, CRLF, a BOM and a missing blank line are tolerated")
    func headerForms() {
        let titled = SubtitleDocument(webVTT: "\u{FEFF}WEBVTT - Cinemacore\r\n\r\n00:00:02.500 --> 00:00:03.000\r\nLine")
        #expect(titled.cues.count == 1)
        #expect(titled.cues.first?.start == 2.5)

        // No blank line between the signature and the first cue.
        let tight = SubtitleDocument(webVTT: "WEBVTT\n00:00:01.000 --> 00:00:02.000\nTight")
        #expect(tight.cues.count == 1)
        #expect(tight.cues.first?.text == "Tight")
    }

    @Test("header metadata does not become a cue")
    func headerMetadata() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT
        Kind: captions
        Language: en
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        00:00:01.000 --> 00:00:02.000
        Hello
        """)

        #expect(document.cues.count == 1)
        #expect(document.cues.first?.text == "Hello")
    }

    @Test("NOTE, STYLE and REGION blocks are skipped")
    func skipsNonCueBlocks() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        NOTE This comment
        spans two lines

        STYLE
        ::cue { color: white }

        REGION
        id:fred width:40%

        NOTE
        -->

        00:00:01.000 --> 00:00:02.000
        Real
        """)

        #expect(document.cues.count == 1)
        #expect(document.cues.first?.text == "Real")
    }

    @Test("a cue identifier line is ignored")
    func ignoresCueIdentifier() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        intro
        00:00:01.000 --> 00:00:02.000
        Text
        """)

        #expect(document.cues.count == 1)
        #expect(document.cues.first?.text == "Text")
    }

    @Test("MM:SS.mmm is accepted alongside HH:MM:SS.mmm")
    func shortForm() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        01:02.500 --> 01:04.000
        Short

        01:02:03.250 --> 01:02:04.000
        Long
        """)

        #expect(document.cues.count == 2)
        #expect(document.cues[0].start == 62.5)
        #expect(document.cues[0].end == 64)
        #expect(document.cues[1].start == 3723.25)
    }

    @Test("trailing cue settings are ignored")
    func cueSettings() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 --> 00:00:02.000 align:start position:10%
        Settings
        """)

        #expect(document.cues.first?.start == 1)
        #expect(document.cues.first?.end == 2)
        #expect(document.cues.first?.text == "Settings")
    }

    @Test("multi-line cue text is joined with newlines")
    func multiLineText() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        First line
        Second line
        """)

        #expect(document.cues.first?.text == "First line\nSecond line")
    }

    @Test("malformed cues are dropped, not emitted")
    func dropsMalformed() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 -->
        Missing end

        a block with no timeline at all

        00:00:03.000 --> 00:00:02.000
        Ends before it starts

        00:00:04.000 --> 00:0x:05.000
        Bad stamp

        00:00:06.000 --> 00:00:07.000

        00:00:10.000 --> 00:00:11.000
        Kept
        """)

        #expect(document.cues.count == 1)
        #expect(document.cues.first?.text == "Kept")
    }

    @Test("comma-separated timestamps are accepted")
    func commaTimestamps() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:08,000 --> 00:00:09,250
        SRT-ish
        """)

        #expect(document.cues.first?.start == 8)
        #expect(document.cues.first?.end == 9.25)
    }

    @Test("cues are sorted by start time")
    func sortsCues() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:05.000 --> 00:00:06.000
        Third

        00:00:01.000 --> 00:00:02.000
        First

        00:00:03.000 --> 00:00:04.000
        Second
        """)

        #expect(document.cues.map(\.text) == ["First", "Second", "Third"])
        #expect(document.cues.map(\.start) == [1, 3, 5])
    }

    @Test("activeCue includes the start and excludes the end")
    func boundaries() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Cue
        """)

        #expect(document.activeCue(at: 0.999) == nil)
        #expect(document.activeCue(at: 1)?.text == "Cue")
        #expect(document.activeCue(at: 3.999)?.text == "Cue")
        #expect(document.activeCue(at: 4) == nil)
        #expect(document.activeCue(at: 4.001) == nil)
    }

    @Test("activeCue is nil in the gaps and outside the document")
    func gaps() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        One

        00:00:05.000 --> 00:00:06.000
        Two
        """)

        #expect(document.activeCue(at: 0) == nil)
        #expect(document.activeCue(at: 1.5)?.text == "One")
        #expect(document.activeCue(at: 3) == nil)
        #expect(document.activeCue(at: 5)?.text == "Two")
        #expect(document.activeCue(at: 6) == nil)
        #expect(document.activeCue(at: 99) == nil)
    }

    @Test("an empty or unusable document has no cues")
    func emptyDocument() {
        for text in ["", "WEBVTT\n", "   \n\n", "not a subtitle at all"] {
            let document = SubtitleDocument(webVTT: text)
            #expect(document.cues.isEmpty)
            #expect(document.activeCue(at: 0) == nil)
        }
    }

    @Test("overlapping cues resolve to the one that starts last")
    func overlapping() {
        let document = SubtitleDocument(webVTT: """
        WEBVTT

        00:00:01.000 --> 00:00:20.000
        Long

        00:00:05.000 --> 00:00:06.000
        Short
        """)

        #expect(document.activeCue(at: 5.5)?.text == "Short")
        // Past the short cue, the long one is still running.
        #expect(document.activeCue(at: 10)?.text == "Long")
        #expect(document.activeCue(at: 20) == nil)
    }
}
