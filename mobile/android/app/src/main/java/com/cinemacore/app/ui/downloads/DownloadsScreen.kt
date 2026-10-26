package com.cinemacore.app.ui.downloads

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cinemacore.app.R
import com.cinemacore.app.domain.AppSettings
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.DownloadGrouping
import com.cinemacore.app.domain.DownloadItem
import com.cinemacore.app.domain.DownloadSortKey
import com.cinemacore.app.domain.DownloadStatus
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.NoticeBanner
import com.cinemacore.app.ui.components.RemoteImage
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlin.math.roundToInt

@Composable
fun DownloadsScreen(
    app: CinemacoreViewModel,
    onOpenDetail: (Subject, Int?) -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val viewModel: DownloadsViewModel = viewModel(factory = DownloadsViewModel.factory(app))
    val items by app.downloads.collectAsState()
    val settings = app.settings
    val completedCount = items.count { it.status == DownloadStatus.COMPLETED }
    val activeCount = items.count { it.isActive }
    val resumableCount = items.count {
        it.status == DownloadStatus.PAUSED || it.status == DownloadStatus.FAILED
    }

    LaunchedEffect(items.size, completedCount) { viewModel.refreshStorage() }

    var pending by remember { mutableStateOf<PendingDestructive?>(null) }

    val storageFailure = stringResource(R.string.downloads_storage_unavailable)
    val state: LoadState<Unit> = when (viewModel.phase) {
        DownloadsPhase.Loading -> LoadState.Loading
        DownloadsPhase.StorageUnavailable ->
            LoadState.Failed(CinemacoreError.Upstream(storageFailure))
        DownloadsPhase.Ready -> if (items.isEmpty()) LoadState.Empty else LoadState.Loaded(Unit)
    }

    Column(modifier = modifier.fillMaxSize()) {
        DownloadsHeader(
            settings = settings,
            activeCount = activeCount,
            resumableCount = resumableCount,
            completedCount = completedCount,
            onSortKey = viewModel::setSortKey,
            onAscending = viewModel::setAscending,
            onGrouping = viewModel::setGrouping,
            onPauseAll = viewModel::pauseAll,
            onResumeAll = viewModel::resumeAll,
            onRemoveCompleted = {
                pending = PendingDestructive(
                    kind = DestructiveKind.REMOVE_COMPLETED,
                    ids = emptyList(),
                    name = "",
                )
            },
        )

        if (!app.isLive) {
            NoticeBanner(text = stringResource(R.string.downloads_demo_notice))
        }

        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            StateView(
                state = state,
                emptyTitle = stringResource(R.string.downloads_empty_title),
                emptyMessage = stringResource(R.string.downloads_empty_message),
                modifier = Modifier.fillMaxSize(),
                loadingMessage = stringResource(R.string.downloads_loading),
                onRetry = viewModel::load,
            ) {
                DownloadsContent(
                    allItems = items,
                    settings = settings,
                    onOpenDetail = onOpenDetail,
                    onPlay = { item ->
                        onPlay(
                            PlaybackRequest.fromDownload(item).copy(
                                localFilePath = app.fileFor(item).absolutePath,
                            ),
                        )
                    },
                    onPause = viewModel::pause,
                    onResume = viewModel::resume,
                    onRetry = viewModel::retry,
                    onPauseShow = viewModel::pauseShow,
                    onResumeShow = viewModel::resumeShow,
                    onAskDestructive = { kind, ids, name ->
                        pending = PendingDestructive(kind, ids, name)
                    },
                )
            }
        }

        if (viewModel.phase == DownloadsPhase.Ready && items.isNotEmpty()) {
            StorageFooter(
                bytesOnDisk = viewModel.bytesOnDisk,
                completedCount = completedCount,
            )
        }
    }

    pending?.let { action ->
        DestructiveDialog(
            action = action,
            onDismiss = { pending = null },
            onConfirm = {
                when (action.kind) {
                    DestructiveKind.CANCEL -> viewModel.cancel(action.ids)
                    DestructiveKind.REMOVE -> viewModel.remove(action.ids)
                    DestructiveKind.REMOVE_COMPLETED -> viewModel.removeCompleted()
                }
                pending = null
            },
        )
    }
}

@Composable
private fun DownloadsHeader(
    settings: AppSettings,
    activeCount: Int,
    resumableCount: Int,
    completedCount: Int,
    onSortKey: (DownloadSortKey) -> Unit,
    onAscending: (Boolean) -> Unit,
    onGrouping: (DownloadGrouping) -> Unit,
    onPauseAll: () -> Unit,
    onResumeAll: () -> Unit,
    onRemoveCompleted: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = CinemaSpacing.screenHorizontal,
                end = CinemaSpacing.x1,
                top = CinemaSpacing.x4,
                bottom = CinemaSpacing.x2,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = stringResource(R.string.downloads_title),
            style = MaterialTheme.typography.headlineMedium,
            color = CinemaColors.TextPrimary,
            modifier = Modifier.weight(1f),
        )
        SortMenu(
            settings = settings,
            onSortKey = onSortKey,
            onAscending = onAscending,
            onGrouping = onGrouping,
        )
        BulkMenu(
            activeCount = activeCount,
            resumableCount = resumableCount,
            completedCount = completedCount,
            onPauseAll = onPauseAll,
            onResumeAll = onResumeAll,
            onRemoveCompleted = onRemoveCompleted,
        )
    }
}

@Composable
private fun SortMenu(
    settings: AppSettings,
    onSortKey: (DownloadSortKey) -> Unit,
    onAscending: (Boolean) -> Unit,
    onGrouping: (DownloadGrouping) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.Sort,
                contentDescription = stringResource(R.string.downloads_sort_and_group),
                tint = CinemaColors.TextPrimary,
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            MenuLabel(stringResource(R.string.downloads_sort_by))
            DownloadSortKey.entries.forEach { key ->
                DropdownMenuItem(
                    text = { Text(sortLabel(key)) },
                    onClick = {
                        expanded = false
                        if (settings.downloadSortKey != key) onSortKey(key)
                    },
                    leadingIcon = {
                        SelectionMark(selected = settings.downloadSortKey == key)
                    },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = {
                    Text(
                        if (settings.downloadSortAscending) {
                            stringResource(R.string.downloads_sort_descending)
                        } else {
                            stringResource(R.string.downloads_sort_ascending)
                        },
                    )
                },
                onClick = {
                    expanded = false
                    onAscending(!settings.downloadSortAscending)
                },
                leadingIcon = {
                    Icon(
                        imageVector = if (settings.downloadSortAscending) {
                            Icons.Filled.ArrowDownward
                        } else {
                            Icons.Filled.ArrowUpward
                        },
                        contentDescription = null,
                    )
                },
            )
            HorizontalDivider()
            MenuLabel(stringResource(R.string.downloads_group_by))
            DownloadGrouping.entries.forEach { grouping ->
                DropdownMenuItem(
                    text = { Text(groupLabel(grouping)) },
                    onClick = {
                        expanded = false
                        if (settings.downloadGrouping != grouping) onGrouping(grouping)
                    },
                    leadingIcon = {
                        SelectionMark(selected = settings.downloadGrouping == grouping)
                    },
                )
            }
        }
    }
}

@Composable
private fun BulkMenu(
    activeCount: Int,
    resumableCount: Int,
    completedCount: Int,
    onPauseAll: () -> Unit,
    onResumeAll: () -> Unit,
    onRemoveCompleted: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(
                imageVector = Icons.Filled.MoreVert,
                contentDescription = stringResource(R.string.downloads_actions),
                tint = CinemaColors.TextPrimary,
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_pause_all)) },
                onClick = {
                    expanded = false
                    onPauseAll()
                },
                enabled = activeCount > 0,
                leadingIcon = { Icon(Icons.Filled.Pause, null) },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_resume_all)) },
                onClick = {
                    expanded = false
                    onResumeAll()
                },
                enabled = resumableCount > 0,
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
            )
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_remove_completed)) },
                onClick = {
                    expanded = false
                    onRemoveCompleted()
                },
                enabled = completedCount > 0,
                leadingIcon = { Icon(Icons.Filled.Delete, null) },
            )
        }
    }
}

@Composable
private fun MenuLabel(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        color = CinemaColors.TextSecondary,
        modifier = Modifier.padding(
            horizontal = CinemaSpacing.x4,
            vertical = CinemaSpacing.x1,
        ),
    )
}

@Composable
private fun SelectionMark(selected: Boolean) {
    if (selected) {
        Icon(
            imageVector = Icons.Filled.Check,
            contentDescription = null,
            tint = CinemaColors.Brand,
        )
    } else {
        Spacer(Modifier.size(24.dp))
    }
}

@Composable
private fun DownloadsContent(
    allItems: List<DownloadItem>,
    settings: AppSettings,
    onOpenDetail: (Subject, Int?) -> Unit,
    onPlay: (DownloadItem) -> Unit,
    onPause: (String) -> Unit,
    onResume: (String) -> Unit,
    onRetry: (String) -> Unit,
    onPauseShow: (List<String>) -> Unit,
    onResumeShow: (List<String>) -> Unit,
    onAskDestructive: (DestructiveKind, List<String>, String) -> Unit,
) {
    val ordered = remember(
        allItems,
        settings.downloadSortKey,
        settings.downloadSortAscending,
    ) {
        sortDownloads(
            items = allItems,
            key = settings.downloadSortKey,
            ascending = settings.downloadSortAscending,
        )
    }
    val sections = remember(ordered, settings.downloadGrouping) {
        when (settings.downloadGrouping) {
            DownloadGrouping.NONE -> listOf(
                DownloadSection(key = "all", status = null, items = ordered),
            )
            DownloadGrouping.STATUS -> DownloadStatus.entries
                .sortedBy { it.rank }
                .mapNotNull { status ->
                    val group = ordered.filter { it.status == status }
                    if (group.isEmpty()) {
                        null
                    } else {
                        DownloadSection(
                            key = status.name,
                            status = status,
                            items = group,
                        )
                    }
                }
        }
    }
    val showIds = allItems
        .groupBy { it.subjectId }
        .mapValues { entry -> entry.value.map { it.id } }
    val failedCount = allItems.count { it.status == DownloadStatus.FAILED }

    Column(modifier = Modifier.fillMaxSize()) {
        if (failedCount > 0) {
            NoticeBanner(
                text = pluralStringResource(
                    R.plurals.downloads_failed_notice,
                    failedCount,
                    failedCount,
                ),
            )
        }
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            contentPadding = PaddingValues(
                top = CinemaSpacing.x1,
                bottom = CinemaSpacing.x6,
            ),
        ) {
            sections.forEach { section ->
                val status = section.status
                if (status != null) {
                    item(key = "section-${section.key}") {
                        Text(
                            text = statusLabel(status),
                            style = MaterialTheme.typography.titleSmall,
                            color = CinemaColors.TextPrimary,
                            modifier = Modifier.padding(
                                start = CinemaSpacing.screenHorizontal,
                                end = CinemaSpacing.screenHorizontal,
                                top = CinemaSpacing.x4,
                                bottom = CinemaSpacing.x2,
                            ),
                        )
                    }
                }
                items(toRows(section.items), key = { it.item.id }) { row ->
                    val item = row.item
                    val itemShowIds = showIds[item.subjectId].orEmpty()
                    DownloadRowView(
                        row = row,
                        showIds = itemShowIds,
                        onOpen = {
                            onOpenDetail(
                                Subject(
                                    id = item.subjectId,
                                    title = item.title,
                                    poster = item.poster,
                                    kind = if (item.season != null) "series" else "movie",
                                ),
                                item.season,
                            )
                        },
                        onPlay = { onPlay(item) },
                        onPause = { onPause(item.id) },
                        onResume = { onResume(item.id) },
                        onRetry = { onRetry(item.id) },
                        onPauseShow = { onPauseShow(itemShowIds) },
                        onResumeShow = { onResumeShow(itemShowIds) },
                        onAskDestructive = onAskDestructive,
                    )
                }
            }
        }
    }
}

@Composable
private fun DownloadRowView(
    row: DownloadRow,
    showIds: List<String>,
    onOpen: () -> Unit,
    onPlay: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRetry: () -> Unit,
    onPauseShow: () -> Unit,
    onResumeShow: () -> Unit,
    onAskDestructive: (DestructiveKind, List<String>, String) -> Unit,
) {
    val item = row.item
    val name = displayName(item)
    var menuExpanded by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                onClickLabel = stringResource(R.string.downloads_open_details),
                onClick = onOpen,
            )
            .padding(
                horizontal = CinemaSpacing.screenHorizontal,
                vertical = CinemaSpacing.x2,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
    ) {
        RemoteImage(
            url = item.poster,
            modifier = Modifier
                .width(56.dp)
                .height(84.dp)
                .clip(RoundedCornerShape(CinemaShape.small)),
            contentDescription = null,
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x1),
        ) {
            if (row.showsSubjectTitle) {
                Text(
                    text = item.title,
                    style = MaterialTheme.typography.titleSmall,
                    color = CinemaColors.TextPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
            ) {
                val label = item.episodeLabel ?: if (!row.showsSubjectTitle) item.title else null
                if (label != null) {
                    Text(
                        text = label,
                        style = MaterialTheme.typography.labelLarge,
                        color = CinemaColors.TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                }
                Text(
                    text = statusLabel(item.status),
                    style = MaterialTheme.typography.labelMedium,
                    color = statusColor(item.status),
                    maxLines = 1,
                )
            }
            val episodeTitle = item.episodeTitle
            if (!episodeTitle.isNullOrBlank() && episodeTitle != item.title) {
                Text(
                    text = episodeTitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (item.status == DownloadStatus.FAILED) {
                Text(
                    text = item.failure?.takeIf { it.isNotBlank() }
                        ?: stringResource(R.string.downloads_failure_unknown),
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.Brand,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            } else if (item.status != DownloadStatus.COMPLETED) {
                LinearProgressIndicator(
                    progress = { item.progress },
                    modifier = Modifier.fillMaxWidth(),
                    color = CinemaColors.Brand,
                    trackColor = CinemaColors.SurfaceElevated,
                )
            }
            detailText(item)?.let { detail ->
                Text(
                    text = detail,
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (item.subtitles.isNotEmpty()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x1),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Subtitles,
                        contentDescription = null,
                        tint = CinemaColors.TextSecondary,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        text = pluralStringResource(
                            R.plurals.downloads_captions,
                            item.subtitles.size,
                            item.subtitles.size,
                        ),
                        style = MaterialTheme.typography.labelMedium,
                        color = CinemaColors.TextSecondary,
                    )
                }
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            when (item.status) {
                DownloadStatus.COMPLETED -> IconButton(onClick = onPlay) {
                    Icon(
                        imageVector = Icons.Filled.PlayArrow,
                        contentDescription = stringResource(R.string.downloads_play, name),
                        tint = CinemaColors.TextPrimary,
                    )
                }
                DownloadStatus.FAILED -> IconButton(onClick = onRetry) {
                    Icon(
                        imageVector = Icons.Filled.Refresh,
                        contentDescription = stringResource(R.string.downloads_retry, name),
                        tint = CinemaColors.TextPrimary,
                    )
                }
                DownloadStatus.PAUSED -> IconButton(onClick = onResume) {
                    Icon(
                        imageVector = Icons.Filled.PlayArrow,
                        contentDescription = stringResource(R.string.downloads_resume, name),
                        tint = CinemaColors.TextPrimary,
                    )
                }
                DownloadStatus.QUEUED, DownloadStatus.DOWNLOADING ->
                    IconButton(onClick = onPause) {
                        Icon(
                            imageVector = Icons.Filled.Pause,
                            contentDescription = stringResource(R.string.downloads_pause, name),
                            tint = CinemaColors.TextPrimary,
                        )
                    }
            }
            Box {
                IconButton(onClick = { menuExpanded = true }) {
                    Icon(
                        imageVector = Icons.Filled.MoreVert,
                        contentDescription = stringResource(
                            R.string.downloads_more_actions,
                            name,
                        ),
                        tint = CinemaColors.TextPrimary,
                    )
                }
                RowItemMenu(
                    expanded = menuExpanded,
                    item = item,
                    showIds = showIds,
                    onDismiss = { menuExpanded = false },
                    onPause = onPause,
                    onResume = onResume,
                    onRetry = onRetry,
                    onPauseShow = onPauseShow,
                    onResumeShow = onResumeShow,
                    onAskDestructive = onAskDestructive,
                )
            }
        }
    }
}

@Composable
private fun RowItemMenu(
    expanded: Boolean,
    item: DownloadItem,
    showIds: List<String>,
    onDismiss: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRetry: () -> Unit,
    onPauseShow: () -> Unit,
    onResumeShow: () -> Unit,
    onAskDestructive: (DestructiveKind, List<String>, String) -> Unit,
) {
    val name = displayName(item)
    val hasStatusAction = item.isActive ||
        item.status == DownloadStatus.PAUSED ||
        item.status == DownloadStatus.FAILED
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        if (item.isActive) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_pause)) },
                onClick = {
                    onDismiss()
                    onPause()
                },
                leadingIcon = { Icon(Icons.Filled.Pause, null) },
            )
        }
        if (item.status == DownloadStatus.PAUSED) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_resume)) },
                onClick = {
                    onDismiss()
                    onResume()
                },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
            )
        }
        if (item.status == DownloadStatus.FAILED) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_retry)) },
                onClick = {
                    onDismiss()
                    onRetry()
                },
                leadingIcon = { Icon(Icons.Filled.Refresh, null) },
            )
        }
        if (hasStatusAction) HorizontalDivider()
        if (!item.isFinished) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_cancel)) },
                onClick = {
                    onDismiss()
                    onAskDestructive(DestructiveKind.CANCEL, listOf(item.id), name)
                },
                leadingIcon = { Icon(Icons.Filled.Close, null) },
            )
        }
        DropdownMenuItem(
            text = { Text(stringResource(R.string.downloads_menu_remove)) },
            onClick = {
                onDismiss()
                onAskDestructive(DestructiveKind.REMOVE, listOf(item.id), name)
            },
            leadingIcon = { Icon(Icons.Filled.Delete, null) },
        )
        if (showIds.size > 1) {
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_pause_show)) },
                onClick = {
                    onDismiss()
                    onPauseShow()
                },
                leadingIcon = { Icon(Icons.Filled.Pause, null) },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_resume_show)) },
                onClick = {
                    onDismiss()
                    onResumeShow()
                },
                leadingIcon = { Icon(Icons.Filled.PlayArrow, null) },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.downloads_menu_remove_show)) },
                onClick = {
                    onDismiss()
                    onAskDestructive(DestructiveKind.REMOVE, showIds, item.title)
                },
                leadingIcon = { Icon(Icons.Filled.Delete, null) },
            )
        }
    }
}

@Composable
private fun StorageFooter(bytesOnDisk: Long, completedCount: Int) {
    val size = PlaybackPolicy.formatSize(bytesOnDisk)
        ?: stringResource(R.string.downloads_zero_bytes)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(CinemaColors.Surface.copy(alpha = 0.6f))
            .padding(
                horizontal = CinemaSpacing.screenHorizontal,
                vertical = CinemaSpacing.x3,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
    ) {
        Icon(
            imageVector = Icons.Filled.Storage,
            contentDescription = null,
            tint = CinemaColors.TextSecondary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = stringResource(
                R.string.downloads_storage_footer,
                size,
                completedCount,
            ),
            style = MaterialTheme.typography.labelMedium,
            color = CinemaColors.TextSecondary,
        )
    }
}

@Composable
private fun DestructiveDialog(
    action: PendingDestructive,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val isShow = action.ids.size > 1
    val title = when (action.kind) {
        DestructiveKind.CANCEL -> stringResource(R.string.downloads_confirm_cancel_title)
        DestructiveKind.REMOVE -> stringResource(
            if (isShow) {
                R.string.downloads_confirm_remove_show_title
            } else {
                R.string.downloads_confirm_remove_title
            },
        )
        DestructiveKind.REMOVE_COMPLETED ->
            stringResource(R.string.downloads_confirm_remove_completed_title)
    }
    val message = when (action.kind) {
        DestructiveKind.CANCEL -> stringResource(
            R.string.downloads_confirm_cancel_message,
            action.name,
        )
        DestructiveKind.REMOVE -> stringResource(
            if (isShow) {
                R.string.downloads_confirm_remove_show_message
            } else {
                R.string.downloads_confirm_remove_message
            },
            action.name,
        )
        DestructiveKind.REMOVE_COMPLETED ->
            stringResource(R.string.downloads_confirm_remove_completed_message)
    }
    val confirm = when (action.kind) {
        DestructiveKind.CANCEL -> stringResource(R.string.downloads_confirm_cancel_action)
        DestructiveKind.REMOVE -> stringResource(R.string.downloads_confirm_remove_action)
        DestructiveKind.REMOVE_COMPLETED ->
            stringResource(R.string.downloads_confirm_remove_completed_action)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(text = confirm, color = CinemaColors.Brand)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.downloads_dialog_dismiss))
            }
        },
    )
}

@Composable
private fun sortLabel(key: DownloadSortKey): String = stringResource(
    when (key) {
        DownloadSortKey.ADDED -> R.string.downloads_sort_added
        DownloadSortKey.TITLE -> R.string.downloads_sort_title
        DownloadSortKey.STATUS -> R.string.downloads_sort_status
    },
)

@Composable
private fun groupLabel(grouping: DownloadGrouping): String = stringResource(
    when (grouping) {
        DownloadGrouping.NONE -> R.string.downloads_group_none
        DownloadGrouping.STATUS -> R.string.downloads_group_status
    },
)

@Composable
private fun statusLabel(status: DownloadStatus): String = stringResource(
    when (status) {
        DownloadStatus.QUEUED -> R.string.downloads_status_queued
        DownloadStatus.DOWNLOADING -> R.string.downloads_status_downloading
        DownloadStatus.PAUSED -> R.string.downloads_status_paused
        DownloadStatus.COMPLETED -> R.string.downloads_status_completed
        DownloadStatus.FAILED -> R.string.downloads_status_failed
    },
)

@Composable
private fun detailText(item: DownloadItem): String? = when (item.status) {
    DownloadStatus.QUEUED -> stringResource(R.string.downloads_waiting)
    DownloadStatus.FAILED -> null
    DownloadStatus.COMPLETED -> {
        val size = item.sizeText
        if (size != null) stringResource(R.string.downloads_detail_completed, size) else null
    }
    DownloadStatus.PAUSED, DownloadStatus.DOWNLOADING -> when {
        item.totalBytes > 0 -> {
            val written = PlaybackPolicy.formatSize(item.bytesWritten)
                ?: stringResource(R.string.downloads_zero_bytes)
            val total = PlaybackPolicy.formatSize(item.totalBytes)
                ?: stringResource(R.string.downloads_zero_bytes)
            stringResource(
                R.string.downloads_detail_progress,
                written,
                total,
                (item.progress * 100).roundToInt(),
            )
        }
        item.bytesWritten > 0 -> {
            val written = PlaybackPolicy.formatSize(item.bytesWritten)
                ?: stringResource(R.string.downloads_zero_bytes)
            stringResource(R.string.downloads_detail_written, written)
        }
        else -> stringResource(R.string.downloads_starting)
    }
}

private fun statusColor(status: DownloadStatus) = when (status) {
    DownloadStatus.COMPLETED -> CinemaColors.Success
    DownloadStatus.FAILED -> CinemaColors.Brand
    DownloadStatus.PAUSED -> CinemaColors.TextSecondary
    DownloadStatus.QUEUED, DownloadStatus.DOWNLOADING -> CinemaColors.Brand
}

@Composable
private fun displayName(item: DownloadItem): String {
    val label = item.episodeLabel
    return if (label != null) {
        stringResource(R.string.downloads_name_with_episode, item.title, label)
    } else {
        item.title
    }
}

private fun toRows(items: List<DownloadItem>): List<DownloadRow> {
    var previousSubject: String? = null
    return items.map { item ->
        val shows = item.subjectId != previousSubject
        previousSubject = item.subjectId
        DownloadRow(item = item, showsSubjectTitle = shows)
    }
}

private fun sortDownloads(
    items: List<DownloadItem>,
    key: DownloadSortKey,
    ascending: Boolean,
): List<DownloadItem> {
    val comparator = when (key) {
        DownloadSortKey.ADDED -> compareBy<DownloadItem> { it.createdAt }
            .thenBy { it.title.lowercase() }
        DownloadSortKey.TITLE -> compareBy<DownloadItem> { it.title.lowercase() }
            .thenBy { it.season ?: 0 }
            .thenBy { it.episode ?: 0 }
        DownloadSortKey.STATUS -> compareBy<DownloadItem> { it.status.rank }
            .thenByDescending { it.createdAt }
    }
    val ordered = items.sortedWith(comparator)
    return if (ascending) ordered else ordered.reversed()
}

private enum class DestructiveKind {
    CANCEL,
    REMOVE,
    REMOVE_COMPLETED,
}

private data class PendingDestructive(
    val kind: DestructiveKind,
    val ids: List<String>,
    val name: String,
)

private data class DownloadRow(
    val item: DownloadItem,
    val showsSubjectTitle: Boolean,
)

private data class DownloadSection(
    val key: String,
    val status: DownloadStatus?,
    val items: List<DownloadItem>,
)
