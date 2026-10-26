package com.cinemacore.app.ui.player

import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.cinemacore.app.AppContainer
import com.cinemacore.app.R
import com.cinemacore.app.data.DownloadRequest
import com.cinemacore.app.data.DownloadService
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.Dub
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.MediaContainer
import com.cinemacore.app.domain.PlayInfo
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.domain.SubtitleTrack
import java.io.File
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Everything the player chrome renders. */
data class PlayerUiState(
    val request: PlaybackRequest,
    val loadState: LoadState<PlayInfo> = LoadState.Idle,
    val streams: List<StreamRendition> = emptyList(),
    val subtitles: List<SubtitleTrack> = emptyList(),
    val webUrl: String? = null,
    val rendition: StreamRendition? = null,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = true,
    val selectedSubtitle: SubtitleTrack? = null,
    val speed: Float = 1f,
    val seasons: List<Season> = emptyList(),
    val dubs: List<Dub> = emptyList(),
    val subject: Subject? = null,
    val fullscreen: Boolean = false,
    val controlsVisible: Boolean = true,
    val inPip: Boolean = false,
    val downloadNotice: String? = null,
    val notice: String? = null,
    val autoPlayNext: Boolean = true,
    val fillScreen: Boolean = false,
    val resumePositionMs: Long = 0,
)

/**
 * Owns the playback decision and the Media3 listener, but never the player's
 * lifetime: [AppContainer.player] outlives this view model so PiP and the media
 * session keep the same transport.
 */
class PlayerViewModel(
    private val container: AppContainer,
    initialRequest: PlaybackRequest,
) : ViewModel() {
    private val appContext = container.context
    private val initialSettings = container.settings.value

    var state by mutableStateOf(
        PlayerUiState(
            request = initialRequest,
            speed = initialSettings.playbackSpeed.coerceIn(MIN_SPEED, MAX_SPEED),
            autoPlayNext = initialSettings.autoPlayNext,
            fillScreen = initialSettings.playerFillScreen,
        ),
    )
        private set

    val player: ExoPlayer
        get() = container.player

    private var selectedSubtitleFile: File? = null
    private var activeUri: Uri? = null
    private var activeRendition: StreamRendition? = null
    private var loadJob: Job? = null
    private var progressJob: Job? = null
    private var settingsJob: Job? = null
    private var subtitleRequestToken = 0

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            state = state.copy(isPlaying = isPlaying)
            if (!isPlaying) recordProgress()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            val duration = player.duration
                .takeIf { it > 0 && it != C.TIME_UNSET }
                ?: 0
            state = state.copy(
                durationMs = duration,
                positionMs = player.currentPosition.coerceAtLeast(0),
                isBuffering = playbackState == Player.STATE_BUFFERING,
            )
            if (playbackState == Player.STATE_ENDED) {
                state = state.copy(isPlaying = false, controlsVisible = true)
                handleEnded()
            }
        }

        override fun onIsLoadingChanged(isLoading: Boolean) {
            state = state.copy(isBuffering = isLoading)
        }

        override fun onPlayerError(error: PlaybackException) {
            fail(CinemacoreError.Unknown(error.localizedMessage))
        }
    }

    init {
        player.addListener(listener)
        settingsJob = viewModelScope.launch {
            container.settings.settings.collect { settings ->
                val speed = settings.playbackSpeed.coerceIn(MIN_SPEED, MAX_SPEED)
                state = state.copy(
                    speed = speed,
                    autoPlayNext = settings.autoPlayNext,
                    fillScreen = settings.playerFillScreen,
                )
                if (player.playbackParameters.speed != speed) {
                    player.playbackParameters = PlaybackParameters(speed)
                }
            }
        }
        open(initialRequest)
        progressJob = viewModelScope.launch {
            var lastRecordAt = 0L
            while (isActive) {
                delay(PROGRESS_POLL_MS)
                if (state.webUrl == null && player.mediaItemCount > 0) {
                    val duration = player.duration
                        .takeIf { it > 0 && it != C.TIME_UNSET }
                        ?: 0
                    val position = player.currentPosition.coerceAtLeast(0)
                    if (position != state.positionMs || duration != state.durationMs) {
                        state = state.copy(positionMs = position, durationMs = duration)
                    }
                    if (player.isPlaying) {
                        val now = System.currentTimeMillis()
                        if (now - lastRecordAt >= RECORD_INTERVAL_MS) {
                            lastRecordAt = now
                            recordProgress()
                        }
                    }
                }
            }
        }
    }

    /** Resolves a request again, keeping the user's chrome preferences. */
    fun open(request: PlaybackRequest) {
        recordProgress()
        loadJob?.cancel()
        subtitleRequestToken++
        selectedSubtitleFile = null
        activeUri = null
        activeRendition = null
        val previous = state
        val sameSubject = previous.request.subjectId == request.subjectId
        state = PlayerUiState(
            request = request,
            loadState = LoadState.Loading,
            speed = previous.speed,
            autoPlayNext = previous.autoPlayNext,
            fillScreen = previous.fillScreen,
            fullscreen = previous.fullscreen,
            controlsVisible = true,
            inPip = previous.inPip,
            subject = previous.subject.takeIf { sameSubject },
            dubs = previous.dubs.takeIf { sameSubject }.orEmpty(),
            seasons = previous.seasons.takeIf { sameSubject }.orEmpty(),
            isBuffering = true,
        )
        player.stop()
        player.clearMediaItems()
        player.playWhenReady = false
        loadJob = viewModelScope.launch { load(request) }
    }

    fun retry() {
        val position = state.positionMs
        open(
            state.request.copy(
                startPositionMs = position.takeIf { it > 0 },
            ),
        )
    }

    fun togglePlayPause() {
        if (state.webUrl != null) return
        when {
            player.playbackState == Player.STATE_ENDED -> {
                player.seekTo(0)
                player.play()
            }
            player.isPlaying -> player.pause()
            else -> player.play()
        }
    }

    fun seekTo(positionMs: Long) {
        if (state.webUrl != null) return
        val duration = state.durationMs
        val target = if (duration > 0) {
            positionMs.coerceIn(0, duration)
        } else {
            positionMs.coerceAtLeast(0)
        }
        player.seekTo(target)
        state = state.copy(positionMs = target)
    }

    fun seekBy(deltaMs: Long) {
        seekTo(player.currentPosition + deltaMs)
    }

    fun setSpeed(speed: Float) {
        val clamped = speed.coerceIn(MIN_SPEED, MAX_SPEED)
        state = state.copy(speed = clamped)
        player.playbackParameters = PlaybackParameters(clamped)
        viewModelScope.launch {
            container.settings.update { it.copy(playbackSpeed = clamped) }
        }
    }

    fun setControlsVisible(visible: Boolean) {
        if (!state.inPip) state = state.copy(controlsVisible = visible)
    }

    fun setFullscreen(fullscreen: Boolean) {
        state = state.copy(fullscreen = fullscreen)
    }

    fun setPipMode(inPip: Boolean) {
        state = state.copy(
            inPip = inPip,
            controlsVisible = if (inPip) false else true,
        )
    }

    fun selectRendition(rendition: StreamRendition) {
        if (state.webUrl != null || rendition.isWeb) return
        if (activeRendition?.url == rendition.url) {
            state = state.copy(rendition = rendition)
            return
        }
        state = state.copy(rendition = rendition)
        val start = if (player.playbackState == Player.STATE_ENDED) {
            0
        } else {
            player.currentPosition.coerceAtLeast(0)
        }
        prepare(
            uri = Uri.parse(rendition.url),
            rendition = rendition,
            startPositionMs = start,
            playWhenReady = player.playWhenReady || player.isPlaying,
        )
    }

    fun selectSubtitle(track: SubtitleTrack?) {
        if (state.webUrl != null) return
        subtitleRequestToken++
        if (track == null) {
            selectedSubtitleFile = null
            state = state.copy(selectedSubtitle = null)
            reprepare()
            return
        }
        val token = subtitleRequestToken
        viewModelScope.launch {
            val file = if (track.url.startsWith("file:")) {
                Uri.parse(track.url).path?.let(::File)?.takeIf { it.exists() }
            } else {
                try {
                    container.subtitleCache.cached(track, state.rendition?.cookie)
                } catch (cancelled: CancellationException) {
                throw cancelled
                } catch (error: Exception) {
                    null
                }
            }
            if (token != subtitleRequestToken) return@launch
            if (file == null) {
                state = state.copy(
                    notice = appContext.getString(R.string.player_subtitle_failed),
                )
                return@launch
            }
            selectedSubtitleFile = file
            state = state.copy(selectedSubtitle = track, notice = null)
            reprepare()
        }
    }

    /**
     * Dubs are separate provider subjects, so switching audio re-resolves the
     * stream instead of selecting an ExoPlayer audio track.
     */
    fun selectDub(dub: Dub) {
        if (dub.subjectId == state.request.subjectId) return
        val position = player.currentPosition.takeIf { it > 0 } ?: state.positionMs
        open(
            state.request.copy(
                subjectId = dub.subjectId,
                downloadId = null,
                localFilePath = null,
                startPositionMs = position.takeIf { it > 0 },
            ),
        )
    }

    fun selectEpisode(episode: Episode) {
        if (
            state.request.season == episode.season &&
            state.request.episode == episode.number
        ) {
            return
        }
        open(
            state.request.copy(
                season = episode.season,
                episode = episode.number,
                episodeTitle = episode.displayTitle,
                downloadId = null,
                localFilePath = null,
                startPositionMs = null,
            ),
        )
    }

    fun setAutoPlayNext(enabled: Boolean) {
        state = state.copy(autoPlayNext = enabled)
        viewModelScope.launch {
            container.settings.update { it.copy(autoPlayNext = enabled) }
        }
    }

    fun setFillScreen(enabled: Boolean) {
        state = state.copy(fillScreen = enabled)
        viewModelScope.launch {
            container.settings.update { it.copy(playerFillScreen = enabled) }
        }
    }

    /**
     * Queues the quality the viewer explicitly picked in the download sheet.
     *
     * The sheet is handed the already-resolved renditions, so this never
     * resolves the title again: a second request could return a URL the viewer
     * did not choose.
     */
    fun download(rendition: StreamRendition) {
        val request = state.request
        if (!request.localFilePath.isNullOrBlank() || request.downloadId != null) {
            state = state.copy(
                downloadNotice = appContext.getString(R.string.player_download_local),
            )
            return
        }
        val rejection = PlaybackPolicy.downloadRejection(rendition, rendition.isWeb)
        if (rejection != null) {
            state = state.copy(downloadNotice = rejection)
            return
        }
        val subject = state.subject?.takeIf { it.id == request.subjectId } ?: Subject(
            id = request.subjectId,
            title = request.title,
            poster = request.poster,
            kind = if (request.isSeries) "series" else "movie",
        )
        viewModelScope.launch {
            val outcome = container.downloads.enqueue(
                listOf(
                    DownloadRequest(
                        subject = subject,
                        season = request.season,
                        episode = request.episode,
                        episodeTitle = request.episodeTitle,
                        stream = rendition,
                    ),
                ),
            ).firstOrNull()
            if (outcome?.added == true) DownloadService.start(container.context)
            state = state.copy(
                downloadNotice = outcome?.message
                    ?: appContext.getString(R.string.player_download_unavailable),
            )
        }
    }

    fun clearNotices() {
        if (state.downloadNotice == null && state.notice == null) return
        state = state.copy(downloadNotice = null, notice = null)
    }

    /** Called by the activity when it leaves the foreground; still safe to call after PiP. */
    fun recordProgress() {
        if (state.webUrl != null) return
        val request = state.request
        val nativeMedia = player.mediaItemCount > 0
        val position = if (nativeMedia) player.currentPosition else state.positionMs
        val duration = if (nativeMedia) {
            player.duration.takeIf { it > 0 && it != C.TIME_UNSET } ?: state.durationMs
        } else {
            state.durationMs
        }
        if (duration <= 0 || position < RESUME_MIN_POSITION_MS) return
        if (position >= duration - RESUME_END_GUARD_MS) return
        val subject = state.subject?.takeIf { it.id == request.subjectId } ?: Subject(
            id = request.subjectId,
            title = request.title,
            poster = request.poster,
            kind = if (request.isSeries) "series" else "movie",
        )
        viewModelScope.launch {
            container.library.recordResume(
                subject = subject,
                season = request.season,
                episode = request.episode,
                episodeTitle = request.episodeTitle,
                positionMs = position,
                durationMs = duration,
            )
        }
    }

    private suspend fun load(request: PlaybackRequest) {
        val localPath = request.localFilePath?.takeIf { it.isNotBlank() }
        if (localPath != null) {
            val file = File(localPath)
            if (file.exists() && file.length() > 0) {
                val item = request.downloadId
                    ?.let { id -> container.downloads.items.value.firstOrNull { it.id == id } }
                playLocal(Uri.fromFile(file), request, item)
            } else {
                fail(
                    CinemacoreError.Unknown(
                        appContext.getString(R.string.player_download_not_ready),
                    ),
                )
            }
            return
        }

        val downloadId = request.downloadId?.takeIf { it.isNotBlank() }
        if (downloadId != null) {
            val item = container.downloads.items.value.firstOrNull { it.id == downloadId }
            if (item != null) {
                val file = container.downloads.fileFor(item)
                if (file.exists() && file.length() > 0) {
                    playLocal(Uri.fromFile(file), request, item)
                } else {
                    fail(
                        CinemacoreError.Unknown(
                            appContext.getString(R.string.player_download_not_ready),
                        ),
                    )
                }
                return
            }
        }

        val info = try {
            container.repository.play(request.subjectId, request.season, request.episode)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: CinemacoreError) {
            fail(error)
            return
        } catch (error: Exception) {
            fail(CinemacoreError.Unknown(error.message))
            return
        }
        if (state.request != request) return

        state = state.copy(
            loadState = LoadState.Loaded(info),
            streams = info.streams,
            subtitles = info.subtitles,
        )

        val web = PlaybackPolicy.webRendition(info.streams)
        if (web != null) {
            player.stop()
            player.clearMediaItems()
            state = state.copy(
                webUrl = web.url,
                rendition = null,
                isPlaying = false,
                isBuffering = false,
                positionMs = 0,
                durationMs = 0,
            )
            loadMetadata(request)
            return
        }

        val rendition = PlaybackPolicy.defaultRendition(info.streams)
        if (rendition == null) {
            fail(CinemacoreError.Upstream(appContext.getString(R.string.player_no_stream)))
            loadMetadata(request)
            return
        }

        val start = resumePositionMs(request)
        state = state.copy(
            webUrl = null,
            rendition = rendition,
            resumePositionMs = start,
            isBuffering = true,
        )
        prepare(Uri.parse(rendition.url), rendition, start, playWhenReady = true)
        loadMetadata(request)
    }

    private fun playLocal(
        uri: Uri,
        request: PlaybackRequest,
        download: com.cinemacore.app.domain.DownloadItem? = null,
    ) {
        val start = resumePositionMs(request)
        val localSubtitles = download?.subtitles.orEmpty().map { subtitle ->
            SubtitleTrack(
                language = subtitle.language,
                url = Uri.fromFile(
                    File(container.downloads.downloadsDir(), subtitle.fileName),
                ).toString(),
                format = subtitle.format,
            )
        }
        state = state.copy(
            loadState = LoadState.Loaded(PlayInfo(streams = emptyList())),
            streams = emptyList(),
            subtitles = localSubtitles,
            webUrl = null,
            rendition = null,
            resumePositionMs = start,
            isBuffering = true,
        )
        prepare(uri, rendition = null, startPositionMs = start, playWhenReady = true)
        loadMetadata(request)
    }

    private fun loadMetadata(request: PlaybackRequest) {
        viewModelScope.launch {
            val subject = try {
                container.repository.detail(request.subjectId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                null
            }
            if (state.request.subjectId != request.subjectId) return@launch
            if (subject != null) {
                state = state.copy(subject = subject, dubs = subject.dubOptions)
            }
        }
        if (request.isSeries || request.season != null) {
            viewModelScope.launch {
                val seasons = try {
                    container.repository.seasons(request.subjectId)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    null
                }
                if (state.request.subjectId != request.subjectId) return@launch
                if (seasons != null) state = state.copy(seasons = seasons)
            }
        }
    }

    private fun prepare(
        uri: Uri,
        rendition: StreamRendition?,
        startPositionMs: Long,
        playWhenReady: Boolean,
    ) {
        activeUri = uri
        activeRendition = rendition

        val builder = MediaItem.fromUri(uri).buildUpon()
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(state.request.displayTitle)
                    .build(),
            )
        when (rendition?.container) {
            MediaContainer.HLS -> builder.setMimeType(MimeTypes.APPLICATION_M3U8)
            MediaContainer.DASH -> builder.setMimeType(MimeTypes.APPLICATION_MPD)
            else -> Unit
        }
        selectedSubtitleFile?.let { file ->
            val track = state.selectedSubtitle
            builder.setSubtitleConfigurations(
                listOf(
                    MediaItem.SubtitleConfiguration.Builder(Uri.fromFile(file))
                        .setMimeType(MimeTypes.TEXT_VTT)
                        .setLanguage(track?.language)
                        .setLabel(track?.language)
                        .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
                        .build(),
                ),
            )
        }

        val baseDataSource = OkHttpDataSource.Factory(container.okHttp).apply {
            rendition?.cookie
                ?.takeIf { it.isNotBlank() }
                ?.let { cookie -> setDefaultRequestProperties(mapOf("Cookie" to cookie)) }
        }
        // The container factory only knows HTTP. Downloads and side-loaded
        // subtitles are file URIs, so route through DefaultDataSource.
        val dataSource = DefaultDataSource.Factory(container.context, baseDataSource)
        val mediaSource = DefaultMediaSourceFactory(dataSource)
            .createMediaSource(builder.build())

        player.setMediaSource(mediaSource, startPositionMs.coerceAtLeast(0))
        player.playbackParameters = PlaybackParameters(state.speed)
        player.prepare()
        player.playWhenReady = playWhenReady
    }

    private fun reprepare() {
        val uri = activeUri ?: return
        val start = player.currentPosition.coerceAtLeast(0)
        val play = player.playWhenReady || player.isPlaying
        prepare(uri, activeRendition, start, play)
    }

    private fun resumePositionMs(request: PlaybackRequest): Long {
        request.startPositionMs?.let { return it.coerceAtLeast(0) }
        val point = container.library.resumeFor(
            subjectId = request.subjectId,
            season = request.season,
            episode = request.episode,
        ) ?: return 0
        val position = point.positionMs
        val duration = point.durationMs
        return if (
            position >= RESUME_MIN_POSITION_MS &&
            (duration <= 0 || position < duration - RESUME_END_GUARD_MS)
        ) {
            position
        } else {
            0
        }
    }

    private fun handleEnded() {
        if (!state.autoPlayNext) return
        val next = nextEpisode() ?: return
        open(
            state.request.copy(
                season = next.season,
                episode = next.number,
                episodeTitle = next.displayTitle,
                downloadId = null,
                localFilePath = null,
                startPositionMs = null,
            ),
        )
    }

    private fun nextEpisode(): Episode? {
        val seasons = state.seasons
        if (seasons.isEmpty()) return null
        val currentSeason = state.request.season ?: seasons.first().number
        val season = seasons.firstOrNull { it.number == currentSeason } ?: return null
        val currentEpisode = state.request.episode
        if (currentEpisode != null) {
            val index = season.episodes.indexOfFirst { it.number == currentEpisode }
            if (index >= 0 && index < season.episodes.lastIndex) {
                return season.episodes[index + 1]
            }
        }
        return seasons
            .firstOrNull { it.number > currentSeason }
            ?.episodes
            ?.firstOrNull()
    }

    private fun fail(error: CinemacoreError) {
        state = state.copy(
            loadState = LoadState.Failed(error),
            isBuffering = false,
            isPlaying = false,
        )
    }

    override fun onCleared() {
        player.removeListener(listener)
        loadJob?.cancel()
        progressJob?.cancel()
        settingsJob?.cancel()
        super.onCleared()
    }

    companion object {
        const val MIN_SPEED = 0.25f
        const val MAX_SPEED = 4f
        val SPEED_OPTIONS = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)

        private const val PROGRESS_POLL_MS = 500L
        private const val RECORD_INTERVAL_MS = 10_000L
        private const val RESUME_MIN_POSITION_MS = 5_000L
        private const val RESUME_END_GUARD_MS = 10_000L

        fun formatTime(milliseconds: Long): String {
            val totalSeconds = (milliseconds / 1000).coerceAtLeast(0)
            val hours = totalSeconds / 3600
            val minutes = (totalSeconds % 3600) / 60
            val seconds = totalSeconds % 60
            return if (hours > 0) {
                String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                String.format(Locale.US, "%d:%02d", minutes, seconds)
            }
        }

        fun formatSpeed(speed: Float): String =
            if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()

        fun factory(
            container: AppContainer,
            request: PlaybackRequest,
        ): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                PlayerViewModel(container, request) as T
        }
    }
}
