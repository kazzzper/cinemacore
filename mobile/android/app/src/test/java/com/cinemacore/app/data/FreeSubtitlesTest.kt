package com.cinemacore.app.data

import com.cinemacore.app.domain.SubtitleProvider
import com.cinemacore.app.domain.SubtitleTracks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The keyless caption fallback, exercised on the two shapes it has to read:
 * Cinemeta's id lookup and the addon's subtitle listing. Both payloads are
 * trimmed copies of live responses.
 */
class FreeSubtitlesTest {
    private val cinemeta = """
        {"query":"inception","metas":[
          {"id":"tt1375666","imdb_id":"tt1375666","type":"movie","name":"Inception","releaseInfo":"2010"},
          {"id":"tt1790736","imdb_id":"tt1790736","type":"movie","name":"Inception: The Cobol Job","releaseInfo":"2010"}
        ]}
    """.trimIndent()

    private val addon = """
        {"subtitles":[
          {"id":"1","url":"https://subs.test/hi/1","lang":"hin"},
          {"id":"2","url":"https://subs.test/en/1","lang":"eng"},
          {"id":"3","url":"https://subs.test/en/1","lang":"eng"},
          {"id":"4","url":"https://subs.test/pt/1","lang":"pob"},
          {"id":"5","url":"https://subs.test/es/1","lang":"spa"}
        ]}
    """.trimIndent()

    @Test
    fun `the year picks between a title and its same-year tie`() {
        assertEquals("tt1375666", FreeSubtitles.imdbIdFromCinemeta(cinemeta, 2010))
        assertEquals("tt1375666", FreeSubtitles.imdbIdFromCinemeta(cinemeta, null))
    }

    @Test
    fun `an unparsable or empty lookup has no id`() {
        assertNull(FreeSubtitles.imdbIdFromCinemeta("{}", 2010))
        assertNull(FreeSubtitles.imdbIdFromCinemeta("not json", null))
        // A numeric TMDB id is not an imdb id; the addon would answer empty.
        assertNull(FreeSubtitles.imdbIdFromCinemeta("""{"metas":[{"id":"27205"}]}""", null))
    }

    @Test
    fun `the viewer's language leads, then English, then the rest`() {
        val hindi = FreeSubtitles.tracksFromAddon(
            addon,
            FreeSubtitleRequest(title = "Inception", language = "hi"),
            10,
        )
        assertEquals(listOf("Hindi", "English", "Portuguese", "Spanish"), hindi.map { it.language })

        val french = FreeSubtitles.tracksFromAddon(
            addon,
            FreeSubtitleRequest(title = "Inception", language = "fr"),
            10,
        )
        assertEquals(listOf("English", "Hindi", "Portuguese", "Spanish"), french.map { it.language })
    }

    @Test
    fun `one file listed under several releases appears once`() {
        val tracks = FreeSubtitles.tracksFromAddon(
            addon,
            FreeSubtitleRequest(title = "Inception", language = "en"),
            10,
        )
        assertEquals(tracks.map { it.url }.distinct().size, tracks.size)
        assertEquals(4, tracks.size)
    }

    @Test
    fun `the addon's tracks are SRT and capped`() {
        val tracks = FreeSubtitles.tracksFromAddon(
            addon,
            FreeSubtitleRequest(title = "Inception", language = "en"),
            2,
        )
        assertEquals(2, tracks.size)
        assertTrue(tracks.all { it.format == "srt" })
        assertTrue(tracks.all { it.provider == SubtitleProvider.COMMUNITY })
        // A code `Locale` does not know is still shown rather than dropped.
        assertTrue(
            FreeSubtitles.tracksFromAddon(
                addon,
                FreeSubtitleRequest(title = "Inception", language = "pt"),
                10,
            ).any { it.language == "Portuguese" },
        )
    }

    @Test
    fun `a broken listing yields nothing instead of throwing`() {
        val request = FreeSubtitleRequest(title = "Inception", language = "en")
        assertTrue(FreeSubtitles.tracksFromAddon("<html>", request, 5).isEmpty())
        assertTrue(FreeSubtitles.tracksFromAddon("""{"subtitles":[]}""", request, 5).isEmpty())
    }

    @Test
    fun `ISO-639-2 and ISO-639-1 spellings match each other`() {
        assertTrue(FreeSubtitles.matches("eng", "en"))
        assertTrue(FreeSubtitles.matches("en", "eng"))
        assertTrue(FreeSubtitles.matches("hin", "hi"))
        assertFalse(FreeSubtitles.matches("eng", "hi"))
        assertFalse(FreeSubtitles.matches("e", "en"))
    }

    @Test
    fun `URLs address the movie and series shapes the addon documents`() {
        val movie = FreeSubtitleRequest(title = "Inception", year = 2010)
        assertEquals(
            "https://opensubtitles-v3.strem.io/subtitles/movie/tt1375666.json",
            FreeSubtitles.addonUrl("tt1375666", movie)?.toString(),
        )

        val episode = FreeSubtitleRequest(
            title = "Breaking Bad",
            isSeries = true,
            season = 2,
            episode = 7,
        )
        assertEquals(
            "https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:2:7.json",
            FreeSubtitles.addonUrl("tt0903747", episode)?.toString(),
        )

        // A series with no season yet still asks for episode one rather than
        // sending an empty path component.
        val bare = FreeSubtitleRequest(title = "Breaking Bad", isSeries = true)
        assertEquals(
            "https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:1:1.json",
            FreeSubtitles.addonUrl("tt0903747", bare)?.toString(),
        )
    }

    @Test
    fun `a title with spaces and punctuation survives the path`() {
        val request = FreeSubtitleRequest(title = "El Camino: A Breaking Bad Movie / Part 2")
        val url = FreeSubtitles.cinemetaUrl(request)?.toString().orEmpty()
        assertFalse(url.contains(" "))
        assertTrue(
            url.startsWith("https://v3-cinemeta.strem.io/catalog/movie/top/search="),
        )
        assertFalse(url.substringAfter("https://v3-cinemeta.strem.io").contains("/Part"))
    }

    @Test
    fun `an episode number is never shifted by one`() {
        for (number in 1..12) {
            val request = FreeSubtitleRequest(
                title = "Game of Thrones",
                isSeries = true,
                season = 2,
                episode = number,
            )
            assertTrue(
                FreeSubtitles.addonUrl("tt0944947", request).toString()
                    .endsWith(":2:$number.json"),
            )
        }
    }

    @Test
    fun `a missing season or episode falls back to the first, never zero`() {
        val both = FreeSubtitleRequest(title = "Game of Thrones", isSeries = true)
        assertEquals(
            "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:1:1.json",
            FreeSubtitles.addonUrl("tt0944947", both)?.toString(),
        )
        val zero = FreeSubtitleRequest(
            title = "Game of Thrones",
            isSeries = true,
            season = 0,
            episode = 0,
        )
        assertEquals(
            "https://opensubtitles-v3.strem.io/subtitles/series/tt0944947:1:1.json",
            FreeSubtitles.addonUrl("tt0944947", zero)?.toString(),
        )
    }
}

/** The addon answers a series lookup with a fuzzy match; the entries carry the
 * release they came from, which is what the per-entry filter and label use. */
class FreeSubtitlesEpisodeTest {
    private val listing = """
        {"subtitles":[
          {"url":"https://subs.test/en/s01e01-hdtv","lang":"eng",
           "subtitleFileName":"Game.of.Thrones.S01E01.720p.HDTV.DD5.1.x264-EbP.srt",
           "movieReleaseName":"Game.of.Thrones.S01E01.720p.HDTV.DD5.1.x264-EbP",
           "releaseGroup":"EbP","releaseFormat":"HDTV","season":1,"episode":1},
          {"url":"https://subs.test/en/s08e02","lang":"eng",
           "subtitleFileName":"Game of Thrones S08E02 WEB x264-NogroupL.srt",
           "movieReleaseName":"Game of Thrones S08E02 WEB x264-NogroupL",
           "releaseGroup":"NogroupL","releaseFormat":"WEB-DL","season":1,"episode":1},
          {"url":"https://subs.test/en/bluray","lang":"eng",
           "subtitleFileName":"Game.of.Thrones.S01E01.720p.BluRay.X264-REWARD.eng.srt",
           "movieReleaseName":"Game.Of.Thrones.S01.720p.BluRay.x264-MIXED",
           "releaseGroup":"REWARD","releaseFormat":"BluRay","season":1,"episode":1},
          {"url":"https://subs.test/en/bare","lang":"eng","subtitleFileName":"S01E01.srt","season":1,"episode":1},
          {"url":"https://subs.test/en/unmarked","lang":"eng"}
        ]}
    """.trimIndent()

    private fun tracks(season: Int?, episode: Int?) = FreeSubtitles.tracksFromAddon(
        listing,
        FreeSubtitleRequest(
            title = "Game of Thrones",
            isSeries = true,
            season = season,
            episode = episode,
            language = "en",
        ),
        10,
    )

    @Test
    fun `the requested episode's file survives and a different one is dropped`() {
        val urls = tracks(1, 1).map { it.url }
        assertTrue(urls.contains("https://subs.test/en/s01e01-hdtv"))
        assertFalse(urls.contains("https://subs.test/en/s08e02"))
        // A season pack has no episode marker, so it is kept.
        assertTrue(urls.contains("https://subs.test/en/bluray"))
        assertTrue(urls.contains("https://subs.test/en/bare"))
        assertTrue(urls.contains("https://subs.test/en/unmarked"))
    }

    @Test
    fun `a request for another episode keeps only unmarked entries`() {
        val urls = tracks(2, 3).map { it.url }
        // The BluRay entry names S01E01 in its file name, so it is dropped too.
        assertEquals(listOf("https://subs.test/en/unmarked"), urls)
    }

    @Test
    fun `a release name labels the track`() {
        val first = tracks(1, 1).first { it.url.endsWith("s01e01-hdtv") }
        assertEquals("Game.of.Thrones.S01E01.720p.HDTV.DD5.1.x264-EbP", first.source)
    }

    @Test
    fun `the marker parser reads S and x spellings`() {
        assertEquals(1 to 1, FreeSubtitles.episodeMarker(listOf("Game.of.Thrones.S01E01.720p")))
        assertEquals(8 to 2, FreeSubtitles.episodeMarker(listOf("Show S08E02 WEB")))
        assertEquals(null, FreeSubtitles.episodeMarker(listOf("Show.2019.1080p")))
        // A leading `s` inside a word is not a season marker.
        assertEquals(null, FreeSubtitles.episodeMarker(listOf("classics.s01")))
    }
}

/** The default-track rule: English first, community first for episodes. */
class SubtitleTracksTest {
    private fun track(
        language: String,
        provider: SubtitleProvider = SubtitleProvider.PROVIDER,
        url: String = "https://subs.test/${language.lowercase()}-${provider.name}",
    ) = com.cinemacore.app.domain.SubtitleTrack(
        language = language,
        url = url,
        provider = provider,
    )

    @Test
    fun `merging keeps the visible order and drops duplicates`() {
        val provider = track("English")
        val community = track("English", SubtitleProvider.COMMUNITY, "https://subs.test/community")
        val merged = SubtitleTracks.merging(listOf(provider), listOf(provider, community))
        assertEquals(listOf(provider, community), merged)
    }

    @Test
    fun `a numbered episode starts on the community English track`() {
        val provider = track("English")
        val community = track("English", SubtitleProvider.COMMUNITY, "https://subs.test/c")
        val chosen = SubtitleTracks.defaultTrack(
            tracks = listOf(provider, community),
            isOriginalAudio = true,
            chosen = null,
            prefersCommunity = true,
        )
        assertEquals(community, chosen)
    }

    @Test
    fun `a film starts on the provider English track`() {
        val provider = track("English")
        val community = track("English", SubtitleProvider.COMMUNITY, "https://subs.test/c")
        val chosen = SubtitleTracks.defaultTrack(
            tracks = listOf(provider, community),
            isOriginalAudio = true,
            chosen = null,
            prefersCommunity = false,
        )
        assertEquals(provider, chosen)
    }

    @Test
    fun `a viewer's pick is never replaced`() {
        val chosen = track("Hindi")
        assertEquals(
            chosen,
            SubtitleTracks.defaultTrack(
                tracks = listOf(track("English")),
                isOriginalAudio = true,
                chosen = chosen,
            ),
        )
        // A dub already speaks the viewer's language, so no caption starts on.
        assertNull(
            SubtitleTracks.defaultTrack(
                tracks = listOf(track("English")),
                isOriginalAudio = false,
                chosen = null,
            ),
        )
    }

    @Test
    fun `English labels tolerate the spellings the sources emit`() {
        assertTrue(SubtitleTracks.isEnglish("English"))
        assertTrue(SubtitleTracks.isEnglish("en"))
        assertTrue(SubtitleTracks.isEnglish("eng"))
        assertTrue(SubtitleTracks.isEnglish("en-US"))
        assertTrue(SubtitleTracks.isEnglish("English (US)"))
        assertFalse(SubtitleTracks.isEnglish("Bengali"))
        assertFalse(SubtitleTracks.isEnglish("Hindi"))
    }
}
