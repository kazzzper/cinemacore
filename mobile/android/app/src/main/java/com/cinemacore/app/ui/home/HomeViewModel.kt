package com.cinemacore.app.ui.home

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.Page
import com.cinemacore.app.domain.Section
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Screen state for the landing page. The catalogue itself stays on the app view
 * model, so swapping sources only needs a new instance of this holder.
 */
class HomeViewModel(private val repository: CatalogRepository) : ViewModel() {
    var state: LoadState<Page> by mutableStateOf(LoadState.Idle)
        private set

    /** The pull-to-refresh indicator; the loaded page stays on screen meanwhile. */
    var isRefreshing: Boolean by mutableStateOf(false)
        private set

    private var loadedOnce = false

    /** Tab switches recreate the composition, not the holder; only load once. */
    fun loadIfNeeded() {
        if (!loadedOnce) load()
    }

    fun load() = fetch(keepContent = false)

    /** A pull keeps the current page visible instead of replacing it with a spinner. */
    fun refresh() = fetch(keepContent = true)

    private fun fetch(keepContent: Boolean) {
        if (state.isLoading || isRefreshing) return
        if (keepContent && state.valueOrNull != null) {
            isRefreshing = true
        } else {
            state = LoadState.Loading
        }
        viewModelScope.launch {
            try {
                val page = repository.home()
                loadedOnce = true
                state = if (page.isEmpty) LoadState.Empty else LoadState.Loaded(page)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                val error = failure.asCinemacoreError()
                state = if (error.requiresGate) LoadState.Locked(error) else LoadState.Failed(error)
            } finally {
                isRefreshing = false
            }
        }
    }

    /**
     * Rails the viewer hid in Settings never reach the composition, and the
     * saved Manage Categories order wins over the provider's.
     *
     * The order used to be stored but never read here, so a rail "moved" in
     * Settings came back in the catalogue's position.
     */
    fun visibleSections(
        hidden: Collection<String>,
        order: List<String> = emptyList(),
    ): List<Section> {
        val visible = state.valueOrNull?.sections
            ?.filterNot { hidden.contains(it.title) }
            .orEmpty()
        if (order.isEmpty()) return visible
        val rank = order.withIndex().associate { (index, title) -> title to index }
        return visible.withIndex()
            .sortedWith(
                compareBy(
                    { rank[it.value.title] ?: (order.size + it.index) },
                    { it.index },
                ),
            )
            .map { it.value }
    }

    companion object {
        fun factory(repository: CatalogRepository): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    HomeViewModel(repository) as T
            }
    }
}

private fun Throwable.asCinemacoreError(): CinemacoreError =
    this as? CinemacoreError ?: CinemacoreError.Unknown(message)
