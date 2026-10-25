import Foundation

/// Which provider renditions may be handed to `AVPlayer` as video.
///
/// The provider lists audio-only tracks beside real video renditions, and it
/// repeats one URL under several labels. `AVPlayer` plays an audio-only asset
/// without complaint while the surface stays black, so the decision of what is
/// a usable video source has to happen before an item is built — not after the
/// viewer reports a silent movie.
public enum PlaybackSourcePolicy {
    /// Extensions that carry sound but never a picture.
    private static let audioOnlyExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "ac3", "eac3", "flac", "opus", "ogg", "oga",
        "wav", "aif", "aiff", "wma", "amr", "dts",
    ]

    /// Labels the provider uses on soundtrack entries. Matched in full rather
    /// than by substring so "Audio Description" (a video rendition) survives.
    private static let audioOnlyLabels: Set<String> = [
        "audio", "audioonly", "soundtrack", "music", "mp3", "m4a", "aac",
    ]

    /// Containers the gateway names on sound-only stream entries. It lists a
    /// title's audio tracks beside its video and hands both out as ordinary
    /// streams, so `format` is the only field that separates them before the
    /// bytes are fetched.
    private static let audioOnlyFormats: Set<String> = [
        "mp3", "m2a", "m4a", "m4b", "aac", "flac", "opus", "ogg", "oga",
        "wav", "aif", "aiff", "wma", "amr", "ac3", "eac3", "ec3", "dts", "mka",
        "audio",
    ]

    /// Sound codecs as the gateway spells them in `codecName`. Real video codecs
    /// (`hevc`, `h264`, …) are absent on purpose: an unfamiliar *video* codec
    /// must still be offered to the player rather than silently dropped.
    private static let audioOnlyCodecs: Set<String> = [
        "mp2", "mp3", "mp4a", "aac", "heaac", "heaacv1", "heaacv2", "opus",
        "vorbis", "flac", "alac", "ac3", "eac3", "ec3", "dts", "dtshd", "dtsx",
        "mlp", "truehd", "pcm", "lpcm", "amr", "wmav2",
    ]

    /// Manifest containers `AVPlayer` cannot open.
    ///
    /// The gateway answers the same title from an HLS tree, a DASH tree, or a
    /// plain file — its signed prefix decides which. The Go core keeps DASH
    /// because the terminal client renders it through mpv, but iOS has no DASH
    /// support at all: an `.mpd` item fails after it has already been handed to
    /// the player, which reads to the viewer as a quality that "goes blank" and
    /// then silently drops to whatever else the payload holds.
    private static let unplayableExtensions: Set<String> = ["mpd"]

    /// Whether the URL itself points at an audio container.
    public static func isAudioOnly(url: URL) -> Bool {
        audioOnlyExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the URL names a container this platform cannot play, whatever it
    /// claims to carry.
    public static func isUnplayableContainer(url: URL) -> Bool {
        unplayableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether a provider label names a soundtrack rather than a video track.
    public static func isAudioOnly(label raw: String) -> Bool {
        let compact = compact(raw)
        guard !compact.isEmpty else { return false }
        return audioOnlyLabels.contains(compact)
            || compact.hasPrefix("audioonly")
            || compact.hasPrefix("soundtrack")
    }

    /// Whether the provider's declared container is sound alone.
    public static func isAudioOnly(format raw: String?) -> Bool {
        guard let raw else { return false }
        let value = compact(raw)
        return !value.isEmpty && audioOnlyFormats.contains(value)
    }

    /// Whether the provider's declared codec is a sound codec.
    public static func isAudioOnly(codec raw: String?) -> Bool {
        guard let raw else { return false }
        let value = compact(raw)
        return !value.isEmpty && audioOnlyCodecs.contains(value)
    }

    /// Video codecs AVFoundation renders reliably on iOS.
    ///
    /// A short allowlist on purpose: unlike the audio denylist, a codec missing
    /// here is not rejected — it is only tried after the ones that are known to
    /// work, so a new codec costs a fallback rather than a dead end.
    private static let decodableVideoCodecs: Set<String> = [
        "h264", "avc", "avc1", "avc3", "h263", "mpeg4", "mp4v", "vp8", "vp9",
        "av1", "av01",
    ]

    /// Whether the provider's codec label is a codec this device decodes
    /// without doubt.
    public static func isKnownDecodableVideo(codec raw: String?) -> Bool {
        guard let raw else { return false }
        let value = compact(raw)
        return !value.isEmpty && decodableVideoCodecs.contains(value)
    }

    /// Whether the provider's codec label names HEVC.
    ///
    /// HEVC is not a rejection: the device may decode it, and the gateway serves
    /// it in both sample-entry layouts (`hvc1` renders, `hev1` often does not).
    /// It is a hint that another source is a safer default when one exists.
    public static func isHEVC(codec raw: String?) -> Bool {
        guard let raw else { return false }
        let value = compact(raw)
        return value == "hevc" || value == "h265" || value == "hvc1" || value == "hev1"
    }

    /// Whether a stream entry advertises a picture at all.
    ///
    /// Checked at the provider boundary, before a rendition exists: an
    /// audio-only entry that reaches `AVPlayer` plays sound over a black
    /// surface, which reads to the viewer as a broken player rather than as a
    /// title without video.
    public static func isVideoStream(format: String?, codec: String?, url: String?) -> Bool {
        if isAudioOnly(format: format) || isAudioOnly(codec: codec) { return false }
        guard let url, let parsed = URL(string: url) else { return true }
        return !isAudioOnly(url: parsed) && !isUnplayableContainer(url: parsed)
    }

    /// A rendition is a candidate only when both the bytes and the label say
    /// "video"; either one being audio-only is enough to keep the player out.
    public static func isVideoCapable(_ rendition: StreamRendition) -> Bool {
        guard let url = rendition.urlValue else { return false }
        return !isAudioOnly(url: url)
            && !isAudioOnly(label: rendition.quality)
            && !isUnplayableContainer(url: url)
    }

    /// Lowercases and strips the separators the gateway sprinkles through
    /// container and codec names (`"E-AC-3"`, `"m4a "`), so one table matches.
    private static func compact(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The identity of the bytes. Two labels on one URL are one source, so this
    /// is the key both duplicate filtering and fallback exclusion use.
    public static func sourceKey(_ rendition: StreamRendition) -> String {
        guard let url = rendition.urlValue else { return rendition.url.trimmingCharacters(in: .whitespacesAndNewlines) }
        return sourceKey(url)
    }

    public static func sourceKey(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renditions the quality sheet may offer: video-capable, best-first with
    /// the provider's `Auto` entry leading.
    ///
    /// The dedupe key is label **and** URL. Two labels on one adaptive manifest
    /// are separate bit-rate hints, while two uploads that both call themselves
    /// "1080" are separate files the viewer must be able to choose.
    public static func videoOptions(_ streams: [StreamRendition]) -> [StreamRendition] {
        ranked(streams, dedupeKey: {
            let label = $0.quality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return label + "\u{0}" + sourceKey($0)
        })
    }

    /// Renditions worth *playing*: video-capable, one per URL, best-first.
    /// Several labels commonly share a URL, and playing that URL again through
    /// another label is not a fallback — it is the same failure. Duplicate
    /// labels collapse for the same reason: the viewer cannot tell them apart.
    public static func videoCandidates(_ streams: [StreamRendition]) -> [StreamRendition] {
        var seen = Set<String>()
        return videoOptions(streams).filter { seen.insert(sourceKey($0)).inserted }
    }

    /// The rendition a fresh session should start on.
    public static func preferred(_ streams: [StreamRendition]) -> StreamRendition? {
        videoCandidates(streams).first
    }

    /// The next source to try after one proved unplayable.    ///
    /// `tried` carries URLs already known bad for this session. The rendition's
    /// own URL is always excluded, so a caller cannot loop on the same bytes.
    public static func fallback(
        from rendition: StreamRendition,
        in streams: [StreamRendition],
        excluding tried: Set<String> = []
    ) -> StreamRendition? {
        let current = sourceKey(rendition)
        return videoCandidates(streams).first {
            let key = sourceKey($0)
            return key != current && !tried.contains(key)
        }
    }

    /// Stable sort: `Auto` first, then decodable codecs, then resolution
    /// descending, ties in provider order. The tie-break is what keeps the sheet
    /// from reshuffling when the caller rebuilds an equal-ranked list.
    ///
    /// Codec outranks resolution because a 720p H.264 copy renders and a 4K
    /// HEVC one may not: resolution is worthless on a source the device cannot
    /// draw. Only *known* codecs are promoted, so an unlabelled or unfamiliar
    /// entry keeps its natural place rather than being demoted on a guess.
    private static func ranked(
        _ streams: [StreamRendition],
        dedupeKey: (StreamRendition) -> String
    ) -> [StreamRendition] {
        var seen = Set<String>()
        var kept: [(offset: Int, element: StreamRendition)] = []
        for (offset, stream) in streams.enumerated() where isVideoCapable(stream) {
            guard seen.insert(dedupeKey(stream)).inserted else { continue }
            kept.append((offset, stream))
        }
        return kept
            .sorted { lhs, rhs in
                let lhsAuto = isAuto(lhs.element)
                let rhsAuto = isAuto(rhs.element)
                if lhsAuto != rhsAuto { return lhsAuto }
                let lhsDecodable = isKnownDecodableVideo(codec: lhs.element.codec)
                let rhsDecodable = isKnownDecodableVideo(codec: rhs.element.codec)
                if lhsDecodable != rhsDecodable { return lhsDecodable }
                if lhs.element.resolutionRank != rhs.element.resolutionRank {
                    return lhs.element.resolutionRank > rhs.element.resolutionRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func isAuto(_ rendition: StreamRendition) -> Bool {
        rendition.quality.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare("Auto") == .orderedSame
    }
}
