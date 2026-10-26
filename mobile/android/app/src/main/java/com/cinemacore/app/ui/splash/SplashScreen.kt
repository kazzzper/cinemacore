package com.cinemacore.app.ui.splash

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.ui.components.Wordmark
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.delay

/**
 * The launch mark. It is an overlay, not a second activity: the catalogue can
 * boot behind it without a cold-start hand-off that would duplicate the process
 * state once the first frame appears.
 */
@Composable
fun SplashOverlay(content: @Composable () -> Unit) {
    var visible by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        delay(900)
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
                    .background(
                        Brush.radialGradient(
                            colors = listOf(
                                CinemaColors.BrandPressed.copy(alpha = 0.45f),
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
                    Wordmark()
                    Spacer()
                    Text(
                        text = stringResource(R.string.splash_tagline),
                        style = MaterialTheme.typography.labelSmall,
                        color = CinemaColors.TextSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun Spacer() {
    Box(Modifier.height(CinemaSpacing.x3))
}
