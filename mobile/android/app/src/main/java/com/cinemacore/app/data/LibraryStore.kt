package com.cinemacore.app.data

import com.cinemacore.app.domain.LibraryData
import com.cinemacore.app.domain.LibraryEntry
import com.cinemacore.app.domain.ResumePoint
import com.cinemacore.app.domain.Subject
import java.io.File
import kotlinx.coroutines.flow.StateFlow

class LibraryStore(directory: File) {
    private val store = JsonStateStore(
        file = File(directory, "library.json"),
        serializer = LibraryData.serializer(),
        defaultValue = LibraryData(),
    )

    val data: StateFlow<LibraryData> = store.state

    val value: LibraryData
        get() = store.value

    val watchlistIds: Set<String>
        get() = value.watchlist.mapTo(mutableSetOf()) { it.subject.id }

    fun isInWatchlist(subjectId: String): Boolean =
        value.watchlist.any { it.subject.id == subjectId }

    suspend fun toggleWatchlist(subject: Subject): Boolean {
        var added = false
        store.update { current ->
            val existing = current.watchlist.firstOrNull { it.subject.id == subject.id }
            if (existing != null) {
                current.copy(watchlist = current.watchlist - existing)
            } else {
                added = true
                current.copy(
                    watchlist = listOf(
                        LibraryEntry(subject = subject, addedAt = System.currentTimeMillis()),
                    ) + current.watchlist,
                )
            }
        }
        return added
    }

    suspend fun removeFromWatchlist(subjectId: String) {
        store.update { current ->
            current.copy(watchlist = current.watchlist.filterNot { it.subject.id == subjectId })
        }
    }

    suspend fun recordResume(
        subject: Subject,
        season: Int?,
        episode: Int?,
        episodeTitle: String?,
        positionMs: Long,
        durationMs: Long,
    ) {
        val entry = ResumePoint(
            subjectId = subject.id,
            title = subject.title,
            poster = subject.poster,
            season = season,
            episode = episode,
            episodeTitle = episodeTitle,
            positionMs = positionMs.coerceAtLeast(0),
            durationMs = durationMs.coerceAtLeast(0),
            updatedAt = System.currentTimeMillis(),
        )
        store.update { current ->
            val next = listOf(entry) + current.history.filterNot { it.key == entry.key }
            current.copy(history = next.take(MAX_HISTORY))
        }
    }

    suspend fun clearWatchlist() {
        store.update { it.copy(watchlist = emptyList()) }
    }

    suspend fun removeHistory(key: String) {
        store.update { current ->
            current.copy(history = current.history.filterNot { it.key == key })
        }
    }

    suspend fun clearHistory() {
        store.update { it.copy(history = emptyList()) }
    }

    fun resumeFor(subjectId: String, season: Int?, episode: Int?): ResumePoint? {
        val key = "$subjectId:${season ?: 0}:${episode ?: 0}"
        return value.history.firstOrNull { it.key == key }
    }

    fun latestResumeFor(subjectId: String): ResumePoint? =
        value.history.firstOrNull { it.subjectId == subjectId }

    companion object {
        const val MAX_HISTORY: Int = 300
    }
}
