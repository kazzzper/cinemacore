package com.cinemacore.app.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.cinemacore.app.BuildConfig
import com.cinemacore.app.R
import com.cinemacore.app.domain.SourceMode
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.SectionTitle
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private val PlaybackSpeeds = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)

/**
 * Source picker, gateway/TMDB setup, playback preferences and the entry points
 * for the library, docs and lab. Every mutation is a suspend call owned by the
 * screen's scope, so nothing blocks composition or the main thread.
 */
@Composable
fun SettingsScreen(
    app: CinemacoreViewModel,
    onOpenHistory: () -> Unit,
    onOpenManage: () -> Unit,
    onOpenDocs: () -> Unit,
    onOpenLab: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var actionFailed by remember { mutableStateOf(false) }
    var switchingSource by remember { mutableStateOf(false) }
    var applyingGateway by remember { mutableStateOf(false) }
    var savingKey by remember { mutableStateOf(false) }
    var gatewayDraft by rememberSaveable { mutableStateOf(app.settings.gatewayUrl) }
    var tmdbDraft by rememberSaveable { mutableStateOf(app.settings.tmdbKey) }
    var tmdbVisible by rememberSaveable { mutableStateOf(false) }

    fun launchAction(action: suspend () -> Unit) {
        actionFailed = false
        scope.launch {
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                actionFailed = true
            }
        }
    }

    val selectSource: (SourceMode) -> Unit = { mode ->
        if (!switchingSource && app.settings.sourceMode != mode) {
            switchingSource = true
            launchAction {
                try {
                    app.setSourceMode(mode)
                } finally {
                    switchingSource = false
                }
            }
        }
    }

    val applyGateway: () -> Unit = {
        if (!applyingGateway) {
            applyingGateway = true
            launchAction {
                try {
                    app.setGatewayUrl(gatewayDraft)
                    gatewayDraft = gatewayDraft.trim()
                } finally {
                    applyingGateway = false
                }
            }
        }
    }

    val saveTmdbKey: () -> Unit = {
        if (!savingKey) {
            savingKey = true
            launchAction {
                try {
                    app.setTmdbKey(tmdbDraft)
                    tmdbDraft = tmdbDraft.trim()
                } finally {
                    savingKey = false
                }
            }
        }
    }

    val clearTmdbKey: () -> Unit = {
        if (!savingKey) {
            savingKey = true
            launchAction {
                try {
                    app.setTmdbKey("")
                    tmdbDraft = ""
                } finally {
                    savingKey = false
                }
            }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = CinemaSpacing.x8),
    ) {
        SectionTitle(
            text = stringResource(R.string.settings_title),
            modifier = Modifier.padding(
                start = CinemaSpacing.screenHorizontal,
                end = CinemaSpacing.screenHorizontal,
                top = CinemaSpacing.x4,
                bottom = CinemaSpacing.x3,
            ),
        )

        if (actionFailed) {
            Text(
                text = stringResource(R.string.settings_action_failed),
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.Brand,
                modifier = Modifier.padding(
                    start = CinemaSpacing.screenHorizontal,
                    end = CinemaSpacing.screenHorizontal,
                    bottom = CinemaSpacing.x2,
                ),
            )
        }

        SettingsSection(stringResource(R.string.settings_section_source)) {
            SettingsCard {
                Column(Modifier.selectableGroup()) {
                    SourceMode.entries.forEachIndexed { index, mode ->
                        SourceOptionRow(
                            title = sourceTitle(mode),
                            detail = sourceDetail(mode),
                            selected = app.settings.sourceMode == mode,
                            enabled = !switchingSource,
                            onSelect = { selectSource(mode) },
                        )
                        if (index != SourceMode.entries.lastIndex) {
                            CardDivider()
                        }
                    }
                }
                CardDivider()
                SourceStatus(
                    note = app.sourceNote,
                    live = app.isLive,
                    demoSelected = app.settings.sourceMode == SourceMode.DEMO,
                    busy = switchingSource,
                )
            }
            Spacer(Modifier.height(CinemaSpacing.x2))
            Text(
                text = sourceFooter(app.settings.sourceMode),
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
                modifier = Modifier.padding(horizontal = CinemaSpacing.x1),
            )
        }

        if (app.settings.sourceMode == SourceMode.GATEWAY) {
            SettingsSection(stringResource(R.string.settings_gateway_section)) {
                SettingsCard {
                    Column(
                        modifier = Modifier.padding(CinemaSpacing.x4),
                        verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
                    ) {
                        OutlinedTextField(
                            value = gatewayDraft,
                            onValueChange = { gatewayDraft = it },
                            label = { Text(stringResource(R.string.settings_gateway_label)) },
                            placeholder = {
                                Text(stringResource(R.string.settings_gateway_placeholder))
                            },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(
                                keyboardType = KeyboardType.Uri,
                                imeAction = ImeAction.Done,
                            ),
                            keyboardActions = KeyboardActions(onDone = { applyGateway() }),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(
                            text = stringResource(R.string.settings_gateway_help),
                            style = MaterialTheme.typography.labelMedium,
                            color = CinemaColors.TextSecondary,
                        )
                        Button(
                            onClick = applyGateway,
                            enabled = !applyingGateway &&
                                gatewayDraft.trim() != app.settings.gatewayUrl,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                stringResource(
                                    if (applyingGateway) {
                                        R.string.settings_gateway_applying
                                    } else {
                                        R.string.settings_gateway_apply
                                    },
                                ),
                            )
                        }
                    }
                }
            }
        }

        SettingsSection(stringResource(R.string.settings_tmdb_section)) {
            SettingsCard {
                Column(
                    modifier = Modifier.padding(CinemaSpacing.x4),
                    verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x3),
                ) {
                    OutlinedTextField(
                        value = tmdbDraft,
                        onValueChange = { tmdbDraft = it },
                        label = { Text(stringResource(R.string.settings_tmdb_label)) },
                        singleLine = true,
                        visualTransformation = if (tmdbVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            imeAction = ImeAction.Done,
                        ),
                        keyboardActions = KeyboardActions(onDone = { saveTmdbKey() }),
                        trailingIcon = {
                            TextButton(onClick = { tmdbVisible = !tmdbVisible }) {
                                Text(
                                    stringResource(
                                        if (tmdbVisible) {
                                            R.string.settings_tmdb_hide
                                        } else {
                                            R.string.settings_tmdb_show
                                        },
                                    ),
                                )
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        text = stringResource(R.string.settings_tmdb_help),
                        style = MaterialTheme.typography.labelMedium,
                        color = CinemaColors.TextSecondary,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2)) {
                        Button(
                            onClick = saveTmdbKey,
                            enabled = !savingKey && tmdbDraft.trim() != app.settings.tmdbKey,
                        ) {
                            Text(
                                stringResource(
                                    if (savingKey) {
                                        R.string.settings_tmdb_saving
                                    } else {
                                        R.string.settings_tmdb_save
                                    },
                                ),
                            )
                        }
                        if (app.settings.tmdbKey.isNotEmpty()) {
                            TextButton(onClick = clearTmdbKey, enabled = !savingKey) {
                                Text(stringResource(R.string.settings_tmdb_clear))
                            }
                        }
                    }
                }
            }
        }

        SettingsSection(stringResource(R.string.settings_section_playback)) {
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .toggleable(
                            value = app.settings.autoPlayNext,
                            role = Role.Switch,
                            onValueChange = { enabled ->
                                launchAction { app.setAutoPlayNext(enabled) }
                            },
                        )
                        .padding(CinemaSpacing.x4),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            text = stringResource(R.string.settings_autoplay),
                            style = MaterialTheme.typography.titleSmall,
                            color = CinemaColors.TextPrimary,
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = stringResource(R.string.settings_autoplay_detail),
                            style = MaterialTheme.typography.bodyMedium,
                            color = CinemaColors.TextSecondary,
                        )
                    }
                    Spacer(Modifier.width(CinemaSpacing.x3))
                    Switch(
                        checked = app.settings.autoPlayNext,
                        onCheckedChange = null,
                    )
                }
                CardDivider()
                Column(Modifier.padding(CinemaSpacing.x4)) {
                    Text(
                        text = stringResource(R.string.settings_speed),
                        style = MaterialTheme.typography.titleSmall,
                        color = CinemaColors.TextPrimary,
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = stringResource(R.string.settings_speed_detail),
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                    )
                    Spacer(Modifier.height(CinemaSpacing.x3))
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .selectableGroup(),
                        horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
                    ) {
                        PlaybackSpeeds.forEach { speed ->
                            SpeedPill(
                                label = speedLabel(speed),
                                selected = app.settings.playbackSpeed == speed,
                                onClick = {
                                    launchAction { app.setPlaybackSpeed(speed) }
                                },
                            )
                        }
                    }
                }
            }
        }

        SettingsSection(stringResource(R.string.settings_section_library)) {
            SettingsCard {
                NavigationRow(
                    title = stringResource(R.string.settings_library_history),
                    detail = stringResource(R.string.settings_library_history_detail),
                    onClick = onOpenHistory,
                )
                CardDivider()
                NavigationRow(
                    title = stringResource(R.string.settings_library_manage),
                    detail = stringResource(R.string.settings_library_manage_detail),
                    onClick = onOpenManage,
                )
            }
        }

        SettingsSection(stringResource(R.string.settings_section_about)) {
            SettingsCard {
                NavigationRow(
                    title = stringResource(R.string.settings_about_docs),
                    detail = stringResource(R.string.settings_about_docs_detail),
                    onClick = onOpenDocs,
                )
                CardDivider()
                NavigationRow(
                    title = stringResource(R.string.settings_about_lab),
                    detail = stringResource(R.string.settings_about_lab_detail),
                    onClick = onOpenLab,
                )
                CardDivider()
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(CinemaSpacing.x4),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = stringResource(R.string.settings_about_version),
                        style = MaterialTheme.typography.titleSmall,
                        color = CinemaColors.TextPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = BuildConfig.VERSION_NAME,
                        style = MaterialTheme.typography.bodyMedium,
                        color = CinemaColors.TextSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = CinemaSpacing.screenHorizontal),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelMedium,
            color = CinemaColors.TextSecondary,
            modifier = Modifier.padding(
                start = CinemaSpacing.x1,
                bottom = CinemaSpacing.x2,
            ),
        )
        content()
        Spacer(Modifier.height(CinemaSpacing.x5))
    }
}

@Composable
private fun SettingsCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = CinemaColors.Surface,
        shape = RoundedCornerShape(CinemaShape.large),
    ) {
        Column(content = content)
    }
}

@Composable
private fun SourceOptionRow(
    title: String,
    detail: String,
    selected: Boolean,
    enabled: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(
                selected = selected,
                enabled = enabled,
                role = Role.RadioButton,
                onClick = onSelect,
            )
            .padding(horizontal = CinemaSpacing.x4, vertical = CinemaSpacing.x3),
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
        Spacer(Modifier.width(CinemaSpacing.x3))
        RadioButton(selected = selected, onClick = null, enabled = enabled)
    }
}

@Composable
private fun SourceStatus(note: String, live: Boolean, demoSelected: Boolean, busy: Boolean) {
    val label = stringResource(
        when {
            live -> R.string.settings_source_live
            demoSelected -> R.string.settings_source_demo
            else -> R.string.settings_source_fallback
        },
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(CinemaSpacing.x4),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(if (live) CinemaColors.Success else CinemaColors.Accent),
        )
        Spacer(Modifier.width(CinemaSpacing.x2))
        Column(Modifier.weight(1f)) {
            Text(
                text = note,
                style = MaterialTheme.typography.titleSmall,
                color = CinemaColors.TextPrimary,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = CinemaColors.TextSecondary,
            )
        }
        if (busy) {
            Spacer(Modifier.width(CinemaSpacing.x2))
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                color = CinemaColors.Brand,
                strokeWidth = 2.dp,
            )
        }
    }
}

@Composable
private fun NavigationRow(title: String, detail: String, onClick: () -> Unit) {
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
private fun SpeedPill(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(CircleShape)
            .background(
                if (selected) CinemaColors.TextPrimary else CinemaColors.SurfaceElevated,
            )
            .selectable(
                selected = selected,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .padding(horizontal = CinemaSpacing.x4),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) CinemaColors.Background else CinemaColors.TextPrimary,
        )
    }
}

@Composable
private fun CardDivider() {
    HorizontalDivider(
        thickness = CinemaSpacing.hairline,
        color = CinemaColors.Separator,
    )
}

@Composable
private fun sourceTitle(mode: SourceMode): String = stringResource(
    when (mode) {
        SourceMode.BUILT_IN -> R.string.settings_source_builtin
        SourceMode.STREAM_HYPE -> R.string.settings_source_streamhype
        SourceMode.GATEWAY -> R.string.settings_source_gateway
        SourceMode.DEMO -> R.string.settings_source_demo
    },
)

@Composable
private fun sourceDetail(mode: SourceMode): String = stringResource(
    when (mode) {
        SourceMode.BUILT_IN -> R.string.settings_source_builtin_detail
        SourceMode.STREAM_HYPE -> R.string.settings_source_streamhype_detail
        SourceMode.GATEWAY -> R.string.settings_source_gateway_detail
        SourceMode.DEMO -> R.string.settings_source_demo_detail
    },
)

@Composable
private fun sourceFooter(mode: SourceMode): String = stringResource(
    when (mode) {
        SourceMode.BUILT_IN -> R.string.settings_source_footer_builtin
        SourceMode.STREAM_HYPE -> R.string.settings_source_footer_streamhype
        SourceMode.GATEWAY -> R.string.settings_source_footer_gateway
        SourceMode.DEMO -> R.string.settings_source_footer_demo
    },
)

@Composable
private fun speedLabel(speed: Float): String = stringResource(
    when (speed) {
        0.5f -> R.string.settings_speed_half
        0.75f -> R.string.settings_speed_three_quarters
        1f -> R.string.settings_speed_normal
        1.25f -> R.string.settings_speed_five_quarters
        1.5f -> R.string.settings_speed_one_and_half
        else -> R.string.settings_speed_double
    },
)
