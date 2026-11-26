package com.cinemacore.app.domain

/**
 * The app's own "Continue Watching" rail.
 *
 * The home page is the provider's payload, and a provider may stop returning a
 * continue row (a new session, a tokenless guest, a renamed rail) — which is how
 * the row disappeared from a screen that had it a minute earlier. Resume points
 * live on the device, so the app owns this rail rather than depending on the
 * catalogue for it. [TITLE] is also the flag name Manage Categories stores, so
 * the row can still be hidden and enabled like any other.
 */
object ContinueWatching {
    const val TITLE = "Continue Watching"

    /**
     * Newest first, one row per title, and only points worth resuming.
     *
     * One row per *title* keeps a binge from filling the rail with the same
     * show; the resume point is the latest episode, which is what "continue"
     * means there.
     */
    fun points(history: List<ResumePoint>, limit: Int = 12): List<ResumePoint> {
        val seen = mutableSetOf<String>()
        return history
            .filter { it.isResumable }
            .sortedByDescending { it.updatedAt }
            .filter { seen.add(it.subjectId) }
            .take(limit.coerceAtLeast(0))
    }
}
