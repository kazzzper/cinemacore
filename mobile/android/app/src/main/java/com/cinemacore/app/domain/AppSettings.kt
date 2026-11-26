package com.cinemacore.app.domain

import kotlinx.serialization.Serializable

@Serializable
enum class SourceMode {
    /** Direct to MovieBox in Kotlin. Default; needs no server. */
    BUILT_IN,

    STREAM_HYPE,

    GATEWAY,

    DEMO,
    ;

    val label: String
        get() = when (this) {
            BUILT_IN -> "MovieBox (direct)"
            STREAM_HYPE -> "StreamHype (web)"
            GATEWAY -> "Gateway server"
            DEMO -> "Bundled demo"
        }
}

@Serializable
enum class DownloadSortKey {
    ADDED,
    TITLE,
    STATUS,
    ;

    val label: String
        get() = when (this) {
            ADDED -> "Date added"
            TITLE -> "Title"
            STATUS -> "Status"
        }
}

@Serializable
enum class DownloadGrouping {
    NONE,
    STATUS,

    /** One section per show, with its episodes in transmission order. */
    EPISODE,
    ;

    val label: String
        get() = when (this) {
            NONE -> "Ungrouped"
            STATUS -> "Group by status"
            EPISODE -> "Group by episode"
        }
}

@Serializable
data class AppSettings(
    val sourceMode: SourceMode = SourceMode.BUILT_IN,
    /** Empty means "use BuildConfig.DEFAULT_GATEWAY". */
    val gatewayUrl: String = "",
    val tmdbKey: String = "",
    val preferredLanguage: String = "",
    val hiddenRails: List<String> = emptyList(),
    val railOrder: List<String> = emptyList(),
    val playbackSpeed: Float = 1f,
    val autoPlayNext: Boolean = true,
    val playerFillScreen: Boolean = false,
    val playerAvoidNotch: Boolean = false,
    val downloadSortKey: DownloadSortKey = DownloadSortKey.ADDED,
    val downloadSortAscending: Boolean = false,
    val downloadGrouping: DownloadGrouping = DownloadGrouping.NONE,
) {
    val effectiveGatewayUrl: String
        get() = gatewayUrl.trim().ifEmpty { DEFAULT_GATEWAY }

    companion object {
        // Replaced by AppContainer with BuildConfig.DEFAULT_GATEWAY. Keeping a
        // constant here lets pure tests construct settings without Android.
        const val DEFAULT_GATEWAY: String = "http://10.0.2.2:8080"
    }
}

@Serializable
data class LibraryEntry(
    val subject: Subject,
    val addedAt: Long,
)

@Serializable
data class ResumePoint(
    val subjectId: String,
    val title: String,
    val poster: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val updatedAt: Long,
) {
    val key: String
        get() = "$subjectId:${season ?: 0}:${episode ?: 0}"

    val progress: Float
        get() = if (durationMs > 0) {
            (positionMs.toDouble() / durationMs.toDouble()).toFloat().coerceIn(0f, 1f)
        } else {
            0f
        }

    /**
     * A point worth putting on Home: moved past the opening credit, and not
     * effectively finished. Mirrors the iOS `ResumePoint.isResumable`.
     */
    val isResumable: Boolean
        get() = durationMs > 0 && progress < 0.98f && positionMs > 5_000L

    val episodeLabel: String?
        get() = when {
            season != null && episode != null -> "S${season}E${episode}"
            else -> null
        }
}

@Serializable
data class LibraryData(
    val watchlist: List<LibraryEntry> = emptyList(),
    val history: List<ResumePoint> = emptyList(),
)
