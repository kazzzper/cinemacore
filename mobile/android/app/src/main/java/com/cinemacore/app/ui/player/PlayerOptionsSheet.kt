package com.cinemacore.app.ui.player

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.domain.Dub
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.SubtitleAvailability
import com.cinemacore.app.domain.SubtitleProvider
import com.cinemacore.app.domain.SubtitleTrack
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PlayerOptionsSheet(
    state: PlayerUiState,
    onDismiss: () -> Unit,
    onSpeed: (Float) -> Unit,
    onQuality: (StreamRendition) -> Unit,
    onSubtitle: (SubtitleTrack?) -> Unit,
    onRetryCommunitySubtitles: () -> Unit,
    onAudio: (Dub) -> Unit,
    onEpisode: (Episode) -> Unit,
    onAutoPlayNext: (Boolean) -> Unit,
    onFillScreen: (Boolean) -> Unit,
    onEnterPip: (() -> Unit)?,
    onDownload: (StreamRendition) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = CinemaColors.Surface,
        contentColor = CinemaColors.TextPrimary,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = CinemaSpacing.x5)
                .padding(bottom = CinemaSpacing.x8),
            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
        ) {
            Text(
                text = stringResource(R.string.player_options_title),
                style = MaterialTheme.typography.titleLarge,
            )

            SheetSectionTitle(stringResource(R.string.player_speed))
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
            ) {
                PlayerViewModel.SPEED_OPTIONS.forEach { speed ->
                    SpeedChip(
                        speed = speed,
                        selected = state.speed == speed,
                        onClick = { onSpeed(speed) },
                    )
                }
            }

            val qualities = PlaybackPolicy.orderedDirect(state.streams)
            if (state.webUrl == null && qualities.isNotEmpty()) {
                HorizontalDivider(
                    modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                    color = CinemaColors.Separator,
                )
                SheetSectionTitle(stringResource(R.string.player_quality))
                qualities.forEach { rendition ->
                    OptionRow(
                        selected = state.rendition?.url == rendition.url,
                        title = rendition.quality.ifBlank {
                            stringResource(R.string.player_quality_auto)
                        },
                        subtitle = rendition.size,
                        onClick = {
                            onQuality(rendition)
                            onDismiss()
                        },
                    )
                }
            }

            val isLocal = !state.request.localFilePath.isNullOrBlank() ||
                state.request.downloadId != null
            val downloadable = qualities.filter {
                PlaybackPolicy.downloadRejection(it, it.isWeb) == null
            }
            if (!isLocal && downloadable.isNotEmpty()) {
                HorizontalDivider(
                    modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                    color = CinemaColors.Separator,
                )
                SheetSectionTitle(stringResource(R.string.player_download))
                Text(
                    text = stringResource(R.string.player_download_choose_hint),
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                )
                downloadable.forEach { rendition ->
                    val quality = rendition.quality.ifBlank {
                        stringResource(R.string.player_quality_auto)
                    }
                    OptionRow(
                        selected = state.rendition?.url == rendition.url,
                        title = quality,
                        subtitle = renditionDetail(rendition),
                        onClick = {
                            onDownload(rendition)
                            onDismiss()
                        },
                    )
                }
            }

            if (state.webUrl == null) {
                HorizontalDivider(
                    modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                    color = CinemaColors.Separator,
                )
                SheetSectionTitle(stringResource(R.string.player_subtitles))
                val providerTracks = state.subtitles.filter { it.provider == SubtitleProvider.PROVIDER }
                val communityTracks = state.subtitles.filter { it.provider == SubtitleProvider.COMMUNITY }
                if (state.subtitles.isEmpty() && state.subtitleAvailability != SubtitleAvailability.LOADING) {
                    Text(
                        text = stringResource(R.string.player_subtitles_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                    )
                } else {
                    OptionRow(
                        selected = state.selectedSubtitle == null,
                        title = stringResource(R.string.player_subtitles_off),
                        subtitle = null,
                        onClick = {
                            onSubtitle(null)
                            onDismiss()
                        },
                    )
                    providerTracks.forEach { track ->
                        SubtitleRow(track = track, state = state, onSubtitle = onSubtitle, onDismiss = onDismiss)
                    }
                }

                // The lookup reports its own outcome: an empty section is
                // indistinguishable from a source that does not exist, which is
                // what made "community subtitles are missing" look like a
                // missing feature rather than a failed request.
                when (state.subtitleAvailability) {
                    SubtitleAvailability.LOADING -> Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = CinemaColors.TextSecondary,
                        )
                        Text(
                            text = stringResource(R.string.player_subtitles_searching),
                            style = MaterialTheme.typography.bodyMedium,
                            color = CinemaColors.TextSecondary,
                        )
                    }

                    SubtitleAvailability.UNAVAILABLE -> Column {
                        Text(
                            text = stringResource(R.string.player_subtitles_community_none),
                            style = MaterialTheme.typography.bodyMedium,
                            color = CinemaColors.TextSecondary,
                        )
                        TextButton(onClick = onRetryCommunitySubtitles) {
                            Text(stringResource(R.string.player_subtitles_retry))
                        }
                    }

                    SubtitleAvailability.AVAILABLE -> if (communityTracks.isNotEmpty()) {
                        SheetSectionTitle(stringResource(R.string.player_subtitles_community))
                        Text(
                            text = stringResource(R.string.player_subtitles_community_hint),
                            style = MaterialTheme.typography.bodySmall,
                            color = CinemaColors.TextSecondary,
                        )
                        communityTracks.forEach { track ->
                            SubtitleRow(
                                track = track,
                                state = state,
                                onSubtitle = onSubtitle,
                                onDismiss = onDismiss,
                            )
                        }
                    }

                    SubtitleAvailability.IDLE -> Unit
                }

                HorizontalDivider(
                    modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                    color = CinemaColors.Separator,
                )
                SheetSectionTitle(stringResource(R.string.player_audio))
                if (state.dubs.isEmpty()) {
                    Text(
                        text = stringResource(R.string.player_audio_original_only),
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                    )
                } else {
                    state.dubs.forEach { dub ->
                        OptionRow(
                            selected = dub.subjectId == state.request.subjectId,
                            title = dub.languageName,
                            subtitle = if (dub.isOriginal) {
                                stringResource(R.string.player_audio_original)
                            } else {
                                null
                            },
                            onClick = {
                                onAudio(dub)
                                onDismiss()
                            },
                        )
                    }
                }
            }

            if (state.request.isSeries || state.seasons.isNotEmpty()) {
                HorizontalDivider(
                    modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                    color = CinemaColors.Separator,
                )
                SheetSectionTitle(stringResource(R.string.player_episodes))
                if (state.seasons.isEmpty()) {
                    Text(
                        text = stringResource(R.string.player_episodes_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                    )
                } else {
                    state.seasons.forEach { season ->
                        Text(
                            text = stringResource(R.string.player_season_format, season.number),
                            style = MaterialTheme.typography.titleSmall,
                            color = CinemaColors.TextPrimary,
                            modifier = Modifier.padding(top = CinemaSpacing.x2),
                        )
                        season.episodes.forEach { episode ->
                            val number = stringResource(
                                R.string.player_episode_number,
                                episode.number,
                            )
                            OptionRow(
                                selected = state.request.season == episode.season &&
                                    state.request.episode == episode.number,
                                title = episode.displayTitle,
                                subtitle = number,
                                onClick = {
                                    onEpisode(episode)
                                    onDismiss()
                                },
                            )
                        }
                    }
                }
            }

            HorizontalDivider(
                modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                color = CinemaColors.Separator,
            )
            SheetSectionTitle(stringResource(R.string.player_settings))
            SettingRow(
                title = stringResource(R.string.player_auto_next),
                checked = state.autoPlayNext,
                onCheckedChange = onAutoPlayNext,
            )
            SettingRow(
                title = stringResource(R.string.player_fill_screen),
                checked = state.fillScreen,
                onCheckedChange = onFillScreen,
            )

            if (onEnterPip != null) {
                HorizontalDivider(
                    modifier = Modifier.padding(vertical = CinemaSpacing.x2),
                    color = CinemaColors.Separator,
                )
                SheetSectionTitle(stringResource(R.string.player_output))
                ActionRow(
                    title = stringResource(R.string.player_pip),
                    subtitle = stringResource(R.string.player_pip_detail),
                    onClick = {
                        onDismiss()
                        onEnterPip()
                    },
                )
            }
        }
    }
}

/** "1.2 GB · MP4" — the facts a viewer needs to pick an offline quality. */
internal fun renditionDetail(rendition: StreamRendition): String {
    val size = rendition.size
        ?.takeIf { it.isNotBlank() }
        ?.let { raw -> raw.toLongOrNull()?.let(PlaybackPolicy::formatSize) ?: raw }
    return listOfNotNull(size, rendition.container.displayName).joinToString(" · ")
}

@Composable
private fun ActionRow(
    title: String,
    subtitle: String?,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(CinemaShape.small),
        color = Color.Transparent,
        contentColor = CinemaColors.TextPrimary,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x3),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
        ) {
            Icon(
                imageVector = Icons.Filled.PictureInPictureAlt,
                contentDescription = null,
                tint = CinemaColors.TextSecondary,
                modifier = Modifier.size(22.dp),
            )
            Column(Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge,
                )
                subtitle?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelMedium,
                        color = CinemaColors.TextSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun SheetSectionTitle(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleSmall,
        color = CinemaColors.TextSecondary,
    )
}

@Composable
private fun SpeedChip(
    speed: Float,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = if (selected) CinemaColors.TextPrimary else CinemaColors.SurfaceElevated,
        contentColor = if (selected) CinemaColors.Background else CinemaColors.TextPrimary,
    ) {
        Text(
            text = stringResource(
                R.string.player_speed_value,
                PlayerViewModel.formatSpeed(speed),
            ),
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.padding(
                horizontal = CinemaSpacing.x3,
                vertical = CinemaSpacing.x2,
            ),
        )
    }
}

@Composable
internal fun OptionRow(
    selected: Boolean,
    title: String,
    subtitle: String?,
    onClick: () -> Unit,
) {    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(CinemaShape.small),
        color = if (selected) CinemaColors.SurfaceElevated else Color.Transparent,
        contentColor = CinemaColors.TextPrimary,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x1),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RadioButton(selected = selected, onClick = null)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(start = CinemaSpacing.x1),
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                subtitle?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelMedium,
                        color = CinemaColors.TextSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun SettingRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = CinemaSpacing.x1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = CinemaColors.TextPrimary,
            modifier = Modifier.weight(1f),
        )
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/**
 * One caption row. The release label is what tells two English files apart;
 * without it both rows would read "English" and pick the same-looking track.
 */
@Composable
private fun SubtitleRow(
    track: SubtitleTrack,
    state: PlayerUiState,
    onSubtitle: (SubtitleTrack?) -> Unit,
    onDismiss: () -> Unit,
) {
    OptionRow(
        selected = state.selectedSubtitle?.url == track.url,
        title = track.language,
        subtitle = track.source ?: track.format?.uppercase(),
        onClick = {
            onSubtitle(track)
            onDismiss()
        },
    )
}
