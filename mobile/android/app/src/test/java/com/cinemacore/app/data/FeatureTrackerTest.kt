package com.cinemacore.app.data

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FeatureTrackerTest {
    private val tempDirectories = mutableListOf<File>()

    private fun tempDir(): File =
        Files.createTempDirectory("feature-tracker-test").toFile().also { tempDirectories += it }

    @After
    fun cleanUp() {
        tempDirectories.forEach { it.deleteRecursively() }
    }

    @Test
    fun `chromecast is the only feature off by default`() = runBlocking {
        val tracker = FeatureTracker(tempDir())

        assertFalse(tracker.isEnabled(Feature.CHROMECAST))
        assertTrue(tracker.isEnabled(Feature.PLAYBACK))
        var offByDefault = 0
        for (feature in Feature.entries) {
            if (!tracker.isEnabled(feature)) offByDefault++
        }
        assertEquals(1, offByDefault)
    }

    @Test
    fun `enabled override survives a second instance`() = runBlocking {
        val directory = tempDir()
        FeatureTracker(directory).setEnabled(Feature.PLAYBACK, false)

        assertFalse(FeatureTracker(directory).isEnabled(Feature.PLAYBACK))
    }

    @Test
    fun `record counts uses and failures separately`() = runBlocking {
        val tracker = FeatureTracker(tempDir())
        tracker.record(Feature.DOWNLOADS, FeatureEvent.Kind.USED)
        tracker.record(Feature.DOWNLOADS, FeatureEvent.Kind.USED)
        tracker.record(Feature.DOWNLOADS, FeatureEvent.Kind.FAILED)

        val usage = tracker.usage().first { it.feature == Feature.DOWNLOADS }
        assertEquals(2, usage.useCount)
        assertEquals(1, usage.failureCount)
        assertEquals(3, tracker.events(limit = 10).size)
    }

    @Test
    fun `event log is capped but totals stay exact`() = runBlocking {
        val tracker = FeatureTracker(tempDir())
        repeat(520) { tracker.record(Feature.PLAYBACK, FeatureEvent.Kind.USED) }

        assertEquals(FeatureTracker.EVENT_LIMIT, tracker.events(limit = 1000).size)
        assertEquals(520, tracker.usage().first { it.feature == Feature.PLAYBACK }.useCount)
    }

    @Test
    fun `events are newest first`() = runBlocking {
        val tracker = FeatureTracker(tempDir())
        tracker.record(Feature.PLAYBACK, FeatureEvent.Kind.USED, detail = "first")
        tracker.record(Feature.SEARCH, FeatureEvent.Kind.USED, detail = "second")

        val events = tracker.events(limit = 10)
        assertEquals(Feature.SEARCH, events.first().feature)
        assertEquals("first", events.last().detail)
    }

    @Test
    fun `a document naming an unknown feature keeps its other events`() = runBlocking {
        val directory = tempDir()
        File(directory, "features.json").writeText(
            """
            {
              "enabled": {"playback": false, "retiredFeature": true},
              "usage": {"retiredFeature": {"useCount": 9}},
              "events": [
                {"feature": "retiredFeature", "kind": "USED", "timestamp": 1},
                {"feature": "playback", "kind": "USED", "timestamp": 2}
              ]
            }
            """.trimIndent(),
        )

        val tracker = FeatureTracker(directory)
        assertFalse(tracker.isEnabled(Feature.PLAYBACK))
        assertEquals(1, tracker.events(limit = 10).size)
        assertEquals(Feature.PLAYBACK, tracker.events(limit = 10).single().feature)
    }

    @Test
    fun `reset clears overrides and counts`() = runBlocking {
        val tracker = FeatureTracker(tempDir())
        tracker.setEnabled(Feature.PLAYBACK, false)
        tracker.record(Feature.PLAYBACK, FeatureEvent.Kind.USED)

        tracker.reset()

        assertTrue(tracker.isEnabled(Feature.PLAYBACK))
        assertTrue(tracker.events().isEmpty())
        assertTrue(tracker.usage().isEmpty())
    }

    @Test
    fun `report names the registry and states the privacy promise`() = runBlocking {
        val tracker = FeatureTracker(tempDir())
        tracker.record(Feature.QUALITY_SELECTION, FeatureEvent.Kind.USED, detail = "1080p")

        val text = tracker.report().text()

        assertTrue(text.startsWith("Cinemacore feature report"))
        assertTrue(text.contains("PLAYER"))
        assertTrue(text.contains("quality_selection"))
        assertTrue(text.trimEnd().endsWith("No identifiers, titles, or URLs."))
    }
}
