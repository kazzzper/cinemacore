package com.cinemacore.app.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.cinemacore.app.AppContainer
import com.cinemacore.app.data.DemoCatalogRepository
import com.cinemacore.app.data.DownloadRequest
import com.cinemacore.app.data.DownloadService
import com.cinemacore.app.domain.AppSettings
import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.DownloadGrouping
import com.cinemacore.app.domain.DownloadItem
import com.cinemacore.app.domain.DownloadQueueOutcome
import com.cinemacore.app.domain.DownloadSortKey
import com.cinemacore.app.domain.DownloadTarget
import com.cinemacore.app.domain.LibraryData
import com.cinemacore.app.domain.LibraryEntry
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.ResumePoint
import com.cinemacore.app.domain.SourceMode
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Process-level state: the resolved catalogue, the user's library, preferences
 * and the download queue's identity. Screen loading/error state stays in each
 * screen's own view model.
 */
class CinemacoreViewModel(private val container: AppContainer) : ViewModel() {
    var repository: CatalogRepository by mutableStateOf(container.repository)
        private set

    var sourceNote: String by mutableStateOf(container.lastResolution.note)
        private set

    var isLive: Boolean by mutableStateOf(false)
        private set

    var settings: AppSettings by mutableStateOf(container.settings.value)
        private set

    var library: LibraryData by mutableStateOf(container.library.value)
        private set

    var repositoryGeneration: Int by mutableIntStateOf(0)
        private set

    var bootstrapped: Boolean by mutableStateOf(false)
        private set

    var gatewayVersion: String? by mutableStateOf(null)
        private set

    val downloads: StateFlow<List<DownloadItem>> = container.downloads.items

    val downloadsDirectory = container.downloadsDirectory
    val subtitleCache = container.subtitleCache
    val player get() = container.player

    init {
        viewModelScope.launch {
            container.settings.settings.collect { settings = it }
        }
        viewModelScope.launch {
            container.library.data.collect { library = it }
        }
        container.downloads.captionProvider = { item ->
            runCatching {
                repository.play(item.subjectId, item.season, item.episode)
            }.getOrNull()?.subtitles?.let { tracks ->
                if (tracks.isEmpty()) {
                    emptyList()
                } else {
                    subtitleCache.store(
                        tracks = tracks,
                        cookie = item.cookie,
                        idPrefix = item.id,
                        targetDirectory = downloadsDirectory,
                    )
                }
            }.orEmpty()
        }
        viewModelScope.launch { bootstrap() }
    }

    suspend fun bootstrap() {
        val resolution = runCatching { container.bootstrap() }.getOrElse {
            container.lastResolution
        }
        repository = resolution.repository
        sourceNote = resolution.note
        isLive = repository !is DemoCatalogRepository
        repositoryGeneration++
        bootstrapped = true
        container.downloads.start()
        if (container.downloads.activeCount() > 0) DownloadService.start(container.context)
    }

    suspend fun setSourceMode(mode: SourceMode) {
        container.settings.setSource(mode)
        resetPlayback()
        bootstrap()
    }

    suspend fun setGatewayUrl(url: String) {
        container.settings.applyGateway(url)
        resetPlayback()
        bootstrap()
    }

    suspend fun setTmdbKey(key: String) {
        container.settings.setTmdbKey(key)
        if (settings.sourceMode == SourceMode.STREAM_HYPE) {
            resetPlayback()
            bootstrap()
        }
    }

    private fun resetPlayback() {
        runCatching {
            player.stop()
            player.clearMediaItems()
        }
    }

    suspend fun probeGatewayVersion() {
        gatewayVersion = container.gatewayVersion()
    }

    fun isInWatchlist(subjectId: String): Boolean =
        library.watchlist.any { it.subject.id == subjectId }

    suspend fun toggleWatchlist(subject: Subject): Boolean =
        container.library.toggleWatchlist(subject)

    suspend fun removeFromWatchlist(subjectId: String) =
        container.library.removeFromWatchlist(subjectId)

    suspend fun clearWatchlist() {
        container.library.clearWatchlist()
    }

    suspend fun recordResume(
        request: PlaybackRequest,
        positionMs: Long,
        durationMs: Long,
    ) {
        if (durationMs <= 0 || positionMs < 5_000) return
        val subject = Subject(
            id = request.subjectId,
            title = request.title,
            poster = request.poster,
            kind = if (request.isSeries) "series" else "movie",
        )
        container.library.recordResume(
            subject = subject,
            season = request.season,
            episode = request.episode,
            episodeTitle = request.episodeTitle,
            positionMs = positionMs,
            durationMs = durationMs,
        )
    }

    fun resumeFor(request: PlaybackRequest): ResumePoint? =
        container.library.resumeFor(request.subjectId, request.season, request.episode)
            ?: container.library.latestResumeFor(request.subjectId)

    suspend fun removeHistory(key: String) = container.library.removeHistory(key)

    suspend fun clearHistory() = container.library.clearHistory()

    suspend fun updateSettings(transform: (AppSettings) -> AppSettings) {
        container.settings.update(transform)
    }

    suspend fun setPlaybackSpeed(speed: Float) = updateSettings { it.copy(playbackSpeed = speed) }

    suspend fun setAutoPlayNext(enabled: Boolean) = updateSettings { it.copy(autoPlayNext = enabled) }

    suspend fun setDownloadSort(key: DownloadSortKey, ascending: Boolean, grouping: DownloadGrouping) {
        updateSettings {
            it.copy(
                downloadSortKey = key,
                downloadSortAscending = ascending,
                downloadGrouping = grouping,
            )
        }
    }

    suspend fun enqueueTargets(subject: Subject, targets: List<DownloadTarget>): DownloadQueueOutcome {
        val requests = mutableListOf<DownloadRequest>()
        var failed = 0
        var reason: String? = null
        for (target in targets) {
            try {
                val info = repository.play(subject.id, target.season, target.episode?.number)
                val ordered = PlaybackPolicy.orderedDirect(info.streams)
                val stream = target.quality
                    ?.let { quality -> ordered.firstOrNull { it.quality == quality } }
                    ?: ordered.firstOrNull()
                if (stream == null) {
                    failed++
                    reason = reason ?: "The provider returned no playable video stream."
                    continue
                }
                val rejection = PlaybackPolicy.downloadRejection(stream, stream.isWeb)
                if (rejection != null) {
                    failed++
                    reason = reason ?: rejection
                    continue
                }
                requests += DownloadRequest(
                    subject = subject,
                    season = target.season,
                    episode = target.episode?.number,
                    episodeTitle = target.episodeTitle ?: target.episode?.displayTitle,
                    stream = stream,
                )
            } catch (error: Exception) {
                failed++
                reason = reason ?: (error as? com.cinemacore.app.domain.CinemacoreError)
                    ?.userMessage ?: error.message
            }
        }
        val results = if (requests.isEmpty()) emptyList() else container.downloads.enqueue(requests)
        val added = results.count { it.added }
        if (added > 0) DownloadService.start(container.context)
        val message = when {
            requestedMessage(targets.size, added, failed, reason) != null ->
                requestedMessage(targets.size, added, failed, reason)!!
            results.any { !it.added } -> results.first { !it.added }.message
            else -> DownloadQueueOutcome(
                requested = targets.size,
                added = added,
                failed = failed,
                failureReason = reason,
            ).message
        }
        return DownloadQueueOutcome(
            requested = targets.size,
            added = added,
            failed = failed,
            failureReason = message,
        )
    }

    private fun requestedMessage(count: Int, added: Int, failed: Int, reason: String?): String? =
        if (added == 0 && failed > 0) {
            reason ?: "No streams were available for those $count episodes."
        } else {
            null
        }

    suspend fun enqueueRendition(
        request: PlaybackRequest,
        rendition: StreamRendition,
    ): DownloadQueueOutcome {
        val rejection = PlaybackPolicy.downloadRejection(rendition, rendition.isWeb)
        if (rejection != null) {
            return DownloadQueueOutcome(1, 0, 1, rejection)
        }
        val subject = Subject(
            id = request.subjectId,
            title = request.title,
            poster = request.poster,
            kind = if (request.isSeries) "series" else "movie",
        )
        val results = container.downloads.enqueue(
            listOf(
                DownloadRequest(
                    subject = subject,
                    season = request.season,
                    episode = request.episode,
                    episodeTitle = request.episodeTitle,
                    stream = rendition,
                ),
            ),
        )
        if (results.any { it.added }) DownloadService.start(container.context)
        val result = results.firstOrNull()
        return DownloadQueueOutcome(
            requested = 1,
            added = if (result?.added == true) 1 else 0,
            failed = if (result?.added == true) 0 else 1,
            failureReason = result?.message,
        )
    }

    val watchlist: List<LibraryEntry>
        get() = library.watchlist

    val history: List<ResumePoint>
        get() = library.history

    fun canStoreDownloads(): Boolean =
        downloadsDirectory.isDirectory && downloadsDirectory.canWrite()

    suspend fun pause(id: String) = container.downloads.pause(id)

    suspend fun resume(id: String) {
        container.downloads.resume(id)
        DownloadService.start(container.context)
    }

    suspend fun retry(id: String) {
        container.downloads.retry(id)
        DownloadService.start(container.context)
    }
    suspend fun cancel(id: String) = container.downloads.cancel(id)
    suspend fun remove(id: String) = container.downloads.remove(id)
    suspend fun pauseAll() = container.downloads.pauseAll()

    suspend fun resumeAll() {
        container.downloads.resumeAll()
        DownloadService.start(container.context)
    }
    suspend fun removeCompleted() = container.downloads.removeCompleted()
    fun fileFor(item: DownloadItem) = container.downloads.fileFor(item)
    fun activeCount(items: List<DownloadItem> = downloads.value) =
        container.downloads.activeCount(items)
    fun bytesOnDisk(): Long = container.downloads.bytesOnDisk()

    companion object {
        fun factory(container: AppContainer): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    CinemacoreViewModel(container) as T
            }
    }
}
