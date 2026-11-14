package com.cinemacore.app.domain

import java.util.Locale

/** Track-list rules shared by the player and the picker. */
object SubtitleTracks {
    /**
     * [existing] first, then whatever [incoming] adds.
     *
     * Order is deliberate: the existing list is what the picker is showing, and
     * re-sorting it on a late response would move the row the viewer is about to
     * tap.
     */
    fun merging(existing: List<SubtitleTrack>, incoming: List<SubtitleTrack>): List<SubtitleTrack> {
        val seen = existing.mapTo(mutableSetOf()) { it.id }
        return existing + incoming.filter { seen.add(it.id) }
    }

    /**
     * The track a fresh playback should start on.
     *
     * A dub already speaks the requested language, so an original-language
     * caption is not a default there — the picker still offers it. [chosen]
     * being non-nil means the viewer has picked, and the answer is never a new
     * default.
     *
     * [prefersCommunity] is for a numbered episode: the provider keys captions
     * on a title-level id, so an episode can be answered with the first file of
     * the season while the response still looks valid. The community search is
     * keyed on the episode itself, so it wins the default when both offer
     * English. Films are unaffected — their captions are title-keyed everywhere.
     */
    fun defaultTrack(
        tracks: List<SubtitleTrack>,
        isOriginalAudio: Boolean,
        chosen: SubtitleTrack?,
        prefersCommunity: Boolean = false,
    ): SubtitleTrack? {
        if (chosen != null || !isOriginalAudio) return chosen
        if (prefersCommunity) {
            english(tracks.filter { it.provider == SubtitleProvider.COMMUNITY })?.let { return it }
        }
        return english(tracks) ?: tracks.firstOrNull()
    }

    /** The first English track, or `null` when the list carries none. */
    fun english(tracks: List<SubtitleTrack>): SubtitleTrack? =
        tracks.firstOrNull { isEnglish(it.language) }

    /**
     * Whether a track label names English.
     *
     * Tolerates the spellings the sources emit: `English`, `en`, `eng`,
     * `en-US`, `English (US)`. A label that merely contains the letters (e.g.
     * `Bengali`) must not match, so this compares tokens, not substrings.
     */
    fun isEnglish(language: String): Boolean {
        val tokens = language
            .lowercase(Locale.ROOT)
            .split(Regex("[^a-z0-9]+"))
            .filter { it.isNotEmpty() }
        if ("english" in tokens) return true
        return "en" in tokens || "eng" in tokens
    }
}

/** What the community caption lookup currently has to offer. */
enum class SubtitleAvailability {
    IDLE,
    LOADING,

    /** Community tracks are in the list. */
    AVAILABLE,

    /** The lookup ran and found nothing; the picker offers a retry. */
    UNAVAILABLE,
}
