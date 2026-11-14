package com.cinemacore.app.ui.splash

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.ui.components.Wordmark
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.delay

/**
 * The launch mark, drawn over a catalogue that is already booting behind it.
 *
 * It stays until [isLoading] clears, with a short minimum so the fade is not a
 * flash and a hard ceiling so a stalled provider cannot hold the app hostage.
 */
@Composable
fun SplashOverlay(
    isLoading: Boolean,
    content: @Composable () -> Unit,
) {
    var visible by rememberSaveable { mutableStateOf(true) }
    var minimumElapsed by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        delay(MIN_VISIBLE_MS)
        minimumElapsed = true
    }
    LaunchedEffect(isLoading, minimumElapsed) {
        if (!isLoading && minimumElapsed) {
            delay(FADE_LEAD_MS)
            visible = false
        }
    }
    LaunchedEffect(Unit) {
        delay(MAX_VISIBLE_MS)
        visible = false
    }

    Box(Modifier.fillMaxSize()) {
        content()
        AnimatedVisibility(
            visible = visible,
            exit = fadeOut(animationSpec = tween(320)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    // The catalogue boots behind the mark; without this, a
                    // launch tap would land on a screen the user cannot see.
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                awaitPointerEvent().changes.forEach { it.consume() }
                            }
                        }
                    }
                    .clearAndSetSemantics { }
                    .background(
                        Brush.radialGradient(
                            colors = listOf(
                                CinemaColors.BrandPressed.copy(alpha = 0.38f),
                                CinemaColors.Background,
                            ),
                            radius = 900f,
                        ),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(CinemaSpacing.x6),
                ) {
                    Image(
                        painter = painterResource(R.drawable.splash_logo),
                        contentDescription = stringResource(R.string.app_name),
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .size(176.dp)
                            .clip(RoundedCornerShape(44.dp)),
                    )
                    Spacer()
                    Wordmark()
                    Spacer()
                    Text(
                        text = stringResource(R.string.splash_tagline),
                        style = MaterialTheme.typography.labelSmall,
                        color = CinemaColors.TextSecondary,
                        textAlign = TextAlign.Center,
                    )
                    if (isLoading) {
                        Spacer()
                        CircularProgressIndicator(
                            color = CinemaColors.Accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Spacer() {
    Box(Modifier.height(CinemaSpacing.x3))
}

private const val MIN_VISIBLE_MS = 900L
private const val MAX_VISIBLE_MS = 8_000L
private const val FADE_LEAD_MS = 120L
