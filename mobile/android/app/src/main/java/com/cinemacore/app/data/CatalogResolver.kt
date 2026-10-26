package com.cinemacore.app.data

import com.cinemacore.app.data.direct.DirectMovieBoxRepository
import com.cinemacore.app.data.direct.MovieBoxSession
import com.cinemacore.app.domain.AppSettings
import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.SourceMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient

data class SourceResolution(
    val repository: CatalogRepository,
    val note: String,
    val mode: SourceMode,
    val gatewayVersion: String? = null,
)

/**
 * Resolves exactly one catalog per bootstrap. A gateway failure falls back to
 * the bundled demo and says so; it must never silently look live.
 */
class CatalogResolver(
    private val http: OkHttpClient,
    private val fallbackGateway: String,
    private val tmdbEnvironmentKey: String? = System.getenv("TMDB_API_KEY"),
    private val tmdbPublicKey: String = StreamHypeCatalogRepository.PUBLIC_API_KEY,
) {
    suspend fun resolve(settings: AppSettings): SourceResolution {
        return when (settings.sourceMode) {
            SourceMode.BUILT_IN -> {
                // Direct to MovieBox, the same default as iOS. The guest login
                // is both the source probe and the first request; a phone with
                // no route to the provider falls back to the honest demo note
                // rather than showing an empty live catalog.
                val session = MovieBoxSession(http = http)
                val repository = DirectMovieBoxRepository(session)
                try {
                    withTimeout(SOURCE_PROBE_MILLIS) { repository.warmUp() }
                    SourceResolution(
                        repository = repository,
                        note = "MovieBox",
                        mode = SourceMode.BUILT_IN,
                    )
                } catch (timedOut: TimeoutCancellationException) {
                    SourceResolution(
                        repository = DemoCatalogRepository(),
                        note = "Demo data — connect to the internet to load the catalog",
                        mode = SourceMode.BUILT_IN,
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    SourceResolution(
                        repository = DemoCatalogRepository(),
                        note = "Demo data — connect to the internet to load the catalog",
                        mode = SourceMode.BUILT_IN,
                    )
                }
            }

            SourceMode.DEMO -> SourceResolution(
                repository = DemoCatalogRepository(),
                note = "Bundled demo",
                mode = SourceMode.DEMO,
            )

            SourceMode.STREAM_HYPE -> {
                val key = StreamHypeCatalogRepository.resolveApiKey(
                    settings.tmdbKey,
                    tmdbEnvironmentKey,
                    tmdbPublicKey,
                )
                SourceResolution(
                    repository = StreamHypeCatalogRepository(key, http),
                    note = "StreamHype · TMDB catalog",
                    mode = SourceMode.STREAM_HYPE,
                )
            }

            SourceMode.GATEWAY -> {
                val base = settings.gatewayUrl.trim().ifEmpty { fallbackGateway }
                val gateway = GatewayCatalogRepository(base, http)
                try {
                    val version = gateway.version()
                    SourceResolution(
                        repository = gateway,
                        note = "Gateway ${gateway.sourceName} · v$version",
                        mode = SourceMode.GATEWAY,
                        gatewayVersion = version,
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    SourceResolution(
                        repository = DemoCatalogRepository(),
                        note = "Bundled demo · gateway unreachable",
                        mode = SourceMode.GATEWAY,
                    )
                }
            }
        }
    }

    private companion object {
        /** Matches the iOS direct-source probe; a dead provider must not stall launch. */
        const val SOURCE_PROBE_MILLIS = 6_000L
    }
}
