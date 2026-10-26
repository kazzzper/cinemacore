package com.cinemacore.app.domain

/**
 * The catalog boundary every screen talks to.
 *
 * Implementations: the gateway, direct StreamHype/TMDB, and the bundled demo
 * catalog. Screen code does not know which one it has.
 */
interface CatalogRepository {
    val sourceName: String
    val isLive: Boolean

    suspend fun home(): Page
    suspend fun search(query: String): List<Subject>
    suspend fun detail(id: String): Subject
    suspend fun seasons(subjectId: String): List<Season>
    suspend fun play(subjectId: String, season: Int?, episode: Int?): PlayInfo
    suspend fun suggestions(query: String): List<String>
}
