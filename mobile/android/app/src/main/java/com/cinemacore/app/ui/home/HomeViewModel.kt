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

    private var loadedOnce = false

    /** Tab switches recreate the composition, not the holder; only load once. */
    fun loadIfNeeded() {
        if (!loadedOnce) load()
    }

    fun load() {
        if (state.isLoading) return
        state = LoadState.Loading
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
            }
        }
    }

    /** Rails the viewer hid in Settings never reach the composition. */
    fun visibleSections(hidden: Collection<String>): List<Section> =
        state.valueOrNull?.sections?.filterNot { hidden.contains(it.title) }.orEmpty()

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
