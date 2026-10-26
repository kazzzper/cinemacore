package com.cinemacore.app.data.direct

import com.cinemacore.app.domain.CastMember
import com.cinemacore.app.domain.Dub
import com.cinemacore.app.domain.Episode
import com.cinemacore.app.domain.Page
import com.cinemacore.app.domain.ResourceDetector
import com.cinemacore.app.domain.Season
import com.cinemacore.app.domain.Section
import com.cinemacore.app.domain.Subject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The MovieBox gateway's wire vocabulary, decoded by hand into the domain
 * models. Mirrors the iOS `MovieBoxWire` and `core/provider/moviebox` wire
 * types; keep the three in step.
 *
 * Every entry point takes the raw response body and is deliberately lossy
 * rather than strict: one malformed card, caption or row must not discard the
 * rest of the payload. No transport or Android type belongs here.
 */
object MovieBoxWire {
    private val parser = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        explicitNulls = false
    }

    private val homeRowContainers = listOf(
        "customData",
        "banner",
        "rankingListData",
        "list",
        "items",
        "subjects",
        "movieList",
    )

    // MARK: - Envelope

    private fun parseObject(raw: String): JsonObject? =
        runCatching { parser.parseToJsonElement(raw) }.getOrNull() as? JsonObject

    private fun payload(root: JsonObject): JsonElement? =
        root["data"]?.takeUnless { it is JsonNull } ?: root

    private fun envelopeObject(raw: String): JsonObject? {
        val root = parseObject(raw) ?: return null
        return payload(root) as? JsonObject
    }

    // MARK: - Subject

    /**
     * Maps one subject object. Returns `null` when the entry has no usable
     * `subjectId`, which is how category/cast cards are kept out of the feed.
     */
    fun subject(json: JsonObject): Subject? {
        val id = json.string("subjectId").orEmpty()
        if (id.isEmpty()) return null

        val subjectType = json.int("subjectType")
        val dubs = json.array("dubs")
        val dubNames = mutableListOf<String>()
        val dubOptions = mutableListOf<Dub>()
        for (entry in dubs) {
            val dub = entry as? JsonObject ?: continue
            val name = dub.string("lanName").orEmpty()
            if (name.isEmpty()) continue
            dubNames += name
            val dubId = dub.string("subjectId").orEmpty()
            if (dubId.isEmpty()) continue
            dubOptions += Dub(
                subjectId = dubId,
                languageName = name,
                languageCode = dub.string("lanCode"),
                isOriginal = dub.boolean("original") ?: false,
            )
        }

        val cast = mutableListOf<CastMember>()
        for (entry in json.array("staffList")) {
            val staff = entry as? JsonObject ?: continue
            val name = staff.string("name").orEmpty()
            if (name.isEmpty()) continue
            cast += CastMember(
                name = name,
                role = staff.string("character") ?: "",
                avatar = staff.string("avatarUrl"),
            )
        }

        val detectors = mutableListOf<ResourceDetector>()
        for (entry in json.array("resourceDetectors")) {
            val detector = entry as? JsonObject ?: continue
            val resourceId = detector.string("resourceId").orEmpty()
            if (resourceId.isEmpty()) continue
            val name = detector.string("source").orEmpty()
            detectors += ResourceDetector(
                resourceId = resourceId,
                name = name.ifEmpty { "Resource" },
            )
        }

        return Subject(
            id = id,
            title = firstNonEmpty(json.string("title"), json.string("name")),
            poster = httpsURL(json.obj("cover")?.string("url") ?: json.string("cover")),
            year = year(json.string("releaseDate")),
            rating = json.string("imdbRatingValue")
                ?.let(::parseRating)
                ?: json.string("imdbRate")?.let(::parseRating),
            kind = firstNonEmpty(json.string("kind"), kindOf(subjectType))
                .takeIf { it.isNotEmpty() },
            synopsis = json.string("description")?.takeIf { it.isNotEmpty() },
            genres = splitList(json.string("genre")),
            dubs = dubNames,
            dubOptions = dubOptions,
            durationMinutes = durationMinutes(
                totalSeconds = json.int("durationSeconds")?.takeIf { it > 0 }
                    ?: json.int("seconds")
                    ?: 0,
                human = json.string("duration"),
            ),
            seasonCount = json.int("seasonCount") ?: json.int("seNum") ?: 1,
            cast = cast,
            resourceDetectors = detectors,
        )
    }

    // MARK: - Catalog

    fun homePage(json: String): Page {
        val root = parseObject(json) ?: return Page(emptyList())
        val data = payload(root) ?: return Page(emptyList())

        if (data is JsonArray) {
            val objects = data.filterIsInstance<JsonObject>()
            if (objects.isNotEmpty() && objects.all { isDirectSubject(it) }) {
                val subjects = objects.mapNotNull { subjectEntry(it) }
                return Page(listOf(Section("Top Picks", subjects)))
            }
            return homeFromRows(data)
        }

        val page = data as? JsonObject ?: return Page(emptyList())
        val rows = page.array("items") + page.array("list")
        if (rows.isEmpty()) {
            val single = subjectEntry(page) ?: return Page(emptyList())
            return Page(listOf(Section(rowTitle(page), listOf(single))))
        }

        // daily-movie-rec has no titled rows: its `items` are subjects. Keep
        // that shape as the single rail the repository's fallback exposes.
        val objects = rows.filterIsInstance<JsonObject>()
        if (objects.isNotEmpty() && objects.all { isDirectSubject(it) }) {
            val subjects = objects.mapNotNull { subjectEntry(it) }
            if (subjects.isEmpty()) return Page(emptyList())
            val title = firstNonEmpty(page.string("title"), page.string("name"), "Top Picks")
            return Page(listOf(Section(title, subjects)))
        }

        return homeFromRows(rows)
    }

    private fun homeFromRows(rows: List<JsonElement>): Page {
        val sections = mutableListOf<Section>()
        for (row in rows) {
            val obj = row as? JsonObject ?: continue
            val subjects = homeRowSubjects(obj)
            if (subjects.isEmpty()) continue
            sections += Section(rowTitle(obj), subjects)
        }
        return Page(sections)
    }

    private fun homeRowSubjects(row: JsonObject): List<Subject> {
        val out = mutableListOf<Subject>()

        appendCards(row["customData"], out)
        appendCards(row["banner"], out)

        for (entry in rankingEntries(row["rankingListData"])) {
            val rank = entry as? JsonObject
            if (rank == null) {
                subjectEntry(entry)?.let(out::add)
                continue
            }
            val nested = rank.array("subjects")
            if (nested.isNotEmpty()) {
                for (nestedEntry in nested) {
                    subjectEntry(nestedEntry)?.let(out::add)
                }
            } else {
                subjectEntry(rank)?.let(out::add)
            }
        }

        // postData/playListData/liveList are UGC and live-room cards whose ids
        // Detail cannot answer, so they never contribute catalog subjects.
        for (key in listOf("list", "items", "subjects", "movieList")) {
            for (entry in row.array(key)) {
                subjectEntry(entry)?.let(out::add)
            }
        }

        if (out.isEmpty()) subjectEntry(row)?.let(out::add)
        return out
    }

    private fun appendCards(container: JsonElement?, out: MutableList<Subject>) {
        for (entry in containerEntries(container)) {
            subjectEntry(entry)?.let(out::add)
        }
    }

    private fun containerEntries(container: JsonElement?): List<JsonElement> =
        when (container) {
            is JsonObject -> container.array("items") + container.array("banners")
            is JsonArray -> container.toList()
            else -> emptyList()
        }

    private fun rankingEntries(container: JsonElement?): List<JsonElement> =
        when (container) {
            is JsonObject -> container.array("items").ifEmpty { listOf(container) }
            is JsonArray -> container.toList()
            else -> emptyList()
        }

    private fun isDirectSubject(entry: JsonElement): Boolean {
        val obj = entry as? JsonObject ?: return false
        if (obj.string("subjectId").isNullOrEmpty()) return false
        return homeRowContainers.none { key ->
            val value = obj[key]
            value != null && value !is JsonNull
        }
    }

    fun searchItems(json: String): List<Subject> {
        val root = parseObject(json) ?: return emptyList()
        val entries = when (val data = payload(root)) {
            is JsonArray -> data.toList()
            is JsonObject -> data.array("items").ifEmpty { data.array("list") }
            else -> emptyList()
        }
        if (entries.isEmpty()) {
            return listOfNotNull((payload(root) as? JsonObject)?.let { subjectEntry(it) })
        }
        return entries.mapNotNull { subjectEntry(it) }
    }

    fun detailSubject(json: String): Subject? {
        val root = parseObject(json) ?: return null
        return (payload(root) as? JsonObject)?.let { subjectEntry(it) }
    }

    fun seasons(json: String): List<Season> {
        val root = parseObject(json) ?: return emptyList()
        val entries = when (val data = payload(root)) {
            is JsonArray -> data.toList()
            is JsonObject -> data.array("seasons")
            else -> emptyList()
        }

        val seasons = mutableListOf<Season>()
        for (entry in entries) {
            val raw = entry as? JsonObject ?: continue
            val number = raw.int("se") ?: continue
            val episodes = episodeNumbers(raw.string("allEp"), raw.int("maxEp") ?: 0)
                .map { Episode(subjectId = "", season = number, number = it) }
            seasons += Season(number = number, episodes = episodes)
        }
        return seasons
    }

    fun playStreams(json: String): List<RawStream> {
        val root = parseObject(json) ?: return emptyList()
        val entries = when (val data = payload(root)) {
            is JsonArray -> data.toList()
            is JsonObject -> data.array("streams")
            else -> emptyList()
        }
        return entries.mapNotNull { entry ->
            val stream = entry as? JsonObject ?: return@mapNotNull null
            RawStream(
                url = stream.string("url").orEmpty(),
                resolutions = stream.string("resolutions"),
                size = stream.string("size"),
                signCookie = stream.string("signCookie"),
                format = stream.string("format"),
                codecName = stream.string("codecName"),
            )
        }
    }

    fun suggestions(json: String): List<String> {
        val root = parseObject(json) ?: return emptyList()
        val entries = when (val data = payload(root)) {
            is JsonArray -> data.toList()
            is JsonObject -> data.array("items")
            else -> emptyList()
        }
        return entries.mapNotNull { entry ->
            val item = entry as? JsonObject ?: return@mapNotNull null
            item.string("word")?.takeIf { it.isNotEmpty() }
        }
    }

    fun captions(json: String): List<RawCaption> {
        val root = parseObject(json) ?: return emptyList()
        val entries = when (val data = payload(root)) {
            is JsonArray -> data.toList()
            is JsonObject -> data.array("extCaptions")
            else -> emptyList()
        }
        // Decode each caption independently: one bad element must not empty the
        // track list, and an unrecognised object keeps whatever fields it has.
        return entries.mapNotNull { entry ->
            val caption = entry as? JsonObject ?: return@mapNotNull null
            RawCaption(
                lan = caption.string("lan"),
                lanName = caption.string("lanName"),
                url = caption.string("url").orEmpty(),
            )
        }
    }

    // MARK: - UGC recovery

    fun ugcFirst(json: String): UgcFirst? {
        val data = envelopeObject(json) ?: return null
        return UgcFirst(
            ugcVideoId = data.string("ugcVideoId").orEmpty(),
            collectionId = data.obj("belongToCollection")?.string("collectionId"),
        )
    }

    fun ugcDownloadResources(json: String): List<UgcResource> =
        ugcItems(json).flatMap { it.resources }

    fun ugcCollectionItems(json: String): List<UgcItem> = ugcItems(json)

    private fun ugcItems(json: String): List<UgcItem> {
        val data = envelopeObject(json) ?: return emptyList()
        return data.array("items").mapNotNull { entry ->
            val item = entry as? JsonObject ?: return@mapNotNull null
            val resources = item.array("resources").mapNotNull { entry ->
                val raw = entry as? JsonObject ?: return@mapNotNull null
                UgcResource(
                    url = raw.string("url").orEmpty(),
                    resolutions = raw.string("resolutions"),
                    size = raw.string("size"),
                    duration = raw.int("duration"),
                    signCookie = raw.string("signCookie"),
                    codecName = raw.string("codecName"),
                )
            }
            UgcItem(
                epTitle = item.string("epTitle"),
                title = item.string("title"),
                resources = resources,
            )
        }
    }

    // MARK: - Resource listing

    fun resources(json: String): Pair<List<RawResource>, Boolean> {
        val root = parseObject(json) ?: return emptyList<RawResource>() to false
        val data = payload(root)
        val entries = when (data) {
            is JsonArray -> data.toList()
            is JsonObject -> data.array("list")
            else -> emptyList()
        }
        val hasMore = (data as? JsonObject)
            ?.obj("pager")
            ?.boolean("hasMore") == true
        val items = entries.mapNotNull { entry ->
            val raw = entry as? JsonObject ?: return@mapNotNull null
            RawResource(
                se = raw.int("se") ?: 0,
                ep = raw.int("ep") ?: 0,
                duration = raw.int("duration") ?: 0,
                resolution = raw.int("resolution") ?: 0,
                size = raw.string("size"),
                resourceLink = raw.string("resourceLink").orEmpty(),
                resourceId = raw.string("resourceId").orEmpty(),
                codecName = raw.string("codecName"),
            )
        }
        return items to hasMore
    }

    // MARK: - Session

    fun token(json: String): String? {
        val root = parseObject(json) ?: return null
        val data = payload(root)
        val fromData = (data as? JsonObject)?.string("token")
            ?: (data as? JsonPrimitive)?.asString()
        return (fromData ?: root.string("token"))?.takeIf { it.isNotEmpty() }
    }

    /**
     * The guest session rotates through the `x-user` response header, which is
     * either the bare token or the user object that carries it.
     */
    fun xUserToken(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (!trimmed.startsWith("{")) return trimmed
        val user = parseObject(trimmed) ?: return null
        return user.string("token")?.takeIf { it.isNotEmpty() }
    }

    // MARK: - Mapping helpers

    fun httpsURL(raw: String?): String? =
        raw?.takeIf { it.isNotEmpty() }?.let { if (it.startsWith("//")) "https:$it" else it }

    fun year(releaseDate: String?): Int? {
        if (releaseDate == null || releaseDate.length < 4) return null
        return releaseDate.substring(0, 4).toIntOrNull()?.takeIf { it > 0 }
    }

    fun kindOf(subjectType: Int?): String? =
        when (subjectType) {
            1 -> "movie"
            2 -> "series"
            10 -> "game"
            else -> null
        }

    fun splitList(raw: String?): List<String> =
        raw?.split(',')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            .orEmpty()

    /** Prefers the exact second count and falls back to the human `"1h 33m"`. */
    fun durationMinutes(totalSeconds: Int, human: String?): Int {
        if (totalSeconds > 0) return totalSeconds / 60
        if (human.isNullOrEmpty()) return 0
        var total = 0
        var digits = ""
        for (character in human) {
            when {
                character in '0'..'9' -> digits += character
                character == 'h' || character == 'H' -> {
                    total += (digits.toIntOrNull() ?: 0) * 60
                    digits = ""
                }
                character == 'm' || character == 'M' -> {
                    total += digits.toIntOrNull() ?: 0
                    digits = ""
                }
            }
        }
        return total
    }

    private fun episodeNumbers(allEp: String?, maxEp: Int): List<Int> {
        val marked = allEp
            ?.split(',')
            ?.mapNotNull { it.trim().toIntOrNull() }
            ?.filter { it > 0 }
            .orEmpty()
        if (marked.isNotEmpty()) return marked
        if (maxEp <= 0) return emptyList()
        return (1..maxEp).toList()
    }

    private fun subjectEntry(entry: JsonElement?): Subject? {
        val obj = entry as? JsonObject ?: return null
        val wrapped = obj["subject"] as? JsonObject
        if (wrapped != null) return subject(wrapped)
        return subject(obj)
    }

    private fun rowTitle(row: JsonObject): String =
        firstNonEmpty(row.string("title"), row.string("name"), "Section")

    private fun parseRating(raw: String): Double? =
        raw.trim().toDoubleOrNull()

    private fun firstNonEmpty(vararg values: String?): String =
        values.firstOrNull { !it.isNullOrEmpty() }.orEmpty()

    private fun JsonObject.string(key: String): String? =
        get(key)?.asString()

    private fun JsonObject.int(key: String): Int? =
        get(key)?.asInt()

    private fun JsonObject.boolean(key: String): Boolean? =
        get(key)?.asBoolean()

    private fun JsonObject.obj(key: String): JsonObject? =
        get(key) as? JsonObject

    private fun JsonObject.array(key: String): List<JsonElement> =
        (get(key) as? JsonArray)?.toList().orEmpty()

    private fun JsonElement.asString(): String? =
        when (this) {
            is JsonNull -> null
            is JsonPrimitive -> content
            else -> null
        }

    private fun JsonElement.asInt(): Int? =
        asString()?.trim()?.toIntOrNull()

    private fun JsonElement.asBoolean(): Boolean? {
        val value = asString()?.trim()?.lowercase() ?: return null
        return when (value) {
            "true", "1" -> true
            "false", "0" -> false
            else -> null
        }
    }
}

data class RawStream(
    val url: String,
    val resolutions: String? = null,
    val size: String? = null,
    val signCookie: String? = null,
    val format: String? = null,
    val codecName: String? = null,
)

data class RawCaption(
    val lan: String?,
    val lanName: String?,
    val url: String,
)

data class UgcFirst(
    val ugcVideoId: String,
    val collectionId: String?,
)

data class UgcItem(
    val epTitle: String?,
    val title: String?,
    val resources: List<UgcResource>,
)

data class UgcResource(
    val url: String,
    val resolutions: String?,
    val size: String?,
    val duration: Int?,
    val signCookie: String?,
    val codecName: String?,
)

data class RawResource(
    val se: Int,
    val ep: Int,
    val duration: Int,
    val resolution: Int,
    val size: String?,
    val resourceLink: String,
    val resourceId: String,
    val codecName: String?,
)
