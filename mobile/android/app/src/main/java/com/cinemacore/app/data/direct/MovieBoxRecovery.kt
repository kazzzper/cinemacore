package com.cinemacore.app.data.direct

import com.cinemacore.app.domain.StreamRendition
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Pure stream-recovery rules for the direct MovieBox source.
 *
 * A port of `StreamRecovery.swift` and the UGC/resource matchers in
 * `MovieBoxRepository.swift`. The gateway answers unofficial clients with a
 * 23-second "please update your app" decoy, so a decoy is never returned as a
 * stream: callers fail honestly when every rung is exhausted.
 */
object MovieBoxRecovery {
    /** The only media header besides the rendition cookie. */
    const val streamUserAgent = "ExoPlayerLib/2.19.1"

    /** Bounds resource pagination so a broken pager cannot loop. */
    const val resourcePageLimit = 20

    private const val base64Alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    private val decoyMarkers = listOf(
        "1c7de0bd3393702d9191801f15f88f8d",
        "9a0461bc39da389663bf3dbb17091d3f",
        "b164fbfb43",
        "/notice.mp4",
        "please_update",
        "update_app",
    )

    private val policyJson = Json { ignoreUnknownKeys = true }

    /**
     * Whether [raw] is the anti-piracy placeholder instead of content.
     *
     * The known slugs, `/notice.mp4` and the `macdn.aoneroom.com/other/` shape
     * come from the Rust TUI; `please_update`/`update_app` come from the Kotlin
     * proxy.
     */
    fun isDecoy(raw: String): Boolean {
        val lower = raw.lowercase()
        if (decoyMarkers.any { lower.contains(it) }) return true
        return lower.contains("macdn.aoneroom.com") && lower.contains("/other/")
    }

    fun isUsable(raw: String): Boolean =
        raw.isNotEmpty() && raw.startsWith("http") && !isDecoy(raw)

    /**
     * Decodes the CDN's signed cookie into a real manifest URL, or `null` when
     * it carries only a decoy or no usable prefix.
     *
     * The cookie is a `;`-separated key=value list; `urlprefix=` holds a
     * base64url base path, while CloudFront keeps the same prefix inside a
     * signed policy. A `/dash/` tree gets `index.mpd`, any other http prefix
     * gets `index.m3u8`.
     */
    fun manifestFromSignCookie(cookie: String): String? {
        for (part in cookie.split(';')) {
            val field = part.trim()
            val prefixAt = field.indexOf("urlprefix=")
            if (prefixAt >= 0) {
                val token = field.substring(prefixAt + "urlprefix=".length)
                    .substringBefore(':')
                    .substringBefore(';')
                val decoded = decodeBase64(token)
                if (decoded != null && !isDecoy(decoded)) {
                    dashManifest(decoded)?.let { return it }
                    hlsManifest(decoded)?.let { return it }
                }
            }
            if (field.startsWith("CloudFront-Policy=")) {
                val policy = field.substring("CloudFront-Policy=".length)
                val resource = decodeBase64(cloudFrontAlphabet(policy))
                    ?.let(::cloudFrontResource)
                if (resource != null && !isDecoy(resource)) {
                    dashManifest(resource)?.let { return it }
                }
            }
        }
        return null
    }

    /** Accepts the standard and URL-safe alphabets and restores omitted padding. */
    internal fun decodeBase64(raw: String): String? {
        var value = raw.trim()
        if (value.isEmpty()) return null
        value = value.replace('-', '+').replace('_', '/')
        val pad = (4 - value.length % 4) % 4
        if (pad > 0) value += "=".repeat(pad)
        val bytes = decodeBase64Bytes(value) ?: return null
        return decodeUtf8(bytes)
    }

    /** Only a `/dash/` tree under an absolute http(s) prefix resolves. */
    internal fun dashManifest(raw: String): String? {
        var base = raw.trim()
        while (base.endsWith("*") || base.endsWith("/")) {
            base = base.dropLast(1)
        }
        if (!base.startsWith("http://") && !base.startsWith("https://")) return null
        if (!base.contains("/dash/")) return null
        return "$base/index.mpd"
    }

    internal fun hlsManifest(raw: String): String? {
        val value = raw.trim()
        if (!value.startsWith("http://") && !value.startsWith("https://")) return null
        return if (value.endsWith("/")) value + "index.m3u8" else "$value/index.m3u8"
    }

    /** Restores CloudFront's non-standard policy alphabet before decoding. */
    internal fun cloudFrontAlphabet(raw: String): String =
        raw.trim()
            .replace('-', '+')
            .replace('_', '=')
            .replace('~', '/')

    /** `Statement[0].Resource` out of a decoded policy. */
    internal fun cloudFrontResource(policy: String): String? = try {
        policyJson.decodeFromString(CloudFrontPolicy.serializer(), policy)
            .Statement
            .firstOrNull()
            ?.Resource
            ?.takeIf { it.isNotEmpty() }
    } catch (_: SerializationException) {
        null
    }

    /**
     * Expands one stream entry into one rendition per advertised resolution,
     * carrying that entry's size, cookie and declared codec.
     *
     * The codec rides on [RecoveredRendition] because the domain
     * [StreamRendition] has no codec field yet.
     */
    fun renditions(
        url: String,
        resolutions: String,
        size: String? = null,
        cookie: String? = null,
        codec: String? = null,
    ): List<RecoveredRendition> = splitList(resolutions).map { label ->
        RecoveredRendition(
            quality = label,
            url = url,
            size = size,
            cookie = cookie,
            codec = codec,
        )
    }

    fun splitList(raw: String): List<String> {
        if (raw.isEmpty()) return emptyList()
        return raw.split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
    }

    /**
     * Sort key so `1080` outranks `720` rather than sorting lexically. Live
     * labels arrive without a trailing `p`.
     */
    fun resolutionRank(label: String): Int {
        val lowered = label.lowercase().trim()
        val digits = lowered.takeWhile { it.isNumberLike() }
        // Swift `Int` only parses ASCII, so a mixed Unicode label ranks 0.
        if (digits.any { it !in '0'..'9' }) return 0
        return digits.toIntOrNull() ?: 0
    }

    /** Media headers: `User-Agent` plus the rendition cookie, never a signing header. */
    fun headers(cookie: String?): Map<String, String> = buildMap {
        put("User-Agent", streamUserAgent)
        if (!cookie.isNullOrEmpty()) put("Cookie", cookie)
    }

    /**
     * How strongly one UGC item names the requested episode: `2` for a fully
     * qualified `S{season}EP{episode}`, `1` for a bare `E{episode}`, `0`
     * otherwise.
     *
     * `epTitle` is the dedicated marker field: when it names an episode, a
     * contradictory title must not lend that item a different number.
     */
    fun ugcMarkerRank(
        epTitle: String?,
        title: String?,
        season: Int,
        episode: Int,
    ): Int {
        val primary = epTitle.orEmpty().uppercase()
        if (hasEpisodeMarkerToken(primary)) {
            return markerRank(primary, season, episode)
        }
        val fallback = title.orEmpty().uppercase()
        if (!hasEpisodeMarkerToken(fallback)) return 0
        return markerRank(fallback, season, episode)
    }

    /**
     * Whether any field carries an episode marker at all.
     *
     * Episode 1 may fall back to the first item, but only for a collection with
     * no markers: a marked collection that does not name episode 1 is a
     * mismatch, not an invitation to play the first episode.
     */
    fun ugcHasEpisodeMarker(epTitle: String?, title: String?): Boolean =
        hasEpisodeMarkerToken(epTitle.orEmpty().uppercase()) ||
            hasEpisodeMarkerToken(title.orEmpty().uppercase())

    /**
     * Whether one resource belongs to the requested episode.
     *
     * The live cluster ignores `se`/`ep` on the listing endpoint, so callers
     * filter locally. A request with no episode keeps every resource; a season
     * narrows the result only when it is positive.
     */
    fun resourceMatchesEpisode(
        itemSeason: Int,
        itemEpisode: Int,
        season: Int?,
        episode: Int?,
    ): Boolean {
        if (episode == null || episode <= 0) return true
        if (itemEpisode != episode) return false
        if (season == null || season <= 0) return true
        return itemSeason == season
    }

    /** [resourceMatchesEpisode] over a listing whose season/episode accessors differ per wire type. */
    fun <T> resourcesForEpisode(
        items: List<T>,
        season: Int?,
        episode: Int?,
        seasonOf: (T) -> Int,
        episodeOf: (T) -> Int,
    ): List<T> {
        if (episode == null || episode <= 0) return items
        return items.filter { item ->
            resourceMatchesEpisode(
                itemSeason = seasonOf(item),
                itemEpisode = episodeOf(item),
                season = season,
                episode = episode,
            )
        }
    }

    private fun markerRank(hay: String, season: Int, episode: Int): Int {
        if (containsNumberToken(hay, "S${season}EP$episode", digitBefore = false)) return 2
        if (containsNumberToken(hay, "E$episode", digitBefore = true)) return 1
        return 0
    }

    private fun hasEpisodeMarkerToken(hay: CharSequence): Boolean {
        var index = 0
        while (index < hay.length) {
            if (hay[index] == 'E') {
                var next = index + 1
                // `S1EP2` spells its marker with the E and P adjacent.
                if (next < hay.length && hay[next] == 'P') next++
                if (next < hay.length && hay[next].isNumberLike()) return true
            }
            index++
        }
        return false
    }

    /**
     * `true` when [marker] is a complete token: a longer number after it names
     * a different episode (`E1` inside `S1EP10`), and a preceding letter means
     * it is part of a word. A digit may precede a bare `E` because `S1E2`
     * spells the season directly before it.
     */
    private fun containsNumberToken(
        hay: CharSequence,
        marker: String,
        digitBefore: Boolean,
    ): Boolean {
        var search = 0
        while (search <= hay.length - marker.length) {
            val at = hay.indexOf(marker, search)
            if (at < 0) return false
            val beforeOk = if (at == 0) {
                true
            } else {
                val before = hay[at - 1]
                digitBefore || (!before.isLetter() && !before.isNumberLike())
            }
            val after = at + marker.length
            val afterOk = after == hay.length || !hay[after].isNumberLike()
            if (beforeOk && afterOk) return true
            search = after
        }
        return false
    }

    private fun Char.isNumberLike(): Boolean = when (category) {
        CharCategory.DECIMAL_DIGIT_NUMBER,
        CharCategory.LETTER_NUMBER,
        CharCategory.OTHER_NUMBER,
        -> true
        else -> false
    }

    private fun decodeBase64Bytes(value: String): ByteArray? {
        val padding = when {
            value.endsWith("==") -> 2
            value.endsWith("=") -> 1
            else -> 0
        }
        val contentLength = value.length - padding
        if (contentLength < 0 || contentLength % 4 == 1) return null
        val out = ByteArray(contentLength * 3 / 4)
        var buffer = 0
        var bits = 0
        var written = 0
        for (index in 0 until contentLength) {
            val digit = base64Alphabet.indexOf(value[index])
            if (digit < 0) return null
            buffer = (buffer shl 6) or digit
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out[written++] = ((buffer shr bits) and 0xFF).toByte()
            }
        }
        return out
    }

    private fun decodeUtf8(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }
}

/** One resolution of a recovered stream, before it is mapped to the domain. */
data class RecoveredRendition(
    val quality: String,
    val url: String,
    val size: String? = null,
    val cookie: String? = null,
    val codec: String? = null,
) {
    fun toStreamRendition(): StreamRendition = StreamRendition(
        quality = quality,
        url = url,
        size = size,
        cookie = cookie,
    )
}

@Serializable
private data class CloudFrontPolicy(
    val Statement: List<CloudFrontStatement> = emptyList(),
)

@Serializable
private data class CloudFrontStatement(
    val Resource: String? = null,
)
