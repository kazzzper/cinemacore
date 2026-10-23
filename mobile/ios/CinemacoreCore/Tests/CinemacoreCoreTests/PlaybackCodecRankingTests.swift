import Testing
import Foundation
@testable import CinemacoreCore

/// HEVC is the one codec the provider serves in a layout iOS often will not
/// render (`hev1`), while its audio track plays perfectly — the black picture
/// with sound. The policy never drops such a source, because the device may
/// decode it; it ranks a known-decodable codec ahead so the viewer starts on the
/// copy that draws.
@Suite("Playback codec ranking")
struct PlaybackCodecRankingTests {
    private func rendition(
        _ quality: String,
        _ url: String,
        codec: String? = nil
    ) -> StreamRendition {
        StreamRendition(quality: quality, url: url, codec: codec)
    }

    @Test("a decodable codec outranks a higher-resolution HEVC source")
    func decodableFirst() {
        let streams = [
            rendition("1080", "https://cdn.test/1080.mp4", codec: "hevc"),
            rendition("720", "https://cdn.test/720.mp4", codec: "h264"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality) == ["720", "1080"])
        #expect(PlaybackSourcePolicy.preferred(streams)?.quality == "720")
    }

    @Test("codec ranking never drops the HEVC source")
    func hevcStillOffered() {
        // A device that decodes HEVC must still be able to pick it, and it is
        // the only fallback when every other copy fails.
        let streams = [
            rendition("720", "https://cdn.test/720.mp4", codec: "h264"),
            rendition("1080", "https://cdn.test/1080.mp4", codec: "hevc"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).count == 2)
        #expect(PlaybackSourcePolicy.fallback(from: streams[0], in: streams)?.quality == "1080")
    }

    @Test("resolution still orders sources that share a codec")
    func resolutionWithinCodec() {
        let streams = [
            rendition("480", "https://cdn.test/480.mp4", codec: "hevc"),
            rendition("1080", "https://cdn.test/1080.mp4", codec: "hevc"),
            rendition("720", "https://cdn.test/720.mp4", codec: "hevc"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality)
            == ["1080", "720", "480"])
    }

    @Test("an unlabelled source keeps its natural place")
    func unknownCodecIsNotDemoted() {
        // Only a *known* codec is promoted. Demoting an unlabelled entry would
        // push a perfectly good source below HEVC on a guess.
        let streams = [
            rendition("1080", "https://cdn.test/1080.mp4"),
            rendition("720", "https://cdn.test/720.mp4", codec: "h264"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(streams).map(\.quality) == ["720", "1080"])

        let unlabelledFirst = [
            rendition("1080", "https://cdn.test/1080.mp4"),
            rendition("720", "https://cdn.test/720.mp4", codec: "hevc"),
        ]
        #expect(PlaybackSourcePolicy.videoCandidates(unlabelledFirst).map(\.quality)
            == ["1080", "720"])
    }

    @Test("Auto leads even when it carries HEVC")
    func autoWins() {
        let streams = [
            rendition("1080", "https://cdn.test/1080.mp4", codec: "h264"),
            rendition("Auto", "https://cdn.test/master.m3u8", codec: "hevc"),
        ]
        #expect(PlaybackSourcePolicy.preferred(streams)?.quality == "Auto")
    }

    @Test("HEVC is recognised however the provider spells it")
    func hevcSpellings() {
        for raw in ["hevc", "HEVC", "h265", "hvc1", "hev1", "H.265"] {
            #expect(PlaybackSourcePolicy.isHEVC(codec: raw), "\(raw) should read as HEVC")
        }
        for raw in ["h264", "avc1", "vp9", "av01", "", "unknown"] {
            #expect(!PlaybackSourcePolicy.isHEVC(codec: raw), "\(raw) is not HEVC")
        }
        #expect(!PlaybackSourcePolicy.isHEVC(codec: nil))
    }

    @Test("known decodable codecs are the ones iOS renders")
    func decodableSpellings() {
        for raw in ["h264", "H.264", "avc", "avc1", "av01", "vp9", "mpeg4"] {
            #expect(PlaybackSourcePolicy.isKnownDecodableVideo(codec: raw), "\(raw) should decode")
        }
        // HEVC is deliberately absent: it may decode, so it must not be
        // promoted, and it must not be rejected either.
        for raw in ["hevc", "hev1", "hvc1", "", "weird"] {
            #expect(!PlaybackSourcePolicy.isKnownDecodableVideo(codec: raw), "\(raw) is not a sure bet")
        }
        #expect(!PlaybackSourcePolicy.isKnownDecodableVideo(codec: nil))
    }

    @Test("the provider's codec survives rendition expansion")
    func codecCarriedThroughRecovery() {
        let renditions = StreamRecovery.renditions(
            url: "https://cdn.test/movie.mp4",
            resolutions: "1080,720",
            size: "1024",
            cookie: nil,
            codec: "hevc"
        )
        #expect(renditions.map(\.codec) == ["hevc", "hevc"])
        #expect(renditions.map(\.quality) == ["1080", "720"])
    }
}
