package com.cinemacore.app.domain

/**
 * Pure playback decisions. No Android imports, so the rules are covered by JVM
 * tests instead of a device.
 */
object PlaybackPolicy {
    /** `null` when the stream is not native media (a web embed). */
    fun orderedDirect(streams: List<StreamRendition>): List<StreamRendition> =
        streams
            .filter { !it.isWeb && it.url.isNotBlank() }
            .sortedWith(
                compareByDescending<StreamRendition> { qualityScore(it.quality) }
                    .thenBy { it.quality },
            )

    fun defaultRendition(streams: List<StreamRendition>): StreamRendition? =
        orderedDirect(streams).firstOrNull()

    fun webRendition(streams: List<StreamRendition>): StreamRendition? =
        streams.firstOrNull { it.isWeb && it.url.isNotBlank() }

    fun qualityScore(label: String): Int {
        val normalized = label.trim().lowercase()
        return when {
            normalized == "auto" -> Int.MAX_VALUE
            normalized.contains("4k") || normalized.contains("2160") -> 2160
            normalized.contains("1440") -> 1440
            normalized.contains("1080") -> 1080
            normalized.contains("720") -> 720
            normalized.contains("480") -> 480
            normalized.contains("360") -> 360
            normalized.contains("240") -> 240
            else -> normalized.filter(Char::isDigit).toIntOrNull() ?: 0
        }
    }

    /**
     * Why a stream cannot enter the Android download queue, or `null` when it
     * can. The message is user-facing and matches the current iOS limitation.
     */
    fun downloadRejection(
        stream: StreamRendition,
        isStreamHype: Boolean,
    ): String? = when {
        isStreamHype || stream.isWeb ->
            "StreamHype titles play in the web player and cannot be downloaded."
        stream.container.isManifest ->
            "The ${stream.container.displayName} downloader is not enabled in this build."
        else -> null
    }

    fun formatSize(bytes: Long?): String? {
        val value = bytes?.takeIf { it > 0 } ?: return null
        val units = listOf("B", "KB", "MB", "GB", "TB")
        var amount = value.toDouble()
        var index = 0
        while (amount >= 1024 && index < units.lastIndex) {
            amount /= 1024
            index++
        }
        return if (index == 0) {
            "${amount.toLong()} ${units[index]}"
        } else {
            String.format(java.util.Locale.US, "%.1f %s", amount, units[index])
        }
    }
}
