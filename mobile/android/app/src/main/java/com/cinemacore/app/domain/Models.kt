package com.cinemacore.app.domain

import kotlinx.serialization.Serializable

/**
 * Domain models for the Android client.
 *
 * These mirror `contracts/openapi.yaml` but are not the generated wire types.
 * Repositories map generated models into these, so screens never bind to
 * Retrofit or to a generated package. Fields the contract does not carry today
 * (for example an episode still) are absent on purpose; do not invent them in a
 * screen.
 */

@Serializable
data class Subject(
    val id: String,
    val title: String,
    val poster: String? = null,
    val year: Int? = null,
    val rating: Double? = null,
    /** `"movie"`, `"series"`, or the provider's legacy `"1"` / `"2"`. */
    val kind: String? = null,
    val synopsis: String? = null,
    val genres: List<String> = emptyList(),
    val dubs: List<String> = emptyList(),
    val dubOptions: List<Dub> = emptyList(),
    val durationMinutes: Int? = null,
    val seasonCount: Int = 1,
    val cast: List<CastMember> = emptyList(),
    val resourceDetectors: List<ResourceDetector> = emptyList(),
) {
    val isSeries: Boolean
        get() = kind == "series" || kind == "2"

    val kindLabel: String
        get() = if (isSeries) "Series" else "Movie"

    val yearLabel: String?
        get() = year?.toString()

    val runtimeLabel: String?
        get() = durationMinutes?.takeIf { it > 0 }?.let { minutes ->
            val hours = minutes / 60
            val rest = minutes % 60
            if (hours > 0) "${hours}h ${rest}m" else "${rest}m"
        }

    val ratingLabel: String?
        get() = rating?.let { String.format(java.util.Locale.US, "%.1f", it) }

    val seasonLabel: String?
        get() = if (isSeries && seasonCount > 0) {
            if (seasonCount == 1) "1 season" else "$seasonCount seasons"
        } else {
            null
        }
}

@Serializable
data class Dub(
    val subjectId: String,
    val languageName: String,
    val languageCode: String? = null,
    val isOriginal: Boolean = false,
) {
    val displayName: String
        get() = languageName.ifBlank { languageCode ?: "Audio" }
}

@Serializable
data class CastMember(
    val name: String,
    val role: String? = null,
    val avatar: String? = null,
)

@Serializable
data class ResourceDetector(
    val resourceId: String,
    val name: String,
)

@Serializable
data class Section(
    val title: String,
    val items: List<Subject>,
)

@Serializable
data class Page(
    val sections: List<Section>,
) {
    val isEmpty: Boolean
        get() = sections.all { it.items.isEmpty() }
}

@Serializable
data class Episode(
    val subjectId: String,
    val season: Int,
    val number: Int,
    val title: String? = null,
    val durationSeconds: Int? = null,
) {
    val id: String
        get() = "$subjectId:$season:$number"

    val displayTitle: String
        get() = title?.takeIf { it.isNotBlank() } ?: "Episode $number"

    val durationText: String?
        get() = durationSeconds?.takeIf { it > 0 }?.let { seconds ->
            "${seconds / 60} min"
        }
}

@Serializable
data class Season(
    val number: Int,
    val episodes: List<Episode>,
)

@Serializable
data class PlayInfo(
    val streams: List<StreamRendition>,
    val subtitles: List<SubtitleTrack> = emptyList(),
)

@Serializable
enum class StreamKind {
    DIRECT,
    WEB,
}

@Serializable
data class StreamRendition(
    val quality: String,
    val url: String,
    val size: String? = null,
    val cookie: String? = null,
    val kind: StreamKind = StreamKind.DIRECT,
) {
    val isWeb: Boolean
        get() = kind == StreamKind.WEB

    val container: MediaContainer
        get() = MediaContainer.classify(url)
}

@Serializable
data class SubtitleTrack(
    val language: String,
    val url: String,
    val format: String? = null,
)
