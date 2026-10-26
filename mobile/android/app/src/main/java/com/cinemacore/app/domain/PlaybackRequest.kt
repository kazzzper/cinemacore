package com.cinemacore.app.domain

/**
 * What the user asked to play.
 *
 * The player navigates by value so it never reaches into a screen's state. The
 * subject id is the only required identity; the player re-resolves the full
 * title from the active catalogue, which keeps saved history and downloads
 * working after the catalogue shape changes.
 */
data class PlaybackRequest(
    val subjectId: String,
    val title: String,
    val poster: String? = null,
    val kind: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    val resourceId: String? = null,
    val downloadId: String? = null,
    val localFilePath: String? = null,
    val startPositionMs: Long? = null,
) {
    val isSeries: Boolean
        get() = kind == "series" || kind == "2" || season != null

    val id: String
        get() {
            val suffix = when {
                season != null && episode != null -> "-s${season}e$episode"
                season != null -> "-s$season"
                else -> ""
            }
            return "$subjectId$suffix"
        }

    val displayTitle: String
        get() = if (episode != null) "$title · ${episodeTitle ?: "Episode $episode"}" else title

    val episodeLabel: String?
        get() = if (season != null && episode != null) "S${season}E$episode" else null

    companion object {
        fun forSubject(subject: Subject, season: Int? = null, episode: Episode? = null): PlaybackRequest =
            PlaybackRequest(
                subjectId = subject.id,
                title = subject.title,
                poster = subject.poster,
                kind = subject.kind,
                season = season,
                episode = episode?.number,
                episodeTitle = episode?.displayTitle,
            )

        fun fromDownload(item: DownloadItem): PlaybackRequest = PlaybackRequest(
            subjectId = item.subjectId,
            title = item.title,
            poster = item.poster,
            kind = if (item.season != null) "series" else "movie",
            season = item.season,
            episode = item.episode,
            episodeTitle = item.episodeTitle,
            downloadId = item.id,
            localFilePath = null,
        )

        fun fromResume(point: ResumePoint): PlaybackRequest = PlaybackRequest(
            subjectId = point.subjectId,
            title = point.title,
            poster = point.poster,
            kind = if (point.episode != null) "series" else "movie",
            season = point.season,
            episode = point.episode,
            episodeTitle = point.episodeTitle,
            startPositionMs = point.positionMs,
        )
    }
}

/** One episode (or a movie) the user asked to download. */
data class DownloadTarget(
    val season: Int? = null,
    val episode: Episode? = null,
    val episodeTitle: String? = null,
    /** Quality label picked in the UI; `null` keeps the provider's best. */
    val quality: String? = null,
)

/** What one enqueue attempt did, so the UI reports facts rather than guesses. */
data class DownloadQueueOutcome(
    val requested: Int,
    val added: Int,
    val failed: Int,
    val failureReason: String? = null,
) {
    val skipped: Int
        get() = (requested - added - failed).coerceAtLeast(0)

    val message: String
        get() = when {
            requested == 0 -> "Nothing to download."
            added == 0 && failed == requested -> failureReason
                ?: if (requested == 1) {
                    "No stream was available to download."
                } else {
                    "No streams were available for those $requested episodes."
                }
            else -> buildList {
                if (added > 0) add("Queued $added ${if (added == 1) "download" else "downloads"}")
                if (skipped > 0) add("$skipped already queued")
                if (failed > 0) add("$failed could not be resolved")
            }.joinToString(" · ") + "."
        }
}
