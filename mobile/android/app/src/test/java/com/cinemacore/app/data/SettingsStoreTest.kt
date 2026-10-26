package com.cinemacore.app.data

import com.cinemacore.app.domain.AppSettings
import com.cinemacore.app.domain.SourceMode
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsStoreTest {
    private val directories = mutableListOf<File>()

    private fun newDirectory(): File =
        Files.createTempDirectory("settings-store-test").toFile().also { directories += it }

    private fun newStore(directory: File) = SettingsStore(directory)

    @After
    fun cleanUp() {
        directories.forEach { it.deleteRecursively() }
    }

    @Test
    fun `a fresh store exposes the defaults`() = runBlocking {
        val store = newStore(newDirectory())

        assertEquals(AppSettings(), store.value)
        assertEquals(SourceMode.BUILT_IN, store.settings.value.sourceMode)
        assertEquals(AppSettings.DEFAULT_GATEWAY, store.value.effectiveGatewayUrl)
        assertTrue(store.value.hiddenRails.isEmpty())
        assertTrue(store.value.railOrder.isEmpty())
    }

    @Test
    fun `updates are written to settings json and reload from disk`() = runBlocking {
        val directory = newDirectory()
        val store = newStore(directory)

        store.update { it.copy(playbackSpeed = 1.5f, autoPlayNext = false) }

        val reloaded = newStore(directory)
        assertEquals(1.5f, reloaded.value.playbackSpeed, 0.0f)
        assertFalse(reloaded.value.autoPlayNext)
        assertTrue(File(directory, "settings.json").isFile)
    }

    @Test
    fun `writes are atomic and leave no temporary file behind`() = runBlocking {
        val directory = newDirectory()
        val store = newStore(directory)

        store.setSource(SourceMode.DEMO)

        assertTrue(File(directory, "settings.json").isFile)
        assertFalse(File(directory, "settings.json.tmp").exists())
        assertEquals(listOf("settings.json"), directory.list()!!.toList())
    }

    @Test
    fun `a corrupt settings file falls back to the defaults`() = runBlocking {
        val directory = newDirectory()
        File(directory, "settings.json").writeText("{ not valid json")

        val store = newStore(directory)

        assertEquals(AppSettings(), store.value)
    }

    @Test
    fun `set source persists the mode`() = runBlocking {
        val directory = newDirectory()
        val store = newStore(directory)

        store.setSource(SourceMode.STREAM_HYPE)

        assertEquals(SourceMode.STREAM_HYPE, store.value.sourceMode)
        assertEquals(SourceMode.STREAM_HYPE, newStore(directory).value.sourceMode)
    }

    @Test
    fun `apply gateway trims the url and selects the gateway source`() = runBlocking {
        val store = newStore(newDirectory())

        store.setSource(SourceMode.DEMO)
        val updated = store.applyGateway("  http://192.168.1.10:9000  ")

        assertEquals("http://192.168.1.10:9000", updated.gatewayUrl)
        assertEquals(SourceMode.GATEWAY, updated.sourceMode)
        assertEquals("http://192.168.1.10:9000", updated.effectiveGatewayUrl)
    }

    @Test
    fun `apply gateway with a blank url falls back to the default gateway`() = runBlocking {
        val store = newStore(newDirectory())

        store.applyGateway("   ")

        assertEquals("", store.value.gatewayUrl)
        assertEquals(AppSettings.DEFAULT_GATEWAY, store.value.effectiveGatewayUrl)
    }

    @Test
    fun `tmdb key is trimmed before it is stored`() = runBlocking {
        val store = newStore(newDirectory())

        store.setTmdbKey("  abc123  ")

        assertEquals("abc123", store.value.tmdbKey)
    }

    @Test
    fun `toggling a hidden rail adds it sorted and removes it again`() = runBlocking {
        val store = newStore(newDirectory())

        store.toggleHiddenRail("Trending Now")
        store.toggleHiddenRail("Top Rated")

        assertEquals(listOf("Top Rated", "Trending Now"), store.value.hiddenRails)

        store.toggleHiddenRail("Trending Now")

        assertEquals(listOf("Top Rated"), store.value.hiddenRails)
    }

    @Test
    fun `hidden rails persist across a reload`() = runBlocking {
        val directory = newDirectory()
        val store = newStore(directory)

        store.toggleHiddenRail("Popular TV")

        assertEquals(listOf("Popular TV"), newStore(directory).value.hiddenRails)
    }

    @Test
    fun `moving a rail swaps it with its neighbour`() = runBlocking {
        val store = newStore(newDirectory())
        store.update { it.copy(railOrder = listOf("a", "b", "c")) }

        store.moveRail("b", -1)

        assertEquals(listOf("b", "a", "c"), store.value.railOrder)
    }

    @Test
    fun `moving a rail down swaps it with its neighbour`() = runBlocking {
        val store = newStore(newDirectory())
        store.update { it.copy(railOrder = listOf("a", "b", "c")) }

        store.moveRail("a", 1)

        assertEquals(listOf("b", "a", "c"), store.value.railOrder)
    }

    @Test
    fun `moving past the end of the list is clamped and changes nothing`() = runBlocking {
        val store = newStore(newDirectory())
        store.update { it.copy(railOrder = listOf("a", "b", "c")) }

        store.moveRail("c", 5)
        assertEquals(listOf("a", "b", "c"), store.value.railOrder)

        store.moveRail("a", -5)
        assertEquals(listOf("a", "b", "c"), store.value.railOrder)
    }

    @Test
    fun `moving an unknown rail or an empty order is a no-op`() = runBlocking {
        val store = newStore(newDirectory())

        store.moveRail("a", 1)
        assertTrue(store.value.railOrder.isEmpty())

        store.update { it.copy(railOrder = listOf("a", "b")) }
        store.moveRail("missing", 1)

        assertEquals(listOf("a", "b"), store.value.railOrder)
    }

    @Test
    fun `rail order persists across a reload`() = runBlocking {
        val directory = newDirectory()
        val store = newStore(directory)
        store.update { it.copy(railOrder = listOf("a", "b", "c")) }

        store.moveRail("c", -1)

        assertEquals(listOf("a", "c", "b"), newStore(directory).value.railOrder)
    }

    @Test
    fun `the state flow reflects updates`() = runBlocking {
        val store = newStore(newDirectory())

        store.update { it.copy(autoPlayNext = false) }

        assertFalse(store.settings.value.autoPlayNext)
    }
}
