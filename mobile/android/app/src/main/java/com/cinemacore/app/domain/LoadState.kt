package com.cinemacore.app.domain

/**
 * The shared screen state. `Empty` is distinct from `Loaded` with an empty list
 * so a screen cannot accidentally render the success path for "no results".
 */
sealed interface LoadState<out T> {
    data object Idle : LoadState<Nothing>
    data object Loading : LoadState<Nothing>
    data object Empty : LoadState<Nothing>
    data class Loaded<T>(val value: T) : LoadState<T>
    data class Failed(val error: CinemacoreError) : LoadState<Nothing>
    data class Locked(val error: CinemacoreError) : LoadState<Nothing>

    val valueOrNull: T?
        get() = (this as? Loaded<T>)?.value

    val isLoading: Boolean
        get() = this is Loading

    val isError: Boolean
        get() = this is Failed || this is Locked
}
