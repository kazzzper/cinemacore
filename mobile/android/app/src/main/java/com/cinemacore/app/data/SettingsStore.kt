package com.cinemacore.app.data

import com.cinemacore.app.domain.AppSettings
import com.cinemacore.app.domain.SourceMode
import java.io.File
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.builtins.serializer

class SettingsStore(directory: File) {
    private val store = JsonStateStore(
        file = File(directory, "settings.json"),
        serializer = AppSettings.serializer(),
        defaultValue = AppSettings(),
    )

    val settings: StateFlow<AppSettings> = store.state

    val value: AppSettings
        get() = store.value

    suspend fun update(transform: (AppSettings) -> AppSettings): AppSettings =
        store.update(transform)

    suspend fun applyGateway(url: String): AppSettings = update {
        it.copy(
            gatewayUrl = url.trim(),
            sourceMode = SourceMode.GATEWAY,
        )
    }

    suspend fun setSource(mode: SourceMode): AppSettings = update {
        it.copy(sourceMode = mode)
    }

    suspend fun setTmdbKey(key: String): AppSettings = update {
        it.copy(tmdbKey = key.trim())
    }

    suspend fun toggleHiddenRail(title: String): AppSettings = update { settings ->
        val hidden = settings.hiddenRails.toMutableSet()
        if (!hidden.add(title)) hidden.remove(title)
        settings.copy(hiddenRails = hidden.toList().sorted())
    }

    suspend fun moveRail(title: String, delta: Int): AppSettings = update { settings ->
        val current = settings.railOrder.toMutableList()
        if (current.isEmpty()) return@update settings
        val index = current.indexOf(title)
        if (index < 0) return@update settings
        val target = (index + delta).coerceIn(0, current.lastIndex)
        if (target == index) return@update settings
        current.removeAt(index)
        current.add(target, title)
        settings.copy(railOrder = current)
    }
}
