package com.cinemacore.app.data.direct

import com.cinemacore.app.domain.StreamRendition
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class MovieBoxRecoveryTest {
    private val userAgent = "ExoPlayerLib/2.19.1"
    private val decoy =
        "https://macdn.aoneroom.com/other/2026/10/10/80da52722ee7de7a4303290af6783424.mp4"

    private fun base64Url(raw: String): String =
        Base64.getEncoder().encodeToString(raw.toByteArray())
            .trimEnd('=')
            .replace('+', '-')
            .replace('/', '_')

    private fun base64(raw: String): String =
        Base64.getEncoder().encodeToString(raw.toByteArray())

    private fun cloudFrontCookie(policy: String): String {
        val encoded = Base64.getEncoder().encodeToString(policy.toByteArray())
            .replace('+', '-')
            .replace('/', '~')
            .replace('=', '_')
        return "CloudFront-Policy=$encoded"
    }

    private fun cloudFrontCookieFor(resource: String): String =
        cloudFrontCookie("""{"Statement":[{"Resource":"$resource"}]}""")

    private fun rank(epTitle: String?, title: String?, season: Int, episode: Int): Int =
        MovieBoxRecovery.ugcMarkerRank(
            epTitle = epTitle,
            title = title,
            season = season,
            episode = episode,
        )

    // Decoy gate

    @Test
    fun `every decoy marker is rejected whatever its case`() {
        val markers = listOf(
            "1c7de0bd3393702d9191801f15f88f8d",
            "9a0461bc39da389663bf3dbb17091d3f",
            "b164fbfb43",
            "/notice.mp4",
            "please_update",
            "update_app",
        )

        markers.forEach { marker ->
            assertTrue(marker, MovieBoxRecovery.isDecoy("https://cdn.test/$marker"))
            assertTrue(marker, MovieBoxRecovery.isDecoy("https://cdn.test/${marker.uppercase()}"))
        }
    }

    @Test
    fun `the macdn other shape is a decoy but the host alone is not`() {
        assertTrue(MovieBoxRecovery.isDecoy(decoy))
        assertTrue(MovieBoxRecovery.isDecoy("HTTPS://MACDN.AONEROOM.COM/OTHER/x.mp4"))
        assertFalse(MovieBoxRecovery.isDecoy("https://macdn.aoneroom.com/title/x.mp4"))
        assertFalse(MovieBoxRecovery.isDecoy("https://cdn.example.com/other/x.mp4"))
    }

    @Test
    fun `usable means absolute http and not a decoy`() {
        assertTrue(MovieBoxRecovery.isUsable("https://cdn.test/title.mp4"))
        assertTrue(MovieBoxRecovery.isUsable("http://cdn.test/title.mp4"))
        assertFalse(MovieBoxRecovery.isUsable(""))
        assertFalse(MovieBoxRecovery.isUsable(" //cdn.test/title.mp4 "))
        assertFalse(MovieBoxRecovery.isUsable("HTTP://cdn.test/title.mp4"))
        assertFalse(MovieBoxRecovery.isUsable("https://cdn.test/notice.mp4"))
        assertFalse(MovieBoxRecovery.isUsable(decoy))
    }

    // Signed cookie -> manifest

    @Test
    fun `urlprefix resolves an hls tree`() {
        val prefix = "https://cdn.example.com/hls/title/"
        assertEquals(
            "https://cdn.example.com/hls/title/index.m3u8",
            MovieBoxRecovery.manifestFromSignCookie("urlprefix=${base64Url(prefix)}"),
        )
        assertEquals(
            "https://cdn.example.com/hls/title/index.m3u8",
            MovieBoxRecovery.manifestFromSignCookie("urlprefix=${base64Url(prefix.dropLast(1))}"),
        )
    }

    @Test
    fun `urlprefix resolves a dash tree before hls`() {
        val prefix = "https://cdn.example.com/dash/title/"
        assertEquals(
            "https://cdn.example.com/dash/title/index.mpd",
            MovieBoxRecovery.manifestFromSignCookie("urlprefix=${base64Url(prefix)}"),
        )
    }

    @Test
    fun `urlprefix accepts standard base64 with padding`() {
        val prefix = "https://cdn.example.com/hls/title"
        assertEquals(
            "https://cdn.example.com/hls/title/index.m3u8",
            MovieBoxRecovery.manifestFromSignCookie("urlprefix=${base64(prefix)}"),
        )
    }

    @Test
    fun `urlprefix stops at the signature separator and trims surrounding space`() {
        val prefix = "https://cdn.example.com/hls/title/"
        val cookie = "sign=abc;  urlprefix=${base64Url(prefix)}:sign=f1a522f7  ; other=1"
        assertEquals(
            "https://cdn.example.com/hls/title/index.m3u8",
            MovieBoxRecovery.manifestFromSignCookie(cookie),
        )
    }

    @Test
    fun `a signed decoy or notice clip never resolves`() {
        assertNull(MovieBoxRecovery.manifestFromSignCookie("urlprefix=${base64Url(decoy)}"))
        assertNull(
            MovieBoxRecovery.manifestFromSignCookie(
                "urlprefix=${base64Url("https://cdn.example.com/notice.mp4")}",
            ),
        )
    }

    @Test
    fun `a failed urlprefix still allows a later field to resolve`() {
        assertNull(MovieBoxRecovery.manifestFromSignCookie(""))
        assertNull(MovieBoxRecovery.manifestFromSignCookie("sign=abc"))
        assertNull(MovieBoxRecovery.manifestFromSignCookie("urlprefix=not*base64!!"))
        assertEquals(
            "https://cdn.example.com/hls/title/index.m3u8",
            MovieBoxRecovery.manifestFromSignCookie(
                "urlprefix=not*base64!!;urlprefix=${base64Url("https://cdn.example.com/hls/title/")}",
            ),
        )
    }

    @Test
    fun `cloudfront policy resolves a dash resource`() {
        assertEquals(
            "https://cdn.example.com/dash/title/index.mpd",
            MovieBoxRecovery.manifestFromSignCookie(
                cloudFrontCookieFor("https://cdn.example.com/dash/title/*"),
            ),
        )
    }

    @Test
    fun `cloudfront policy rejects decoys and non dash resources`() {
        assertNull(MovieBoxRecovery.manifestFromSignCookie(cloudFrontCookieFor(decoy)))
        assertNull(
            MovieBoxRecovery.manifestFromSignCookie(
                cloudFrontCookieFor("https://cdn.example.com/hls/title/*"),
            ),
        )
    }

    @Test
    fun `cloudfront policy tolerates unknown fields and rejects malformed policies`() {
        val policy = """
            {"Version":"1","Statement":[
              {"Resource":"https://cdn.example.com/dash/title/*","Condition":{}}
            ]}
        """.trimIndent()
        assertEquals(
            "https://cdn.example.com/dash/title/index.mpd",
            MovieBoxRecovery.manifestFromSignCookie(cloudFrontCookie(policy)),
        )
        assertNull(MovieBoxRecovery.manifestFromSignCookie(cloudFrontCookie("not json")))
        assertNull(MovieBoxRecovery.manifestFromSignCookie(cloudFrontCookie("""{"Statement":[]}""")))
        assertNull(
            MovieBoxRecovery.manifestFromSignCookie(
                cloudFrontCookie("""{"Statement":[{"Resource":""}]}"""),
            ),
        )
        assertNull(MovieBoxRecovery.manifestFromSignCookie(cloudFrontCookie("{}")))
        assertNull(
            MovieBoxRecovery.manifestFromSignCookie(
                cloudFrontCookie("""{"Statement":[{}]}"""),
            ),
        )
    }

    // Base64 and manifest construction

    @Test
    fun `decode base64 accepts the url safe alphabet and restores padding`() {
        assertEquals("https://cdn/dash/x/", MovieBoxRecovery.decodeBase64(base64Url("https://cdn/dash/x/")))
        assertEquals("hello", MovieBoxRecovery.decodeBase64("aGVsbG8"))
        assertEquals("hello", MovieBoxRecovery.decodeBase64(" aGVsbG8= "))
        assertEquals("??>", MovieBoxRecovery.decodeBase64("Pz8+"))
    }

    @Test
    fun `decode base64 rejects blank invalid and non utf8 input`() {
        assertNull(MovieBoxRecovery.decodeBase64(""))
        assertNull(MovieBoxRecovery.decodeBase64("   "))
        assertNull(MovieBoxRecovery.decodeBase64("not*base64"))
        assertNull(MovieBoxRecovery.decodeBase64("a"))
        assertNull(MovieBoxRecovery.decodeBase64("/w=="))
    }

    @Test
    fun `dash manifest trims stars and slashes and requires a dash tree`() {
        assertEquals(
            "https://cdn/dash/title/index.mpd",
            MovieBoxRecovery.dashManifest(" https://cdn/dash/title/** "),
        )
        assertEquals(
            "https://cdn/dash/title/index.mpd",
            MovieBoxRecovery.dashManifest("https://cdn/dash/title"),
        )
        assertNull(MovieBoxRecovery.dashManifest("https://cdn/hls/title/"))
        assertNull(MovieBoxRecovery.dashManifest("ftp://cdn/dash/title/"))
        assertNull(MovieBoxRecovery.dashManifest("https://cdn/dash/"))
    }

    @Test
    fun `hls manifest trims and appends one index name`() {
        assertEquals(
            "https://cdn/hls/title/index.m3u8",
            MovieBoxRecovery.hlsManifest(" https://cdn/hls/title/ "),
        )
        assertEquals(
            "https://cdn/hls/title/index.m3u8",
            MovieBoxRecovery.hlsManifest("https://cdn/hls/title"),
        )
        assertNull(MovieBoxRecovery.hlsManifest("ftp://cdn/hls/title/"))
    }

    @Test
    fun `cloudfront alphabet restores the signing characters`() {
        assertEquals("+=/", MovieBoxRecovery.cloudFrontAlphabet(" -_~ "))
    }

    // Renditions and ordering

    @Test
    fun `renditions expand each resolution with the entry metadata`() {
        val url = "https://cdn.test/title/index.m3u8"
        val out = MovieBoxRecovery.renditions(
            url = url,
            resolutions = " 1080 , 720,, ",
            size = "3",
            cookie = "a=b",
            codec = "h264",
        )

        assertEquals(listOf("1080", "720"), out.map { it.quality })
        out.forEach { rendition ->
            assertEquals(url, rendition.url)
            assertEquals("3", rendition.size)
            assertEquals("a=b", rendition.cookie)
            assertEquals("h264", rendition.codec)
        }
        assertEquals(
            StreamRendition(quality = "1080", url = url, size = "3", cookie = "a=b"),
            out.first().toStreamRendition(),
        )
    }

    @Test
    fun `renditions without labels stay empty and keep null metadata`() {
        assertTrue(MovieBoxRecovery.renditions("https://cdn.test/x", "").isEmpty())
        assertTrue(MovieBoxRecovery.renditions("https://cdn.test/x", " , ").isEmpty())

        val out = MovieBoxRecovery.renditions("https://cdn.test/x", "360")
        assertEquals(1, out.size)
        assertNull(out.first().size)
        assertNull(out.first().cookie)
        assertNull(out.first().codec)
    }

    @Test
    fun `split list trims and drops empty entries`() {
        assertEquals(emptyList<String>(), MovieBoxRecovery.splitList(""))
        assertEquals(emptyList<String>(), MovieBoxRecovery.splitList(" , , "))
        assertEquals(listOf("1080"), MovieBoxRecovery.splitList("1080"))
        assertEquals(listOf("1080", "720"), MovieBoxRecovery.splitList(" 1080 , , 720 "))
    }

    @Test
    fun `resolution rank reads leading digits and ignores suffixes`() {
        assertEquals(1080, MovieBoxRecovery.resolutionRank("1080p"))
        assertEquals(1080, MovieBoxRecovery.resolutionRank(" 1080P "))
        assertEquals(720, MovieBoxRecovery.resolutionRank("720"))
        assertTrue(
            MovieBoxRecovery.resolutionRank("1080p") >
                MovieBoxRecovery.resolutionRank("720p"),
        )
        assertEquals(4, MovieBoxRecovery.resolutionRank("4K"))
        assertEquals(0, MovieBoxRecovery.resolutionRank("best"))
        assertEquals(0, MovieBoxRecovery.resolutionRank(""))
        assertEquals(0, MovieBoxRecovery.resolutionRank("999999999999"))
        assertEquals(0, MovieBoxRecovery.resolutionRank("1080\u0662"))
    }

    @Test
    fun `media headers carry the player agent and only a non empty cookie`() {
        assertEquals(mapOf("User-Agent" to userAgent), MovieBoxRecovery.headers(null))
        assertEquals(mapOf("User-Agent" to userAgent), MovieBoxRecovery.headers(""))
        assertEquals(
            mapOf("User-Agent" to userAgent, "Cookie" to "a=b; c=d"),
            MovieBoxRecovery.headers("a=b; c=d"),
        )
        assertEquals("ExoPlayerLib/2.19.1", MovieBoxRecovery.streamUserAgent)
    }

    // UGC episode markers

    @Test
    fun `an exact SxEPy marker outranks a bare episode marker`() {
        assertEquals(2, rank("S1EP2", "Dune S1E2", 1, 2))
        assertEquals(1, rank(null, "Dune S1E2", 1, 2))
        assertEquals(1, rank("S1E2", null, 1, 2))
        assertEquals(2, rank("s1ep2", null, 1, 2))
    }

    @Test
    fun `E1 inside S1EP10 does not match episode 1`() {
        assertEquals(0, rank("S1EP10", "Dune S1E10", 1, 1))
    }

    @Test
    fun `a longer number never matches a shorter episode`() {
        assertEquals(0, rank("S1EP20", "Dune S1E20", 1, 2))
        assertEquals(0, rank("S2EP10", null, 2, 1))
        assertEquals(0, rank(null, "S1E12", 1, 2))
    }

    @Test
    fun `multi digit episodes match exactly`() {
        assertEquals(2, rank("S1EP10", null, 1, 10))
        assertEquals(1, rank(null, "Dune S1E10", 1, 10))
        assertEquals(2, rank("S2EP10", null, 2, 10))
    }

    @Test
    fun `a conflicting title cannot override the dedicated epTitle`() {
        assertEquals(0, rank("S1EP10", "Dune S1E2", 1, 2))
    }

    @Test
    fun `a preceding letter blocks the qualified marker`() {
        assertEquals(0, rank("XS1EP2", null, 1, 2))
    }

    @Test
    fun `punctuation before the qualified marker is allowed`() {
        assertEquals(2, rank(null, "(S1EP2)", 1, 2))
    }

    @Test
    fun `a title without any marker ranks zero`() {
        assertEquals(0, rank(null, "Dune", 1, 2))
    }

    @Test
    fun `a preceding letter is allowed before a bare episode marker`() {
        assertEquals(1, rank("SCENE1", null, 1, 1))
        assertEquals(1, rank("XE2", null, 1, 2))
    }

    @Test
    fun `a following letter still matches and a following digit does not`() {
        assertEquals(1, rank("E2X", null, 1, 2))
        assertEquals(2, rank("S1EP2X", null, 1, 2))
        assertEquals(0, rank("E20X", null, 1, 2))
    }

    @Test
    fun `episode markers are detected without a season`() {
        assertTrue(MovieBoxRecovery.ugcHasEpisodeMarker("S1EP10", null))
        assertTrue(MovieBoxRecovery.ugcHasEpisodeMarker(null, "Dune S1E2"))
        assertTrue(MovieBoxRecovery.ugcHasEpisodeMarker(null, "s1e2"))
        assertTrue(MovieBoxRecovery.ugcHasEpisodeMarker("EP2", null))
        assertTrue(MovieBoxRecovery.ugcHasEpisodeMarker("E2", null))
        assertFalse(MovieBoxRecovery.ugcHasEpisodeMarker(null, "Dune"))
        assertFalse(MovieBoxRecovery.ugcHasEpisodeMarker("E", null))
        assertFalse(MovieBoxRecovery.ugcHasEpisodeMarker(null, "P2"))
        assertFalse(MovieBoxRecovery.ugcHasEpisodeMarker(null, null))
        assertFalse(MovieBoxRecovery.ugcHasEpisodeMarker("", ""))
    }

    // Resource episode filtering

    private data class Resource(
        val season: Int,
        val episode: Int,
        val link: String = "",
    )

    private val listing = listOf(
        Resource(1, 1, "e1"),
        Resource(1, 2, "e2-720"),
        Resource(1, 2, "e2-1080"),
        Resource(1, 3, "e3"),
        Resource(2, 2, "s2-e2"),
    )

    @Test
    fun `resource filtering keeps the whole requested episode`() {
        val picked = MovieBoxRecovery.resourcesForEpisode(
            items = listing,
            season = 1,
            episode = 2,
            seasonOf = Resource::season,
            episodeOf = Resource::episode,
        )

        assertEquals(listOf("e2-720", "e2-1080"), picked.map { it.link })
    }

    @Test
    fun `a positive season narrows and a missing season does not`() {
        assertEquals(
            listOf("s2-e2"),
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 2,
                episode = 2,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ).map { it.link },
        )
        assertEquals(
            listOf("e2-720", "e2-1080", "s2-e2"),
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = null,
                episode = 2,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ).map { it.link },
        )
        assertEquals(
            listOf("e2-720", "e2-1080", "s2-e2"),
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 0,
                episode = 2,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ).map { it.link },
        )
        assertEquals(
            listOf("e2-720", "e2-1080", "s2-e2"),
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = -1,
                episode = 2,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ).map { it.link },
        )
    }

    @Test
    fun `no requested episode keeps the whole listing`() {
        assertSame(
            listing,
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 1,
                episode = null,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ),
        )
        assertSame(
            listing,
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 1,
                episode = 0,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ),
        )
        assertSame(
            listing,
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 1,
                episode = -1,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ),
        )
    }

    @Test
    fun `an episode missing from the listing yields nothing`() {
        assertTrue(
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 1,
                episode = 4,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ).isEmpty(),
        )
        assertTrue(
            MovieBoxRecovery.resourcesForEpisode(
                listing,
                season = 3,
                episode = 2,
                seasonOf = Resource::season,
                episodeOf = Resource::episode,
            ).isEmpty(),
        )
    }

    @Test
    fun `resource predicate mirrors the listing filter`() {
        assertTrue(MovieBoxRecovery.resourceMatchesEpisode(1, 2, 1, 2))
        assertTrue(MovieBoxRecovery.resourceMatchesEpisode(9, 2, null, 2))
        assertTrue(MovieBoxRecovery.resourceMatchesEpisode(9, 2, 0, 2))
        assertFalse(MovieBoxRecovery.resourceMatchesEpisode(2, 2, 1, 2))
        assertFalse(MovieBoxRecovery.resourceMatchesEpisode(1, 3, 1, 2))
        assertTrue(MovieBoxRecovery.resourceMatchesEpisode(7, 9, 1, null))
        assertEquals(20, MovieBoxRecovery.resourcePageLimit)
    }
}
