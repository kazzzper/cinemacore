package com.cinemacore.app.data

import com.cinemacore.app.data.api.models.CastMember
import com.cinemacore.app.data.api.models.Dub
import com.cinemacore.app.data.api.models.Episode
import com.cinemacore.app.data.api.models.Page
import com.cinemacore.app.data.api.models.PlayInfo
import com.cinemacore.app.data.api.models.ResourceDetector
import com.cinemacore.app.data.api.models.Season
import com.cinemacore.app.data.api.models.StreamRendition
import com.cinemacore.app.data.api.models.Subject
import com.cinemacore.app.data.api.models.SubtitleTrack
import com.cinemacore.app.domain.MediaContainer
import com.cinemacore.app.domain.StreamKind

/**
 * Boundary between the generated wire models and the domain.
 *
 * The generated package is allowed to change when the contract changes; screens
 * are not. Keep every mapping explicit so a renamed wire field fails here, in
 * one place, instead of quietly turning into a blank UI.
 */
object ApiMappers {
    fun subject(value: Subject): com.cinemacore.app.domain.Subject =
        com.cinemacore.app.domain.Subject(
            id = value.id,
            title = value.title,
            poster = value.poster,
            year = value.year,
            rating = value.rating,
            kind = value.kind,
            synopsis = value.synopsis,
            genres = value.genres.orEmpty(),
            dubs = value.dubs.orEmpty(),
            dubOptions = value.dubOptions.orEmpty().map(::dub),
            durationMinutes = value.durationMinutes,
            seasonCount = value.seasonCount ?: 1,
            cast = value.cast.orEmpty().map(::cast),
            resourceDetectors = value.resourceDetectors.orEmpty().map(::resourceDetector),
        )

    fun page(value: Page): com.cinemacore.app.domain.Page =
        com.cinemacore.app.domain.Page(
            sections = value.sections.map { section ->
                com.cinemacore.app.domain.Section(
                    title = section.title,
                    items = section.items.map(::subject),
                )
            },
        )

    fun seasons(values: List<Season>): List<com.cinemacore.app.domain.Season> =
        values.map { season ->
            com.cinemacore.app.domain.Season(
                number = season.number,
                episodes = season.episodes.map(::episode),
            )
        }

    fun episode(value: Episode): com.cinemacore.app.domain.Episode =
        com.cinemacore.app.domain.Episode(
            subjectId = value.subjectId,
            season = value.season,
            number = value.number,
            title = value.title,
            durationSeconds = value.durationSeconds,
        )

    fun playInfo(value: PlayInfo): com.cinemacore.app.domain.PlayInfo =
        com.cinemacore.app.domain.PlayInfo(
            streams = value.streams.map(::rendition),
            subtitles = value.subtitles.map(::subtitle),
        )

    fun rendition(value: StreamRendition): com.cinemacore.app.domain.StreamRendition =
        com.cinemacore.app.domain.StreamRendition(
            quality = value.quality,
            url = value.url,
            size = value.propertySize,
            cookie = value.cookie,
            kind = if (value.kind == StreamRendition.Kind.WEB) {
                StreamKind.WEB
            } else {
                StreamKind.DIRECT
            },
        )

    fun subtitle(value: SubtitleTrack): com.cinemacore.app.domain.SubtitleTrack =
        com.cinemacore.app.domain.SubtitleTrack(
            language = value.language,
            url = value.url,
            format = value.format,
        )

    private fun dub(value: Dub): com.cinemacore.app.domain.Dub =
        com.cinemacore.app.domain.Dub(
            subjectId = value.subjectId,
            languageName = value.languageName,
            languageCode = value.languageCode,
            isOriginal = value.isOriginal == true,
        )

    private fun cast(value: CastMember): com.cinemacore.app.domain.CastMember =
        com.cinemacore.app.domain.CastMember(
            name = value.name,
            role = value.role,
            avatar = value.avatar,
        )

    private fun resourceDetector(value: ResourceDetector): com.cinemacore.app.domain.ResourceDetector =
        com.cinemacore.app.domain.ResourceDetector(
            resourceId = value.resourceId,
            name = value.name,
        )
}

/** Convenience for a download suffix; the URL wins over a provider label. */
fun MediaContainer.forDownload(): MediaContainer = this
