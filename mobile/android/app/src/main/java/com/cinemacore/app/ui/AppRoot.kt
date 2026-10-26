package com.cinemacore.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.ui.detail.DetailScreen
import com.cinemacore.app.ui.docs.DocsScreen
import com.cinemacore.app.ui.docs.LabScreen
import com.cinemacore.app.ui.downloads.DownloadsScreen
import com.cinemacore.app.ui.home.HomeScreen
import com.cinemacore.app.ui.library.HistoryScreen
import com.cinemacore.app.ui.library.WatchlistScreen
import com.cinemacore.app.ui.manage.ManageCategoriesScreen
import com.cinemacore.app.ui.navigation.AppRoute
import com.cinemacore.app.ui.navigation.AppTab
import com.cinemacore.app.ui.search.SearchScreen
import com.cinemacore.app.ui.settings.SettingsScreen
import com.cinemacore.app.ui.theme.CinemaColors

@Composable
fun CinemacoreRoot(
    app: CinemacoreViewModel,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedTab by rememberSaveable { mutableStateOf(AppTab.HOME) }
    val stacks = remember {
        mutableStateMapOf<AppTab, SnapshotStateList<AppRoute>>().apply {
            AppTab.entries.forEach { put(it, mutableListOf<AppRoute>().toMutableStateList()) }
        }
    }
    val stack = stacks.getValue(selectedTab)

    fun push(route: AppRoute) {
        stacks.getValue(selectedTab).add(route)
    }

    fun pop() {
        val current = stacks.getValue(selectedTab)
        if (current.isNotEmpty()) current.removeAt(current.lastIndex)
    }

    BackHandler(enabled = stack.isNotEmpty()) { pop() }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = CinemaColors.Background,
        bottomBar = {
            if (stack.isEmpty()) {
                AppNavigationBar(
                    selected = selectedTab,
                    onSelect = { tab ->
                        if (selectedTab == tab) {
                            stacks.getValue(tab).clear()
                        } else {
                            selectedTab = tab
                        }
                    },
                )
            }
        },
    ) { innerPadding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            val detail = stack.lastOrNull()
            if (detail == null) {
                when (selectedTab) {
                    AppTab.HOME -> HomeScreen(
                        app = app,
                        onOpenDetail = { subject -> push(AppRoute.Detail(subject)) },
                        onPlay = onPlay,
                    )
                    AppTab.SEARCH -> SearchScreen(
                        app = app,
                        onOpenDetail = { subject -> push(AppRoute.Detail(subject)) },
                    )
                    AppTab.WATCHLIST -> WatchlistScreen(
                        app = app,
                        onOpenDetail = { subject -> push(AppRoute.Detail(subject)) },
                        onPlay = onPlay,
                    )
                    AppTab.DOWNLOADS -> DownloadsScreen(
                        app = app,
                        onOpenDetail = { subject, season ->
                            push(AppRoute.Detail(subject, season))
                        },
                        onPlay = onPlay,
                    )
                    AppTab.SETTINGS -> SettingsScreen(
                        app = app,
                        onOpenHistory = { push(AppRoute.History) },
                        onOpenManage = { push(AppRoute.ManageCategories) },
                        onOpenDocs = { push(AppRoute.Docs) },
                        onOpenLab = { push(AppRoute.Lab) },
                    )
                }
            } else {
                val route = detail ?: return@Box
                when (route) {
                    is AppRoute.Detail -> DetailScreen(
                        app = app,
                        subject = route.subject,
                        initialSeason = route.season,
                        onBack = ::pop,
                        onPlay = onPlay,
                    )
                    is AppRoute.Player -> LaunchedEffect(route.request) {
                        // PlayerActivity is the owner of playback; this route is
                        // only a safety net for a stale saved stack.
                        pop()
                        onPlay(route.request)
                    }
                    AppRoute.History -> HistoryScreen(
                        app = app,
                        onBack = ::pop,
                        onPlay = onPlay,
                    )
                    AppRoute.ManageCategories -> ManageCategoriesScreen(
                        app = app,
                        onBack = ::pop,
                    )
                    AppRoute.Docs -> DocsScreen(onBack = ::pop)
                    AppRoute.Lab -> LabScreen(
                        app = app,
                        onBack = ::pop,
                    )
                }
            }
        }
    }
}

@Composable
private fun AppNavigationBar(
    selected: AppTab,
    onSelect: (AppTab) -> Unit,
) {
    val icons = mapOf(
        AppTab.HOME to Icons.Filled.Home,
        AppTab.SEARCH to Icons.Filled.Search,
        AppTab.WATCHLIST to Icons.Filled.Bookmark,
        AppTab.DOWNLOADS to Icons.Filled.Download,
        AppTab.SETTINGS to Icons.Filled.Settings,
    )
    NavigationBar(
        containerColor = CinemaColors.Surface,
        tonalElevation = 0.dp,
    ) {
        AppTab.entries.forEach { tab ->
            NavigationBarItem(
                selected = selected == tab,
                onClick = { onSelect(tab) },
                icon = {
                    Icon(
                        imageVector = icons.getValue(tab),
                        contentDescription = stringResource(tab.labelRes),
                    )
                },
                label = { Text(stringResource(tab.labelRes)) },
            )
        }
    }
}

