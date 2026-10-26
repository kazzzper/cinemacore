package com.cinemacore.app.ui.downloads

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.cinemacore.app.domain.DownloadGrouping
import com.cinemacore.app.domain.DownloadSortKey
import com.cinemacore.app.ui.CinemacoreViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the screen can render once it has looked at the queue and its folder. */
sealed interface DownloadsPhase {
    data object Loading : DownloadsPhase
    data object Ready : DownloadsPhase
    data object StorageUnavailable : DownloadsPhase
}

/**
 * Screen-local state for the download manager.
 *
 * The queue belongs to DownloadEngine and the sort choices to AppSettings; this
 * only measures the storage footer and reports whether the directory can take
 * writes, which neither of them can express.
 */
class DownloadsViewModel(private val app: CinemacoreViewModel) : ViewModel() {
    var phase by mutableStateOf<DownloadsPhase>(DownloadsPhase.Loading)
        private set

    var bytesOnDisk by mutableLongStateOf(0L)
        private set

    private var loadJob: Job? = null

    init {
        load()
    }

    fun load() {
        if (loadJob?.isActive == true) return
        loadJob = viewModelScope.launch {
            phase = DownloadsPhase.Loading
            val canStore = withContext(Dispatchers.IO) {
                runCatching { app.canStoreDownloads() }.getOrDefault(false)
            }
            val measured = withContext(Dispatchers.IO) {
                runCatching { app.bytesOnDisk() }.getOrNull()
            }
            if (measured != null) bytesOnDisk = measured
            phase = if (canStore) DownloadsPhase.Ready else DownloadsPhase.StorageUnavailable
        }
    }

    /** Re-measured when the queue gains, loses, or finishes an item. */
    fun refreshStorage() {
        viewModelScope.launch { refreshStorageNow() }
    }

    fun pause(id: String) {
        viewModelScope.launch { app.pause(id) }
    }

    fun resume(id: String) {
        viewModelScope.launch { app.resume(id) }
    }

    fun retry(id: String) {
        viewModelScope.launch { app.retry(id) }
    }

    fun pauseShow(ids: List<String>) {
        viewModelScope.launch { ids.forEach { app.pause(it) } }
    }

    fun resumeShow(ids: List<String>) {
        viewModelScope.launch { ids.forEach { app.resume(it) } }
    }

    fun cancel(ids: List<String>) {
        viewModelScope.launch {
            ids.forEach { app.cancel(it) }
            refreshStorageNow()
        }
    }

    fun remove(ids: List<String>) {
        viewModelScope.launch {
            ids.forEach { app.remove(it) }
            refreshStorageNow()
        }
    }

    fun pauseAll() {
        viewModelScope.launch { app.pauseAll() }
    }

    fun resumeAll() {
        viewModelScope.launch { app.resumeAll() }
    }

    fun removeCompleted() {
        viewModelScope.launch {
            app.removeCompleted()
            refreshStorageNow()
        }
    }

    fun setSortKey(key: DownloadSortKey) {
        viewModelScope.launch {
            app.setDownloadSort(
                key = key,
                ascending = app.settings.downloadSortAscending,
                grouping = app.settings.downloadGrouping,
            )
        }
    }

    fun setAscending(ascending: Boolean) {
        viewModelScope.launch {
            app.setDownloadSort(
                key = app.settings.downloadSortKey,
                ascending = ascending,
                grouping = app.settings.downloadGrouping,
            )
        }
    }

    fun setGrouping(grouping: DownloadGrouping) {
        viewModelScope.launch {
            app.setDownloadSort(
                key = app.settings.downloadSortKey,
                ascending = app.settings.downloadSortAscending,
                grouping = grouping,
            )
        }
    }

    private suspend fun refreshStorageNow() {
        val measured = withContext(Dispatchers.IO) {
            runCatching { app.bytesOnDisk() }.getOrNull()
        }
        if (measured != null) bytesOnDisk = measured
    }

    companion object {
        fun factory(app: CinemacoreViewModel): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    DownloadsViewModel(app) as T
            }
    }
}
