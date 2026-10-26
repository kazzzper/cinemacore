package com.cinemacore.app.ui.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.ResumePoint
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.NoticeBanner
import com.cinemacore.app.ui.components.RemoteImage
import com.cinemacore.app.ui.components.SectionTitle
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.launch

/** Continue-watching history, newest first, capped by the store. */
@Composable
fun HistoryScreen(
    app: CinemacoreViewModel,
    onBack: () -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = remember(app) { HistoryViewModel(app) }
    val state = model.state
    val scope = rememberCoroutineScope()
    var confirmsClear by rememberSaveable { mutableStateOf(false) }

    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = CinemaSpacing.screenHorizontal,
                    vertical = CinemaSpacing.x2,
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.action_back),
                    tint = CinemaColors.TextPrimary,
                )
            }
            Spacer(Modifier.width(CinemaSpacing.x1))
            SectionTitle(stringResource(R.string.library_history_title))
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
                emptyTitle = stringResource(R.string.library_history_empty_title),
                emptyMessage = stringResource(R.string.library_history_empty_message),
                loadingMessage = stringResource(R.string.state_loading),
                modifier = Modifier.fillMaxSize(),
            ) { points ->
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        horizontal = CinemaSpacing.screenHorizontal,
                        vertical = CinemaSpacing.x3,
                    ),
                    verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
                ) {
                    items(points, key = { it.key }) { point ->
                        HistoryRow(
                            point = point,
                            onPlay = onPlay,
                            onRemove = { scope.launch { model.remove(point.key) } },
                        )
                    }
                }
            }
        }
    }

    if (confirmsClear) {
        AlertDialog(
            onDismissRequest = { confirmsClear = false },
            title = { Text(stringResource(R.string.library_history_clear_title)) },
            text = { Text(stringResource(R.string.library_history_clear_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmsClear = false
                        scope.launch { model.clear() }
                    },
                ) {
                    Text(
                        text = stringResource(R.string.library_history_clear_confirm),
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

@Composable
private fun HistoryRow(
    point: ResumePoint,
    onPlay: (PlaybackRequest) -> Unit,
    onRemove: () -> Unit,
) {
    val season = point.season
    val episode = point.episode
    val resumeText = if (point.positionMs > 0) {
        stringResource(R.string.library_history_resume_at, formatTimecode(point.positionMs))
    } else {
        stringResource(R.string.library_history_from_start)
    }
    val remainingText = remainingText(point)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(CinemaShape.medium))
            .background(CinemaColors.Surface)
            .clickable { onPlay(PlaybackRequest.fromResume(point)) }
            .padding(CinemaSpacing.x2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
    ) {
        Box(
            modifier = Modifier
                .width(64.dp)
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(CinemaShape.small)),
        ) {
            RemoteImage(
                url = point.poster,
                modifier = Modifier.fillMaxSize(),
                contentDescription = null,
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x1),
        ) {
            Text(
                text = point.title,
                style = MaterialTheme.typography.titleSmall,
                color = CinemaColors.TextPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (season != null && episode != null) {
                Text(
                    text = stringResource(R.string.library_history_episode, season, episode),
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
            LinearProgressIndicator(
                progress = { point.progress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(CircleShape),
                color = CinemaColors.Brand,
                trackColor = CinemaColors.Separator,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2)) {
                Text(
                    text = resumeText,
                    style = MaterialTheme.typography.labelSmall,
                    color = CinemaColors.TextSecondary,
                )
                if (remainingText != null) {
                    Text(
                        text = remainingText,
                        style = MaterialTheme.typography.labelSmall,
                        color = CinemaColors.TextSecondary,
                    )
                }
            }
        }

        IconButton(onClick = onRemove) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = stringResource(
                    R.string.library_history_remove,
                    point.title,
                ),
                tint = CinemaColors.TextSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun remainingText(point: ResumePoint): String? {
    if (point.durationMs <= 0) return null
    val minutes = remainingMinutes(point)
    return when {
        minutes <= 0 -> stringResource(R.string.library_history_finished)
        minutes < 60 -> stringResource(R.string.library_history_remaining_minutes, minutes)
        minutes % 60 == 0 -> stringResource(
            R.string.library_history_remaining_hour,
            minutes / 60,
        )
        else -> stringResource(
            R.string.library_history_remaining_hours,
            minutes / 60,
            minutes % 60,
        )
    }
}
