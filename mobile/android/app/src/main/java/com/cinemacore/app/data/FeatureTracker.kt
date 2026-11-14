package com.cinemacore.app.data

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The product features this build can offer, as a closed registry.
 *
 * A typed list rather than free-form strings so a typo in a call site is a
 * compile error, and so the report has a fixed set of rows to compare against:
 * a feature that never appears in the event log is a dead feature, which is the
 * one question this subsystem exists to answer.
 */
enum class Feature(val category: FeatureCategory, val displayName: String) {
    // Playback
    PLAYBACK(FeatureCategory.PLAYBACK, "Playback"),
    RESUME_PLAYBACK(FeatureCategory.PLAYBACK, "Resume playback"),
    AUTO_PLAY_NEXT(FeatureCategory.PLAYBACK, "Autoplay next"),
    PROGRESSIVE_PLAYBACK(FeatureCategory.PLAYBACK, "Progressive playback"),
    OFFLINE_PLAYBACK(FeatureCategory.PLAYBACK, "Offline playback"),
    SUBTITLES_PROVIDER(FeatureCategory.PLAYBACK, "Provider subtitles"),
    SUBTITLES_COMMUNITY(FeatureCategory.PLAYBACK, "Community subtitles"),
    SUBTITLE_SEARCH(FeatureCategory.PLAYBACK, "Subtitle search"),
    // Library
    DOWNLOADS(FeatureCategory.LIBRARY, "Downloads"),
    BACKGROUND_DOWNLOADS(FeatureCategory.LIBRARY, "Background downloads"),
    WATCHLIST(FeatureCategory.LIBRARY, "Watchlist"),
    HISTORY(FeatureCategory.LIBRARY, "History"),
    // Source
    GATEWAY_SOURCE(FeatureCategory.SOURCE, "Gateway source"),
    BUILT_IN_SOURCE(FeatureCategory.SOURCE, "Built-in source"),
    STREAM_HYPE_SOURCE(FeatureCategory.SOURCE, "StreamHype source"),
    HEVC_REPAIR(FeatureCategory.SOURCE, "HEVC repair"),
    // Player
    EPISODE_PICKER(FeatureCategory.PLAYER, "Episode picker"),
    SEASON_SWITCHER(FeatureCategory.PLAYER, "Season switcher"),
    DUB_SWITCHING(FeatureCategory.PLAYER, "Dub switching"),
    QUALITY_SELECTION(FeatureCategory.PLAYER, "Quality selection"),
    AUDIO_TRACK_SELECTION(FeatureCategory.PLAYER, "Audio track selection"),
    SPEED_CONTROL(FeatureCategory.PLAYER, "Speed control"),
    PICTURE_IN_PICTURE(FeatureCategory.PLAYER, "Picture in Picture"),
    AIR_PLAY(FeatureCategory.PLAYER, "AirPlay"),
    CHROMECAST(FeatureCategory.PLAYER, "Chromecast"),
    PLAYER_LOCK(FeatureCategory.PLAYER, "Player lock"),
    EDGE_GESTURES(FeatureCategory.PLAYER, "Edge gestures"),
    // Discovery
    SEARCH(FeatureCategory.DISCOVERY, "Search"),
    SUGGESTIONS(FeatureCategory.DISCOVERY, "Search suggestions"),
    CATEGORIES(FeatureCategory.DISCOVERY, "Categories"),
    ;

    /** The id written to disk and shown in the report. */
    val id: String = name.lowercase(Locale.ROOT)

    /**
     * Chromecast is the only off-by-default feature: the build has no sender,
     * and an "enabled" row would claim a capability the app cannot honour.
     */
    val enabledByDefault: Boolean
        get() = this != CHROMECAST
}

/** The section a feature is reported under. */
enum class FeatureCategory(val displayName: String) {
    PLAYBACK("Playback"),
    LIBRARY("Library"),
    SOURCE("Source"),
    PLAYER("Player"),
    DISCOVERY("Discovery"),
}

/** One thing that happened to one feature. */
data class FeatureEvent(
    val feature: Feature,
    val kind: Kind,
    val timestamp: Long = System.currentTimeMillis(),
    val detail: String? = null,
) {
    enum class Kind { USED, ENABLED, DISABLED, FAILED }
}

/** Per-feature totals, so a report does not have to re-scan the event log. */
data class FeatureUsage(
    val feature: Feature,
    /** `.USED` events only; a failure is not adoption. */
    val useCount: Int = 0,
    val failureCount: Int = 0,
    /**
     * First and last activity of any kind: a feature that is switched on and
     * off but never used is still alive, and hiding that would be wrong.
     */
    val firstUsed: Long? = null,
    val lastUsed: Long? = null,
)

/** One renderable row: the feature, whether it is on, and what it has done. */
data class FeatureSnapshot(val entries: List<Entry>) {
    data class Entry(
        val feature: Feature,
        val isEnabled: Boolean,
        val usage: FeatureUsage,
    ) {
        val id: String
            get() = feature.id
    }

    /**
     * Every registered feature, in registry order, so the screen can render a
     * complete list without a second lookup.
     */
    val enabledCount: Int
        get() = entries.count { it.isEnabled }

    val unusedCount: Int
        get() = entries.count { it.usage.useCount == 0 }

    fun entryFor(feature: Feature): Entry? = entries.firstOrNull { it.feature == feature }
}

/**
 * A plain-text rendering of a snapshot.
 *
 * Plain text because its two consumers are a monospaced debug view and the
 * clipboard: it survives a paste into a bug report, and it can be asserted on
 * without a snapshot-testing dependency.
 */
class FeatureReport(
    val snapshot: FeatureSnapshot,
    private val generatedAt: Long = System.currentTimeMillis(),
) {
    fun text(): String {
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

        val width = maxOf(snapshot.entries.maxOfOrNull { it.feature.id.length } ?: 0, 7) + 2

        val lines = mutableListOf(
            "Cinemacore feature report",
            "generated ${iso.format(Date(generatedAt))}",
            "${snapshot.enabledCount}/${snapshot.entries.size} enabled · " +
                "${snapshot.unusedCount} never used",
            "",
        )

        for (category in FeatureCategory.entries) {
            val rows = snapshot.entries.filter { it.feature.category == category }
            if (rows.isEmpty()) continue
            lines += category.displayName.uppercase(Locale.ENGLISH)
            lines += pad("feature", width) + pad("state", 6) + pad("uses", 6) +
                pad("fails", 7) + "last used"
            for (row in rows) {
                lines += pad(row.feature.id, width) +
                    pad(if (row.isEnabled) "on" else "off", 6) +
                    pad(row.usage.useCount.toString(), 6) +
                    pad(row.usage.failureCount.toString(), 7) +
                    (row.usage.lastUsed?.let { stamp.format(Date(it)) } ?: "-")
            }
            lines += ""
        }

        lines += "Recorded on this device only. No identifiers, titles, or URLs."
        return lines.joinToString("\n")
    }

    /**
     * Width-pads without ever truncating: a long id must widen its column, not
     * lose characters the reader needs.
     */
    private fun pad(text: String, width: Int): String =
        text.padEnd(maxOf(text.length, width))
}

/** The on-disk document. */
@Serializable
private data class FeatureDocument(
    /** Only explicit overrides, so a default that ships on stays on. */
    val enabled: Map<String, Boolean> = emptyMap(),
    val usage: Map<String, FeatureUsageRecord> = emptyMap(),
    val events: List<StoredEvent> = emptyList(),
)

/**
 * The event decoded from disk, before it is known to name a feature or kind
 * this build has. Unknown rows are dropped one at a time on load, so a document
 * written by a newer build still contributes its other events.
 */
@Serializable
private data class StoredEvent(
    val feature: String,
    val kind: String,
    val timestamp: Long,
    val detail: String? = null,
)

@Serializable
private data class FeatureUsageRecord(
    val useCount: Int = 0,
    val failureCount: Int = 0,
    val firstUsed: Long? = null,
    val lastUsed: Long? = null,
)

/**
 * Local, private feature telemetry: what exists, what is on, and what is used.
 *
 * Nothing leaves the device — there is no network path in this type at all.
 * Writes are serialised by one mutex and happen on every record: the call sites
 * are discrete actions (a playback start, a download, a search), not the
 * player's tick, so there is no burst for a debounce to collapse.
 */
class FeatureTracker(directory: File) {
    private val file = File(directory, "features.json")
    private val mutex = Mutex()
    private var document: FeatureDocument? = null

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = true
    }

    companion object {
        /** The event log is capped so a long-lived install cannot grow without bound. */
        const val EVENT_LIMIT = 500
    }

    suspend fun isEnabled(feature: Feature): Boolean = read { doc ->
        doc.enabled[feature.id] ?: feature.enabledByDefault
    }

    suspend fun enabledFeatures(): List<Feature> = read { doc ->
        Feature.entries.filter { doc.enabled[it.id] ?: it.enabledByDefault }
    }

    /**
     * Only features with recorded activity, most used first; the report fills in
     * the zero rows from the registry.
     */
    suspend fun usage(): List<FeatureUsage> = read { doc ->
        doc.usage.mapNotNull { (id, record) ->
            Feature.entries.firstOrNull { it.id == id }?.let { feature ->
                FeatureUsage(
                    feature = feature,
                    useCount = record.useCount,
                    failureCount = record.failureCount,
                    firstUsed = record.firstUsed,
                    lastUsed = record.lastUsed,
                )
            }
        }.sortedWith(
            compareByDescending<FeatureUsage> { it.useCount }.thenBy { it.feature.id },
        )
    }

    /** Newest first, capped at [limit]. */
    suspend fun events(limit: Int = 50): List<FeatureEvent> = read { doc ->
        if (limit <= 0) {
            emptyList()
        } else {
            doc.events.takeLast(limit).asReversed().mapNotNull { it.toEvent() }
        }
    }

    suspend fun snapshot(): FeatureSnapshot = read { doc ->
        FeatureSnapshot(
            entries = Feature.entries.map { feature ->
                val record = doc.usage[feature.id]
                FeatureSnapshot.Entry(
                    feature = feature,
                    isEnabled = doc.enabled[feature.id] ?: feature.enabledByDefault,
                    usage = FeatureUsage(
                        feature = feature,
                        useCount = record?.useCount ?: 0,
                        failureCount = record?.failureCount ?: 0,
                        firstUsed = record?.firstUsed,
                        lastUsed = record?.lastUsed,
                    ),
                )
            },
        )
    }

    suspend fun report(): FeatureReport = FeatureReport(snapshot())

    suspend fun record(feature: Feature, kind: FeatureEvent.Kind, detail: String? = null) {
        update { doc -> doc.append(FeatureEvent(feature, kind, detail = detail), feature.id) }
    }

    suspend fun setEnabled(feature: Feature, enabled: Boolean) {
        update { doc ->
            // Storing the default explicitly is harmless and keeps the "off"
            // case representable, which a missing key cannot express.
            doc.copy(enabled = doc.enabled + (feature.id to enabled))
                .append(
                    FeatureEvent(
                        feature,
                        if (enabled) FeatureEvent.Kind.ENABLED else FeatureEvent.Kind.DISABLED,
                    ),
                    feature.id,
                )
        }
    }

    suspend fun reset() {
        withContext(Dispatchers.IO) {
            mutex.withLock {
                val cleared = FeatureDocument()
                document = cleared
                write(cleared)
            }
        }
    }

    // MARK: - Internals

    private fun FeatureDocument.append(event: FeatureEvent, featureID: String): FeatureDocument {
        val events = (this.events + StoredEvent(
            feature = featureID,
            kind = event.kind.name,
            timestamp = event.timestamp,
            detail = event.detail,
        )).takeLast(EVENT_LIMIT)

        val record = usage[featureID] ?: FeatureUsageRecord()
        val nextRecord = when (event.kind) {
            FeatureEvent.Kind.USED -> record.copy(useCount = record.useCount + 1)
            FeatureEvent.Kind.FAILED -> record.copy(failureCount = record.failureCount + 1)
            FeatureEvent.Kind.ENABLED, FeatureEvent.Kind.DISABLED -> record
        }.copy(
            firstUsed = record.firstUsed ?: event.timestamp,
            lastUsed = event.timestamp,
        )
        return copy(events = events, usage = usage + (featureID to nextRecord))
    }

    private fun StoredEvent.toEvent(): FeatureEvent? {
        val known = Feature.entries.firstOrNull { it.id == feature } ?: return null
        val knownKind = FeatureEvent.Kind.entries.firstOrNull { it.name == kind } ?: return null
        return FeatureEvent(known, knownKind, timestamp, detail)
    }

    private suspend fun <T> read(transform: (FeatureDocument) -> T): T =
        withContext(Dispatchers.IO) {
            mutex.withLock { transform(loadedLocked()) }
        }

    private suspend fun update(transform: (FeatureDocument) -> FeatureDocument) {
        withContext(Dispatchers.IO) {
            mutex.withLock {
                val next = transform(loadedLocked())
                document = next
                write(next)
            }
        }
    }

    private fun loadedLocked(): FeatureDocument {
        document?.let { return it }
        val loaded = load()
        document = loaded
        return loaded
    }

    private fun load(): FeatureDocument {
        if (!file.exists()) return FeatureDocument()
        // A corrupt or newer document must not take the app down; the registry
        // defaults are a usable empty state.
        val decoded = runCatching {
            json.decodeFromString(FeatureDocument.serializer(), file.readText())
        }.getOrNull() ?: return FeatureDocument()
        // Drop rows for features this build does not have, so the report cannot
        // show a row with no name and no toggle.
        val known = Feature.entries.mapTo(mutableSetOf()) { it.id }
        return decoded.copy(
            enabled = decoded.enabled.filterKeys { it in known },
            usage = decoded.usage.filterKeys { it in known },
            events = decoded.events.filter { it.toEvent() != null }.takeLast(EVENT_LIMIT),
        )
    }

    private fun write(value: FeatureDocument) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        runCatching {
            temp.writeText(json.encodeToString(FeatureDocument.serializer(), value))
            if (!temp.renameTo(file)) {
                file.writeText(temp.readText())
                temp.delete()
            }
        }
    }
}
