package com.cinemacore.app.ui.search

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.cinemacore.app.domain.CatalogRepository
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.Subject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

/**
 * Search state. One job owns the whole query lifecycle, so a new keystroke or a
 * submit cancels the request it replaces instead of racing it.
 */
class SearchViewModel(private val repository: CatalogRepository) : ViewModel() {
    var state: LoadState<List<Subject>> by mutableStateOf(LoadState.Idle)
        private set

    var suggestions: List<String> by mutableStateOf(emptyList())
        private set

    private var searchJob: Job? = null

    fun queryChanged(value: String) {
        searchJob?.cancel()
        val trimmed = value.trim()
        if (trimmed.isEmpty()) {
            state = LoadState.Idle
            suggestions = emptyList()
            return
        }
        searchJob = viewModelScope.launch {
            delay(DEBOUNCE_MS)
            runSearch(trimmed)
        }
    }

    /** Submitting means the suggestion list has served its purpose. */
    fun submit(value: String) {
        searchJob?.cancel()
        suggestions = emptyList()
        val trimmed = value.trim()
        if (trimmed.isEmpty()) {
            state = LoadState.Idle
            return
        }
        searchJob = viewModelScope.launch { runSearch(trimmed) }
    }

    fun clear() {
        searchJob?.cancel()
        state = LoadState.Idle
        suggestions = emptyList()
    }

    private suspend fun runSearch(query: String) {
        state = LoadState.Loading
        try {
            val items = repository.search(query)
            currentCoroutineContext().ensureActive()
            state = if (items.isEmpty()) LoadState.Empty else LoadState.Loaded(items)

            // Suggestions are a convenience: the results are already on screen,
            // so a failed suggestion call must not replace them with an error.
            val next = try {
                repository.suggestions(query)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                emptyList()
            }
            currentCoroutineContext().ensureActive()
            suggestions = next
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            // A cancellation can surface wrapped by the transport; never turn
            // the new query's superseded request into a screen error.
            currentCoroutineContext().ensureActive()
            val error = failure.asCinemacoreError()
            state = if (error.requiresGate) LoadState.Locked(error) else LoadState.Failed(error)
        }
    }

    companion object {
        private const val DEBOUNCE_MS = 280L

        fun factory(repository: CatalogRepository): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    SearchViewModel(repository) as T
            }
    }
}

private fun Throwable.asCinemacoreError(): CinemacoreError =
    this as? CinemacoreError ?: CinemacoreError.Unknown(message)
