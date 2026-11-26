package com.cinemacore.app.ui.settings

import android.content.ClipData
import android.content.ClipboardManager
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.data.Feature
import com.cinemacore.app.data.FeatureCategory
import com.cinemacore.app.data.FeatureReport
import com.cinemacore.app.data.FeatureSnapshot
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.launch

/**
 * Which features exist, whether they are on, and what they have actually done.
 *
 * The whole report is local: it exists so a dead feature is visible without a
 * third-party SDK, and the copy button is the only way it leaves the device —
 * deliberately, by hand.
 */
@Composable
fun FeatureTrackingScreen(
    app: CinemacoreViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var snapshot by remember { mutableStateOf<FeatureSnapshot?>(null) }
    var report by remember { mutableStateOf("") }
    var copied by remember { mutableStateOf(false) }
    var confirmsReset by remember { mutableStateOf(false) }

    suspend fun reload() {
        val next = app.features.snapshot()
        snapshot = next
        report = FeatureReport(next).text()
        copied = false
    }

    LaunchedEffect(Unit) { reload() }

    Column(modifier = modifier.fillMaxSize().background(CinemaColors.Background)) {
        FeatureTrackingHeader(onBack = onBack)
        val current = snapshot
        if (current == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    text = stringResource(R.string.feature_tracking_loading),
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
        } else {
            FeatureTrackingList(
                snapshot = current,
                onToggle = { feature, enabled ->
                    scope.launch {
                        app.features.setEnabled(feature, enabled)
                        // The shell reads the same flags; refresh it so the tab
                        // or entry point appears or goes without a relaunch.
                        app.reloadFeatures()
                        reload()
                    }
                },
                onCopy = {
                    val clipboard = context.getSystemService(ClipboardManager::class.java)
                    clipboard?.setPrimaryClip(
                        ClipData.newPlainText(
                            context.getString(R.string.feature_tracking_title),
                            report,
                        ),
                    )
                    copied = true
                },
                copied = copied,
                onReset = { confirmsReset = true },
            )
        }
    }

    if (confirmsReset) {
        AlertDialog(
            onDismissRequest = { confirmsReset = false },
            title = { Text(stringResource(R.string.feature_tracking_reset_title)) },
            text = { Text(stringResource(R.string.feature_tracking_reset_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmsReset = false
                        scope.launch {
                            app.features.reset()
                            reload()
                        }
                    },
                ) {
                    Text(stringResource(R.string.feature_tracking_reset))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmsReset = false }) {
                    Text(stringResource(R.string.feature_tracking_cancel))
                }
            },
        )
    }
}

@Composable
private fun FeatureTrackingHeader(onBack: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.x2, vertical = CinemaSpacing.x1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.feature_tracking_back),
            )
        }
        Text(
            text = stringResource(R.string.feature_tracking_title),
            style = MaterialTheme.typography.titleLarge,
            color = CinemaColors.TextPrimary,
            modifier = Modifier.padding(start = CinemaSpacing.x1),
        )
    }
}

@Composable
private fun FeatureTrackingList(
    snapshot: FeatureSnapshot,
    onToggle: (Feature, Boolean) -> Unit,
    onCopy: () -> Unit,
    copied: Boolean,
    onReset: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = CinemaSpacing.screenHorizontal,
            end = CinemaSpacing.screenHorizontal,
            top = CinemaSpacing.x2,
            bottom = CinemaSpacing.x6,
        ),
    ) {
        item { SummaryCard(snapshot) }
        for (category in FeatureCategory.entries) {
            val rows = snapshot.entries.filter { it.feature.category == category }
            if (rows.isEmpty()) continue
            item(key = category.name) {
                Text(
                    text = category.displayName.uppercase(),
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextSecondary,
                    modifier = Modifier.padding(
                        start = CinemaSpacing.x1,
                        top = CinemaSpacing.x4,
                        bottom = CinemaSpacing.x2,
                    ),
                )
            }
            items(rows, key = { it.id }) { entry ->
                FeatureRow(entry = entry, onToggle = { onToggle(entry.feature, it) })
            }
        }
        item {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = CinemaSpacing.x4),
                horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
            ) {
                TextButton(onClick = onCopy) {
                    Text(
                        stringResource(
                            if (copied) {
                                R.string.feature_tracking_copied
                            } else {
                                R.string.feature_tracking_copy
                            },
                        ),
                    )
                }
                TextButton(onClick = onReset) {
                    Text(stringResource(R.string.feature_tracking_reset))
                }
            }
        }
    }
}

@Composable
private fun SummaryCard(snapshot: FeatureSnapshot) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = CinemaColors.Surface,
        shape = RoundedCornerShape(CinemaShape.large),
    ) {
        Column(Modifier.padding(CinemaSpacing.x4)) {
            Row(Modifier.fillMaxWidth()) {
                Text(
                    text = stringResource(R.string.feature_tracking_summary_enabled),
                    style = MaterialTheme.typography.titleSmall,
                    color = CinemaColors.TextPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = stringResource(
                        R.string.feature_tracking_enabled_value,
                        snapshot.enabledCount,
                        snapshot.entries.size,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
            Spacer(Modifier.height(CinemaSpacing.x1))
            Row(Modifier.fillMaxWidth()) {
                Text(
                    text = stringResource(R.string.feature_tracking_summary_unused),
                    style = MaterialTheme.typography.titleSmall,
                    color = CinemaColors.TextPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = snapshot.unusedCount.toString(),
                    style = MaterialTheme.typography.bodyMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
            Spacer(Modifier.height(CinemaSpacing.x2))
            Text(
                text = stringResource(R.string.feature_tracking_footer),
                style = MaterialTheme.typography.bodySmall,
                color = CinemaColors.TextSecondary,
            )
        }
    }
}

@Composable
private fun FeatureRow(
    entry: FeatureSnapshot.Entry,
    onToggle: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.x1, vertical = CinemaSpacing.x1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                text = entry.feature.displayName,
                style = MaterialTheme.typography.bodyLarge,
                color = CinemaColors.TextPrimary,
            )
            Text(
                text = stringResource(
                    R.string.feature_tracking_usage,
                    entry.usage.useCount,
                    entry.usage.failureCount,
                ),
                style = MaterialTheme.typography.bodySmall,
                color = CinemaColors.TextSecondary,
            )
        }
        Switch(checked = entry.isEnabled, onCheckedChange = onToggle)
    }
}
