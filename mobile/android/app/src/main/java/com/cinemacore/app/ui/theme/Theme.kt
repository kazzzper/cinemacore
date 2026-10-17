package com.cinemacore.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

private val CinemacoreColors = darkColorScheme()

@Composable
fun CinemacoreTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = CinemacoreColors, content = content)
}
