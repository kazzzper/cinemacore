package com.cinemacore.app.ui.manage

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import com.cinemacore.app.domain.CinemacoreError
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Reorder and hide the rails shown on Home.
 *
 * A saved order wins, but rails the provider added since are appended so a new
 * category cannot become unreachable. Hidden titles that no longer exist are
 * dropped, because the catalogue, not this screen, decides what a rail is.
 */
@Composable
fun ManageCategoriesScreen(
    app: CinemacoreViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf<LoadState<List<String>>>(LoadState.Idle) }
    var hidden by remember { mutableStateOf(emptySet<String>()) }
    var reloadToken by remember { mutableIntStateOf(0) }

    LaunchedEffect(app.repository, reloadToken) {
        state = LoadState.Loading
        try {
            val titles = app.repository.home().sections.map { it.title }.distinct()
            val saved = app.settings.railOrder.filter { it in titles }
            val merged = saved + titles.filter { it !in saved }
            hidden = app.settings.hiddenRails.filter { it in titles }.toSet()
            state = if (merged.isEmpty()) LoadState.Empty else LoadState.Loaded(merged)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            val typed = error as? CinemacoreError ?: CinemacoreError.Unknown(error.message)
            state = if (typed.requiresGate) LoadState.Locked(typed) else LoadState.Failed(typed)
        }
    }

    fun persist(order: List<String>, hiddenRails: Set<String>) {
        val orderedHidden = order.filter { it in hiddenRails }
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            // A reorder immediately followed by Back must still reach disk.
            withContext(NonCancellable) {
                app.updateSettings { settings ->
                    settings.copy(railOrder = order, hiddenRails = orderedHidden)
                }
            }
        }
    }

    fun toggle(rail: String) {
        val next = if (rail in hidden) hidden - rail else hidden + rail
        hidden = next
        state.valueOrNull?.let { persist(it, next) }
    }

    fun move(rail: String, delta: Int) {
        val current = state.valueOrNull ?: return
        val index = current.indexOf(rail)
        val target = index + delta
        if (index < 0 || target !in current.indices) return
        val reordered = current.toMutableList().apply { add(target, removeAt(index)) }
        state = LoadState.Loaded(reordered)
        persist(reordered, hidden)
    }

    Column(modifier = modifier.fillMaxSize().background(CinemaColors.Background)) {
        ManageHeader(onBack = onBack)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            StateView(
                state = state,
                emptyTitle = stringResource(R.string.manage_empty_title),
                emptyMessage = stringResource(R.string.manage_empty_message),
                loadingMessage = stringResource(R.string.manage_loading),
                onRetry = { reloadToken++ },
            ) { rails ->
                ManageRailList(
                    rails = rails,
                    hidden = hidden,
                    onToggle = ::toggle,
                    onMove = ::move,
                )
            }
        }
    }
}

@Composable
private fun ManageHeader(onBack: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.manage_back),
            )
        }
        Text(
            text = stringResource(R.string.manage_title),
            style = MaterialTheme.typography.titleLarge,
            color = CinemaColors.TextPrimary,
            modifier = Modifier.padding(start = CinemaSpacing.x1),
        )
    }
}

@Composable
private fun ManageRailList(
    rails: List<String>,
    hidden: Set<String>,
    onToggle: (String) -> Unit,
    onMove: (String, Int) -> Unit,
) {
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
        item(key = "hint") {
            Text(
                text = stringResource(R.string.manage_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
                modifier = Modifier.padding(bottom = CinemaSpacing.x2),
            )
        }
        items(rails, key = { it }) { rail ->
            val index = rails.indexOf(rail)
            ManageRailRow(
                title = rail,
                hidden = rail in hidden,
                canMoveUp = index > 0,
                canMoveDown = index >= 0 && index < rails.lastIndex,
                onToggle = { onToggle(rail) },
                onMoveUp = { onMove(rail, -1) },
                onMoveDown = { onMove(rail, 1) },
            )
        }
    }
}

@Composable
private fun ManageRailRow(
    title: String,
    hidden: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onToggle: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(CinemaShape.medium))
            .background(CinemaColors.Surface)
            .padding(horizontal = CinemaSpacing.x1, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onToggle) {
            Icon(
                imageVector = if (hidden) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                contentDescription = stringResource(
                    if (hidden) R.string.manage_show else R.string.manage_hide,
                    title,
                ),
                tint = if (hidden) CinemaColors.TextSecondary else CinemaColors.Brand,
            )
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = if (hidden) CinemaColors.TextSecondary else CinemaColors.TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = CinemaSpacing.x2),
        )
        IconButton(onClick = onMoveUp, enabled = canMoveUp) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowUp,
                contentDescription = stringResource(R.string.manage_move_up, title),
            )
        }
        IconButton(onClick = onMoveDown, enabled = canMoveDown) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = stringResource(R.string.manage_move_down, title),
            )
        }
    }
}
