package com.cinemacore.app.ui.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.domain.CastMember
import com.cinemacore.app.domain.DownloadTarget
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.Chip
import com.cinemacore.app.ui.components.HeroScrim
import com.cinemacore.app.ui.components.NoticeBanner
import com.cinemacore.app.ui.components.RemoteImage
import com.cinemacore.app.ui.components.SectionTitle
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.player.renditionDetail
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One title: hero art, metadata, cast, the episode tree, and the two actions
 * that leave the screen (play and download).
 */
@Composable
fun DetailScreen(
    app: CinemacoreViewModel,
    subject: Subject,
    initialSeason: Int?,
    onBack: () -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = remember(subject, initialSeason, app.repositoryGeneration) {
        DetailViewModel(
            repository = app.repository,
            subject = subject,
            initialSeason = initialSeason,
        )
    }
    val scope = rememberCoroutineScope()
    LaunchedEffect(model) { model.load() }

    var pickerVisible by rememberSaveable { mutableStateOf(false) }
    var qualityPicker by remember { mutableStateOf<DownloadQualityChoice?>(null) }
    var queueing by remember { mutableStateOf(false) }
    var watchlistBusy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }

    val queueFailedText = stringResource(R.string.detail_queue_failed)
    val noEpisodesDownloadText = stringResource(R.string.detail_no_episodes_download)
    val noDownloadText = stringResource(R.string.detail_download_quality_empty)
    val watchlisted = app.isInWatchlist(subject.id)

    fun enqueue(
        subjectToQueue: Subject,
        targets: List<DownloadTarget>,
        quality: String?,
    ) {
        if (queueing || targets.isEmpty()) return
        val selectedTargets = if (quality == null) {
            targets
        } else {
            targets.map { it.copy(quality = quality) }
        }
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            queueing = true
            val message = try {
                // Leaving the screen must not drop a download the user already asked for.
                withContext(NonCancellable) {
                    app.enqueueTargets(subjectToQueue, selectedTargets).message
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                error.message ?: queueFailedText
            }
            queueing = false
            notice = message
        }
    }

    /**
     * Resolves the title once before asking which quality to keep. The download
     * queue later resolves each episode again; this first pass only populates
     * the choices, so it never assumes one episode's ladder matches another's.
     */
    fun chooseQuality(
        subjectToQueue: Subject,
        targets: List<DownloadTarget>,
        season: Int?,
        episode: Episode?,
    ) {
        if (queueing || targets.isEmpty()) return
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            queueing = true
            val choice = try {
                withContext(NonCancellable) {
                    val info = app.repository.play(subjectToQueue.id, season, episode?.number)
                    val streams = PlaybackPolicy.orderedDirect(info.streams).filter {
                        PlaybackPolicy.downloadRejection(it, it.isWeb) == null
                    }
                    if (streams.isEmpty()) {
                        val rejection = info.streams.firstOrNull()?.let {
                            PlaybackPolicy.downloadRejection(it, it.isWeb)
                        }
                        notice = rejection ?: noDownloadText
                        null
                    } else {
                        DownloadQualityChoice(subjectToQueue, targets, streams)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                notice = error.message ?: queueFailedText
                null
            }
            queueing = false
            if (choice != null) qualityPicker = choice
        }
    }

    Box(modifier = modifier.fillMaxSize().background(CinemaColors.Background)) {
        StateView(
            state = model.state,
            emptyTitle = stringResource(R.string.detail_empty_title),
            emptyMessage = stringResource(R.string.detail_empty_message),
            loadingMessage = stringResource(R.string.detail_loading),
            onRetry = { scope.launch { model.load() } },
        ) { detail ->
            DetailContent(
                detail = detail,
                seasons = model.seasons,
                episodes = model.episodes,
                selectedSeason = model.selectedSeason,
                selectedEpisode = model.selectedEpisode,
                episodesFailed = model.episodesFailed,
                actionsEnabled = !queueing,
                onPlaySelected = {
                    playbackFor(detail, model.selectedEpisode)?.let(onPlay)
                },
                onPlayEpisode = { episode ->
                    if (!queueing) {
                        model.selectEpisode(episode)
                        playbackFor(detail, episode)?.let(onPlay)
                    }
                },
                onDownload = {
                    if (detail.subject.isSeries) {
                        if (model.episodes.isEmpty()) {
                            notice = noEpisodesDownloadText
                        } else {
                            pickerVisible = true
                        }
                    } else {
                        chooseQuality(
                            subjectToQueue = detail.subject,
                            targets = listOf(DownloadTarget()),
                            season = null,
                            episode = null,
                        )
                    }
                },
                onSelectSeason = model::selectSeason,
                onRetryEpisodes = { scope.launch { model.load() } },
            )
        }

        // The back control and watchlist toggle stay usable in every state,
        // including a failed load where the content tree is gone.
        DetailTopBar(
            watchlisted = watchlisted,
            watchlistEnabled = !watchlistBusy,
            onBack = onBack,
            onToggleWatchlist = {
                if (!watchlistBusy) {
                    val target = model.detail?.subject ?: subject
                    scope.launch(start = CoroutineStart.UNDISPATCHED) {
                        watchlistBusy = true
                        withContext(NonCancellable) { app.toggleWatchlist(target) }
                        watchlistBusy = false
                    }
                }
            },
            modifier = Modifier.align(Alignment.TopCenter),
        )
    }

    val pickerDetail = model.detail
    if (pickerVisible && pickerDetail != null && model.episodes.isNotEmpty()) {
        DownloadPickerDialog(
            title = stringResource(R.string.detail_download_title, pickerDetail.subject.title),
            season = model.selectedSeason,
            episodes = model.episodes,
            onDismiss = { pickerVisible = false },
            onWholeSeason = {
                pickerVisible = false
                val targets = model.episodes.map { episode ->
                    DownloadTarget(
                        season = episode.season,
                        episode = episode,
                        episodeTitle = episode.displayTitle,
                    )
                }
                val first = targets.firstOrNull()
                if (first == null) {
                    notice = noEpisodesDownloadText
                } else {
                    chooseQuality(
                        subjectToQueue = pickerDetail.subject,
                        targets = targets,
                        season = first.season,
                        episode = first.episode,
                    )
                }
            },
            onEpisode = { episode ->
                pickerVisible = false
                chooseQuality(
                    subjectToQueue = pickerDetail.subject,
                    targets = listOf(
                        DownloadTarget(
                            season = episode.season,
                            episode = episode,
                            episodeTitle = episode.displayTitle,
                        ),
                    ),
                    season = episode.season,
                    episode = episode,
                )
            },
        )
    }

    qualityPicker?.let { pending ->
        DownloadQualityDialog(
            streams = pending.streams,
            onDismiss = { qualityPicker = null },
            onQuality = { rendition ->
                qualityPicker = null
                enqueue(
                    subjectToQueue = pending.subject,
                    targets = pending.targets,
                    quality = rendition.quality,
                )
            },
        )
    }

    notice?.let { message ->
        AlertDialog(
            onDismissRequest = { notice = null },
            title = { Text(stringResource(R.string.detail_download_notice_title)) },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { notice = null }) {
                    Text(stringResource(R.string.detail_ok))
                }
            },
            containerColor = CinemaColors.Surface,
        )
    }
}

/**
 * The row's own episode is passed so a tap that lands in the same frame as a
 * season change still plays the episode the user actually pressed.
 */
private fun playbackFor(detail: SubjectDetail, episode: Episode?): PlaybackRequest? {
    if (!detail.subject.isSeries) return PlaybackRequest.forSubject(detail.subject)
    val chosen = episode ?: return null
    return PlaybackRequest(
        subjectId = detail.subject.id,
        title = detail.subject.title,
        poster = detail.subject.poster,
        kind = detail.subject.kind,
        season = chosen.season,
        episode = chosen.number,
        episodeTitle = chosen.displayTitle,
    )
}

@Composable
private fun DetailContent(
    detail: SubjectDetail,
    seasons: List<Season>,
    episodes: List<Episode>,
    selectedSeason: Int,
    selectedEpisode: Episode?,
    episodesFailed: Boolean,
    actionsEnabled: Boolean,
    onPlaySelected: () -> Unit,
    onPlayEpisode: (Episode) -> Unit,
    onDownload: () -> Unit,
    onSelectSeason: (Int) -> Unit,
    onRetryEpisodes: () -> Unit,
) {
    val subject = detail.subject
    val chips = buildList {
        subject.yearLabel?.let { add(it) }
        subject.runtimeLabel?.let { add(it) }
        addAll(subject.genres)
        addAll(subject.dubs)
    }.distinct()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = CinemaSpacing.x8),
    ) {
        item(key = "hero") { Hero(subject) }

        item(key = "actions") {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = CinemaSpacing.screenHorizontal, vertical = CinemaSpacing.x4),
                verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3)) {
                    Button(
                        onClick = onPlaySelected,
                        enabled = actionsEnabled && (!subject.isSeries || selectedEpisode != null),
                        modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.PlayArrow,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(CinemaSpacing.x2))
                        Text(
                            text = if (subject.isSeries && selectedEpisode != null) {
                                stringResource(
                                    R.string.detail_play_episode,
                                    selectedEpisode.season,
                                    selectedEpisode.number,
                                )
                            } else {
                                stringResource(R.string.detail_play)
                            },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    OutlinedButton(
                        onClick = onDownload,
                        enabled = actionsEnabled,
                        modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Download,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(CinemaSpacing.x2))
                        Text(stringResource(R.string.detail_download), maxLines = 1)
                    }
                }
            }
        }

        if (chips.isNotEmpty()) {
            item(key = "metadata") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = CinemaSpacing.screenHorizontal),
                    horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
                ) {
                    chips.forEach { chip -> Chip(text = chip) }
                }
            }
        }

        subject.synopsis?.takeIf { it.isNotBlank() }?.let { synopsis ->
            item(key = "synopsis") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            horizontal = CinemaSpacing.screenHorizontal,
                            vertical = CinemaSpacing.x4,
                        ),
                    verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
                ) {
                    SectionTitle(stringResource(R.string.detail_synopsis))
                    Text(
                        text = synopsis,
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                    )
                }
            }
        }

        if (subject.cast.isNotEmpty()) {
            item(key = "cast-header") {
                SectionTitle(
                    text = stringResource(R.string.detail_cast),
                    modifier = Modifier.padding(
                        start = CinemaSpacing.screenHorizontal,
                        end = CinemaSpacing.screenHorizontal,
                        top = CinemaSpacing.x4,
                        bottom = CinemaSpacing.x3,
                    ),
                )
            }
            item(key = "cast") {
                CastRow(cast = subject.cast)
            }
        }

        if (subject.isSeries) {
            item(key = "episodes-header") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            start = CinemaSpacing.screenHorizontal,
                            end = CinemaSpacing.screenHorizontal,
                            top = CinemaSpacing.x6,
                            bottom = CinemaSpacing.x3,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SectionTitle(
                        text = stringResource(R.string.detail_episodes),
                        modifier = Modifier.weight(1f),
                    )
                    selectedEpisode?.let { episode ->
                        Text(
                            text = stringResource(
                                R.string.detail_selected_episode,
                                episode.season,
                                episode.number,
                            ),
                            style = MaterialTheme.typography.labelMedium,
                            color = CinemaColors.TextSecondary,
                        )
                    }
                }
            }

            if (seasons.size > 1) {
                item(key = "seasons") {
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = CinemaSpacing.screenHorizontal),
                        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
                        modifier = Modifier.padding(bottom = CinemaSpacing.x3),
                    ) {
                        items(seasons, key = { it.number }) { season ->
                            FilterChip(
                                selected = season.number == selectedSeason,
                                onClick = { onSelectSeason(season.number) },
                                label = {
                                    Text(stringResource(R.string.detail_season, season.number))
                                },
                            )
                        }
                    }
                }
            }

            if (episodesFailed) {
                item(key = "episodes-failed") {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        NoticeBanner(text = stringResource(R.string.detail_episodes_failed))
                        TextButton(
                            onClick = onRetryEpisodes,
                            modifier = Modifier.padding(start = CinemaSpacing.screenHorizontal),
                        ) {
                            Text(stringResource(R.string.detail_retry))
                        }
                    }
                }
            } else if (episodes.isEmpty()) {
                item(key = "episodes-empty") {
                    Text(
                        text = stringResource(R.string.detail_no_episodes),
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                        modifier = Modifier.padding(horizontal = CinemaSpacing.screenHorizontal),
                    )
                }
            }

            items(episodes, key = { it.id }) { episode ->
                EpisodeRow(
                    episode = episode,
                    selected = episode.id == selectedEpisode?.id,
                    enabled = actionsEnabled,
                    onPlay = { onPlayEpisode(episode) },
                )
            }
        }
    }
}

@Composable
private fun Hero(subject: Subject) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(340.dp),
    ) {
        RemoteImage(
            url = subject.poster,
            modifier = Modifier.fillMaxSize(),
            contentDescription = null,
        )
        Box(
            Modifier
                .matchParentSize()
                .background(HeroScrim),
        )
        Text(
            text = subject.title,
            style = MaterialTheme.typography.headlineLarge,
            color = CinemaColors.TextPrimary,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(
                    start = CinemaSpacing.x6,
                    end = CinemaSpacing.x6,
                    bottom = CinemaSpacing.x4,
                ),
        )
    }
}

@Composable
private fun CastRow(cast: List<CastMember>) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = CinemaSpacing.screenHorizontal),
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x4),
    ) {
        itemsIndexed(
            items = cast,
            key = { index, member -> "cast-$index-${member.name}" },
        ) { _, member ->
            Column(
                modifier = Modifier.width(88.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x1),
            ) {
                RemoteImage(
                    url = member.avatar,
                    modifier = Modifier
                        .size(64.dp)
                        .clip(CircleShape),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                )
                Text(
                    text = member.name,
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextPrimary,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                member.role?.takeIf { it.isNotBlank() }?.let { role ->
                    Text(
                        text = role,
                        style = MaterialTheme.typography.labelSmall,
                        color = CinemaColors.TextSecondary,
                        textAlign = TextAlign.Center,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun EpisodeRow(
    episode: Episode,
    selected: Boolean,
    enabled: Boolean,
    onPlay: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.x2, vertical = 2.dp)
            .clip(RoundedCornerShape(CinemaShape.small))
            .clickable(enabled = enabled, onClick = onPlay)
            .background(
                if (selected) CinemaColors.SurfaceElevated.copy(alpha = 0.72f) else Color.Transparent,
            )
            .padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(CinemaColors.Brand),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.PlayArrow,
                contentDescription = null,
                tint = CinemaColors.Background,
                modifier = Modifier.size(16.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = stringResource(
                    R.string.detail_episode_label,
                    episode.number,
                    episode.displayTitle,
                ),
                style = MaterialTheme.typography.titleSmall,
                color = CinemaColors.TextPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            episode.durationText?.let { duration ->
                Text(
                    text = duration,
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
        }
        if (selected) {
            Icon(
                imageVector = Icons.Filled.CheckCircle,
                contentDescription = stringResource(R.string.detail_selected),
                tint = CinemaColors.Brand,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun DownloadPickerDialog(
    title: String,
    season: Int,
    episodes: List<Episode>,
    onDismiss: () -> Unit,
    onWholeSeason: () -> Unit,
    onEpisode: (Episode) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(text = title) },
        text = {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp),
            ) {
                item(key = "whole-season") {
                    TextButton(
                        onClick = onWholeSeason,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            text = stringResource(R.string.detail_download_whole_season, season),
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Start,
                        )
                    }
                    HorizontalDivider(color = CinemaColors.Separator)
                }
                items(episodes, key = { it.id }) { episode ->
                    TextButton(
                        onClick = { onEpisode(episode) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = stringResource(
                                    R.string.detail_episode_label,
                                    episode.number,
                                    episode.displayTitle,
                                ),
                                modifier = Modifier.fillMaxWidth(),
                                textAlign = TextAlign.Start,
                            )
                            episode.durationText?.let { duration ->
                                Text(
                                    text = duration,
                                    style = MaterialTheme.typography.labelMedium,
                                    color = CinemaColors.TextSecondary,
                                    modifier = Modifier.fillMaxWidth(),
                                    textAlign = TextAlign.Start,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.detail_cancel))
            }
        },
        containerColor = CinemaColors.Surface,
    )
}

private data class DownloadQualityChoice(
    val subject: Subject,
    val targets: List<DownloadTarget>,
    val streams: List<StreamRendition>,
)

@Composable
private fun DownloadQualityDialog(
    streams: List<StreamRendition>,
    onDismiss: () -> Unit,
    onQuality: (StreamRendition) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.detail_download_quality_title)) },
        text = {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp),
            ) {
                item(key = "hint") {
                    Text(
                        text = stringResource(R.string.detail_download_quality_hint),
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                        modifier = Modifier.padding(bottom = CinemaSpacing.x2),
                    )
                }
                items(streams, key = { "${it.quality}-${it.url}" }) { rendition ->
                    TextButton(
                        onClick = { onQuality(rendition) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = rendition.quality.ifBlank {
                                    stringResource(R.string.player_quality_auto)
                                },
                                modifier = Modifier.fillMaxWidth(),
                                textAlign = TextAlign.Start,
                            )
                            Text(
                                text = renditionDetail(rendition),
                                style = MaterialTheme.typography.labelMedium,
                                color = CinemaColors.TextSecondary,
                                modifier = Modifier.fillMaxWidth(),
                                textAlign = TextAlign.Start,
                            )
                        }
                    }
                    HorizontalDivider(color = CinemaColors.Separator)
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.detail_cancel))
            }
        },
        containerColor = CinemaColors.Surface,
    )
}

@Composable
private fun DetailTopBar(
    watchlisted: Boolean,
    watchlistEnabled: Boolean,
    onBack: () -> Unit,
    onToggleWatchlist: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x1),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        OverlayIconButton(
            icon = Icons.AutoMirrored.Filled.ArrowBack,
            contentDescription = stringResource(R.string.detail_back),
            onClick = onBack,
        )
        OverlayIconButton(
            icon = if (watchlisted) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder,
            contentDescription = stringResource(
                if (watchlisted) R.string.detail_remove_watchlist else R.string.detail_add_watchlist,
            ),
            onClick = onToggleWatchlist,
            enabled = watchlistEnabled,
            tint = if (watchlisted) CinemaColors.Brand else CinemaColors.TextPrimary,
        )
    }
}

@Composable
private fun OverlayIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    tint: Color = CinemaColors.TextPrimary,
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = CircleShape,
        color = CinemaColors.Background.copy(alpha = 0.66f),
        contentColor = tint,
    ) {
        Box(modifier = Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = contentDescription,
                modifier = Modifier.size(22.dp),
                tint = tint,
            )
        }
    }
}
