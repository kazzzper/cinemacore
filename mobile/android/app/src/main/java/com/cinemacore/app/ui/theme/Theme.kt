package com.cinemacore.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Cinematic Obsidian. These are the only literal colours outside the theme.
 * The brand is dark-only: the source design's "light" palette is byte-identical
 * to its dark palette, so an invented light theme would not be the brand.
 */
object CinemaColors {
    val Background = Color(0xFF090A10)
    val Surface = Color(0xFF141622)
    val SurfaceElevated = Color(0xFF1F2235)
    val Brand = Color(0xFFE50914)
    val BrandPressed = Color(0xFFB81D24)
    val Accent = Color(0xFFFF8C00)
    val TextPrimary = Color(0xFFF5F5F7)
    val TextSecondary = Color(0xFF9E9EAF)
    val Separator = Color(0xFF2B2D3D)
    val PosterPlaceholder = Color(0xFF202230)
    val Success = Color(0xFF34C759)
    val Black = Color(0xFF000000)
}

object CinemaSpacing {
    val hairline: Dp = 1.dp
    val x1: Dp = 4.dp
    val x2: Dp = 8.dp
    val x3: Dp = 12.dp
    val x4: Dp = 16.dp
    val x5: Dp = 20.dp
    val x6: Dp = 24.dp
    val x8: Dp = 32.dp
    val screenHorizontal: Dp = 16.dp
}

object CinemaShape {
    val small: Dp = 8.dp
    val medium: Dp = 12.dp
    val large: Dp = 18.dp
    val poster: Dp = 10.dp
}

private val CinemacoreScheme = darkColorScheme(
    primary = CinemaColors.Brand,
    onPrimary = CinemaColors.TextPrimary,
    primaryContainer = CinemaColors.BrandPressed,
    onPrimaryContainer = CinemaColors.TextPrimary,
    secondary = CinemaColors.Accent,
    onSecondary = CinemaColors.Background,
    tertiary = CinemaColors.TextSecondary,
    background = CinemaColors.Background,
    onBackground = CinemaColors.TextPrimary,
    surface = CinemaColors.Surface,
    onSurface = CinemaColors.TextPrimary,
    surfaceVariant = CinemaColors.SurfaceElevated,
    onSurfaceVariant = CinemaColors.TextSecondary,
    surfaceContainer = CinemaColors.Surface,
    surfaceContainerHigh = CinemaColors.SurfaceElevated,
    surfaceContainerHighest = CinemaColors.SurfaceElevated,
    outline = CinemaColors.Separator,
    outlineVariant = CinemaColors.Separator,
    error = CinemaColors.Brand,
    onError = CinemaColors.TextPrimary,
)

private val CinemacoreTypography = Typography(
    displayLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Black,
        fontSize = 48.sp,
        letterSpacing = 6.sp,
    ),
    headlineLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Bold,
        fontSize = 32.sp,
        lineHeight = 38.sp,
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Bold,
        fontSize = 26.sp,
        lineHeight = 32.sp,
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 17.sp,
        lineHeight = 23.sp,
    ),
    titleSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 15.sp,
        lineHeight = 20.sp,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        lineHeight = 20.sp,
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Bold,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 0.4.sp,
    ),
)

@Composable
fun CinemacoreTheme(content: @Composable () -> Unit) {
    // The design has no light variant. Reading the system setting keeps the
    // call site honest if that ever changes without silently switching now.
    isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = CinemacoreScheme,
        typography = CinemacoreTypography,
        content = content,
    )
}
