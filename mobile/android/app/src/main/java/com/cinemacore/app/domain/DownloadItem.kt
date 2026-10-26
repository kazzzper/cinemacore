package com.cinemacore.app.domain

import kotlinx.serialization.Serializable

@Serializable
enum class DownloadStatus {
    QUEUED,
    DOWNLOADING,
    PAUSED,
    COMPLETED,
    FAILED,
    ;

    val label: String
        get() = when (this) {
            QUEUED -> "Queued"
            DOWNLOADING -> "Downloading"
            PAUSED -> "Paused"
            COMPLETED -> "Completed"
            FAILED -> "Failed"
        }

    val rank: Int
        get() = when (this) {
            DOWNLOADING -> 0
            QUEUED -> 1
            PAUSED -> 2
            FAILED -> 3
            COMPLETED -> 4
        }
}

@Serializable
data class DownloadedSubtitle(
    val language: String,
    val fileName: String,
    val format: String? = null,
)

@Serializable
data class DownloadItem(
    val id: String,
    val subjectId: String,
    val title: String,
    val poster: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    val quality: String,
    val remoteUrl: String,
    val cookie: String? = null,
    val container: MediaContainer = MediaContainer.UNKNOWN,
    val status: DownloadStatus = DownloadStatus.QUEUED,
    val totalBytes: Long = 0,
    val bytesWritten: Long = 0,
    val attempts: Int = 0,
    val failure: String? = null,
    val createdAt: Long,
    val updatedAt: Long,
    val fileName: String,
    val subtitles: List<DownloadedSubtitle> = emptyList(),
) {
    val progress: Float
        get() = if (totalBytes > 0) {
            (bytesWritten.toDouble() / totalBytes.toDouble()).toFloat().coerceIn(0f, 1f)
        } else {
            0f
        }

    val isFinished: Boolean
        get() = status == DownloadStatus.COMPLETED

    val isActive: Boolean
        get() = status == DownloadStatus.DOWNLOADING || status == DownloadStatus.QUEUED

    val remainingBytes: Long
        get() = (totalBytes - bytesWritten).coerceAtLeast(0)

    val episodeLabel: String?
        get() = when {
            season != null && episode != null -> "S${season}E${episode}"
            else -> null
        }

    val sizeText: String?
        get() = when {
            totalBytes > 0 -> PlaybackPolicy.formatSize(totalBytes)
            bytesWritten > 0 -> PlaybackPolicy.formatSize(bytesWritten)
            else -> null
        }
}
