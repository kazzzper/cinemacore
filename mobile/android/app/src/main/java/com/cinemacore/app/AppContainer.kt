package com.cinemacore.app

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.cinemacore.app.data.CatalogResolver
import com.cinemacore.app.data.DemoCatalogRepository
import com.cinemacore.app.data.DownloadEngine
import com.cinemacore.app.data.GatewayCatalogRepository
import com.cinemacore.app.data.LibraryStore
import com.cinemacore.app.data.SettingsStore
import com.cinemacore.app.data.SourceResolution
import com.cinemacore.app.data.SubtitleCache
import com.cinemacore.app.domain.CatalogRepository
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * Manual constructor injection at the process boundary.
 *
 * There is one container per process, created by [CinemacoreApp]. Screens get
 * their dependencies through [CinemacoreViewModel], never through a global
 * singleton, which keeps the JVM-testable logic independent of Android.
 */
class AppContainer(context: Context) {
    private val appContext = context.applicationContext

    val context: Context
        get() = appContext

    val files: File = appContext.filesDir
    val downloadsDirectory: File = File(files, "downloads").apply { mkdirs() }
    val subtitleCache = SubtitleCache(File(appContext.cacheDir, "subtitles"))

    val okHttp: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    val settings = SettingsStore(files)
    val library = LibraryStore(files)
    val downloads = DownloadEngine(downloadsDirectory, okHttp)

    private val resolver = CatalogResolver(
        http = okHttp,
        fallbackGateway = BuildConfig.DEFAULT_GATEWAY,
        tmdbEnvironmentKey = BuildConfig.TMDB_ENV_KEY,
        tmdbPublicKey = BuildConfig.STREAMHYPE_PUBLIC_TMDB_KEY,
    )

    @Volatile
    var repository: CatalogRepository = DemoCatalogRepository()
        private set

    @Volatile
    var lastResolution: SourceResolution = SourceResolution(
        repository = repository,
        note = "Bundled demo",
        mode = com.cinemacore.app.domain.SourceMode.DEMO,
    )
        private set

    /**
     * One ExoPlayer per process, so a PiP window and the media session service
     * observe the same transport. The activity attaches/detaches a surface but
     * never owns the player's lifetime.
     */
    val player: ExoPlayer by lazy {
        val dataSource = OkHttpDataSource.Factory(okHttp)
        ExoPlayer.Builder(appContext)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()
            .apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                    true,
                )
                setHandleAudioBecomingNoisy(true)
                setWakeMode(C.WAKE_MODE_NETWORK)
            }
    }

    suspend fun bootstrap(): SourceResolution {
        val resolution = resolver.resolve(settings.value)
        repository = resolution.repository
        lastResolution = resolution
        return resolution
    }

    val configuredGateway: String
        get() = settings.value.effectiveGatewayUrl.ifBlank { BuildConfig.DEFAULT_GATEWAY }

    suspend fun gatewayVersion(): String? = withContext(Dispatchers.IO) {
        val gateway = GatewayCatalogRepository(configuredGateway, okHttp)
        runCatching { gateway.version() }.getOrNull()
    }
}
