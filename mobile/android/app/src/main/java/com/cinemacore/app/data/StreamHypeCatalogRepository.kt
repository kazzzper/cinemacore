package com.cinemacore.app.data

import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.Page
import com.cinemacore.app.domain.PlayInfo
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.StreamKind
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * StreamHype: TMDB catalog + the vidsrc-family embed player.
 *
 * This is a direct port of the iOS `StreamHypeCatalogRepository` and the Go
 * adapter it mirrors. Playback is always `kind: web`; never hand this URL to
 * Media3 or the download queue.
 */
class StreamHypeCatalogRepository(
    apiKey: String,
    private val http: OkHttpClient = defaultClient(),
) : CatalogRepository {
    private val key = apiKey.trim()
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
        coerceInputValues = true
    }

    override val sourceName: String
        get() = "StreamHype"

    override val isLive: Boolean
        get() = true

    override suspend fun home(): Page {
        val rails = listOf(
            Rail("Trending Now", "/trending/movie/week", MediaType.MOVIE),
            Rail("Popular Movies", "/movie/popular", MediaType.MOVIE),
            Rail("Popular TV", "/tv/popular", MediaType.TV),
            Rail("Top Rated", "/movie/top_rated", MediaType.MOVIE),
        )
        val sections = rails.mapNotNull { rail ->
            runCatching { list(rail.media, rail.path) }.getOrNull()
                ?.takeIf { it.isNotEmpty() }
                ?.let { PageSection(rail.title, it) }
        }
        if (sections.isEmpty()) {
            throw CinemacoreError.Upstream("StreamHype catalog unavailable.")
        }
        return Page(sections.map { com.cinemacore.app.domain.Section(it.title, it.items) })
    }

    override suspend fun search(query: String): List<Subject> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val page: TmdbList<TmdbEntry> = get("/search/multi", mapOf("query" to trimmed))
        return page.results.mapNotNull { entry ->
            val media = entry.mediaTypeOrNull ?: return@mapNotNull null
            media.subject(entry)
        }
    }

    override suspend fun suggestions(query: String): List<String> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        val page: TmdbList<TmdbEntry> = get("/search/multi", mapOf("query" to trimmed))
        return page.results.mapNotNull { entry ->
            val media = entry.mediaTypeOrNull ?: return@mapNotNull null
            media.title(entry.title, entry.name).takeIf { it.isNotBlank() }
        }
    }

    override suspend fun detail(id: String): Subject {
        val ref = SubjectId.parse(id) ?: throw CinemacoreError.Upstream("Not a StreamHype title.")
        val entry: TmdbDetail = get("/${ref.media.value}/${ref.tmdb}")
        return Subject(
            id = id,
            title = ref.media.title(entry.title, entry.name),
            poster = image(entry.posterPath),
            year = year(entry.releaseDate ?: entry.firstAirDate),
            rating = entry.voteAverage,
            kind = ref.media.kindLabel,
            synopsis = entry.overview,
            genres = entry.genres.orEmpty().mapNotNull { it.name },
            durationMinutes = entry.runtime,
            seasonCount = ref.media.seasonCount(entry.seasons),
        )
    }

    override suspend fun seasons(subjectId: String): List<Season> {
        val ref = SubjectId.parse(subjectId) ?: return emptyList()
        if (ref.media != MediaType.TV) return emptyList()
        val detail: TmdbDetail = get("/tv/${ref.tmdb}")
        val numbers = detail.seasons.orEmpty()
            .filter { it.seasonNumber > 0 && it.episodeCount > 0 }
            .map { it.seasonNumber }
        return numbers.map { number ->
            val season: TmdbDetail = get("/tv/${ref.tmdb}/season/$number")
            Season(
                number = number,
                episodes = season.episodes.orEmpty().mapNotNull { ep ->
                    if (ep.episodeNumber <= 0) {
                        null
                    } else {
                        Episode(
                            subjectId = subjectId,
                            season = number,
                            number = ep.episodeNumber,
                            title = ep.name,
                            durationSeconds = ep.runtime?.times(60),
                        )
                    }
                },
            )
        }
    }

    override suspend fun play(subjectId: String, season: Int?, episode: Int?): PlayInfo {
        val ref = SubjectId.parse(subjectId) ?: throw CinemacoreError.Upstream("Not a StreamHype title.")
        val url = embedUrl(ref, season, episode)
        return PlayInfo(
            streams = listOf(
                StreamRendition(
                    quality = "Auto",
                    url = url,
                    kind = StreamKind.WEB,
                ),
            ),
            subtitles = emptyList(),
        )
    }

    private suspend fun list(media: MediaType, path: String): List<Subject> {
        val page: TmdbList<TmdbEntry> = get(path)
        return page.results
            .filter { it.mediaTypeRaw == null || it.mediaTypeOrNull == media }
            .map { media.subject(it) }
    }

    private suspend inline fun <reified T> get(
        path: String,
        extra: Map<String, String> = emptyMap(),
    ): T {
        if (key.isBlank()) {
            throw CinemacoreError.Upstream("No TMDB key is configured.")
        }
        val url = HttpUrl.Builder()
            .scheme("https")
            .host("api.themoviedb.org")
            .addPathSegments("3${path.trimStart('/')}")
            .addQueryParameter("api_key", key)
            .apply { extra.forEach { (name, value) -> addQueryParameter(name, value) } }
            .build()
        val request = Request.Builder().url(url).header("Accept", "application/json").get().build()
        try {
            http.newCall(request).execute().use { response ->
                if (response.code == 404) {
                    throw CinemacoreError.NotFound
                }
                if (!response.isSuccessful) {
                    throw CinemacoreError.Http(response.code)
                }
                val body = response.body?.string() ?: throw CinemacoreError.Decoding("Empty TMDB body.")
                return json.decodeFromString<T>(body)
            }
        } catch (error: CinemacoreError) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (error: SocketTimeoutException) {
            throw CinemacoreError.TimedOut
        } catch (error: SerializationException) {
            throw CinemacoreError.Decoding(error.message)
        } catch (error: IOException) {
            throw CinemacoreError.Offline
        } catch (error: Exception) {
            throw CinemacoreError.Unknown(error.message)
        }
    }

    private data class Rail(val title: String, val path: String, val media: MediaType)

    private data class PageSection(val title: String, val items: List<Subject>)

    enum class MediaType(val value: String, val kindLabel: String) {
        MOVIE("movie", "movie"),
        TV("tv", "series"),
        ;

        fun title(title: String?, name: String?): String =
            if (this == TV) name ?: title.orEmpty() else title ?: name.orEmpty()

        fun seasonCount(seasons: List<TmdbSeason>?): Int {
            if (this != TV) return 1
            return seasons.orEmpty().count { it.seasonNumber > 0 }
        }

        fun subject(entry: TmdbEntry): Subject = Subject(
            id = "tmdb-$value-${entry.id}",
            title = title(entry.title, entry.name),
            poster = image(entry.posterPath),
            year = year(entry.releaseDate ?: entry.firstAirDate),
            rating = entry.voteAverage,
            kind = kindLabel,
            synopsis = entry.overview,
        )
    }

    data class SubjectId(val tmdb: Int, val media: MediaType) {
        companion object {
            fun parse(raw: String): SubjectId? {
                val parts = raw.split("-")
                if (parts.size != 3 || parts[0] != "tmdb") return null
                val media = MediaType.entries.firstOrNull { it.value == parts[1] } ?: return null
                val tmdb = parts[2].toIntOrNull()?.takeIf { it > 0 } ?: return null
                return SubjectId(tmdb, media)
            }
        }
    }

    @Serializable
    data class TmdbList<T>(val results: List<T> = emptyList())

    @Serializable
    data class TmdbEntry(
        val id: Int,
        @SerialName("media_type") val mediaTypeRaw: String? = null,
        val title: String? = null,
        val name: String? = null,
        val overview: String? = null,
        @SerialName("poster_path") val posterPath: String? = null,
        @SerialName("vote_average") val voteAverage: Double? = null,
        @SerialName("release_date") val releaseDate: String? = null,
        @SerialName("first_air_date") val firstAirDate: String? = null,
    ) {
        val mediaTypeOrNull: MediaType?
            get() = mediaTypeRaw?.let { raw -> MediaType.entries.firstOrNull { it.value == raw } }
    }

    @Serializable
    data class TmdbDetail(
        val id: Int? = null,
        val title: String? = null,
        val name: String? = null,
        val overview: String? = null,
        @SerialName("poster_path") val posterPath: String? = null,
        @SerialName("vote_average") val voteAverage: Double? = null,
        val runtime: Int? = null,
        @SerialName("release_date") val releaseDate: String? = null,
        @SerialName("first_air_date") val firstAirDate: String? = null,
        val genres: List<TmdbGenre>? = null,
        val seasons: List<TmdbSeason>? = null,
        val episodes: List<TmdbEpisode>? = null,
    )

    @Serializable
    data class TmdbGenre(val name: String? = null)

    @Serializable
    data class TmdbSeason(
        @SerialName("season_number") val seasonNumber: Int = 0,
        @SerialName("episode_count") val episodeCount: Int = 0,
    )

    @Serializable
    data class TmdbEpisode(
        @SerialName("episode_number") val episodeNumber: Int = 0,
        val name: String? = null,
        val runtime: Int? = null,
    )

    companion object {
        const val PUBLIC_API_KEY = "90b2cae8d7161e8ba0f3836240d7d352"
        private const val EMBED_BASE = "https://screenfetch4.cyou/"
        private const val ATTRIBUTION = "streamhype.net"
        private const val IMAGE_BASE = "https://image.tmdb.org/t/p/w780"

        /** User setting first, then environment, then the published key. */
        fun resolveApiKey(userSetting: String?, environment: String?, fallback: String): String =
            listOf(userSetting, environment, fallback)
                .firstOrNull { !it.isNullOrBlank() }
                ?.trim()
                .orEmpty()

        fun image(path: String?): String? =
            path?.takeIf { it.isNotBlank() }?.let { IMAGE_BASE + it }

        fun year(date: String?): Int? =
            date?.takeIf { it.length >= 4 }?.substring(0, 4)?.toIntOrNull()

        fun embedUrl(ref: SubjectId, season: Int?, episode: Int?): String {
            val builder = EMBED_BASE.toHttpUrl().newBuilder()
                .addPathSegments("embed/${ref.media.value}")
                .addQueryParameter("tmdb", ref.tmdb.toString())
                .addQueryParameter("o", ATTRIBUTION)
            if (ref.media == MediaType.TV) {
                builder.addQueryParameter("season", (season ?: 1).coerceAtLeast(1).toString())
                builder.addQueryParameter("episode", (episode ?: 1).coerceAtLeast(1).toString())
            }
            return builder.build().toString()
        }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}
