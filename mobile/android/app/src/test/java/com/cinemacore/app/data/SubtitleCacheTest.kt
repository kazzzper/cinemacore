package com.cinemacore.app.data

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubtitleCacheTest {
    private val tempDirectories = mutableListOf<File>()

    private fun tempDir(): File =
        Files.createTempDirectory("subtitle-cache-test").toFile().also { tempDirectories += it }

    @After
    fun cleanUp() {
        tempDirectories.forEach { it.deleteRecursively() }
    }

    @Test
    fun `srt comma timestamps become webvtt dot timestamps`() {
        val srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello, world\r\n"

        val vtt = SubtitleCache.toVtt(srt)

        assertEquals(
            "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500\nHello, world\n\n",
            vtt,
        )
    }

    @Test
    fun `srt hours are preserved and the header is added once`() {
        val srt = "00:12:34,567 --> 00:12:36,001\nLine one\nLine two\n"

        val vtt = SubtitleCache.toVtt(srt)

        assertTrue(vtt.startsWith("WEBVTT\n\n"))
        assertTrue(vtt.contains("00:12:34.567 --> 00:12:36.001"))
        assertFalse(vtt.contains("00:12:34,567"))
        assertEquals(1, Regex("WEBVTT").findAll(vtt).count())
    }

    @Test
    fun `two component timestamps gain an hours field`() {
        val srt = "00:01,500 --> 00:02,000\nShort\n"

        val vtt = SubtitleCache.toVtt(srt)

        assertTrue(vtt.contains("00:00:01.500 --> 00:00:02.000"))
    }

    @Test
    fun `webvtt input is returned unchanged`() {
        val webvtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n"

        assertEquals(webvtt, SubtitleCache.toVtt(webvtt))
    }

    @Test
    fun `webvtt input with crlf and a bom is normalised but not wrapped again`() {
        val raw = "\uFEFFWEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nHello\r\n"

        val vtt = SubtitleCache.toVtt(raw)

        assertEquals("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n", vtt)
        assertEquals("WEBVTT", vtt.substringBefore('\n'))
    }

    @Test
    fun `converting twice is idempotent`() {
        val first = SubtitleCache.toVtt("1\n00:00:01,000 --> 00:00:02,000\nHi\n")

        assertEquals(first, SubtitleCache.toVtt(first))
    }

    @Test
    fun `cue text with commas is not rewritten`() {
        val srt = "1\n00:00:01,000 --> 00:00:02,000\nOne, two, three\n"

        val vtt = SubtitleCache.toVtt(srt)

        assertTrue(vtt.contains("One, two, three"))
    }

    @Test
    fun `safe name lowercases and replaces unsafe characters`() {
        assertEquals("english--us", SubtitleCache.safeName("English (US)"))
        assertEquals("s01e02.ass", SubtitleCache.safeName("S01E02.ASS"))
        assertEquals("espa-ol", SubtitleCache.safeName("Español"))
    }

    @Test
    fun `safe name never keeps path separators`() {
        val name = SubtitleCache.safeName("../../etc/passwd")

        assertEquals("..-..-etc-passwd", name)
        assertFalse(name.contains('/'))
        assertFalse(name.contains('\\'))
    }

    @Test
    fun `safe name falls back for blank input`() {
        assertEquals("subtitle", SubtitleCache.safeName(""))
        assertEquals("subtitle", SubtitleCache.safeName("   "))
        assertEquals("subtitle", SubtitleCache.safeName("///"))
    }

    @Test
    fun `safe name is capped at one hundred characters`() {
        val name = SubtitleCache.safeName("A".repeat(120))

        assertEquals(100, name.length)
        assertEquals("a".repeat(100), name)
    }

    @Test
    fun `storing no tracks creates the target directory and returns nothing`() = runBlocking {
        val directory = tempDir()
        val target = File(directory, "episode")

        val stored = SubtitleCache(directory).store(
            tracks = emptyList(),
            idPrefix = "episode",
            targetDirectory = target,
        )

        assertTrue(stored.isEmpty())
        assertTrue(target.isDirectory)
    }
}
