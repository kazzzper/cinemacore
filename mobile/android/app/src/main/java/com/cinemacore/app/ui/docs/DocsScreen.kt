package com.cinemacore.app.ui.docs

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
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.cinemacore.app.R
import com.cinemacore.app.ui.components.SectionTitle
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing

private data class DocSectionSpec(val heading: Int, val body: Int)

private data class DocChapterSpec(val title: Int, val sections: List<DocSectionSpec>)

private val DocChapters = listOf(
    DocChapterSpec(
        title = R.string.docs_chapter_start_title,
        sections = listOf(
            DocSectionSpec(
                heading = R.string.docs_start_browse_heading,
                body = R.string.docs_start_browse_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_start_resume_heading,
                body = R.string.docs_start_resume_body,
            ),
        ),
    ),
    DocChapterSpec(
        title = R.string.docs_chapter_live_title,
        sections = listOf(
            DocSectionSpec(
                heading = R.string.docs_live_active_heading,
                body = R.string.docs_live_active_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_live_connect_heading,
                body = R.string.docs_live_connect_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_live_troubleshoot_heading,
                body = R.string.docs_live_troubleshoot_body,
            ),
        ),
    ),
    DocChapterSpec(
        title = R.string.docs_chapter_playback_title,
        sections = listOf(
            DocSectionSpec(
                heading = R.string.docs_playback_quality_heading,
                body = R.string.docs_playback_quality_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_playback_subtitles_heading,
                body = R.string.docs_playback_subtitles_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_playback_media3_heading,
                body = R.string.docs_playback_media3_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_playback_downloads_heading,
                body = R.string.docs_playback_downloads_body,
            ),
        ),
    ),
    DocChapterSpec(
        title = R.string.docs_chapter_privacy_title,
        sections = listOf(
            DocSectionSpec(
                heading = R.string.docs_privacy_stored_heading,
                body = R.string.docs_privacy_stored_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_privacy_keys_heading,
                body = R.string.docs_privacy_keys_body,
            ),
            DocSectionSpec(
                heading = R.string.docs_privacy_clear_heading,
                body = R.string.docs_privacy_clear_body,
            ),
        ),
    ),
)

/** In-app documentation written for the Android player and data layer. */
@Composable
fun DocsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxSize()) {
        NestedScreenHeader(
            title = stringResource(R.string.docs_title),
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
                text = stringResource(R.string.docs_subtitle),
                style = MaterialTheme.typography.bodyMedium,
                color = CinemaColors.TextSecondary,
            )

            DocChapters.forEachIndexed { chapterIndex, chapter ->
                Spacer(
                    Modifier.height(
                        if (chapterIndex == 0) CinemaSpacing.x5 else CinemaSpacing.x6,
                    ),
                )
                Text(
                    text = stringResource(chapter.title),
                    style = MaterialTheme.typography.titleLarge,
                    color = CinemaColors.TextPrimary,
                )
                Spacer(Modifier.height(CinemaSpacing.x2))
                chapter.sections.forEachIndexed { sectionIndex, section ->
                    if (sectionIndex > 0) {
                        Spacer(Modifier.height(CinemaSpacing.x2))
                    }
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        color = CinemaColors.Surface,
                        shape = RoundedCornerShape(CinemaShape.medium),
                    ) {
                        Column(
                            modifier = Modifier.padding(CinemaSpacing.x4),
                            verticalArrangement = Arrangement.spacedBy(CinemaSpacing.x1),
                        ) {
                            Text(
                                text = stringResource(section.heading),
                                style = MaterialTheme.typography.titleSmall,
                                color = CinemaColors.TextPrimary,
                            )
                            Text(
                                text = stringResource(section.body),
                                style = MaterialTheme.typography.bodyMedium,
                                color = CinemaColors.TextSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Back row shared by the nested help screens. */
@Composable
internal fun NestedScreenHeader(title: String, onBack: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = CinemaSpacing.screenHorizontal,
                vertical = CinemaSpacing.x2,
            ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.action_back),
                tint = CinemaColors.TextPrimary,
            )
        }
        Spacer(Modifier.width(CinemaSpacing.x1))
        SectionTitle(title)
    }
}
