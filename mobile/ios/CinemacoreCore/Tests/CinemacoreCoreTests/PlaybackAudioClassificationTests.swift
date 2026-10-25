import Foundation
import Testing
@testable import CinemacoreCore

/// The provider-side half of the audio-only guard: the gateway advertises a
/// title's audio tracks beside its video and hands both out as ordinary
/// streams, so `format` and `codecName` are the only fields that separate them
/// before the bytes are fetched.
@Suite("Playback audio classification")
struct PlaybackAudioClassificationTests {
    @Test("audio containers are recognised however they are spelled")
    func audioFormats() {
        for raw in ["M4A", "m4a", "MP3", "aac", "FLAC", "E-AC-3", "eac3", "opus", "DTS"] {
            #expect(PlaybackSourcePolicy.isAudioOnly(format: raw), "\(raw) should be audio")
        }
        for raw in ["MP4", "mp4", "HLS", "DASH", "M4V", "WEBM", "mkv"] {
            #expect(!PlaybackSourcePolicy.isAudioOnly(format: raw), "\(raw) should stay video")
        }
    }

    @Test("audio codecs are recognised, video codecs are not")
    func audioCodecs() {
        for raw in ["aac", "AAC", "he-aac", "mp3", "opus", "vorbis", "ac-3", "ec-3", "alac", "pcm"] {
            #expect(PlaybackSourcePolicy.isAudioOnly(codec: raw), "\(raw) should be audio")
        }
        // An unfamiliar *video* codec must still reach the player: the gateway
        // gains codecs with time, and refusing one would drop a working title.
        for raw in ["hevc", "h264", "avc1", "av01", "vp9", "hvc1"] {
            #expect(!PlaybackSourcePolicy.isAudioOnly(codec: raw), "\(raw) should stay video")
        }
    }

    @Test("missing metadata is not evidence of audio")
    func absentMetadata() {
        #expect(!PlaybackSourcePolicy.isAudioOnly(format: nil))
        #expect(!PlaybackSourcePolicy.isAudioOnly(format: ""))
        #expect(!PlaybackSourcePolicy.isAudioOnly(codec: nil))
        #expect(!PlaybackSourcePolicy.isAudioOnly(codec: "  "))
    }

    /// The download queue now picks its source with this policy rather than
    /// `PlayInfo.preferredStream`, so the property that matters is pinned here:
    /// a soundtrack labelled `Auto` never wins over a real video rung. Queued
    /// instead, it would complete, play sound over a black surface, and read as
    /// a broken download.
    @Test("an audio-only Auto entry is never the preferred source")
    func audioAutoIsNotPreferred() {
        let streams = [
            StreamRendition(quality: "Auto", url: "https://cdn.test/title.m4a"),
            StreamRendition(quality: "1080p", url: "https://cdn.test/title.mp4"),
        ]
        #expect(!PlaybackSourcePolicy.isVideoCapable(streams[0]))
        #expect(PlaybackSourcePolicy.preferred(streams)?.quality == "1080p")
        #expect(PlaybackSourcePolicy.videoCandidates(streams).count == 1)

        // The label alone is enough: a soundtrack can be served in an MP4.
        let mislabelled = StreamRendition(quality: "Audio", url: "https://cdn.test/sound.mp4")
        #expect(!PlaybackSourcePolicy.isVideoCapable(mislabelled))
    }

    @Test("a stream entry is rejected when any signal says audio")
    func streamVerdicts() {
        #expect(PlaybackSourcePolicy.isVideoStream(
            format: "MP4", codec: "hevc", url: "https://cdn.test/a.mp4"
        ))
        // An MP4 container carrying an audio codec is still an audio track.
        #expect(!PlaybackSourcePolicy.isVideoStream(
            format: "MP4", codec: "aac", url: "https://cdn.test/a.mp4"
        ))
        #expect(!PlaybackSourcePolicy.isVideoStream(
            format: "M4A", codec: "aac", url: "https://cdn.test/a.m4a"
        ))
        // The URL alone can condemn an otherwise unlabelled entry.
        #expect(!PlaybackSourcePolicy.isVideoStream(
            format: nil, codec: nil, url: "https://cdn.test/audio.mp3"
        ))
        // An unknown but unremarkable entry is offered rather than dropped.
        #expect(PlaybackSourcePolicy.isVideoStream(format: nil, codec: nil, url: nil))
    }

    /// iOS has no DASH support, while the gateway builds an `index.mpd` tree
    /// whenever its signed prefix is one. Offering that rung is what made a
    /// quality pick go blank and then "fall back" to a lower label: the pick
    /// handed `AVPlayer` a manifest it cannot open, and the recovery moved on.
    @Test("a DASH manifest is never offered as a video source")
    func dashIsUnplayable() {
        let dash = StreamRendition(
            quality: "720p",
            url: "https://cdn.test/dash/title/index.mpd"
        )
        let hls = StreamRendition(
            quality: "360p",
            url: "https://cdn.test/hls/title/index.m3u8"
        )

        #expect(PlaybackSourcePolicy.isUnplayableContainer(url: URL(string: dash.url)!))
        #expect(!PlaybackSourcePolicy.isVideoCapable(dash))
        #expect(PlaybackSourcePolicy.isVideoCapable(hls))

        let candidates = PlaybackSourcePolicy.videoCandidates([dash, hls])
        #expect(candidates.map(\.quality) == ["360p"])
        #expect(PlaybackSourcePolicy.preferred([dash, hls])?.quality == "360p")

        // The same rung must not be reached through the fallback ladder either.
        #expect(PlaybackSourcePolicy.fallback(from: hls, in: [dash, hls]) == nil)
        // A provider-side entry is dropped before a rendition exists.
        #expect(!PlaybackSourcePolicy.isVideoStream(
            format: "DASH", codec: "h264", url: dash.url
        ))
    }
}
