package com.cinemacore.app.ui.player

import android.app.Activity
import android.os.Build
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.cinemacore.app.R
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.ui.components.Chip
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.delay

@Composable
fun PlayerScreen(
    viewModel: PlayerViewModel,
    playerView: PlayerView,
    onBack: () -> Unit,
    onEnterPip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = viewModel.state
    PlayerSystemBars(fullscreen = state.fullscreen, inPip = state.inPip)

    var showOptions by rememberSaveable { mutableStateOf(false) }
    var showDownloadQuality by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state.inPip) {
        if (state.inPip) {
            showOptions = false
            showDownloadQuality = false
        }
    }

    BackHandler(enabled = !state.inPip) {
        if (state.fullscreen) {
            viewModel.setFullscreen(false)
        } else {
            onBack()
        }
    }

    val snackbarHostState = remember { SnackbarHostState() }
    val notice = state.downloadNotice ?: state.notice
    LaunchedEffect(notice) {
        if (notice != null && !state.inPip) {
            snackbarHostState.showSnackbar(notice)
            viewModel.clearNotices()
        }
    }

    val immersive = state.fullscreen || state.inPip
    val webUrl = state.webUrl
    Box(modifier.fillMaxSize().background(Color.Black)) {
        Column(Modifier.fillMaxSize()) {
            Box(
                modifier = if (immersive) {
                    Modifier.fillMaxSize()
                } else {
                    Modifier.fillMaxWidth().aspectRatio(16f / 9f)
                },
            ) {
                if (webUrl != null) {
                    WebStreamView(
                        url = webUrl,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    PlayerSurface(
                        playerView = playerView,
                        viewModel = viewModel,
                        modifier = Modifier.fillMaxSize(),
                    )
                }

                when {
                    state.loadState is LoadState.Loading -> LoadingPane()

                    state.loadState.isError -> ErrorPane(
                        message = state.errorMessage(),
                        onRetry = viewModel::retry,
                        onBack = onBack,
                    )

                    webUrl != null -> {
                        if (!state.inPip) {
                            WebChrome(
                                title = state.request.title,
                                episode = episodeLine(state),
                                fullscreen = state.fullscreen,
                                onBack = onBack,
                                onToggleFullscreen = {
                                    viewModel.setFullscreen(!state.fullscreen)
                                },
                            )
                        }
                    }

                    else -> {
                        if (!state.inPip) {
                            if (state.controlsVisible) {
                                PlayerControls(
                                    state = state,
                                    viewModel = viewModel,
                                    onBack = onBack,
                                    onDownload = { showDownloadQuality = true },
                                    onOpenOptions = { showOptions = true },
                                    autoHide = !showOptions && !showDownloadQuality,
                                )
                            } else {
                                Box(
                                    Modifier
                                        .fillMaxSize()
                                        .clickable(
                                            interactionSource = remember { MutableInteractionSource() },
                                            indication = null,
                                            onClick = { viewModel.setControlsVisible(true) },
                                        ),
                                )
                            }
                            if (
                                state.isBuffering &&
                                state.loadState is LoadState.Loaded &&
                                (!state.controlsVisible || state.isPlaying)
                            ) {
                                CircularProgressIndicator(
                                    color = CinemaColors.TextPrimary,
                                    modifier = Modifier
                                        .align(Alignment.Center)
                                        .size(44.dp),
                                )
                            }
                        }
                    }
                }
            }

            if (!immersive) {
                PlayerDetails(
                    state = state,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                )
            }
        }

        if (!state.inPip) {
            SnackbarHost(
                hostState = snackbarHostState,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(CinemaSpacing.x4),
            )
        }
    }

    if (showOptions && !state.inPip) {
        PlayerOptionsSheet(
            state = state,
            onDismiss = { showOptions = false },
            onSpeed = viewModel::setSpeed,
            onQuality = viewModel::selectRendition,
            onSubtitle = viewModel::selectSubtitle,
            onAudio = viewModel::selectDub,
            onEpisode = viewModel::selectEpisode,
            onAutoPlayNext = viewModel::setAutoPlayNext,
            onFillScreen = viewModel::setFillScreen,
            onEnterPip = onEnterPip.takeIf { Build.VERSION.SDK_INT >= Build.VERSION_CODES.O },
            onDownload = { rendition ->
                showOptions = false
                viewModel.download(rendition)
            },
        )
    }

    if (showDownloadQuality && !state.inPip) {
        DownloadQualitySheet(
            state = state,
            onDismiss = { showDownloadQuality = false },
            onDownload = { rendition ->
                showDownloadQuality = false
                viewModel.download(rendition)
            },
        )
    }
}

@Composable
private fun PlayerSurface(
    playerView: PlayerView,
    viewModel: PlayerViewModel,
    modifier: Modifier = Modifier,
) {
    val resizeMode = if (viewModel.state.fillScreen) {
        AspectRatioFrameLayout.RESIZE_MODE_ZOOM
    } else {
        AspectRatioFrameLayout.RESIZE_MODE_FIT
    }
    AndroidView(
        factory = { playerView },
        modifier = modifier,
        update = { view ->
            view.useController = false
            view.resizeMode = resizeMode
            if (view.player != viewModel.player) view.player = viewModel.player
        },
    )
}

@Composable
private fun PlayerControls(
    state: PlayerUiState,
    viewModel: PlayerViewModel,
    onBack: () -> Unit,
    onDownload: () -> Unit,
    onOpenOptions: () -> Unit,
    autoHide: Boolean,
) {
    var dragging by remember { mutableStateOf(false) }
    var dragPosition by remember { mutableLongStateOf(0L) }
    val duration = state.durationMs
    val sliderMax = if (duration > 0) duration.toFloat() else 1f
    val shownPosition = if (dragging) dragPosition else state.positionMs
    // The portrait picture is only 16:9, so its transport has to be a little
    // tighter than the same controls on a full-screen canvas.
    val compact = !state.fullscreen
    val chromeButton = if (compact) 40.dp else 48.dp
    val skipButton = if (compact) 44.dp else 56.dp
    val playButton = if (compact) 54.dp else 68.dp
    val skipIcon = if (compact) 26.dp else 32.dp
    val playIcon = if (compact) 30.dp else 38.dp

    LaunchedEffect(state.controlsVisible, state.isPlaying, dragging, autoHide) {
        if (state.controlsVisible && state.isPlaying && autoHide && !dragging) {
            delay(CONTROLS_HIDE_DELAY_MS)
            viewModel.setControlsVisible(false)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(
                        Color.Black.copy(alpha = 0.78f),
                        Color.Black.copy(alpha = 0.18f),
                        Color.Black.copy(alpha = 0.82f),
                    ),
                ),
            )
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = { viewModel.setControlsVisible(false) },
            ),
    ) {
        val safeArea = if (state.fullscreen) {
            WindowInsets.safeDrawing
        } else {
            // The portrait picture sits at the top of the window, so the
            // navigation-bar inset belongs to the details below it, not to
            // the controls painted over the 16:9 frame.
            WindowInsets.safeDrawing.only(
                WindowInsetsSides.Top + WindowInsetsSides.Horizontal,
            )
        }
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(safeArea)
                .padding(
                    horizontal = CinemaSpacing.x3,
                    vertical = if (compact) CinemaSpacing.x1 else CinemaSpacing.x2,
                ),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(
                    onClick = onBack,
                    modifier = Modifier.size(chromeButton),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = stringResource(R.string.player_back),
                        tint = CinemaColors.TextPrimary,
                    )
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        text = state.request.title,
                        style = MaterialTheme.typography.titleSmall,
                        color = CinemaColors.TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    episodeLine(state)?.let { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.labelMedium,
                            color = CinemaColors.TextSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                if (state.rendition != null) {
                    IconButton(
                        onClick = onDownload,
                        modifier = Modifier.size(chromeButton),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Download,
                            contentDescription = stringResource(R.string.player_download),
                            tint = CinemaColors.TextPrimary,
                        )
                    }
                }
                IconButton(
                    onClick = onOpenOptions,
                    modifier = Modifier.size(chromeButton),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Tune,
                        contentDescription = stringResource(R.string.player_options),
                        tint = CinemaColors.TextPrimary,
                    )
                }
                IconButton(
                    onClick = { viewModel.setFullscreen(!state.fullscreen) },
                    modifier = Modifier.size(chromeButton),
                ) {
                    Icon(
                        imageVector = if (state.fullscreen) {
                            Icons.Filled.FullscreenExit
                        } else {
                            Icons.Filled.Fullscreen
                        },
                        contentDescription = stringResource(
                            if (state.fullscreen) {
                                R.string.player_exit_fullscreen
                            } else {
                                R.string.player_fullscreen
                            },
                        ),
                        tint = CinemaColors.TextPrimary,
                    )
                }
            }

            Spacer(Modifier.weight(1f))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = { viewModel.seekBy(-SEEK_STEP_MS) },
                    modifier = Modifier.size(skipButton),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Replay10,
                        contentDescription = stringResource(R.string.player_rewind_10),
                        tint = CinemaColors.TextPrimary,
                        modifier = Modifier.size(skipIcon),
                    )
                }
                FilledIconButton(
                    onClick = viewModel::togglePlayPause,
                    modifier = Modifier.size(playButton),
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = CinemaColors.TextPrimary,
                        contentColor = CinemaColors.Background,
                    ),
                ) {
                    Icon(
                        imageVector = if (state.isPlaying) {
                            Icons.Filled.Pause
                        } else {
                            Icons.Filled.PlayArrow
                        },
                        contentDescription = stringResource(
                            if (state.isPlaying) R.string.player_pause else R.string.player_play,
                        ),
                        modifier = Modifier.size(playIcon),
                    )
                }
                IconButton(
                    onClick = { viewModel.seekBy(SEEK_STEP_MS) },
                    modifier = Modifier.size(skipButton),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Forward10,
                        contentDescription = stringResource(R.string.player_forward_10),
                        tint = CinemaColors.TextPrimary,
                        modifier = Modifier.size(skipIcon),
                    )
                }
            }

            Spacer(Modifier.weight(1f))

            Column {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = PlayerViewModel.formatTime(shownPosition),
                        style = MaterialTheme.typography.labelMedium,
                        color = CinemaColors.TextPrimary,
                    )
                    Text(
                        text = PlayerViewModel.formatTime(duration),
                        style = MaterialTheme.typography.labelMedium,
                        color = CinemaColors.TextSecondary,
                    )
                }
                PlayerSlider(
                    value = shownPosition.toFloat().coerceIn(0f, sliderMax),
                    valueRange = 0f..sliderMax,
                    enabled = duration > 0,
                    onValueChange = { value ->
                        dragging = true
                        dragPosition = value.toLong().coerceIn(0, duration.coerceAtLeast(0))
                    },
                    onValueChangeFinished = {
                        viewModel.seekTo(dragPosition)
                        dragging = false
                    },
                )
            }
        }
    }
}

/**
 * A slim transport scrubber. Material 3's expressive slider is 16 dp thick,
 * which reads as a progress *bar* rather than the hairline transport iOS uses.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlayerSlider(
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    enabled: Boolean,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
) {
    val colors = SliderDefaults.colors(
        thumbColor = CinemaColors.TextPrimary,
        activeTrackColor = CinemaColors.Brand,
        inactiveTrackColor = CinemaColors.TextPrimary.copy(alpha = 0.22f),
        activeTickColor = Color.Transparent,
        inactiveTickColor = Color.Transparent,
        disabledThumbColor = CinemaColors.TextSecondary.copy(alpha = 0.5f),
        disabledActiveTrackColor = CinemaColors.Separator,
        disabledInactiveTrackColor = CinemaColors.Separator,
    )
    val interactionSource = remember { MutableInteractionSource() }
    Slider(
        value = value,
        onValueChange = onValueChange,
        onValueChangeFinished = onValueChangeFinished,
        valueRange = valueRange,
        enabled = enabled,
        colors = colors,
        interactionSource = interactionSource,
        thumb = {
            SliderDefaults.Thumb(
                interactionSource = interactionSource,
                colors = colors,
                enabled = enabled,
                thumbSize = DpSize(14.dp, 14.dp),
            )
        },
        track = { sliderState ->
            val fraction = sliderState.coercedValueAsFraction
            Canvas(Modifier.fillMaxWidth().height(4.dp)) {
                val radius = CornerRadius(size.height / 2f)
                drawRoundRect(
                    color = if (enabled) {
                        CinemaColors.TextPrimary.copy(alpha = 0.22f)
                    } else {
                        CinemaColors.Separator
                    },
                    size = size,
                    cornerRadius = radius,
                )
                if (fraction > 0f) {
                    drawRoundRect(
                        color = if (enabled) CinemaColors.Brand else CinemaColors.Separator,
                        size = Size(size.width * fraction, size.height),
                        cornerRadius = radius,
                    )
                }
            }
        },
    )
}

@Composable
private fun PlayerDetails(
    state: PlayerUiState,
    modifier: Modifier = Modifier,
) {
    val currentDub = state.dubs.firstOrNull {
        it.subjectId == state.request.subjectId
    }
    val isLocal = !state.request.localFilePath.isNullOrBlank() ||
        state.request.downloadId != null
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .windowInsetsPadding(
                WindowInsets.safeDrawing.only(
                    WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                ),
            )
            .padding(horizontal = CinemaSpacing.x5, vertical = CinemaSpacing.x4),
        verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
    ) {
        Text(
            text = state.request.title,
            style = MaterialTheme.typography.titleLarge,
            color = CinemaColors.TextPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
        ) {
            state.request.episodeLabel?.let { Chip(text = it) }
            if (isLocal) Chip(text = stringResource(R.string.player_downloaded), prominent = true)
            if (state.dubs.size > 1) {
                Chip(text = currentDub?.displayName ?: stringResource(R.string.player_audio))
            }
            val quality = state.rendition?.quality?.takeIf { it.isNotBlank() }
                ?: stringResource(R.string.player_quality_auto)
            Chip(text = quality)
            if (state.speed != 1f) {
                Chip(
                    text = stringResource(
                        R.string.player_speed_value,
                        PlayerViewModel.formatSpeed(state.speed),
                    ),
                )
            }
            state.selectedSubtitle?.let { Chip(text = it.language) }
        }
        if (state.resumePositionMs > 0) {
            Text(
                text = stringResource(
                    R.string.player_resume_notice,
                    PlayerViewModel.formatTime(state.resumePositionMs),
                ),
                style = MaterialTheme.typography.labelMedium,
                color = CinemaColors.Accent,
            )
        }
    }
}

@Composable
private fun WebChrome(
    title: String,
    episode: String?,
    fullscreen: Boolean,
    onBack: () -> Unit,
    onToggleFullscreen: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                Brush.verticalGradient(
                    listOf(
                        Color.Black.copy(alpha = 0.82f),
                        Color.Transparent,
                    ),
                ),
            )
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = CinemaSpacing.x1, vertical = CinemaSpacing.x1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.player_back),
                tint = CinemaColors.TextPrimary,
            )
        }
        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = CinemaColors.TextPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            episode?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        IconButton(onClick = onToggleFullscreen) {
            Icon(
                imageVector = if (fullscreen) {
                    Icons.Filled.FullscreenExit
                } else {
                    Icons.Filled.Fullscreen
                },
                contentDescription = stringResource(
                    if (fullscreen) {
                        R.string.player_exit_fullscreen
                    } else {
                        R.string.player_fullscreen
                    },
                ),
                tint = CinemaColors.TextPrimary,
            )
        }
    }
}

@Composable
private fun LoadingPane() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.55f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
        ) {
            CircularProgressIndicator(color = CinemaColors.TextPrimary)
            Text(
                text = stringResource(R.string.player_loading),
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
            )
        }
    }
}

@Composable
private fun ErrorPane(
    message: String,
    onRetry: () -> Unit,
    onBack: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.86f))
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(CinemaSpacing.x6),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
        ) {
            Text(
                text = stringResource(R.string.player_error_title),
                style = MaterialTheme.typography.titleLarge,
                color = CinemaColors.TextPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
                textAlign = TextAlign.Center,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2)) {
                Button(onClick = onRetry) {
                    Text(stringResource(R.string.player_retry))
                }
                TextButton(onClick = onBack) {
                    Text(stringResource(R.string.player_back))
                }
            }
        }
    }
}

@Composable
private fun PlayerSystemBars(fullscreen: Boolean, inPip: Boolean) {
    val view = LocalView.current
    val context = LocalContext.current

    DisposableEffect(fullscreen, inPip, view) {
        val activity = context.findActivity()
        if (activity == null) {
            onDispose { }
        } else {
            val controller = WindowCompat.getInsetsController(
                activity.window,
                activity.window.decorView,
            )
            controller.isAppearanceLightStatusBars = false
            controller.isAppearanceLightNavigationBars = false
            when {
                inPip -> Unit
                fullscreen -> {
                    controller.systemBarsBehavior =
                        WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    controller.hide(WindowInsetsCompat.Type.systemBars())
                }
                else -> controller.show(WindowInsetsCompat.Type.systemBars())
            }
            onDispose {
                controller.show(WindowInsetsCompat.Type.systemBars())
            }
        }
    }
}

private fun Context.findActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}

@Composable
private fun episodeLine(state: PlayerUiState): String? {
    val season = state.request.season
    val episode = state.request.episode ?: return null
    val label = if (season != null) {
        stringResource(R.string.player_episode_label, season, episode)
    } else {
        stringResource(R.string.player_episode_number, episode)
    }
    val title = state.request.episodeTitle?.takeIf { it.isNotBlank() }
    return if (title != null) {
        stringResource(R.string.player_episode_title_line, label, title)
    } else {
        label
    }
}

private fun PlayerUiState.errorMessage(): String = when (val load = loadState) {
    is LoadState.Failed -> load.error.userMessage
    is LoadState.Locked -> load.error.userMessage
    else -> ""
}

private const val SEEK_STEP_MS = 10_000L
private const val CONTROLS_HIDE_DELAY_MS = 4_000L
