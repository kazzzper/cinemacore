package com.cinemacore.app.ui.library

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.cinemacore.app.R
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.NoticeBanner
import com.cinemacore.app.ui.components.PosterGrid
import com.cinemacore.app.ui.components.SectionTitle
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.launch

/**
 * Saved titles. `onPlay` is part of the tab's navigation contract but a
 * watchlist row has no episode to resume, so it opens Detail instead.
 */
@Suppress("UNUSED_PARAMETER")
@Composable
fun WatchlistScreen(
    app: CinemacoreViewModel,
    onOpenDetail: (Subject) -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = remember(app) { WatchlistViewModel(app) }
    val state = model.state
    val scope = rememberCoroutineScope()
    var confirmsClear by rememberSaveable { mutableStateOf(false) }

    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = CinemaSpacing.screenHorizontal,
                    vertical = CinemaSpacing.x3,
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SectionTitle(stringResource(R.string.library_watchlist_title))
            Spacer(Modifier.weight(1f))
            TextButton(
                onClick = { confirmsClear = true },
                enabled = state.valueOrNull?.isNotEmpty() == true,
            ) {
                Text(stringResource(R.string.action_clear))
            }
        }

        if (model.writeFailed) {
            NoticeBanner(stringResource(R.string.library_write_failed))
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            StateView(
                state = state,
                emptyTitle = stringResource(R.string.library_watchlist_empty_title),
                emptyMessage = stringResource(R.string.library_watchlist_empty_message),
                loadingMessage = stringResource(R.string.state_loading),
                modifier = Modifier.fillMaxSize(),
            ) { subjects ->
                PosterGrid(
                    subjects = subjects,
                    onSubjectClick = onOpenDetail,
                    onRemove = { subject ->
                        scope.launch { model.remove(subject.id) }
                    },
                )
            }
        }
    }

    if (confirmsClear) {
        AlertDialog(
            onDismissRequest = { confirmsClear = false },
            title = { Text(stringResource(R.string.library_watchlist_clear_title)) },
            text = { Text(stringResource(R.string.library_watchlist_clear_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmsClear = false
                        scope.launch { model.clear() }
                    },
                ) {
                    Text(
                        text = stringResource(R.string.library_watchlist_clear_confirm),
                        color = CinemaColors.Brand,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmsClear = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
            containerColor = CinemaColors.SurfaceElevated,
            titleContentColor = CinemaColors.TextPrimary,
            textContentColor = CinemaColors.TextSecondary,
        )
    }
}
