import Testing
import Foundation
@testable import CinemacoreCore

@Suite("PlaybackSourcePolicy")
struct PlaybackSourcePolicyTests {
    private func rendition(_ quality: String, _ url: String) -> StreamRendition {
        StreamRendition(quality: quality, url: url)
    }

    @Test("audio-only URL extensions are never video candidates")
    func audioExtensions() {
        let streams = [
            rendition("1080p", "https://cdn.test/movie.mp4"),
            rendition("128kbps", "https://cdn.test/movie.mp3"),
            rendition("Stereo", "https://cdn.test/movie.m4a"),
            rendition("Lossless", "https://cdn.test/movie.flac"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality) == ["1080p"])
        #expect(PlaybackSourcePolicy.videoOptions(streams).map(\.quality) == ["1080p"])
    }

    @Test("a soundtrack label is skipped even on a video extension")
    func audioLabels() {
        let streams = [
            rendition("Audio", "https://cdn.test/movie.mp4"),
            rendition("Soundtrack", "https://cdn.test/movie.mp4"),
            rendition("720p", "https://cdn.test/movie.m3u8"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality) == ["720p"])
    }

    @Test("an Audio Description rendition is video, not a soundtrack")
    func audioDescriptionIsVideo() {
        // The label starts with "Audio"; only the full-string match keeps a
        // described-video rendition from being dropped.
        let streams = [rendition("Audio Description", "https://cdn.test/described.m3u8")]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).count == 1)
    }

    @Test("a query string does not hide an audio extension")
    func audioExtensionWithQuery() {
        let streams = [rendition("128kbps", "https://cdn.test/movie.mp3?token=1")]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).isEmpty)
    }

    @Test("an unparseable URL is not a candidate")
    func invalidURL() {
        let streams = [rendition("1080p", "")]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).isEmpty)
        #expect(PlaybackSourcePolicy.preferred(streams) == nil)
    }

    @Test("Auto leads, then resolution descends, ties keep provider order")
    func ranking() {
        let streams = [
            rendition("720p", "https://cdn.test/720.m3u8"),
            rendition("Auto", "https://cdn.test/auto.m3u8"),
            rendition("4K", "https://cdn.test/4k.m3u8"),
            rendition("1080p", "https://cdn.test/1080.m3u8"),
            rendition("Trailer", "https://cdn.test/trailer.m3u8"),
            rendition("Extra", "https://cdn.test/extra.m3u8"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality)
            == ["Auto", "4K", "1080p", "720p", "Trailer", "Extra"])
        #expect(PlaybackSourcePolicy.preferred(streams)?.quality == "Auto")
    }

    @Test("quality options keep several labels that share one URL")
    func optionsKeepLabels() {
        // The provider's adaptive ladder names every rung against one URL; each
        // name is a different bit-rate hint, so the sheet must still show them.
        let streams = [
            rendition("Auto", "https://cdn.test/master.m3u8"),
            rendition("1080p", "https://cdn.test/master.m3u8"),
            rendition("720p", "https://cdn.test/master.m3u8"),
        ]
        #expect(PlaybackSourcePolicy.videoOptions(streams).map(\.quality)
            == ["Auto", "1080p", "720p"])
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality) == ["Auto"])
    }

    @Test("distinct files survive a shared label, duplicate URLs do not")
    func duplicateLabels() {
        let streams = [
            rendition("1080p", "https://cdn.test/a.m3u8"),
            rendition("1080p", "https://cdn.test/b.m3u8"),
            rendition("1080p", "https://cdn.test/a.m3u8"),
            rendition("720p", "https://cdn.test/c.m3u8"),
        ]
        // Two uploads can both be called "1080p"; the viewer must see both.
        #expect(PlaybackSourcePolicy.videoOptions(streams).map(\.url)
            == ["https://cdn.test/a.m3u8", "https://cdn.test/b.m3u8", "https://cdn.test/c.m3u8"])
        // Playback fallback still keys bytes, so the same URL is not retried.
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.url)
            == ["https://cdn.test/a.m3u8", "https://cdn.test/b.m3u8", "https://cdn.test/c.m3u8"])
    }

    @Test("fallback skips the failing URL and anything already tried")
    func fallback() {
        let streams = [
            rendition("1080p", "https://cdn.test/a.m3u8"),
            rendition("720p", "https://cdn.test/b.m3u8"),
            rendition("480p", "https://cdn.test/c.m3u8"),
        ]
        let failing = streams[0]
        #expect(PlaybackSourcePolicy.fallback(from: failing, in: streams)?.url
            == "https://cdn.test/b.m3u8")
        #expect(PlaybackSourcePolicy.fallback(
            from: failing,
            in: streams,
            excluding: ["https://cdn.test/b.m3u8"]
        )?.url == "https://cdn.test/c.m3u8")
        #expect(PlaybackSourcePolicy.fallback(
            from: failing,
            in: streams,
            excluding: ["https://cdn.test/b.m3u8", "https://cdn.test/c.m3u8"]
        ) == nil)
    }

    @Test("a ladder behind one URL has no fallback to offer")
    func noDuplicateFallback() {
        let streams = [
            rendition("Auto", "https://cdn.test/master.m3u8"),
            rendition("1080p", "https://cdn.test/master.m3u8"),
        ]
        #expect(PlaybackSourcePolicy.fallback(from: streams[0], in: streams) == nil)
    }

    @Test("an all-audio payload has no preferred source")
    func allAudio() {
        let streams = [
            rendition("Audio", "https://cdn.test/movie.mp3"),
            rendition("128kbps", "https://cdn.test/movie.m4a"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).isEmpty)
        #expect(PlaybackSourcePolicy.preferred(streams) == nil)
    }
}
