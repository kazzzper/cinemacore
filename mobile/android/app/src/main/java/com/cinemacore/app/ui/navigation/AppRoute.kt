package com.cinemacore.app.ui.navigation

import androidx.annotation.StringRes
import com.cinemacore.app.R
import com.cinemacore.app.data.Feature
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

    data object FeatureTracking : AppRoute

    /** One show's downloaded seasons and episodes, inside the Downloads tab. */
    data class DownloadShow(val subjectId: String) : AppRoute
}

enum class AppTab(
    @param:StringRes val labelRes: Int,
    /** The local flag that offers this tab; null for the shell itself. */
    val feature: Feature?,
) {
    HOME(R.string.nav_home, null),
    SEARCH(R.string.nav_search, Feature.SEARCH),
    WATCHLIST(R.string.nav_watchlist, Feature.WATCHLIST),
    DOWNLOADS(R.string.nav_downloads, Feature.DOWNLOADS),
    SETTINGS(R.string.nav_settings, null),
}
