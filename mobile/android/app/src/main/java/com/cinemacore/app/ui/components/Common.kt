package com.cinemacore.app.ui.components

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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.cinemacore.app.R
import coil.request.ImageRequest
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.Section
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing

/** Coil-backed image with a deterministic placeholder, never a blank hole. */
@Composable
fun RemoteImage(
    url: String?,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
    contentScale: ContentScale = ContentScale.Crop,
) {
    val normalized = url?.takeIf { it.isNotBlank() }?.let {
        if (it.startsWith("//")) "https:$it" else it
    }
    val placeholder = ColorPainter(CinemaColors.PosterPlaceholder)
    AsyncImage(
        model = ImageRequest.Builder(LocalContext.current)
            .data(normalized)
            .crossfade(true)
            .build(),
        contentDescription = contentDescription,
        modifier = modifier,
        contentScale = contentScale,
        placeholder = placeholder,
        error = placeholder,
        fallback = placeholder,
    )
}

@Composable
fun RatingBadge(text: String, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(CinemaColors.Background.copy(alpha = 0.74f))
            .padding(horizontal = 7.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.Star,
            contentDescription = null,
            tint = CinemaColors.Accent,
            modifier = Modifier.size(11.dp),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = CinemaColors.Accent,
        )
    }
}

@Composable
fun Chip(
    text: String,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        color = if (prominent) CinemaColors.Background else CinemaColors.TextSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .clip(CircleShape)
            .background(
                if (prominent) CinemaColors.TextPrimary.copy(alpha = 0.94f)
                else CinemaColors.SurfaceElevated,
            )
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

@Composable
fun Wordmark(modifier: Modifier = Modifier) {
    Text(
        text = "CINEMACORE",
        style = MaterialTheme.typography.headlineMedium.copy(letterSpacing = 4.sp),
        color = CinemaColors.TextPrimary,
        maxLines = 1,
        overflow = TextOverflow.Clip,
        modifier = modifier,
    )
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleLarge,
        color = CinemaColors.TextPrimary,
        modifier = modifier,
    )
}

@Composable
fun NoticeBanner(
    text: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(CinemaColors.SurfaceElevated.copy(alpha = 0.9f))
            .padding(horizontal = CinemaSpacing.x4, vertical = CinemaSpacing.x3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
    ) {
        Box(
            Modifier
                .size(7.dp)
                .clip(CircleShape)
                .background(CinemaColors.Accent),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = CinemaColors.TextSecondary,
        )
    }
}

@Composable
fun PosterCard(
    subject: Subject,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    showTitle: Boolean = true,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(CinemaShape.poster))
            .clickable(onClick = onClick),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(CinemaShape.poster)),
        ) {
            RemoteImage(
                url = subject.poster,
                modifier = Modifier.fillMaxSize(),
                contentDescription = subject.title,
            )
            subject.ratingLabel?.let {
                RatingBadge(
                    text = it,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(6.dp),
                )
            }
        }
        if (showTitle) {
            Text(
                text = subject.title,
                style = MaterialTheme.typography.titleSmall,
                color = CinemaColors.TextPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
fun Rail(
    section: Section,
    onSubjectClick: (Subject) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (section.items.isEmpty()) return
    Column(modifier = modifier.fillMaxWidth()) {
        SectionTitle(
            text = section.title,
            modifier = Modifier.padding(horizontal = CinemaSpacing.screenHorizontal),
        )
        Spacer(Modifier.height(CinemaSpacing.x3))
        LazyRow(
            contentPadding = PaddingValues(horizontal = CinemaSpacing.screenHorizontal),
            horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
        ) {
            items(section.items, key = { it.id }) { subject ->
                PosterCard(
                    subject = subject,
                    onClick = { onSubjectClick(subject) },
                    modifier = Modifier.width(124.dp),
                )
            }
        }
    }
}

@Composable
fun PosterGrid(
    subjects: List<Subject>,
    onSubjectClick: (Subject) -> Unit,
    modifier: Modifier = Modifier,
    onRemove: ((Subject) -> Unit)? = null,
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 108.dp),
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = CinemaSpacing.screenHorizontal,
            end = CinemaSpacing.screenHorizontal,
            top = CinemaSpacing.x3,
            bottom = CinemaSpacing.x8,
        ),
        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
        verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x4),
    ) {
        items(subjects, key = { it.id }) { subject ->
            Box {
                PosterCard(
                    subject = subject,
                    onClick = { onSubjectClick(subject) },
                    modifier = Modifier.fillMaxWidth(),
                )
                if (onRemove != null) {
                    Surface(
                        onClick = { onRemove(subject) },
                        shape = CircleShape,
                        color = CinemaColors.Background.copy(alpha = 0.78f),
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(6.dp)
                            .size(30.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(
                                imageVector = Icons.Filled.Close,
                                contentDescription = stringResource(R.string.watchlist_remove_action, subject.title),
                                tint = CinemaColors.TextPrimary,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun LoadingView(
    message: String = stringResource(R.string.state_loading),
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator(color = CinemaColors.Brand)
        Spacer(Modifier.height(CinemaSpacing.x4))
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = CinemaColors.TextSecondary,
        )
    }
}

@Composable
fun EmptyView(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(CinemaSpacing.x6),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Wordmark()
        Spacer(Modifier.height(CinemaSpacing.x5))
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge,
            color = CinemaColors.TextPrimary,
        )
        Spacer(Modifier.height(CinemaSpacing.x2))
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = CinemaColors.TextSecondary,
        )
    }
}

@Composable
fun ErrorView(
    error: CinemacoreError,
    onRetry: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(CinemaSpacing.x6),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = stringResource(
                if (error.requiresGate) R.string.state_locked else R.string.state_load_failed,
            ),
            style = MaterialTheme.typography.titleLarge,
            color = CinemaColors.TextPrimary,
        )
        Spacer(Modifier.height(CinemaSpacing.x2))
        Text(
            text = error.userMessage,
            style = MaterialTheme.typography.bodyMedium,
            color = CinemaColors.TextSecondary,
        )
        if (onRetry != null && error.isRetryable) {
            Spacer(Modifier.height(CinemaSpacing.x4))
            TextButton(onClick = onRetry) { Text(stringResource(R.string.action_retry)) }
        }
    }
}

/**
 * One rendering path for every screen state. Keeping Empty distinct from a
 * loaded empty list is the point: a successful request with no rows must never
 * look like a successful catalogue.
 */
@Composable
fun <T> StateView(
    state: LoadState<T>,
    emptyTitle: String,
    emptyMessage: String,
    modifier: Modifier = Modifier,
    loadingMessage: String = stringResource(R.string.state_loading),
    onRetry: (() -> Unit)? = null,
    content: @Composable (T) -> Unit,
) {
    when (state) {
        LoadState.Idle, LoadState.Loading -> LoadingView(
            message = loadingMessage,
            modifier = modifier,
        )
        LoadState.Empty -> EmptyView(
            title = emptyTitle,
            message = emptyMessage,
            modifier = modifier,
        )
        is LoadState.Failed -> ErrorView(
            error = state.error,
            onRetry = onRetry,
            modifier = modifier,
        )
        is LoadState.Locked -> ErrorView(
            error = state.error,
            onRetry = null,
            modifier = modifier,
        )
        is LoadState.Loaded -> content(state.value)
    }
}

/** Hero scrim shared by the home hero and the detail header. */
val HeroScrim: Brush
    @Composable get() = Brush.verticalGradient(
        0.0f to Color.Transparent,
        0.55f to CinemaColors.Background.copy(alpha = 0.58f),
        1.0f to CinemaColors.Background,
    )
