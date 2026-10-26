package com.cinemacore.app.ui.home

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cinemacore.app.R
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.PlaybackRequest
import com.cinemacore.app.domain.Section
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.HeroScrim
import com.cinemacore.app.ui.components.NoticeBanner
import com.cinemacore.app.ui.components.Rail
import com.cinemacore.app.ui.components.RemoteImage
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.components.Wordmark
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing

/** Compact hero art: a small screen still shows the first rail below it. */
private val HeroArtHeight = 280.dp

@Composable
fun HomeScreen(
    app: CinemacoreViewModel,
    onOpenDetail: (Subject) -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
    modifier: Modifier = Modifier,
) {
    // A source change produces a different catalogue; a new key gives the
    // screen a fresh state instead of showing the previous source's page.
    val viewModel: HomeViewModel = viewModel(
        key = "home-${app.repositoryGeneration}",
        factory = HomeViewModel.factory(app.repository),
    )
    LaunchedEffect(viewModel) { viewModel.loadIfNeeded() }

    val hidden = app.settings.hiddenRails
    val loadedState = viewModel.state
    val visibleSections = viewModel.visibleSections(hidden).filter { it.items.isNotEmpty() }
    val displayState: LoadState<List<Section>> = when (loadedState) {
        LoadState.Idle -> LoadState.Idle
        LoadState.Loading -> LoadState.Loading
        LoadState.Empty -> LoadState.Empty
        is LoadState.Failed -> loadedState
        is LoadState.Locked -> loadedState
        is LoadState.Loaded ->
            if (visibleSections.isEmpty()) LoadState.Empty else LoadState.Loaded(visibleSections)
    }
    val allRailsHidden = loadedState is LoadState.Loaded &&
        visibleSections.isEmpty() &&
        hidden.isNotEmpty()
    val partial = loadedState is LoadState.Loaded &&
        visibleSections.isNotEmpty() &&
        hidden.isNotEmpty()
    val emptyTitle = stringResource(
        if (allRailsHidden) R.string.home_all_hidden_title else R.string.home_empty_title,
    )
    val emptyMessage = stringResource(
        if (allRailsHidden) R.string.home_all_hidden_message else R.string.home_empty_message,
    )

    val demoSources = stringResource(R.string.home_demo_source)
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(CinemaColors.Background),
    ) {
        if (!app.isLive) {
            NoticeBanner(text = app.sourceNote.ifBlank { demoSources })
        }
        HomeHeader(
            loading = loadedState.isLoading,
            onRefresh = viewModel::load,
        )
        Box(
            Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            StateView(
                state = displayState,
                emptyTitle = emptyTitle,
                emptyMessage = emptyMessage,
                loadingMessage = stringResource(R.string.home_loading),
                onRetry = viewModel::load,
                modifier = Modifier.fillMaxSize(),
            ) { sections ->
                HomeContent(
                    sections = sections,
                    showHiddenNotice = partial,
                    onOpenDetail = onOpenDetail,
                    onPlay = onPlay,
                )
            }
        }
    }
}

@Composable
private fun HomeHeader(
    loading: Boolean,
    onRefresh: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = CinemaSpacing.screenHorizontal,
                end = CinemaSpacing.x2,
                top = CinemaSpacing.x4,
                bottom = CinemaSpacing.x2,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Wordmark(Modifier.weight(1f))
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier
                    .padding(horizontal = CinemaSpacing.x3)
                    .size(22.dp),
                color = CinemaColors.Brand,
                strokeWidth = 2.dp,
            )
        } else {
            IconButton(
                onClick = onRefresh,
                modifier = Modifier.size(48.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.Refresh,
                    contentDescription = stringResource(R.string.home_action_refresh),
                    tint = CinemaColors.TextPrimary,
                )
            }
        }
    }
}

@Composable
private fun HomeContent(
    sections: List<Section>,
    showHiddenNotice: Boolean,
    onOpenDetail: (Subject) -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
) {
    val featured = sections.firstOrNull { it.items.isNotEmpty() }?.items?.firstOrNull()
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = CinemaSpacing.x2,
            bottom = CinemaSpacing.x8,
        ),
        verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x6),
    ) {
        if (showHiddenNotice) {
            item(key = "hidden-rails-notice") {
                NoticeBanner(text = stringResource(R.string.home_hidden_rails_notice))
            }
        }
        if (featured != null) {
            item(key = "hero-${featured.id}") {
                Hero(
                    subject = featured,
                    onOpenDetail = onOpenDetail,
                    onPlay = onPlay,
                )
            }
        }
        itemsIndexed(
            items = sections,
            key = { index, section -> "rail-$index-${section.title}" },
        ) { _, section ->
            Rail(
                section = section,
                onSubjectClick = onOpenDetail,
            )
        }
    }
}

@Composable
private fun Hero(
    subject: Subject,
    onOpenDetail: (Subject) -> Unit,
    onPlay: (PlaybackRequest) -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.screenHorizontal),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(HeroArtHeight)
                .clip(RoundedCornerShape(CinemaShape.large)),
        ) {
            RemoteImage(
                url = subject.poster,
                modifier = Modifier.fillMaxSize(),
                contentDescription = subject.title,
                contentScale = ContentScale.Crop,
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .background(HeroScrim),
            )
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .padding(CinemaSpacing.x4),
            ) {
                Text(
                    text = subject.title,
                    style = MaterialTheme.typography.headlineMedium,
                    color = CinemaColors.TextPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                val metadata = metadataLine(subject)
                if (metadata.isNotEmpty()) {
                    Spacer(Modifier.height(CinemaSpacing.x1))
                    Text(
                        text = metadata,
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Spacer(Modifier.height(CinemaSpacing.x3))
        Row(horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3)) {
            Button(
                onClick = { onPlay(PlaybackRequest.forSubject(subject)) },
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp),
                shape = RoundedCornerShape(CinemaShape.small),
                colors = ButtonDefaults.buttonColors(
                    containerColor = CinemaColors.Brand,
                    contentColor = CinemaColors.TextPrimary,
                ),
            ) {
                Icon(
                    imageVector = Icons.Filled.PlayArrow,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(CinemaSpacing.x1))
                Text(stringResource(R.string.home_action_play))
            }
            OutlinedButton(
                onClick = { onOpenDetail(subject) },
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp),
                shape = RoundedCornerShape(CinemaShape.small),
                border = BorderStroke(1.dp, CinemaColors.Separator),
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = CinemaColors.TextPrimary,
                ),
            ) {
                Icon(
                    imageVector = Icons.Filled.Info,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(CinemaSpacing.x1))
                Text(stringResource(R.string.home_action_details))
            }
        }
    }
}

@Composable
private fun metadataLine(subject: Subject): String {
    val parts = buildList {
        subject.yearLabel?.let { add(it) }
        subject.genres.firstOrNull()?.let { add(it) }
        if (subject.isSeries) {
            subject.seasonLabel?.let { add(it) }
        } else {
            subject.runtimeLabel?.let { add(it) }
        }
    }
    return parts.joinToString(stringResource(R.string.home_metadata_separator))
}
