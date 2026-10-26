package com.cinemacore.app.ui.detail

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.Subject
import kotlinx.coroutines.CancellationException

/** The detail call plus the episode tree, so the page renders from one state. */
data class SubjectDetail(
    val subject: Subject,
    val seasons: List<Season> = emptyList(),
) {
    fun episodesFor(season: Int): List<Episode> =
        seasons.firstOrNull { it.number == season }?.episodes.orEmpty()
}

/**
 * Screen-scoped state for one title.
 *
 * This is a plain holder rather than an androidx ViewModel because the subject
 * and the repository are owned by the process-level [com.cinemacore.app.ui.CinemacoreViewModel].
 * The screen remembers one instance per subject, so swapping the catalogue
 * source cannot leave a detail page bound to the previous repository.
 */
class DetailViewModel(
    private val repository: CatalogRepository,
    val subject: Subject,
    initialSeason: Int? = null,
) {
    var state: LoadState<SubjectDetail> by mutableStateOf(LoadState.Idle)
        private set

    var selectedSeason by mutableIntStateOf(initialSeason ?: 1)
        private set

    var selectedEpisode: Episode? by mutableStateOf(null)
        private set

    /** A series whose detail loaded but whose episode tree did not. */
    var episodesFailed: Boolean by mutableStateOf(false)
        private set

    val detail: SubjectDetail?
        get() = state.valueOrNull

    val seasons: List<Season>
        get() = detail?.seasons.orEmpty()

    val episodes: List<Episode>
        get() = detail?.episodesFor(selectedSeason).orEmpty()

    val isSeries: Boolean
        get() = detail?.subject?.isSeries ?: subject.isSeries

    suspend fun load() {
        if (state is LoadState.Loading) return
        state = LoadState.Loading
        episodesFailed = false
        try {
            val loadedSubject = repository.detail(subject.id)
            if (loadedSubject.title.isBlank()) {
                state = LoadState.Empty
                return
            }
            // The page stays useful when only the episode tree fails: the hero,
            // metadata and a download of the title remain available.
            val seasons = if (loadedSubject.isSeries) {
                try {
                    repository.seasons(loadedSubject.id).sortedBy { it.number }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (ignored: Exception) {
                    episodesFailed = true
                    emptyList()
                }
            } else {
                emptyList()
            }
            state = LoadState.Loaded(SubjectDetail(loadedSubject, seasons))
            syncSelection()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            val typed = error as? CinemacoreError ?: CinemacoreError.Unknown(error.message)
            state = if (typed.requiresGate) LoadState.Locked(typed) else LoadState.Failed(typed)
        }
    }

    fun selectSeason(number: Int) {
        if (seasons.none { it.number == number }) return
        selectedSeason = number
        // A season change must not leave an episode from the previous season selected.
        selectedEpisode = episodes.firstOrNull()
    }

    fun selectEpisode(episode: Episode) {
        selectedEpisode = episode
    }

    private fun syncSelection() {
        if (!isSeries) {
            selectedEpisode = null
            return
        }
        if (seasons.isEmpty()) {
            selectedEpisode = null
            return
        }
        // A season requested by the caller (for example a download row) survives
        // the load only when the title actually has it.
        if (seasons.none { it.number == selectedSeason }) {
            selectedSeason = seasons.first().number
        }
        val previousId = selectedEpisode?.id
        selectedEpisode = episodes.firstOrNull { it.id == previousId } ?: episodes.firstOrNull()
    }
}
