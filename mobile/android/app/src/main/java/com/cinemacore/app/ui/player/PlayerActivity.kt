package com.cinemacore.app.ui.player

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.annotation.RequiresApi
import androidx.compose.runtime.snapshotFlow
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.media3.ui.PlayerView
import com.cinemacore.app.CinemacoreApp
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.ui.theme.CinemacoreTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * The single playback activity. The player surface is attached here, but the
 * ExoPlayer itself belongs to [com.cinemacore.app.AppContainer] so PiP, the
 * media session and this screen always control the same transport.
 */
class PlayerActivity : ComponentActivity() {
    private val container by lazy { (application as CinemacoreApp).container }
    private lateinit var viewModel: PlayerViewModel
    private lateinit var playerView: PlayerView
    private val sourceRect = Rect()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }

        val request = readRequest(intent)
        if (request == null) {
            finish()
            return
        }

        viewModel = ViewModelProvider(
            this,
            PlayerViewModel.factory(container, request),
        ).get(PlayerViewModel::class.java)

        playerView = PlayerView(this).apply {
            useController = false
            setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
            setShutterBackgroundColor(android.graphics.Color.BLACK)
            player = viewModel.player
        }

        setContent {
            CinemacoreTheme {
                PlayerScreen(
                    viewModel = viewModel,
                    playerView = playerView,
                    onBack = { finish() },
                    onEnterPip = ::enterPip,
                )
            }
        }

        // Bind the media session while the activity is still in the foreground.
        // If playback starts after the user leaves, the service already exists.
        PlaybackService.start(this)

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                snapshotFlow { viewModel.state.isPlaying }
                    .distinctUntilChanged()
                    .collect { playing ->
                        if (playing) PlaybackService.start(this@PlayerActivity)
                        updatePipParams(playing)
                    }
            }
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                snapshotFlow { viewModel.state.fullscreen || viewModel.state.inPip }
                    .distinctUntilChanged()
                    .collect(::applyImmersiveMode)
            }
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                snapshotFlow { viewModel.state.fullscreen }
                    .distinctUntilChanged()
                    .collect(::setPlayerOrientation)
            }
        }
    }

    /**
     * Fullscreen follows iOS: a phone turns landscape and the picture reaches
     * the edges. Tablets keep their natural orientation because a large canvas
     * already fills the display.
     */
    private fun setPlayerOrientation(fullscreen: Boolean) {
        if (resources.configuration.smallestScreenWidthDp >= 600) return
        requestedOrientation = if (fullscreen) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    /**
     * A rotation or a dialog that briefly takes window focus can let the system
     * bars back in. Fullscreen owns the window, so restore the immersive state
     * whenever the activity regains it.
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && ::viewModel.isInitialized && viewModel.state.fullscreen) {
            applyImmersiveMode(true)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (::viewModel.isInitialized && viewModel.state.fullscreen) {
            applyImmersiveMode(true)
        }
    }

    private fun applyImmersiveMode(immersive: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (immersive) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val request = readRequest(intent) ?: return
        if (::viewModel.isInitialized) viewModel.open(request)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (::viewModel.isInitialized && viewModel.state.isPlaying) enterPip()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (::viewModel.isInitialized) viewModel.setPipMode(isInPictureInPictureMode)
    }

    override fun onStart() {
        super.onStart()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onStop() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (::viewModel.isInitialized) viewModel.recordProgress()
        super.onStop()
    }

    override fun onDestroy() {
        if (::playerView.isInitialized) playerView.player = null
        // A requestless activity finishes before it ever touches the lazy
        // shared player; do not instantiate one just to stop it.
        if (::viewModel.isInitialized && isFinishing && !isChangingConfigurations) {
            container.player.stop()
            container.player.clearMediaItems()
            PlaybackService.stop(this)
        }
        super.onDestroy()
    }

    private fun updatePipParams(playing: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPipParams(playing))
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildPipParams(playing: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (
            playerView.width > 0 &&
            playerView.height > 0 &&
            playerView.getGlobalVisibleRect(sourceRect)
        ) {
            builder.setSourceRectHint(Rect(sourceRect))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(playing)
        }
        return builder.build()
    }

    private fun enterPip() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (isInPictureInPictureMode) return
        if (enterPictureInPictureMode(buildPipParams(viewModel.state.isPlaying))) {
            viewModel.setPipMode(true)
        }
    }

    private fun readRequest(intent: Intent): PlaybackRequest? {
        val subjectId = intent.getStringExtra(EXTRA_SUBJECT_ID)
            ?.takeIf { it.isNotBlank() }
            ?: return null
        return PlaybackRequest(
            subjectId = subjectId,
            title = intent.getStringExtra(EXTRA_TITLE)
                ?.takeIf { it.isNotBlank() }
                ?: subjectId,
            poster = intent.getStringExtra(EXTRA_POSTER),
            kind = intent.getStringExtra(EXTRA_KIND),
            season = if (intent.hasExtra(EXTRA_SEASON)) {
                intent.getIntExtra(EXTRA_SEASON, 0)
            } else {
                null
            },
            episode = if (intent.hasExtra(EXTRA_EPISODE)) {
                intent.getIntExtra(EXTRA_EPISODE, 0)
            } else {
                null
            },
            episodeTitle = intent.getStringExtra(EXTRA_EPISODE_TITLE),
            resourceId = intent.getStringExtra(EXTRA_RESOURCE_ID),
            downloadId = intent.getStringExtra(EXTRA_DOWNLOAD_ID),
            localFilePath = intent.getStringExtra(EXTRA_LOCAL_FILE_PATH),
            startPositionMs = if (intent.hasExtra(EXTRA_START_POSITION)) {
                intent.getLongExtra(EXTRA_START_POSITION, 0)
            } else {
                null
            },
        )
    }

    companion object {
        private const val EXTRA_SUBJECT_ID = "com.cinemacore.app.player.SUBJECT_ID"
        private const val EXTRA_TITLE = "com.cinemacore.app.player.TITLE"
        private const val EXTRA_POSTER = "com.cinemacore.app.player.POSTER"
        private const val EXTRA_KIND = "com.cinemacore.app.player.KIND"
        private const val EXTRA_SEASON = "com.cinemacore.app.player.SEASON"
        private const val EXTRA_EPISODE = "com.cinemacore.app.player.EPISODE"
        private const val EXTRA_EPISODE_TITLE = "com.cinemacore.app.player.EPISODE_TITLE"
        private const val EXTRA_RESOURCE_ID = "com.cinemacore.app.player.RESOURCE_ID"
        private const val EXTRA_DOWNLOAD_ID = "com.cinemacore.app.player.DOWNLOAD_ID"
        private const val EXTRA_LOCAL_FILE_PATH = "com.cinemacore.app.player.LOCAL_FILE_PATH"
        private const val EXTRA_START_POSITION = "com.cinemacore.app.player.START_POSITION"

        /** The only supported way to start the player; extras stay private. */
        fun intent(context: Context, request: PlaybackRequest): Intent =
            Intent(context, PlayerActivity::class.java).apply {
                putExtra(EXTRA_SUBJECT_ID, request.subjectId)
                putExtra(EXTRA_TITLE, request.title)
                request.poster?.let { putExtra(EXTRA_POSTER, it) }
                request.kind?.let { putExtra(EXTRA_KIND, it) }
                request.season?.let { putExtra(EXTRA_SEASON, it) }
                request.episode?.let { putExtra(EXTRA_EPISODE, it) }
                request.episodeTitle?.let { putExtra(EXTRA_EPISODE_TITLE, it) }
                request.resourceId?.let { putExtra(EXTRA_RESOURCE_ID, it) }
                request.downloadId?.let { putExtra(EXTRA_DOWNLOAD_ID, it) }
                request.localFilePath?.let { putExtra(EXTRA_LOCAL_FILE_PATH, it) }
                request.startPositionMs?.let { putExtra(EXTRA_START_POSITION, it) }
            }
    }
}
