package com.cinemacore.app.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ContinueWatchingTest {
    private fun point(
        subjectId: String,
        positionMs: Long,
        durationMs: Long = 1_000_000L,
        season: Int? = null,
        episode: Int? = null,
        updatedAt: Long,
    ) = ResumePoint(
        subjectId = subjectId,
        title = "Show $subjectId",
        season = season,
        episode = episode,
        positionMs = positionMs,
        durationMs = durationMs,
        updatedAt = updatedAt,
    )

    @Test
    fun `keeps only points worth resuming`() {
        val points = ContinueWatching.points(
            listOf(
                point("early", positionMs = 1_000L, updatedAt = 3),
                point("finished", positionMs = 990_000L, updatedAt = 2),
                point("good", positionMs = 500_000L, updatedAt = 1),
            ),
        )

        assertEquals(listOf("good"), points.map { it.subjectId })
    }

    @Test
    fun `newest episode wins and one row per title`() {
        val points = ContinueWatching.points(
            listOf(
                point("a", positionMs = 100_000L, season = 1, episode = 2, updatedAt = 5),
                point("a", positionMs = 100_000L, season = 1, episode = 4, updatedAt = 9),
                point("b", positionMs = 100_000L, updatedAt = 7),
            ),
        )

        assertEquals(listOf("a", "b"), points.map { it.subjectId })
        assertEquals(4, points.first().episode)
    }

    @Test
    fun `limit caps the rail`() {
        val history = (1..20).map {
            point("s$it", positionMs = 100_000L, updatedAt = it.toLong())
        }

        assertTrue(ContinueWatching.points(history, limit = 5).size == 5)
        assertTrue(ContinueWatching.points(history, limit = 0).isEmpty())
    }
}
