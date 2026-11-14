package com.cinemacore.app.data

import com.cinemacore.app.domain.SubtitleProvider
import com.cinemacore.app.domain.SubtitleTrack
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** What a free caption lookup needs in order to identify a title. */
data class FreeSubtitleRequest(
    val title: String,
    val year: Int? = null,
    val isSeries: Boolean = false,
    val season: Int? = null,
    val episode: Int? = null,
    /** ISO-639-1 code or a language name; `null` ranks English first. */
    val language: String? = null,
)

/**
 * Keyless community captions for titles the provider publishes none for.
 *
 * The provider carries external captions only for some titles; the rest report
 * none, which is why most videos looked captionless. Stremio's OpenSubtitles v3
 * addon is the one free source that needs no key, no account and no proxy — the
 * alternatives require a key that must not ship inside an app binary — and it
 * serves UTF-8 SRT that is already unzipped.
 *
 * It matches on an IMDb id, which the catalogue does not publish, so Cinemeta —
 * the same operator's metadata addon — resolves the title to one first. Both
 * calls are plain HTTPS JSON and the lookup is best effort: any failure leaves
 * playback exactly as it was (the picker reports "none" and offers a retry).
 */
class FreeSubtitles(
    private val http: OkHttpClient,
    private val limit: Int = 10,
    /** Injectable listing fetch, so the decoding tests need no network. */
    private val fetch: (suspend (HttpUrl) -> String?)? = null,
) {
    /** Caption tracks for the request, the viewer's language first. */
    suspend fun tracks(request: FreeSubtitleRequest): List<SubtitleTrack> {
        val imdb = imdbId(request) ?: return emptyList()
        val url = addonUrl(imdb, request) ?: return emptyList()
        val body = (fetch ?: ::get)(url) ?: return emptyList()
        return tracksFromAddon(body, request, limit)
    }

    /** The IMDb id Cinemeta resolves the title to. */
    suspend fun imdbId(request: FreeSubtitleRequest): String? {
        val url = cinemetaUrl(request) ?: return null
        val body = (fetch ?: ::get)(url) ?: return null
        return imdbIdFromCinemeta(body, request.year)
    }

    private suspend fun get(url: HttpUrl): String? = withContext(Dispatchers.IO) {
        runCatching {
            http.newCall(Request.Builder().url(url).header("Accept", "application/json").build())
                .execute()
                .use { response ->
                    if (!response.isSuccessful) return@use null
                    response.body?.string()
                }
        }.getOrNull()
    }

    companion object {
        private const val CINEMETA_HOST = "v3-cinemeta.strem.io"
        private const val ADDON_HOST = "opensubtitles-v3.strem.io"

        fun cinemetaUrl(request: FreeSubtitleRequest): HttpUrl? {
            val type = if (request.isSeries) "series" else "movie"
            val title = request.title.trim()
            if (title.isEmpty()) return null
            return HttpUrl.Builder()
                .scheme("https")
                .host(CINEMETA_HOST)
                .addPathSegment("catalog")
                .addPathSegment(type)
                .addPathSegment("top")
                // The addon's documented shape keeps the query inside the path;
                // `HttpUrl` escapes the characters that would re-parse it.
                .addPathSegment("search=$title.json")
                .build()
        }

        fun addonUrl(imdbId: String, request: FreeSubtitleRequest): HttpUrl? {
            if (!imdbId.startsWith("tt")) return null
            val builder = HttpUrl.Builder()
                .scheme("https")
                .host(ADDON_HOST)
                .addPathSegment("subtitles")
            if (!request.isSeries) {
                return builder
                    .addPathSegment("movie")
                    .addPathSegment("$imdbId.json")
                    .build()
            }
            // The addon's episode numbers are one-based, so a missing or zero
            // number must not become `:0:0` and match nothing.
            val season = (request.season ?: 1).coerceAtLeast(1)
            val episode = (request.episode ?: 1).coerceAtLeast(1)
            return builder
                .addPathSegment("series")
                .addPathSegment("$imdbId:$season:$episode.json")
                .build()
        }

        fun imdbIdFromCinemeta(body: String, year: Int?): String? {
            val page = runCatching { JSON.decodeFromString<Cinemeta>(body) }.getOrNull() ?: return null
            val metas = page.metas.orEmpty().filter { it.imdbId?.startsWith("tt") == true }
            val fallback = metas.firstOrNull() ?: return null
            if (year == null) return fallback.imdbId
            val match = metas.firstOrNull { it.releaseInfo?.startsWith(year.toString()) == true }
            return (match ?: fallback).imdbId
        }

        fun tracksFromAddon(
            body: String,
            request: FreeSubtitleRequest,
            limit: Int,
        ): List<SubtitleTrack> {
            val page = runCatching { JSON.decodeFromString<Addon>(body) }.getOrNull() ?: return emptyList()
            val seen = mutableSetOf<String>()
            val candidates = mutableListOf<Ranked>()
            page.subtitles.orEmpty().forEachIndexed { offset, entry ->
                val url = entry.url?.takeIf { it.startsWith("http") } ?: return@forEachIndexed
                if (!seen.add(url)) return@forEachIndexed
                if (!namesRequestedEpisode(entry, request)) return@forEachIndexed
                val code = entry.lang.orEmpty().lowercase(Locale.ROOT)
                candidates += Ranked(
                    rank = rank(code, request.language),
                    offset = offset,
                    track = SubtitleTrack(
                        language = displayName(code),
                        url = url,
                        format = "srt",
                        source = releaseLabel(entry),
                        provider = SubtitleProvider.COMMUNITY,
                    ),
                )
            }
            return candidates
                .sortedWith(compareBy({ it.rank }, { it.offset }))
                .take(limit.coerceAtLeast(0))
                .map { it.track }
        }

        /**
         * Whether an addon entry actually covers the requested episode.
         *
         * The listing is a fuzzy match: an S01E01 lookup can return an S08E02
         * file. Nothing marks it wrong except the release name, so an entry that
         * spells a *different* season/episode is dropped; an unmarked entry is
         * kept because most bare `S01E01.srt` names are right.
         */
        internal fun namesRequestedEpisode(entry: AddonEntry, request: FreeSubtitleRequest): Boolean {
            if (!request.isSeries) return true
            val marker = episodeMarker(listOfNotNull(entry.subtitleFileName, entry.movieReleaseName))
                ?: return true
            val season = (request.season ?: 1).coerceAtLeast(1)
            val episode = (request.episode ?: 1).coerceAtLeast(1)
            return marker == season to episode
        }

        /** The first `S<n>E<n>` marker in any of [names]. */
        fun episodeMarker(names: List<String?>): Pair<Int, Int>? {
            for (name in names) {
                if (name.isNullOrEmpty()) continue
                val chars = name.lowercase(Locale.ROOT)
                var index = 0
                while (index < chars.length) {
                    if (chars[index] != 's') {
                        index++
                        continue
                    }
                    val before = if (index > 0) chars[index - 1] else ' '
                    if (before.isDigit() || before == 's') {
                        index++
                        continue
                    }
                    val season = digits(chars, index + 1)
                    if (season == null) {
                        index++
                        continue
                    }
                    var cursor = season.second
                    if (cursor < chars.length && (chars[cursor] == '.' || chars[cursor] == '_')) {
                        cursor++
                    }
                    if (cursor >= chars.length || chars[cursor] != 'e') {
                        index++
                        continue
                    }
                    val episode = digits(chars, cursor + 1)
                    if (episode == null) {
                        index++
                        continue
                    }
                    return season.first to episode.first
                }
            }
            return null
        }

        private fun digits(text: String, from: Int): Pair<Int, Int>? {
            var cursor = from
            var value = 0
            while (cursor < text.length && text[cursor].isDigit()) {
                value = value * 10 + text[cursor].digitToInt()
                cursor++
            }
            return if (cursor == from) null else value to cursor
        }

        /** The release an entry belongs to, most specific first. */
        internal fun releaseLabel(entry: AddonEntry): String? {
            for (candidate in listOf(entry.movieReleaseName, entry.subtitleFileName)) {
                val trimmed = candidate?.trim().orEmpty()
                if (trimmed.isNotEmpty()) return trimmed
            }
            val parts = listOfNotNull(entry.releaseGroup, entry.releaseFormat)
                .map { it.trim() }
                .filter { it.isNotEmpty() }
            return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
        }

        /** 0 for the viewer's language, 1 for English, 2 for everything else. */
        fun rank(code: String, language: String?): Int {
            if (language != null && matches(code, language)) return 0
            return if (matches(code, "en")) 1 else 2
        }

        /**
         * The addon speaks ISO-639-2 (`eng`) while a stored preference is
         * usually ISO-639-1 (`en`), so either spelling being a prefix of the
         * other is the match they share.
         */
        fun matches(code: String, wanted: String): Boolean {
            val lhs = code.lowercase(Locale.ROOT)
            val rhs = wanted.lowercase(Locale.ROOT)
            if (lhs.length < 2 || rhs.length < 2) return false
            return lhs == rhs || lhs.startsWith(rhs) || rhs.startsWith(lhs)
        }

        /**
         * Legacy ISO-639-2/B codes the addon still emits and `Locale` no longer
         * resolves. Kept to the codes seen in real listings, so an unmapped code
         * stays visible rather than being silently mistranslated.
         */
        private val legacyAliases = mapOf(
            "pob" to "pt", // Brazilian Portuguese
            "scc" to "sr", // Serbian (old)
            "scr" to "hr", // Croatian (old)
            "mol" to "ro", // Moldavian
            "tgl" to "fil", // Tagalog
            "iw" to "he", // Hebrew (old)
            "in" to "id", // Indonesian (old)
            "ji" to "yi", // Yiddish (old)
        )

        fun displayName(code: String): String {
            if (code.isEmpty()) return "Subtitle"
            val lowered = code.lowercase(Locale.ROOT)
            // The alias has to win: `Locale` resolves `pob` back to itself, so
            // testing the raw code first would print "Pob" in the picker.
            for (candidate in listOfNotNull(legacyAliases[lowered], lowered)) {
                val name = Locale.forLanguageTag(candidate).getDisplayLanguage(Locale.ENGLISH)
                if (name.isNotBlank() && !name.equals(candidate, ignoreCase = true)) {
                    return name.replaceFirstChar { it.uppercase() }
                }
            }
            val base = lowered.take(2)
            if (base.length == 2) {
                val name = Locale.forLanguageTag(base).getDisplayLanguage(Locale.ENGLISH)
                if (name.isNotBlank() && !name.equals(base, ignoreCase = true)) {
                    return name.replaceFirstChar { it.uppercase() }
                }
            }
            return code.uppercase(Locale.ROOT)
        }

        private val JSON = Json { ignoreUnknownKeys = true; isLenient = true }
    }
}

private data class Ranked(val rank: Int, val offset: Int, val track: SubtitleTrack)

@Serializable
internal data class Cinemeta(val metas: List<CinemetaMeta>? = null)

@Serializable
internal data class CinemetaMeta(
    @SerialName("imdb_id") val imdbId: String? = null,
    val releaseInfo: String? = null,
)

@Serializable
internal data class Addon(val subtitles: List<AddonEntry>? = null)

@Serializable
internal data class AddonEntry(
    val url: String? = null,
    val lang: String? = null,
    val subtitleFileName: String? = null,
    val movieReleaseName: String? = null,
    val releaseGroup: String? = null,
    val releaseFormat: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
)
