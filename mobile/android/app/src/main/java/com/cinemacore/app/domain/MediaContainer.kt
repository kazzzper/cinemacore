package com.cinemacore.app.domain

import kotlinx.serialization.Serializable

/**
 * What the bytes at a stream URL actually are.
 *
 * A manifest is a recipe, not a file. The download queue must know which one it
 * holds before writing anything; Android's downloader intentionally only handles
 * direct files, matching the current iOS build.
 */
@Serializable
enum class MediaContainer {
    MP4,
    HLS,
    DASH,
    UNKNOWN,
    ;

    val isManifest: Boolean
        get() = this == HLS || this == DASH

    val isDirectDownload: Boolean
        get() = !isManifest

    val displayName: String
        get() = when (this) {
            MP4 -> "MP4"
            HLS -> "HLS"
            DASH -> "DASH"
            UNKNOWN -> "stream"
        }

    val assetExtension: String
        get() = when (this) {
            MP4, UNKNOWN -> "mp4"
            HLS -> "hls"
            DASH -> "dash"
        }

    companion object {
        fun classify(url: String, contentType: String? = null): MediaContainer {
            classifyContentType(contentType)?.let { return it }
            val path = url.substringBefore('?').substringBefore('#')
            return classifyExtension(path.substringAfterLast('.', ""))
        }

        fun classifyExtension(extension: String): MediaContainer = when (extension.lowercase()) {
            "mp4", "m4v", "mov" -> MP4
            "m3u8" -> HLS
            "mpd" -> DASH
            else -> UNKNOWN
        }

        fun classifyContentType(raw: String?): MediaContainer? {
            val type = raw?.substringBefore(';')?.trim()?.lowercase() ?: return null
            return when (type) {
                "application/vnd.apple.mpegurl",
                "application/x-mpegurl",
                "audio/mpegurl",
                "audio/x-mpegurl",
                -> HLS
                "application/dash+xml" -> DASH
                "video/mp4", "application/mp4", "video/quicktime" -> MP4
                else -> null
            }
        }
    }
}
