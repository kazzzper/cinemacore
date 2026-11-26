package com.cinemacore.app.ui.downloads

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.domain.DownloadItem
import com.cinemacore.app.domain.DownloadStatus
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.RemoteImage
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.launch

/**
 * One show's downloads, split by season and then by episode.
 *
 * The queue is flat: an episode is a file, not a tree. Grouping by title is
 * where the library shape belongs, so a show opens here instead of dumping
 * every episode it owns onto the Downloads screen.
 */
@Composable
fun DownloadShowScreen(
    app: CinemacoreViewModel,
    subjectId: String,
    onBack: () -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val all by app.downloads.collectAsState()
    val items = remember(all, subjectId) { all.filter { it.subjectId == subjectId } }
    val title = items.firstOrNull()?.title ?: stringResource(R.string.nav_downloads)
    var pendingRemoval by remember { mutableStateOf<DownloadItem?>(null) }

    val seasons = remember(items) {
        items.groupBy { it.season ?: 0 }
            .toSortedMap()
            .map { (season, members) ->
                season to members.sortedWith(compareBy({ it.episode ?: 0 }, { it.id }))
            }
    }

    Column(modifier = modifier.fillMaxSize().background(CinemaColors.Background)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x1),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = stringResource(R.string.action_back),
                    tint = CinemaColors.TextPrimary,
                )
            }
            Text(
                text = title,
                style = MaterialTheme.typography.titleLarge,
                color = CinemaColors.TextPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = CinemaSpacing.x1),
            )
        }

        if (items.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    text = stringResource(R.string.downloads_show_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
            return@Column
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = CinemaSpacing.screenHorizontal,
                end = CinemaSpacing.screenHorizontal,
                top = CinemaSpacing.x2,
                bottom = CinemaSpacing.x8,
            ),
            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
        ) {
            item(key = "header") {
                ShowHeader(items)
            }
            seasons.forEach { (season, members) ->
                item(key = "season-$season") {
                    Text(
                        text = if (season == 0) {
                            stringResource(R.string.downloads_show_episodes)
                        } else {
                            stringResource(R.string.downloads_show_season, season)
                        },
                        style = MaterialTheme.typography.titleSmall,
                        color = CinemaColors.TextPrimary,
                        modifier = Modifier.padding(top = CinemaSpacing.x3, bottom = CinemaSpacing.x1),
                    )
                }
                items(members, key = { it.id }) { item ->
                    EpisodeRow(
                        item = item,
                        onPlay = { onPlay(playbackRequest(item)) },
                        onPause = { scope.launch { app.pause(item.id) } },
                        onResume = { scope.launch { app.resume(item.id) } },
                        onRetry = { scope.launch { app.retry(item.id) } },
                        onRemove = { pendingRemoval = item },
                    )
                }
            }
        }
    }

    pendingRemoval?.let { item ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text(stringResource(R.string.downloads_remove_title)) },
            text = {
                Text(
                    stringResource(
                        R.string.downloads_remove_message,
                        item.episodeLabel?.let { "$title $it" } ?: title,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingRemoval = null
                        scope.launch { app.remove(item.id) }
                    },
                ) {
                    Text(stringResource(R.string.action_remove))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRemoval = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

@Composable
private fun ShowHeader(items: List<DownloadItem>) {
    val first = items.first()
    val bytes = items.sumOf { it.totalBytes }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = CinemaSpacing.x2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
    ) {
        Box(
            modifier = Modifier
                .width(72.dp)
                .height(108.dp)
                .clip(RoundedCornerShape(CinemaShape.small)),
        ) {
            RemoteImage(
                url = first.poster,
                modifier = Modifier.fillMaxSize(),
                contentDescription = null,
            )
        }
        Column {
            Text(
                text = first.title,
                style = MaterialTheme.typography.titleLarge,
                color = CinemaColors.TextPrimary,
            )
            Text(
                text = buildString {
                    append("${items.size} episode")
                    if (items.size != 1) append('s')
                    if (bytes > 0) {
                        append(" · ")
                        append(com.cinemacore.app.domain.PlaybackPolicy.formatSize(bytes))
                    }
                },
                style = MaterialTheme.typography.bodySmall,
                color = CinemaColors.TextSecondary,
            )
        }
    }
}

@Composable
private fun EpisodeRow(
    item: DownloadItem,
    onPlay: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRetry: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(CinemaShape.medium))
            .background(CinemaColors.Surface)
            .padding(CinemaSpacing.x2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
    ) {
        Column(Modifier.weight(1f)) {
            Row(horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2)) {
                item.episodeLabel?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.titleSmall,
                        color = CinemaColors.TextPrimary,
                    )
                }
                Text(
                    text = item.status.name.lowercase().replaceFirstChar { it.uppercase() },
                    style = MaterialTheme.typography.bodySmall,
                    color = CinemaColors.TextSecondary,
                )
            }
            item.episodeTitle?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (item.status != DownloadStatus.COMPLETED && item.status != DownloadStatus.FAILED) {
                LinearProgressIndicator(
                    progress = { item.progress },
                    color = CinemaColors.Brand,
                    trackColor = CinemaColors.Separator,
                    modifier = Modifier.fillMaxWidth().padding(top = CinemaSpacing.x1),
                )
            }
            item.sizeText?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = CinemaColors.TextSecondary,
                )
            }
        }

        when {
            item.isFinished -> IconButton(onClick = onPlay) {
                Icon(
                    imageVector = Icons.Filled.PlayArrow,
                    contentDescription = stringResource(R.string.action_play),
                    tint = CinemaColors.TextPrimary,
                )
            }
            item.status == DownloadStatus.FAILED -> IconButton(onClick = onRetry) {
                Icon(
                    imageVector = Icons.Filled.Refresh,
                    contentDescription = stringResource(R.string.action_retry),
                    tint = CinemaColors.TextPrimary,
                )
            }
            item.status == DownloadStatus.PAUSED -> IconButton(onClick = onResume) {
                Icon(
                    imageVector = Icons.Filled.PlayArrow,
                    contentDescription = stringResource(R.string.action_resume),
                    tint = CinemaColors.TextPrimary,
                )
            }
            else -> IconButton(onClick = onPause) {
                Icon(
                    imageVector = Icons.Filled.Pause,
                    contentDescription = stringResource(R.string.action_pause),
                    tint = CinemaColors.TextPrimary,
                )
            }
        }
        IconButton(onClick = onRemove) {
            Icon(
                imageVector = Icons.Filled.Delete,
                contentDescription = stringResource(R.string.action_remove),
                tint = CinemaColors.TextSecondary,
            )
        }
    }
}

private fun playbackRequest(item: DownloadItem) = PlaybackRequest(
    subjectId = item.subjectId,
    title = item.title,
    poster = item.poster,
    kind = if (item.episode != null) "series" else "movie",
    season = item.season,
    episode = item.episode,
    episodeTitle = item.episodeTitle,
    downloadId = item.id,
)

