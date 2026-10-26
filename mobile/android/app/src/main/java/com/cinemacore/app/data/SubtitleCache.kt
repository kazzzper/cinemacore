package com.cinemacore.app.data

import com.cinemacore.app.domain.DownloadedSubtitle
import com.cinemacore.app.domain.SubtitleTrack
import java.io.File
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Fetches provider captions once, then hands Media3 a local file.
 *
 * Media3 can decode SubRip, but SRT and WebVTT disagree about both the file
 * header and the timestamp separator. Normalising to VTT here means a track
 * that plays on the device is the same track that was archived beside a
 * download; the player never has to guess from a URL extension.
 */
class SubtitleCache(
    private val directory: File,
    private val http: OkHttpClient = defaultClient(),
) {
    init {
        directory.mkdirs()
    }

    suspend fun cached(track: SubtitleTrack, cookie: String? = null): File? =
        withContext(Dispatchers.IO) {
            val stem = safeName("${track.language}-${track.url.hashCode()}")
            val cached = File(directory, "$stem.vtt")
            if (cached.exists() && cached.length() > 0) return@withContext cached
            val request = Request.Builder()
                .url(track.url)
                .apply { cookie?.takeIf { it.isNotBlank() }?.let { header("Cookie", it) } }
                .get()
                .build()
            runCatching {
                http.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@withContext null
                    val body = response.body?.string() ?: return@withContext null
                    val vtt = toVtt(body)
                    val temp = File(directory, "$stem.vtt.tmp")
                    temp.writeText(vtt)
                    if (!temp.renameTo(cached)) {
                        cached.writeText(vtt)
                        temp.delete()
                    }
                }
            }.getOrNull()
            cached.takeIf { it.exists() && it.length() > 0 }
        }

    /**
     * Saves every caption that can be fetched. A failed caption never fails the
     * episode download it belongs to.
     */
    suspend fun store(
        tracks: List<SubtitleTrack>,
        cookie: String? = null,
        idPrefix: String,
        targetDirectory: File = directory,
    ): List<DownloadedSubtitle> = withContext(Dispatchers.IO) {
        targetDirectory.mkdirs()
        tracks.mapIndexedNotNull { index, track ->
            val target = File(
                targetDirectory,
                safeName("$idPrefix-${index}-${track.language}") + ".vtt",
            )
            val fetched = cached(track, cookie) ?: return@mapIndexedNotNull null
            if (target != fetched) {
                fetched.copyTo(target, overwrite = true)
            }
            DownloadedSubtitle(
                language = track.language,
                fileName = target.name,
                format = "vtt",
            )
        }
    }

    companion object {
        fun toVtt(raw: String): String {
            val normalized = raw.replace("\r\n", "\n").replace('\r', '\n').trimStart('\uFEFF')
            if (normalized.startsWith("WEBVTT")) return normalized
            val body = normalized
                .replace(Regex("(?m)^(\\d+):(\\d{2}):(\\d{2})[,.](\\d{3})\\s*-->\\s*(\\d+):(\\d{2}):(\\d{2})[,.](\\d{3})"), "$1:$2:$3.$4 --> $5:$6:$7.$8")
                .replace(Regex("(?m)^(\\d{2}):(\\d{2})[,.](\\d{3})\\s*-->\\s*(\\d{2}):(\\d{2})[,.](\\d{3})"), "00:$1:$2.$3 --> 00:$4:$5.$6")
                .replace(Regex("(?m)^(\\d{2}):(\\d{2})\\.(\\d{3})\\s*-->\\s*(\\d{2}):(\\d{2})\\.(\\d{3})"), "00:$1:$2.$3 --> 00:$4:$5.$6")
            return "WEBVTT\n\n$body\n"
        }

        fun safeName(raw: String): String =
            raw.lowercase(Locale.US)
                .replace(Regex("[^a-z0-9._-]"), "-")
                .trim('-')
                .take(100)
                .ifBlank { "subtitle" }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}
