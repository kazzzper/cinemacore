package com.cinemacore.app.ui.player

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.cinemacore.app.R
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaSpacing

/**
 * Offline quality is a separate decision from the quality being streamed right
 * now: a viewer may watch 480p on mobile data and still keep 1080p for a flight.
 * The player already holds every resolved rendition, so this sheet never asks
 * the provider again.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DownloadQualitySheet(
    state: PlayerUiState,
    onDismiss: () -> Unit,
    onDownload: (StreamRendition) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val resolved = PlaybackPolicy.orderedDirect(state.streams)
    val downloadable = resolved.filter {
        PlaybackPolicy.downloadRejection(it, it.isWeb) == null
    }
    val isLocal = !state.request.localFilePath.isNullOrBlank() ||
        state.request.downloadId != null
    val unavailable = when {
        state.webUrl != null -> stringResource(R.string.player_download_web)
        resolved.isNotEmpty() ->
            PlaybackPolicy.downloadRejection(resolved.first(), resolved.first().isWeb)
                ?: stringResource(R.string.player_download_unavailable)
        state.loadState is LoadState.Loading ->
            stringResource(R.string.player_download_loading)
        else -> stringResource(R.string.player_download_unavailable)
    }

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
                text = stringResource(R.string.player_download),
                style = MaterialTheme.typography.titleLarge,
            )
            Text(
                text = if (isLocal) {
                    stringResource(R.string.player_download_local)
                } else {
                    stringResource(R.string.player_download_choose_hint)
                },
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
                modifier = Modifier.padding(bottom = CinemaSpacing.x2),
            )

            if (!isLocal && downloadable.isNotEmpty()) {
                downloadable.forEach { rendition ->
                    val quality = rendition.quality.ifBlank {
                        stringResource(R.string.player_quality_auto)
                    }
                    OptionRow(
                        selected = state.rendition?.url == rendition.url,
                        title = quality,
                        subtitle = renditionDetail(rendition),
                        onClick = { onDownload(rendition) },
                    )
                }
            } else if (!isLocal) {
                Text(
                    text = unavailable,
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
        }
    }
}
