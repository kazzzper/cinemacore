package com.cinemacore.app.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackPolicyTest {
    private fun direct(quality: String, url: String = "https://cdn.example/${quality.filter(Char::isLetterOrDigit)}.mp4") =
        StreamRendition(quality = quality, url = url)

    private fun web(quality: String = "Auto", url: String = "https://embed.example/watch/1") =
        StreamRendition(quality = quality, url = url, kind = StreamKind.WEB)

    @Test
    fun `orders direct streams from auto down to 360p`() {
        val ordered = PlaybackPolicy.orderedDirect(
            listOf(
                direct("360p"),
                direct("1080p"),
                direct("Auto"),
                direct("720p"),
                direct("4K"),
            ),
        )

        assertEquals(listOf("Auto", "4K", "1080p", "720p", "360p"), ordered.map { it.quality })
    }

    @Test
    fun `maps 4k and 2160 labels to the same score`() {
        assertEquals(2160, PlaybackPolicy.qualityScore("4K"))
        assertEquals(2160, PlaybackPolicy.qualityScore("2160p"))
        assertEquals(2160, PlaybackPolicy.qualityScore(" 4K HDR "))
    }

    @Test
    fun `quality score handles auto and unknown labels`() {
        assertEquals(Int.MAX_VALUE, PlaybackPolicy.qualityScore("Auto"))
        assertEquals(Int.MAX_VALUE, PlaybackPolicy.qualityScore(" auto "))
        assertEquals(1440, PlaybackPolicy.qualityScore("1440p"))
        assertEquals(480, PlaybackPolicy.qualityScore("480p"))
        assertEquals(240, PlaybackPolicy.qualityScore("240p"))
        assertEquals(576, PlaybackPolicy.qualityScore("576p"))
        assertEquals(0, PlaybackPolicy.qualityScore("best"))
        assertEquals(0, PlaybackPolicy.qualityScore(""))
    }

    @Test
    fun `filters web renditions out of the direct order`() {
        val ordered = PlaybackPolicy.orderedDirect(
            listOf(web(), direct("720p"), direct("1080p")),
        )

        assertEquals(listOf("1080p", "720p"), ordered.map { it.quality })
    }

    @Test
    fun `filters blank urls out of the direct order`() {
        val ordered = PlaybackPolicy.orderedDirect(
            listOf(direct("1080p", " "), direct("720p", ""), direct("360p")),
        )

        assertEquals(listOf("360p"), ordered.map { it.quality })
    }

    @Test
    fun `default rendition is the highest ranked direct stream`() {
        val stream = PlaybackPolicy.defaultRendition(
            listOf(web(), direct("360p"), direct("1080p"), direct("720p")),
        )

        assertNotNull(stream)
        assertEquals("1080p", stream?.quality)
    }

    @Test
    fun `default rendition is null without a direct stream`() {
        assertNull(PlaybackPolicy.defaultRendition(emptyList()))
        assertNull(PlaybackPolicy.defaultRendition(listOf(web())))
        assertNull(PlaybackPolicy.defaultRendition(listOf(direct("1080p", " "))))
    }

    @Test
    fun `web rendition is the first web stream with a url`() {
        val found = PlaybackPolicy.webRendition(
            listOf(direct("1080p"), web(url = " "), web(url = "https://embed.example/2")),
        )

        assertNotNull(found)
        assertEquals("https://embed.example/2", found?.url)
        assertNull(PlaybackPolicy.webRendition(listOf(direct("1080p"))))
    }

    @Test
    fun `mp4 and unknown containers can be downloaded`() {
        assertNull(PlaybackPolicy.downloadRejection(direct("1080p"), isStreamHype = false))
        assertNull(
            PlaybackPolicy.downloadRejection(
                StreamRendition("1080p", "https://cdn.example/file.bin"),
                isStreamHype = false,
            ),
        )
    }

    @Test
    fun `web streams are rejected because they play in the browser`() {
        val message = PlaybackPolicy.downloadRejection(web(), isStreamHype = false)

        assertEquals(
            "StreamHype titles play in the web player and cannot be downloaded.",
            message,
        )
    }

    @Test
    fun `streamhype catalog is rejected even when the url looks direct`() {
        assertEquals(
            "StreamHype titles play in the web player and cannot be downloaded.",
            PlaybackPolicy.downloadRejection(direct("1080p"), isStreamHype = true),
        )
    }

    @Test
    fun `hls manifests are rejected with the container name`() {
        val message = PlaybackPolicy.downloadRejection(
            StreamRendition("1080p", "https://cdn.example/master.m3u8"),
            isStreamHype = false,
        )

        assertEquals("The HLS downloader is not enabled in this build.", message)
    }

    @Test
    fun `dash manifests are rejected with the container name`() {
        val message = PlaybackPolicy.downloadRejection(
            StreamRendition("1080p", "https://cdn.example/manifest.mpd?token=1"),
            isStreamHype = false,
        )

        assertEquals("The DASH downloader is not enabled in this build.", message)
    }

    @Test
    fun `format size returns null for missing or non positive byte counts`() {
        assertNull(PlaybackPolicy.formatSize(null))
        assertNull(PlaybackPolicy.formatSize(0))
        assertNull(PlaybackPolicy.formatSize(-1))
    }

    @Test
    fun `format size renders bytes without a decimal`() {
        assertEquals("1 B", PlaybackPolicy.formatSize(1))
        assertEquals("512 B", PlaybackPolicy.formatSize(512))
        assertEquals("1023 B", PlaybackPolicy.formatSize(1023))
    }

    @Test
    fun `format size scales through kb mb gb and tb`() {
        assertEquals("1.0 KB", PlaybackPolicy.formatSize(1024))
        assertEquals("1.5 KB", PlaybackPolicy.formatSize(1536))
        assertEquals("1.0 MB", PlaybackPolicy.formatSize(1024L * 1024))
        assertEquals("2.5 GB", PlaybackPolicy.formatSize((2.5 * 1024 * 1024 * 1024).toLong()))
        assertEquals("1.0 TB", PlaybackPolicy.formatSize(1024L * 1024 * 1024 * 1024))
    }

    @Test
    fun `format size stops scaling at terabytes`() {
        val rendered = PlaybackPolicy.formatSize(2048L * 1024 * 1024 * 1024)

        assertTrue(rendered!!.endsWith(" TB"))
        assertEquals("2.0 TB", rendered)
    }
}
