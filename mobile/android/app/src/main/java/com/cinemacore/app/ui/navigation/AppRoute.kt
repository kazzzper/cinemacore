package com.cinemacore.app.ui.navigation

import androidx.annotation.StringRes
import com.cinemacore.app.R
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.Subject

/** Every pushed destination inside one tab's stack. */
sealed interface AppRoute {
    data class Detail(
        val subject: Subject,
        val season: Int? = null,
    ) : AppRoute

    data class Player(val request: PlaybackRequest) : AppRoute

    data object History : AppRoute

    data object ManageCategories : AppRoute

    data object Docs : AppRoute

    data object Lab : AppRoute
}

enum class AppTab(@param:StringRes val labelRes: Int) {
    HOME(R.string.nav_home),
    SEARCH(R.string.nav_search),
    WATCHLIST(R.string.nav_watchlist),
    DOWNLOADS(R.string.nav_downloads),
    SETTINGS(R.string.nav_settings),
}
