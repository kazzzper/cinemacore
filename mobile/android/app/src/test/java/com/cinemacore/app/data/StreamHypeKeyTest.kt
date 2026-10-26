package com.cinemacore.app.data

import com.cinemacore.app.data.StreamHypeCatalogRepository.MediaType
import com.cinemacore.app.data.StreamHypeCatalogRepository.SubjectId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StreamHypeKeyTest {
    @Test
    fun `user setting wins over environment and fallback`() {
        assertEquals(
            "user-key",
            StreamHypeCatalogRepository.resolveApiKey("user-key", "env-key", "fallback-key"),
        )
    }

    @Test
    fun `environment wins when the user setting is absent`() {
        assertEquals(
            "env-key",
            StreamHypeCatalogRepository.resolveApiKey(null, "env-key", "fallback-key"),
        )
        assertEquals(
            "env-key",
            StreamHypeCatalogRepository.resolveApiKey("", "env-key", "fallback-key"),
        )
    }

    @Test
    fun `fallback is used when neither source supplies a key`() {
        assertEquals(
            "fallback-key",
            StreamHypeCatalogRepository.resolveApiKey(null, null, "fallback-key"),
        )
        assertEquals(
            "fallback-key",
            StreamHypeCatalogRepository.resolveApiKey("", "   ", "fallback-key"),
        )
    }

    @Test
    fun `blank keys are ignored at every level`() {
        assertEquals("", StreamHypeCatalogRepository.resolveApiKey(null, null, ""))
        assertEquals("", StreamHypeCatalogRepository.resolveApiKey(" ", "\t", "  "))
        assertEquals("fallback-key", StreamHypeCatalogRepository.resolveApiKey(" ", null, "fallback-key"))
    }

    @Test
    fun `resolved keys are trimmed`() {
        assertEquals("user-key", StreamHypeCatalogRepository.resolveApiKey("  user-key  ", null, "fallback"))
        assertEquals("env-key", StreamHypeCatalogRepository.resolveApiKey(null, " env-key\n", "fallback"))
        assertEquals("fallback", StreamHypeCatalogRepository.resolveApiKey(null, null, " fallback "))
    }

    @Test
    fun `parses tv and movie subject ids`() {
        assertEquals(SubjectId(1399, MediaType.TV), SubjectId.parse("tmdb-tv-1399"))
        assertEquals(SubjectId(550, MediaType.MOVIE), SubjectId.parse("tmdb-movie-550"))
    }

    @Test
    fun `rejects malformed subject ids`() {
        val malformed = listOf(
            "",
            "tmdb",
            "tmdb-tv",
            "imdb-tv-1399",
            "TMDB-tv-1399",
            " tmdb-tv-1399",
            "tmdb-anime-1399",
            "tmdb-tv-zero",
            "tmdb-tv-0",
            "tmdb-tv--1",
            "tmdb-tv-1399-extra",
            "tmdb-tv-1399x",
        )

        malformed.forEach { raw ->
            assertNull("expected \"$raw\" to be rejected", SubjectId.parse(raw))
        }
    }

    @Test
    fun `tv embed url carries season and episode`() {
        val url = StreamHypeCatalogRepository.embedUrl(SubjectId(1399, MediaType.TV), 2, 5)

        assertEquals(
            "https://screenfetch4.cyou/embed/tv?tmdb=1399&o=streamhype.net&season=2&episode=5",
            url,
        )
    }

    @Test
    fun `tv embed url defaults to season one episode one`() {
        val url = StreamHypeCatalogRepository.embedUrl(SubjectId(1399, MediaType.TV), null, null)

        assertEquals(
            "https://screenfetch4.cyou/embed/tv?tmdb=1399&o=streamhype.net&season=1&episode=1",
            url,
        )
    }

    @Test
    fun `tv embed url clamps invalid season and episode to one`() {
        val url = StreamHypeCatalogRepository.embedUrl(SubjectId(1399, MediaType.TV), 0, -4)

        assertEquals(
            "https://screenfetch4.cyou/embed/tv?tmdb=1399&o=streamhype.net&season=1&episode=1",
            url,
        )
    }

    @Test
    fun `movie embed url never carries season or episode`() {
        val url = StreamHypeCatalogRepository.embedUrl(SubjectId(550, MediaType.MOVIE), 2, 5)

        assertEquals(
            "https://screenfetch4.cyou/embed/movie?tmdb=550&o=streamhype.net",
            url,
        )
    }

    @Test
    fun `poster images are built from tmdb paths`() {
        assertEquals(
            "https://image.tmdb.org/t/p/w780/poster.jpg",
            StreamHypeCatalogRepository.image("/poster.jpg"),
        )
        assertNull(StreamHypeCatalogRepository.image(null))
        assertNull(StreamHypeCatalogRepository.image("  "))
    }

    @Test
    fun `release years come from a date prefix`() {
        assertEquals(1999, StreamHypeCatalogRepository.year("1999-10-15"))
        assertEquals(2024, StreamHypeCatalogRepository.year("2024"))
        assertNull(StreamHypeCatalogRepository.year(null))
        assertNull(StreamHypeCatalogRepository.year("99"))
        assertNull(StreamHypeCatalogRepository.year("abcd-01-01"))
    }
}
