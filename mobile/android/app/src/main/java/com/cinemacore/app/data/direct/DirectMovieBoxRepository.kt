package com.cinemacore.app.data.direct

import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.Page
import com.cinemacore.app.domain.PlayInfo
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.domain.SubtitleTrack
import java.net.URLEncoder
import kotlinx.coroutines.CancellationException

/**
 * The built-in source: MovieBox's own JSON API, signed on this device.
 *
 * This is the Android port of `MovieBoxRepository.swift` and the Go reference
 * implementation. It deliberately has no gateway dependency: the same signed
 * request shape and the same recovery order work with only the phone's network.
 *
 * Playback is resolved in four rungs, exactly like iOS:
 * 1. `/play-info`, with a `signCookie` manifest outranking the advertised URL;
 * 2. the UGC upload endpoints;
 * 3. the per-title resource listing;
 * 4. an honest failure.
 *
 * A decoy is never returned as a stream. The provider answers unofficial
 * clients with a short "please update" clip, and playing that would look like a
 * broken player rather than an unavailable title.
 */
class DirectMovieBoxRepository(
    private val session: MovieBoxSession,
) : CatalogRepository {

    override val sourceName: String = "MovieBox"

    override val isLive: Boolean = true

    /** Acquires the guest token during source resolution, before the first screen. */
    suspend fun warmUp() {
        session.guestLogin()
    }

    override suspend fun home(): Page {
        // The documented route is gone on the live cluster; tab-operating is
        // its replacement. Try both before the single ranked feed.
        bestEffort {
            homeRails(
                method = "POST",
                path = "/home/v2/get-list",
                body = """{"categoryId":1,"page":1,"pageSize":24}""",
            )
        }?.takeIf { !it.isEmpty }?.let { return it }

        bestEffort {
            homeRails(
                method = "GET",
                path = "/wefeed-mobile-bff/tab-operating?page=1&tabId=1&version=",
                body = null,
            )
        }?.takeIf { !it.isEmpty }?.let { return it }

        val daily = fetch(
            method = "POST",
            path = "/wefeed-mobile-bff/subject-api/daily-movie-rec",
            body = """{"page":1,"pageSize":20}""",
        )
        val subjects = MovieBoxWire.searchItems(daily)
        return Page(
            sections = if (subjects.isEmpty()) {
                emptyList()
            } else {
                listOf(com.cinemacore.app.domain.Section("Top Picks", subjects))
            },
        )
    }

    override suspend fun search(query: String): List<Subject> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val escaped = escapeJson(trimmed)
        val body = """{"keyword":"$escaped","q":"$escaped","type":0,"page":1,"pageSize":20}"""
        return MovieBoxWire.searchItems(
            fetch("POST", "/wefeed-mobile-bff/subject-api/search", body),
        )
    }

    override suspend fun detail(id: String): Subject {
        val raw = fetch(
            "GET",
            "/wefeed-mobile-bff/subject-api/get?subjectId=${encode(id)}",
            null,
        )
        return MovieBoxWire.detailSubject(raw) ?: throw CinemacoreError.Upstream("Unknown title.")
    }

    override suspend fun seasons(subjectId: String): List<Season> {
        val raw = fetch(
            "GET",
            "/wefeed-mobile-bff/subject-api/season-info?subjectId=${encode(subjectId)}",
            null,
        )
        val parsed = MovieBoxWire.seasons(raw)
        if (parsed.isEmpty()) return emptyList()

        // Only the resource listing carries episode durations. It is a best
        // effort: a season list missing runtimes still navigates.
        val durations = bestEffort { episodeDurations(subjectId) }.orEmpty()
        return parsed.map { season ->
            Season(
                number = season.number,
                episodes = season.episodes.map { episode ->
                    val seconds = durations[episodeKey(season.number, episode.number)]
                    Episode(
                        subjectId = subjectId,
                        season = episode.season,
                        number = episode.number,
                        title = episode.title,
                        durationSeconds = seconds?.takeIf { it > 0 },
                    )
                },
            )
        }
    }

    override suspend fun play(
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): PlayInfo {
        var path = "/wefeed-mobile-bff/subject-api/play-info?subjectId=${encode(subjectId)}"
        if ((season ?: 0) > 0) path += "&se=$season"
        if ((episode ?: 0) > 0) path += "&ep=$episode"

        val rawPlay = fetch("GET", path, null)
        val rawStreams = MovieBoxWire.playStreams(rawPlay)
        primaryStreams(rawStreams)?.let { primary ->
            return withCaptions(primary, subjectId, season, episode)
        }

        val ugc = bestEffort { ugcBypass(subjectId, season, episode) }
        if (ugc != null && ugc.streams.isNotEmpty()) {
            return withCaptions(ugc, subjectId, season, episode)
        }

        val resources = bestEffort { resourceStream(subjectId, season, episode) }
        if (resources != null && resources.streams.isNotEmpty()) {
            return withCaptions(resources, subjectId, season, episode)
        }

        throw CinemacoreError.Upstream(
            if (rawStreams.isEmpty()) {
                "No playback source for this title."
            } else {
                "This title is not playable in your region."
            },
        )
    }

    override suspend fun suggestions(query: String): List<String> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val raw = fetch(
            "GET",
            "/wefeed-mobile-bff/subject-api/search-suggest?keyword=${encode(trimmed)}",
            null,
        )
        return MovieBoxWire.suggestions(raw)
    }

    // MARK: - Rungs 1-2

    private fun primaryStreams(streams: List<RawStream>): PlayInfo? {
        val renditions = mutableListOf<RecoveredRendition>()
        val seen = mutableSetOf<String>()
        var resolvedURL: String? = null

        for (stream in streams) {
            if (!isVideoStream(stream.format, stream.codecName, stream.url)) continue
            // The signed cookie carries the real CDN prefix and outranks the
            // advertised URL. Empty cookies fall back to a direct URL.
            val target = bestEffortValue {
                MovieBoxRecovery.manifestFromSignCookie(stream.signCookie.orEmpty())
            } ?: stream.url.takeIf { MovieBoxRecovery.isUsable(it) }
            if (target == null) continue
            if (resolvedURL == null) resolvedURL = target

            val labels = MovieBoxRecovery.splitList(stream.resolutions.orEmpty())
                .ifEmpty { listOf("Auto") }
            for (label in labels) {
                val key = "$label\u0000$target"
                if (seen.add(key)) {
                    renditions += RecoveredRendition(
                        quality = label,
                        url = target,
                        size = stream.size,
                        cookie = stream.signCookie,
                        codec = stream.codecName,
                    )
                }
            }
        }

        if (resolvedURL == null) return null
        return PlayInfo(streams = rank(renditions), subtitles = emptyList())
    }

    // MARK: - Rung 3: UGC

    private suspend fun ugcBypass(
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): PlayInfo {
        val first = MovieBoxWire.ugcFirst(
            fetch(
                "GET",
                "/wefeed-mobile-bff/ugc/video/first-by-subject?subjectId=${encode(subjectId)}",
                null,
            ),
        ) ?: return PlayInfo(emptyList())

        var resources: List<UgcResource> = emptyList()
        first.collectionId?.takeIf { it.isNotBlank() }?.let { collectionId ->
            resources = ugcCollection(collectionId, season, episode)
        }

        if (resources.isEmpty() && (episode ?: 0) <= 1 && first.ugcVideoId.isNotBlank()) {
            resources = MovieBoxWire.ugcDownloadResources(
                fetch(
                    "GET",
                    "/wefeed-mobile-bff/ugc/video/download?ugcVideoId=${encode(first.ugcVideoId)}",
                    null,
                ),
            )
        }

        val renditions = mutableListOf<RecoveredRendition>()
        val seen = mutableSetOf<String>()
        for (resource in resources) {
            if (!MovieBoxRecovery.isUsable(resource.url)) continue
            if (!isVideoStream(null, resource.codecName, resource.url)) continue
            for (label in MovieBoxRecovery.splitList(resource.resolutions.orEmpty())) {
                val key = "$label\u0000${resource.url}"
                if (seen.add(key)) {
                    renditions += RecoveredRendition(
                        quality = label,
                        url = resource.url,
                        size = resource.size,
                        cookie = resource.signCookie,
                        codec = resource.codecName,
                    )
                }
            }
        }
        return PlayInfo(streams = rank(renditions), subtitles = emptyList())
    }

    private suspend fun ugcCollection(
        collectionId: String,
        season: Int?,
        episode: Int?,
    ): List<UgcResource> {
        val items = MovieBoxWire.ugcCollectionItems(
            fetch(
                "GET",
                "/wefeed-mobile-bff/ugc/collection/download-list" +
                    "?collectionId=${encode(collectionId)}&page=1&perPage=50",
                null,
            ),
        )
        val wantedSeason = maxOf(season ?: 1, 1)
        val wantedEpisode = maxOf(episode ?: 1, 1)
        var bare: List<UgcResource>? = null

        for (item in items) {
            when (
                MovieBoxRecovery.ugcMarkerRank(
                    epTitle = item.epTitle,
                    title = item.title,
                    season = wantedSeason,
                    episode = wantedEpisode,
                )
            ) {
                2 -> return item.resources
                1 -> if (bare == null) bare = item.resources
            }
        }
        bare?.let { return it }

        val marked = items.any {
            MovieBoxRecovery.ugcHasEpisodeMarker(it.epTitle, it.title)
        }
        if (wantedEpisode == 1 && !marked) return items.firstOrNull()?.resources.orEmpty()
        return emptyList()
    }

    // MARK: - Rung 4: resource listing

    private suspend fun resourceStream(
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): PlayInfo {
        val listing = resources(subjectId, season, episode)
        val items = MovieBoxRecovery.resourcesForEpisode(
            items = listing,
            season = season,
            episode = episode,
            seasonOf = { it.se },
            episodeOf = { it.ep },
        )

        val renditions = mutableListOf<RecoveredRendition>()
        val seen = mutableSetOf<String>()
        for (item in items) {
            if (!MovieBoxRecovery.isUsable(item.resourceLink)) continue
            if (!isVideoStream(null, item.codecName, item.resourceLink)) continue
            val label = item.resolution.toString()
            val key = "$label\u0000${item.resourceLink}"
            if (seen.add(key)) {
                renditions += RecoveredRendition(
                    quality = label,
                    url = item.resourceLink,
                    size = item.size,
                    codec = item.codecName,
                )
            }
        }
        return PlayInfo(streams = rank(renditions), subtitles = emptyList())
    }

    /**
     * Pages the per-title resource listing. The live cluster ignores `se`/`ep`
     * here, so callers filter locally; a bounded pager cannot loop.
     */
    private suspend fun resources(
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): List<RawResource> {
        var path = "/wefeed-mobile-bff/subject-api/resource?subjectId=${encode(subjectId)}"
        if ((season ?: 0) > 0) path += "&se=$season"
        if ((episode ?: 0) > 0) path += "&ep=$episode"

        val out = mutableListOf<RawResource>()
        for (page in 1..MovieBoxRecovery.resourcePageLimit) {
            val raw = fetch("GET", "$path&page=$page&perPage=50", null)
            val (items, hasMore) = MovieBoxWire.resources(raw)
            out += items
            if (!hasMore) break
        }
        return out
    }

    private suspend fun episodeDurations(subjectId: String): Map<String, Int> {
        val items = resources(subjectId, season = null, episode = null)
        val durations = mutableMapOf<String, Int>()
        for (item in items) {
            if (item.duration <= 0) continue
            durations.putIfAbsent(episodeKey(item.se, item.ep), item.duration)
        }
        return durations
    }

    // MARK: - Captions

    private suspend fun withCaptions(
        info: PlayInfo,
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): PlayInfo {
        val tracks = bestEffort { subtitleTracks(subjectId, season, episode) }.orEmpty()
        return if (tracks.isEmpty()) info else info.copy(subtitles = tracks)
    }

    private suspend fun subtitleTracks(
        subjectId: String,
        season: Int?,
        episode: Int?,
    ): List<SubtitleTrack> {
        val detail = MovieBoxWire.detailSubject(
            fetch(
                "GET",
                "/wefeed-mobile-bff/subject-api/get?subjectId=${encode(subjectId)}",
                null,
            ),
        ) ?: return emptyList()
        val resourceId = detail.resourceDetectors.firstOrNull()?.resourceId
            ?.takeIf { it.isNotBlank() }
            ?: return emptyList()

        var path = "/wefeed-mobile-bff/subject-api/get-ext-captions" +
            "?subjectId=${encode(subjectId)}&resourceId=${encode(resourceId)}"
        if ((season ?: 0) > 0) path += "&se=$season"
        if ((episode ?: 0) > 0) path += "&episode=$episode"

        return MovieBoxWire.captions(fetch("GET", path, null))
            .mapNotNull { caption ->
                val url = MovieBoxWire.httpsURL(caption.url) ?: return@mapNotNull null
                SubtitleTrack(
                    language = firstNonBlank(caption.lanName, caption.lan, "Subtitles"),
                    url = url,
                    format = captionFormat(url),
                )
            }
    }

    // MARK: - Home

    private suspend fun homeRails(
        method: String,
        path: String,
        body: String?,
    ): Page = MovieBoxWire.homePage(fetch(method, path, body))

    // MARK: - Transport

    private suspend fun fetch(
        method: String,
        path: String,
        body: String?,
    ): String = try {
        String(session.call(method, path, body), Charsets.UTF_8)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: MovieBoxSessionException) {
        throw error.toDomain()
    }

    private fun MovieBoxSessionException.toDomain(): CinemacoreError = when (this) {
        is MovieBoxSessionException.NoHosts -> CinemacoreError.Offline
        is MovieBoxSessionException.Transport ->
            if (timedOut) CinemacoreError.TimedOut else CinemacoreError.Offline
        is MovieBoxSessionException.Http ->
            if (status == 404) {
                CinemacoreError.NotFound
            } else {
                CinemacoreError.Http(status, null, body)
            }
        is MovieBoxSessionException.BadResponse ->
            CinemacoreError.Upstream("The provider returned an unreadable response.")
    }

    private inline fun <T> bestEffort(block: () -> T): T? = try {
        block()
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: CinemacoreError) {
        null
    }

    private inline fun <T> bestEffortValue(block: () -> T?): T? = try {
        block()
    } catch (_: Exception) {
        null
    }

    private fun rank(renditions: List<RecoveredRendition>): List<StreamRendition> =
        renditions
            .sortedByDescending { MovieBoxRecovery.resolutionRank(it.quality) }
            .map { it.toStreamRendition() }

    private fun episodeKey(season: Int, episode: Int): String = "$season-$episode"

    private fun encode(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private fun escapeJson(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"")

    private fun firstNonBlank(vararg values: String?): String =
        values.firstOrNull { !it.isNullOrBlank() }.orEmpty()

    private fun captionFormat(rawURL: String): String {
        val path = rawURL.substringBefore('?').substringBefore('#')
        val filename = path.substringAfterLast('/')
        val extension = filename.substringAfterLast('.', "").lowercase()
        return extension.ifEmpty { "srt" }
    }

    /**
     * Soundtracks are listed beside video renditions. Handing one to ExoPlayer
     * produces a black picture with audio, so drop it before a rendition
     * exists. Unlike iOS, Android can play DASH, so `.mpd` is not rejected here.
     */
    private fun isVideoStream(format: String?, codec: String?, url: String?): Boolean {
        if (format.isAudioOnlyFormat() || codec.isAudioOnlyCodec()) return false
        val extension = url
            ?.substringBefore('?')
            ?.substringBefore('#')
            ?.substringAfterLast('.', "")
            ?.lowercase()
            .orEmpty()
        return extension !in AUDIO_EXTENSIONS
    }

    private fun String?.isAudioOnlyFormat(): Boolean {
        val compact = compact(this) ?: return false
        return compact in AUDIO_FORMATS
    }

    private fun String?.isAudioOnlyCodec(): Boolean {
        val compact = compact(this) ?: return false
        return compact in AUDIO_CODECS
    }

    private fun compact(raw: String?): String? =
        raw?.lowercase()?.filter { it.isLetterOrDigit() }?.takeIf { it.isNotEmpty() }

    private companion object {
        val AUDIO_EXTENSIONS = setOf(
            "mp3", "m4a", "m4b", "aac", "ac3", "eac3", "flac", "opus", "ogg",
            "oga", "wav", "aif", "aiff", "wma", "amr", "dts",
        )

        val AUDIO_FORMATS = setOf(
            "mp3", "m2a", "m4a", "m4b", "aac", "flac", "opus", "ogg", "oga",
            "wav", "aif", "aiff", "wma", "amr", "ac3", "eac3", "ec3", "dts",
            "mka", "audio",
        )

        val AUDIO_CODECS = setOf(
            "mp2", "mp3", "mp4a", "aac", "heaac", "heaacv1", "heaacv2", "opus",
            "vorbis", "flac", "alac", "ac3", "eac3", "ec3", "dts", "dtshd",
            "dtsx", "mlp", "truehd", "pcm", "lpcm", "amr", "wmav2",
        )
    }
}
