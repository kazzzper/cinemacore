package com.cinemacore.app.ui.docs

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.cinemacore.app.R
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.launch

private enum class GatePreview(val title: Int, val detail: Int) {
    LOCKOUT(R.string.lab_gate_lockout, R.string.lab_gate_lockout_detail),
    FORCE_UPDATE(R.string.lab_gate_force_update, R.string.lab_gate_force_update_detail),
    OPTIONAL_UPDATE(R.string.lab_gate_optional_update, R.string.lab_gate_optional_update_detail),
    COMMUNITY(R.string.lab_gate_community, R.string.lab_gate_community_detail),
}

/**
 * Support surface: what the app actually resolved, and local previews of the
 * dialogs that a gateway can otherwise force on the user.
 */
@Composable
fun LabScreen(
    app: CinemacoreViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val communityUrl = stringResource(R.string.lab_community_url)
    var probing by remember { mutableStateOf(true) }
    var previewName by rememberSaveable { mutableStateOf<String?>(null) }
    var linkFailed by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        try {
            app.probeGatewayVersion()
        } finally {
            probing = false
        }
    }

    val probeGateway: () -> Unit = {
        if (!probing) {
            scope.launch {
                probing = true
                try {
                    app.probeGatewayVersion()
                } finally {
                    probing = false
                }
            }
        }
    }

    val modeLabel = stringResource(
        if (app.isLive) R.string.settings_source_live else R.string.settings_source_demo,
    )
    val versionLabel = when {
        probing -> stringResource(R.string.lab_version_probing)
        else -> app.gatewayVersion ?: stringResource(R.string.lab_version_unreachable)
    }
    val previewGate = previewName?.let { name ->
        GatePreview.entries.firstOrNull { it.name == name }
    }

    Column(modifier = modifier.fillMaxSize()) {
        NestedScreenHeader(
            title = stringResource(R.string.lab_title),
            onBack = onBack,
        )
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(
                    start = CinemaSpacing.screenHorizontal,
                    end = CinemaSpacing.screenHorizontal,
                    top = CinemaSpacing.x2,
                    bottom = CinemaSpacing.x8,
                ),
        ) {
            Text(
                text = stringResource(R.string.lab_subtitle),
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
            )
            Spacer(Modifier.height(CinemaSpacing.x5))

            LabSectionTitle(stringResource(R.string.lab_section_catalog))
            LabCard {
                LabInfoRow(
                    label = stringResource(R.string.lab_row_source),
                    value = app.sourceNote,
                )
                LabDivider()
                LabInfoRow(
                    label = stringResource(R.string.lab_row_mode),
                    value = modeLabel,
                )
                LabDivider()
                LabInfoRow(
                    label = stringResource(R.string.lab_row_gateway),
                    value = app.settings.effectiveGatewayUrl,
                )
                LabDivider()
                LabInfoRow(
                    label = stringResource(R.string.lab_row_gateway_version),
                    value = versionLabel,
                )
            }
            Spacer(Modifier.height(CinemaSpacing.x3))
            OutlinedButton(onClick = probeGateway, enabled = !probing) {
                Text(stringResource(R.string.lab_probe))
            }

            Spacer(Modifier.height(CinemaSpacing.x6))
            LabSectionTitle(stringResource(R.string.lab_section_gates))
            LabCard {
                GatePreview.entries.forEachIndexed { index, gate ->
                    PreviewRow(
                        title = stringResource(gate.title),
                        detail = stringResource(gate.detail),
                        onClick = { previewName = gate.name },
                    )
                    if (index != GatePreview.entries.lastIndex) {
                        LabDivider()
                    }
                }
            }
            Spacer(Modifier.height(CinemaSpacing.x2))
            Text(
                text = stringResource(R.string.lab_gates_footer),
                style = MaterialTheme.typography.labelMedium,
                color = CinemaColors.TextSecondary,
                modifier = Modifier.padding(horizontal = CinemaSpacing.x1),
            )
        }
    }

    previewGate?.let { gate ->
        when (gate) {
            GatePreview.LOCKOUT -> GateAlert(
                title = stringResource(R.string.gate_lockout_title),
                body = stringResource(R.string.gate_lockout_body),
                confirmLabel = stringResource(R.string.lab_close_preview),
                onConfirm = { previewName = null },
            )
            GatePreview.FORCE_UPDATE -> GateAlert(
                title = stringResource(R.string.gate_force_title),
                body = stringResource(R.string.gate_force_body),
                confirmLabel = stringResource(R.string.lab_close_preview),
                onConfirm = { previewName = null },
            )
            GatePreview.OPTIONAL_UPDATE -> GateAlert(
                title = stringResource(R.string.gate_optional_title),
                body = stringResource(R.string.gate_optional_body),
                notes = stringResource(R.string.gate_optional_notes),
                confirmLabel = stringResource(R.string.lab_close_preview),
                onConfirm = { previewName = null },
                dismissLabel = stringResource(R.string.lab_not_now),
                onDismiss = { previewName = null },
            )
            GatePreview.COMMUNITY -> GateAlert(
                title = stringResource(R.string.gate_community_title),
                body = stringResource(R.string.gate_community_body),
                confirmLabel = stringResource(R.string.lab_join_telegram),
                onConfirm = {
                    previewName = null
                    val opened = runCatching { uriHandler.openUri(communityUrl) }.isSuccess
                    if (!opened) linkFailed = true
                },
                dismissLabel = stringResource(R.string.lab_maybe_later),
                onDismiss = { previewName = null },
            )
        }
    }

    if (linkFailed) {
        AlertDialog(
            onDismissRequest = { linkFailed = false },
            title = { Text(stringResource(R.string.lab_link_unavailable_title)) },
            text = { Text(stringResource(R.string.lab_link_unavailable_body)) },
            confirmButton = {
                TextButton(onClick = { linkFailed = false }) {
                    Text(stringResource(R.string.lab_close_preview))
                }
            },
            containerColor = CinemaColors.SurfaceElevated,
            titleContentColor = CinemaColors.TextPrimary,
            textContentColor = CinemaColors.TextSecondary,
        )
    }
}

@Composable
private fun LabSectionTitle(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        color = CinemaColors.TextSecondary,
        modifier = Modifier.padding(
            start = CinemaSpacing.x1,
            bottom = CinemaSpacing.x2,
        ),
    )
}

@Composable
private fun LabCard(content: @Composable () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = CinemaColors.Surface,
        shape = RoundedCornerShape(CinemaShape.large),
    ) {
        Column { content() }
    }
}

@Composable
private fun LabInfoRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.x4, vertical = CinemaSpacing.x3),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = CinemaColors.TextSecondary,
            modifier = Modifier.width(124.dp),
        )
        Spacer(Modifier.width(CinemaSpacing.x2))
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = CinemaColors.TextPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun PreviewRow(title: String, detail: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(CinemaSpacing.x4),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                color = CinemaColors.TextPrimary,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = detail,
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
            )
        }
        Spacer(Modifier.width(CinemaSpacing.x2))
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = CinemaColors.TextSecondary,
        )
    }
}

@Composable
private fun LabDivider() {
    HorizontalDivider(
        thickness = CinemaSpacing.hairline,
        color = CinemaColors.Separator,
    )
}

@Composable
private fun GateAlert(
    title: String,
    body: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    notes: String? = null,
    dismissLabel: String? = null,
    onDismiss: (() -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = { onDismiss?.invoke() ?: onConfirm() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x2)) {
                Text(body)
                if (notes != null) {
                    Text(
                        text = notes,
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextPrimary,
                    )
                }
                Text(
                    text = stringResource(R.string.gate_preview_note),
                    style = MaterialTheme.typography.labelMedium,
                    color = CinemaColors.TextSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(confirmLabel)
            }
        },
        dismissButton = if (dismissLabel != null) {
            {
                TextButton(onClick = { onDismiss?.invoke() ?: onConfirm() }) {
                    Text(dismissLabel.orEmpty())
                }
            }
        } else {
            null
        },
        containerColor = CinemaColors.SurfaceElevated,
        titleContentColor = CinemaColors.TextPrimary,
        textContentColor = CinemaColors.TextSecondary,
    )
}
