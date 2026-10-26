package com.cinemacore.app.ui.library

import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.cinemacore.app.domain.LibraryData
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.ResumePoint
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.CinemacoreViewModel
import java.util.Locale
import kotlinx.coroutines.CancellationException

/**
 * Screen state holders for the two local-library surfaces.
 *
 * The store is read from disk synchronously when the container is built, so
 * there is no request to await: state maps straight to Empty/Loaded. A `Failed`
 * state would therefore only ever be invented; the only real failure is a
 * write, which is reported without hiding the rows already on screen.
 *
 * Writes delegate to [CinemacoreViewModel], which owns the single persistence
 * path, so these holders never duplicate store logic.
 */
class WatchlistViewModel(private val app: CinemacoreViewModel) {
    var writeFailed by mutableStateOf(false)
        private set

    val state: LoadState<List<Subject>> by derivedStateOf { watchlistState(app.library) }

    suspend fun remove(subjectId: String) = write { app.removeFromWatchlist(subjectId) }

    suspend fun clear() = write { app.clearWatchlist() }

    private suspend fun write(block: suspend () -> Unit) {
        try {
            block()
            writeFailed = false
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            writeFailed = true
        }
    }
}

class HistoryViewModel(private val app: CinemacoreViewModel) {
    var writeFailed by mutableStateOf(false)
        private set

    val state: LoadState<List<ResumePoint>> by derivedStateOf { historyState(app.library) }

    suspend fun remove(key: String) = write { app.removeHistory(key) }

    suspend fun clear() = write { app.clearHistory() }

    private suspend fun write(block: suspend () -> Unit) {
        try {
            block()
            writeFailed = false
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            writeFailed = true
        }
    }
}

internal fun watchlistState(library: LibraryData): LoadState<List<Subject>> {
    val subjects = library.watchlist.map { it.subject }
    return if (subjects.isEmpty()) LoadState.Empty else LoadState.Loaded(subjects)
}

internal fun historyState(library: LibraryData): LoadState<List<ResumePoint>> =
    if (library.history.isEmpty()) LoadState.Empty else LoadState.Loaded(library.history)

/** Compact playback position for the resume line: `12:34` or `1:02:03`. */
internal fun formatTimecode(milliseconds: Long): String {
    val totalSeconds = milliseconds.coerceAtLeast(0) / 1_000
    val hours = totalSeconds / 3_600
    val minutes = (totalSeconds % 3_600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.US, "%d:%02d", minutes, seconds)
    }
}

/**
 * Whole minutes left, rounded up so a resume with a few seconds remaining reads
 * "1 min left" rather than "0 min left".
 */
internal fun remainingMinutes(point: ResumePoint): Int {
    val left = (point.durationMs - point.positionMs).coerceAtLeast(0)
    return ((left + 59_999) / 60_000).toInt()
}
