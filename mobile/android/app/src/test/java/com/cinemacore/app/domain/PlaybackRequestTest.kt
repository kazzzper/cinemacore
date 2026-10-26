package com.cinemacore.app.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackRequestTest {
    private fun download(
        season: Int? = null,
        episode: Int? = null,
        episodeTitle: String? = null,
    ) = DownloadItem(
        id = "download-1",
        subjectId = "tmdb-tv-1399",
        title = "Game of Thrones",
        poster = "https://image.example/poster.jpg",
        season = season,
        episode = episode,
        episodeTitle = episodeTitle,
        quality = "1080p",
        remoteUrl = "https://cdn.example/episode.mp4",
        createdAt = 1_000L,
        updatedAt = 2_000L,
        fileName = "tmdb-tv-1399-s2e5.mp4",
    )

    private fun resume(
        season: Int? = null,
        episode: Int? = null,
        episodeTitle: String? = null,
        positionMs: Long = 0L,
    ) = ResumePoint(
        subjectId = "tmdb-tv-1399",
        title = "Game of Thrones",
        season = season,
        episode = episode,
        episodeTitle = episodeTitle,
        positionMs = positionMs,
        durationMs = 3_600_000L,
        updatedAt = 5_000L,
    )

    @Test
    fun `id has no suffix for a movie subject`() {
        val request = PlaybackRequest(subjectId = "tmdb-movie-550", title = "Fight Club")

        assertEquals("tmdb-movie-550", request.id)
    }

    @Test
    fun `id appends the season for a season level request`() {
        val request = PlaybackRequest(subjectId = "tmdb-tv-1399", title = "Game of Thrones", season = 2)

        assertEquals("tmdb-tv-1399-s2", request.id)
    }

    @Test
    fun `id appends season and episode for an episode request`() {
        val request = PlaybackRequest(
            subjectId = "tmdb-tv-1399",
            title = "Game of Thrones",
            season = 2,
            episode = 5,
        )

        assertEquals("tmdb-tv-1399-s2e5", request.id)
    }

    @Test
    fun `episode without a season does not change the id`() {
        val request = PlaybackRequest(subjectId = "tmdb-tv-1399", title = "Game of Thrones", episode = 5)

        assertEquals("tmdb-tv-1399", request.id)
        assertNull(request.episodeLabel)
    }

    @Test
    fun `episode label requires both season and episode`() {
        val both = PlaybackRequest("id", "Show", season = 1, episode = 2)
        val seasonOnly = PlaybackRequest("id", "Show", season = 1)
        val episodeOnly = PlaybackRequest("id", "Show", episode = 2)

        assertEquals("S1E2", both.episodeLabel)
        assertNull(seasonOnly.episodeLabel)
        assertNull(episodeOnly.episodeLabel)
    }

    @Test
    fun `display title appends the episode title when known`() {
        val request = PlaybackRequest(
            subjectId = "id",
            title = "Show",
            episode = 3,
            episodeTitle = "The Pilot",
        )

        assertEquals("Show · The Pilot", request.displayTitle)
    }

    @Test
    fun `display title falls back to a numbered episode`() {
        val request = PlaybackRequest(subjectId = "id", title = "Show", episode = 3)

        assertEquals("Show · Episode 3", request.displayTitle)
    }

    @Test
    fun `display title is the plain title for a movie`() {
        val request = PlaybackRequest(subjectId = "id", title = "Movie")

        assertEquals("Movie", request.displayTitle)
    }

    @Test
    fun `is series recognises kind strings and season presence`() {
        assertTrue(PlaybackRequest("id", "Show", kind = "series").isSeries)
        assertTrue(PlaybackRequest("id", "Show", kind = "2").isSeries)
        assertTrue(PlaybackRequest("id", "Show", season = 1).isSeries)
        assertFalse(PlaybackRequest("id", "Movie", kind = "movie").isSeries)
        assertFalse(PlaybackRequest("id", "Movie", kind = "1").isSeries)
        assertFalse(PlaybackRequest("id", "Movie").isSeries)
    }

    @Test
    fun `for subject carries the catalogue identity and episode number`() {
        val subject = Subject(id = "tmdb-tv-1399", title = "Game of Thrones", poster = "p.jpg", kind = "series")
        val episode = Episode(subjectId = subject.id, season = 2, number = 5, title = "The Ghost of Harrenhal")

        val request = PlaybackRequest.forSubject(subject, season = 2, episode = episode)

        assertEquals("tmdb-tv-1399-s2e5", request.id)
        assertEquals("Game of Thrones", request.title)
        assertEquals("p.jpg", request.poster)
        assertEquals("series", request.kind)
        assertEquals(5, request.episode)
        assertEquals("The Ghost of Harrenhal", request.episodeTitle)
        assertNull(request.localFilePath)
    }

    @Test
    fun `from download marks an episode as a series and links the download id`() {
        val request = PlaybackRequest.fromDownload(
            download(season = 2, episode = 5, episodeTitle = "The Ghost of Harrenhal"),
        )

        assertEquals("download-1", request.downloadId)
        assertEquals("tmdb-tv-1399-s2e5", request.id)
        assertEquals("series", request.kind)
        assertEquals(2, request.season)
        assertEquals(5, request.episode)
        assertEquals("The Ghost of Harrenhal", request.episodeTitle)
        assertEquals("Game of Thrones · The Ghost of Harrenhal", request.displayTitle)
        assertNull(request.localFilePath)
    }

    @Test
    fun `from download marks a movie as a movie`() {
        val request = PlaybackRequest.fromDownload(download())

        assertEquals("movie", request.kind)
        assertNull(request.season)
        assertNull(request.episode)
        assertEquals("tmdb-tv-1399", request.id)
        assertFalse(request.isSeries)
    }

    @Test
    fun `from resume restores the position and the episode identity`() {
        val request = PlaybackRequest.fromResume(
            resume(season = 2, episode = 5, episodeTitle = "The Ghost of Harrenhal", positionMs = 90_000L),
        )

        assertEquals("tmdb-tv-1399-s2e5", request.id)
        assertEquals("series", request.kind)
        assertEquals(90_000L, request.startPositionMs)
        assertEquals("S2E5", request.episodeLabel)
        assertEquals("Game of Thrones · The Ghost of Harrenhal", request.displayTitle)
    }

    @Test
    fun `from resume treats a movie point as a movie`() {
        val request = PlaybackRequest.fromResume(resume(positionMs = 1_000L))

        assertEquals("movie", request.kind)
        assertEquals(1_000L, request.startPositionMs)
        assertNull(request.episodeLabel)
        assertFalse(request.isSeries)
    }

    @Test
    fun `outcome reports nothing to download when nothing was requested`() {
        val outcome = DownloadQueueOutcome(requested = 0, added = 0, failed = 0)

        assertEquals(0, outcome.skipped)
        assertEquals("Nothing to download.", outcome.message)
    }

    @Test
    fun `outcome explains a single unresolved stream`() {
        val outcome = DownloadQueueOutcome(requested = 1, added = 0, failed = 1)

        assertEquals("No stream was available to download.", outcome.message)
    }

    @Test
    fun `outcome explains several unresolved episodes`() {
        val outcome = DownloadQueueOutcome(requested = 3, added = 0, failed = 3)

        assertEquals("No streams were available for those 3 episodes.", outcome.message)
    }

    @Test
    fun `outcome prefers the supplied failure reason when everything failed`() {
        val outcome = DownloadQueueOutcome(
            requested = 2,
            added = 0,
            failed = 2,
            failureReason = "StreamHype titles cannot be downloaded.",
        )

        assertEquals("StreamHype titles cannot be downloaded.", outcome.message)
    }

    @Test
    fun `outcome reports a single queued download`() {
        val outcome = DownloadQueueOutcome(requested = 1, added = 1, failed = 0)

        assertEquals(0, outcome.skipped)
        assertEquals("Queued 1 download.", outcome.message)
    }

    @Test
    fun `outcome uses the plural for several queued downloads`() {
        val outcome = DownloadQueueOutcome(requested = 4, added = 4, failed = 0)

        assertEquals("Queued 4 downloads.", outcome.message)
    }

    @Test
    fun `outcome joins queued skipped and failed counts`() {
        val outcome = DownloadQueueOutcome(requested = 5, added = 2, failed = 1)

        assertEquals(2, outcome.skipped)
        assertEquals(
            "Queued 2 downloads · 2 already queued · 1 could not be resolved.",
            outcome.message,
        )
    }

    @Test
    fun `outcome reports only the skipped count when nothing was added`() {
        val outcome = DownloadQueueOutcome(requested = 2, added = 0, failed = 0)

        assertEquals(2, outcome.skipped)
        assertEquals("2 already queued.", outcome.message)
    }

    @Test
    fun `skipped never goes negative`() {
        val outcome = DownloadQueueOutcome(requested = 1, added = 2, failed = 0)

        assertEquals(0, outcome.skipped)
        assertEquals("Queued 2 downloads.", outcome.message)
    }
}
