package com.cinemacore.app.data

import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.Page
import com.cinemacore.app.domain.PlayInfo
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.Section
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject

/**
 * The bundled fallback used when the gateway is unreachable.
 *
 * Mirrors the iOS fixture's intent: the catalog is browsable so the UI never
 * lands on a blank screen, while the play URLs point at the reserved `.test`
 * TLD and therefore cannot play. A demo stream that silently played a random
 * public file would hide a real connectivity failure.
 */
class DemoCatalogRepository : CatalogRepository {
    override val sourceName: String
        get() = "Bundled demo"

    override val isLive: Boolean
        get() = false

    private val subjects = listOf(
        Subject(
            id = "demo-1",
            title = "The Last Projectionist",
            year = 2024,
            rating = 8.1,
            kind = "movie",
            synopsis = "A small-town projectionist keeps a dying cinema alive for one final season.",
            genres = listOf("Drama"),
            durationMinutes = 112,
            cast = listOf(
                com.cinemacore.app.domain.CastMember("Mara Voss", "Director"),
                com.cinemacore.app.domain.CastMember("Ilan Reeve", "Lead"),
            ),
        ),
        Subject(
            id = "demo-2",
            title = "Night Signal",
            year = 2023,
            rating = 7.4,
            kind = "series",
            synopsis = "A late-night radio host starts receiving calls from a town that no longer exists.",
            genres = listOf("Mystery", "Thriller"),
            seasonCount = 2,
            dubOptions = listOf(
                com.cinemacore.app.domain.Dub("demo-2", "Original Audio", "en", true),
                com.cinemacore.app.domain.Dub("demo-2-hi", "Hindi dub", "hi"),
            ),
        ),
        Subject(
            id = "demo-3",
            title = "Salt & Silver",
            year = 2025,
            rating = 7.9,
            kind = "movie",
            synopsis = "Two estranged sisters cross a salt flat to settle their father's estate.",
            genres = listOf("Drama", "Adventure"),
            durationMinutes = 98,
        ),
        Subject(
            id = "demo-4",
            title = "Orbital",
            year = 2022,
            rating = 6.8,
            kind = "series",
            synopsis = "The first hotel in low orbit has a very bad opening weekend.",
            genres = listOf("Sci-Fi", "Comedy"),
            seasonCount = 1,
        ),
        Subject(
            id = "demo-5",
            title = "Paper Lanterns",
            year = 2021,
            rating = 8.4,
            kind = "movie",
            synopsis = "A festival night in a city where every lantern carries a confession.",
            genres = listOf("Romance"),
            durationMinutes = 105,
        ),
    )

    override suspend fun home(): Page = Page(
        sections = listOf(
            Section("Featured", subjects.take(3)),
            Section("Continue the story", subjects.filter { it.isSeries }),
            Section("Tonight", listOf(subjects[3], subjects[4])),
        ),
    )

    override suspend fun search(query: String): List<Subject> {
        val needle = query.trim()
        if (needle.isEmpty()) return emptyList()
        return subjects.filter {
            it.title.contains(needle, ignoreCase = true) ||
                it.genres.any { genre -> genre.contains(needle, ignoreCase = true) }
        }
    }

    override suspend fun detail(id: String): Subject =
        subjects.firstOrNull { it.id == id } ?: throw CinemacoreError.NotFound

    override suspend fun seasons(subjectId: String): List<Season> {
        val subject = detail(subjectId)
        if (!subject.isSeries) return emptyList()
        return (1..subject.seasonCount.coerceAtLeast(1)).map { season ->
            Season(
                number = season,
                episodes = (1..4).map { number ->
                    Episode(
                        subjectId = subjectId,
                        season = season,
                        number = number,
                        title = "Episode $number",
                        durationSeconds = 42 * 60,
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
        detail(subjectId)
        val suffix = if (season != null && episode != null) "-s${season}e$episode" else ""
        return PlayInfo(
            streams = listOf(
                StreamRendition(
                    quality = "1080",
                    url = "https://demo.cinemacore.test/$subjectId$suffix.mp4",
                    size = "unknown",
                ),
            ),
        )
    }

    override suspend fun suggestions(query: String): List<String> {
        val needle = query.trim()
        if (needle.isEmpty()) return emptyList()
        return subjects
            .filter { it.title.contains(needle, ignoreCase = true) }
            .map { it.title }
    }
}
