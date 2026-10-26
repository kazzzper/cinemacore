package com.cinemacore.app.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaContainerTest {
    @Test
    fun `classifies mp4 family by extension`() {
        assertEquals(MediaContainer.MP4, MediaContainer.classify("https://cdn.example/movie.mp4"))
        assertEquals(MediaContainer.MP4, MediaContainer.classify("https://cdn.example/movie.m4v"))
        assertEquals(MediaContainer.MP4, MediaContainer.classify("https://cdn.example/movie.mov"))
    }

    @Test
    fun `classifies manifests by extension`() {
        assertEquals(MediaContainer.HLS, MediaContainer.classify("https://cdn.example/master.m3u8"))
        assertEquals(MediaContainer.DASH, MediaContainer.classify("https://cdn.example/manifest.mpd"))
    }

    @Test
    fun `extension matching is case insensitive`() {
        assertEquals(MediaContainer.MP4, MediaContainer.classify("https://cdn.example/MOVIE.MP4"))
        assertEquals(MediaContainer.HLS, MediaContainer.classify("https://cdn.example/MASTER.M3U8"))
        assertEquals(MediaContainer.DASH, MediaContainer.classify("https://cdn.example/MANIFEST.MPD"))
    }

    @Test
    fun `query strings and fragments do not hide the extension`() {
        assertEquals(
            MediaContainer.MP4,
            MediaContainer.classify("https://cdn.example/movie.mp4?token=abc.def&expires=1"),
        )
        assertEquals(
            MediaContainer.HLS,
            MediaContainer.classify("https://cdn.example/master.m3u8?foo=bar.mp4"),
        )
        assertEquals(
            MediaContainer.DASH,
            MediaContainer.classify("https://cdn.example/manifest.mpd#t=10"),
        )
    }

    @Test
    fun `unknown extensions and missing extensions are unknown`() {
        assertEquals(MediaContainer.UNKNOWN, MediaContainer.classify("https://cdn.example/movie.mkv"))
        assertEquals(MediaContainer.UNKNOWN, MediaContainer.classify("https://cdn.example/play"))
        assertEquals(MediaContainer.UNKNOWN, MediaContainer.classify(""))
    }

    @Test
    fun `classifies by content type`() {
        assertEquals(MediaContainer.HLS, MediaContainer.classifyContentType("application/vnd.apple.mpegurl"))
        assertEquals(MediaContainer.HLS, MediaContainer.classifyContentType("application/x-mpegurl"))
        assertEquals(MediaContainer.HLS, MediaContainer.classifyContentType("audio/mpegurl"))
        assertEquals(MediaContainer.HLS, MediaContainer.classifyContentType("audio/x-mpegurl"))
        assertEquals(MediaContainer.DASH, MediaContainer.classifyContentType("application/dash+xml"))
        assertEquals(MediaContainer.MP4, MediaContainer.classifyContentType("video/mp4"))
        assertEquals(MediaContainer.MP4, MediaContainer.classifyContentType("application/mp4"))
        assertEquals(MediaContainer.MP4, MediaContainer.classifyContentType("video/quicktime"))
    }

    @Test
    fun `content type ignores parameters and surrounding casing`() {
        assertEquals(
            MediaContainer.HLS,
            MediaContainer.classifyContentType("  Application/VND.Apple.MpegURL ; charset=utf-8 "),
        )
        assertEquals(
            MediaContainer.DASH,
            MediaContainer.classifyContentType("application/dash+xml;charset=UTF-8"),
        )
    }

    @Test
    fun `unknown or missing content type returns null`() {
        assertNull(MediaContainer.classifyContentType(null))
        assertNull(MediaContainer.classifyContentType(""))
        assertNull(MediaContainer.classifyContentType("text/html"))
        assertNull(MediaContainer.classifyContentType("application/octet-stream"))
    }

    @Test
    fun `content type wins over the url extension`() {
        assertEquals(
            MediaContainer.HLS,
            MediaContainer.classify("https://cdn.example/file.mp4", "application/x-mpegurl"),
        )
        assertEquals(
            MediaContainer.MP4,
            MediaContainer.classify("https://cdn.example/file.mp4", "text/html"),
        )
    }

    @Test
    fun `manifest flags match the container`() {
        assertTrue(MediaContainer.HLS.isManifest)
        assertTrue(MediaContainer.DASH.isManifest)
        assertFalse(MediaContainer.MP4.isManifest)
        assertFalse(MediaContainer.UNKNOWN.isManifest)

        assertFalse(MediaContainer.HLS.isDirectDownload)
        assertFalse(MediaContainer.DASH.isDirectDownload)
        assertTrue(MediaContainer.MP4.isDirectDownload)
        assertTrue(MediaContainer.UNKNOWN.isDirectDownload)
    }

    @Test
    fun `display names are user facing`() {
        assertEquals("MP4", MediaContainer.MP4.displayName)
        assertEquals("HLS", MediaContainer.HLS.displayName)
        assertEquals("DASH", MediaContainer.DASH.displayName)
        assertEquals("stream", MediaContainer.UNKNOWN.displayName)
    }

    @Test
    fun `asset extensions stay consistent with the downloader`() {
        assertEquals("mp4", MediaContainer.MP4.assetExtension)
        assertEquals("mp4", MediaContainer.UNKNOWN.assetExtension)
        assertEquals("hls", MediaContainer.HLS.assetExtension)
        assertEquals("dash", MediaContainer.DASH.assetExtension)
    }

    @Test
    fun `stream rendition derives its container from its url`() {
        assertEquals(
            MediaContainer.HLS,
            StreamRendition("1080p", "https://cdn.example/master.m3u8").container,
        )
        assertEquals(
            MediaContainer.MP4,
            StreamRendition("1080p", "https://cdn.example/movie.mp4").container,
        )
    }
}
