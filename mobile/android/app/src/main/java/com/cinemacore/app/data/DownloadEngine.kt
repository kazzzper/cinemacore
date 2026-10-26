package com.cinemacore.app.data

import com.cinemacore.app.domain.DownloadItem
import com.cinemacore.app.domain.DownloadStatus
import com.cinemacore.app.domain.DownloadedSubtitle
import com.cinemacore.app.domain.MediaContainer
import com.cinemacore.app.domain.PlaybackPolicy
import com.cinemacore.app.domain.StreamRendition
import com.cinemacore.app.domain.Subject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.OkHttpClient
import okhttp3.Request

data class DownloadRequest(
    val subject: Subject,
    val season: Int?,
    val episode: Int?,
    val episodeTitle: String?,
    val stream: StreamRendition,
)

data class EnqueueResult(
    val added: Boolean,
    val message: String,
)

/**
 * Direct-progressive download queue.
 *
 * Mirrors the current iOS scope: MP4/direct files only. A manifest is refused
 * with an explicit reason instead of being saved as an unplayable playlist.
 * Pause/resume uses HTTP Range against the `.part` file.
 */
class DownloadEngine(
    private val directory: File,
    private val http: OkHttpClient,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val jobs = ConcurrentHashMap<String, Job>()
    private val gate = Semaphore(2)
    private val starting = AtomicBoolean(false)

    private val store = JsonStateStore(
        file = File(directory, "queue.json"),
        serializer = kotlinx.serialization.builtins.ListSerializer(DownloadItem.serializer()),
        defaultValue = emptyList(),
    )

    val items: StateFlow<List<DownloadItem>> = store.state

    /** Wired by the container so captions are saved with the episode. */
    var captionProvider: (suspend (DownloadItem) -> List<DownloadedSubtitle>)? = null

    init {
        directory.mkdirs()
    }

    fun start() {
        if (!starting.compareAndSet(false, true)) return
        scope.launch {
            try {
                schedule()
            } finally {
                starting.set(false)
            }
        }
    }

    suspend fun enqueue(requests: List<DownloadRequest>): List<EnqueueResult> {
        val results = mutableListOf<EnqueueResult>()
        val existing = store.value
        val additions = mutableListOf<DownloadItem>()
        requests.forEach { request ->
            val rejection = PlaybackPolicy.downloadRejection(
                stream = request.stream,
                isStreamHype = request.stream.isWeb,
            )
            if (rejection != null) {
                results += EnqueueResult(false, rejection)
                return@forEach
            }
            val id = downloadId(request)
            if (existing.any { it.id == id } || additions.any { it.id == id }) {
                results += EnqueueResult(false, "Already in Downloads.")
                return@forEach
            }
            val container = MediaContainer.classify(request.stream.url)
            val now = System.currentTimeMillis()
            val item = DownloadItem(
                id = id,
                subjectId = request.subject.id,
                title = request.subject.title,
                poster = request.subject.poster,
                season = request.season,
                episode = request.episode,
                episodeTitle = request.episodeTitle,
                quality = request.stream.quality,
                remoteUrl = request.stream.url,
                cookie = request.stream.cookie,
                container = container,
                status = DownloadStatus.QUEUED,
                createdAt = now,
                updatedAt = now,
                fileName = "$id.${container.assetExtension}",
            )
            additions += item
            results += EnqueueResult(true, "Queued ${request.subject.title}.")
        }
        if (additions.isNotEmpty()) {
            store.update { current -> additions + current }
            start()
        }
        return results
    }

    suspend fun pause(id: String) {
        jobs.remove(id)?.cancel()
        update(id) {
            if (it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.QUEUED) {
                it.copy(status = DownloadStatus.PAUSED, updatedAt = System.currentTimeMillis())
            } else {
                it
            }
        }
    }

    suspend fun resume(id: String) {
        update(id) {
            if (it.status == DownloadStatus.PAUSED || it.status == DownloadStatus.FAILED) {
                it.copy(
                    status = DownloadStatus.QUEUED,
                    failure = null,
                    updatedAt = System.currentTimeMillis(),
                )
            } else {
                it
            }
        }
        start()
    }

    suspend fun retry(id: String) {
        update(id) {
            it.copy(
                status = DownloadStatus.QUEUED,
                failure = null,
                updatedAt = System.currentTimeMillis(),
            )
        }
        start()
    }

    suspend fun cancel(id: String) {
        jobs.remove(id)?.cancel()
        val item = store.value.firstOrNull { it.id == id }
        if (item != null) {
            partFile(item).delete()
            finalFile(item).delete()
        }
        store.update { current -> current.filterNot { it.id == id } }
    }

    suspend fun remove(id: String) {
        jobs.remove(id)?.cancel()
        val item = store.value.firstOrNull { it.id == id }
        if (item != null) {
            partFile(item).delete()
            finalFile(item).delete()
            subtitleFiles(item).forEach { it.delete() }
        }
        store.update { current -> current.filterNot { it.id == id } }
    }

    suspend fun pauseAll() {
        jobs.values.forEach { it.cancel() }
        jobs.clear()
        store.update { current ->
            current.map {
                if (it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.QUEUED) {
                    it.copy(status = DownloadStatus.PAUSED, updatedAt = System.currentTimeMillis())
                } else {
                    it
                }
            }
        }
    }

    suspend fun resumeAll() {
        store.update { current ->
            current.map {
                if (it.status == DownloadStatus.PAUSED || it.status == DownloadStatus.FAILED) {
                    it.copy(
                        status = DownloadStatus.QUEUED,
                        failure = null,
                        updatedAt = System.currentTimeMillis(),
                    )
                } else {
                    it
                }
            }
        }
        start()
    }

    suspend fun removeCompleted() {
        val done = store.value.filter { it.status == DownloadStatus.COMPLETED }
        done.forEach { item ->
            finalFile(item).delete()
            subtitleFiles(item).forEach { it.delete() }
        }
        store.update { current -> current.filterNot { it.status == DownloadStatus.COMPLETED } }
    }

    fun fileFor(item: DownloadItem): File = finalFile(item)

    fun downloadsDir(): File = directory

    fun subtitleFiles(item: DownloadItem): List<File> =
        item.subtitles.map { File(directory, it.fileName) }

    fun activeCount(items: List<DownloadItem> = store.value): Int =
        items.count { it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.QUEUED }

    fun bytesOnDisk(): Long = directory.walkTopDown()
        .filter { it.isFile }
        .sumOf { it.length() }

    private suspend fun schedule() {
        val candidates = store.value.filter {
            it.status == DownloadStatus.QUEUED || it.status == DownloadStatus.DOWNLOADING
        }
        synchronized(this) {
            candidates.forEach { item ->
                if (jobs[item.id]?.isActive == true) return@forEach
                val job = scope.launch {
                    try {
                        gate.withPermit { runDownload(item.id) }
                    } finally {
                        jobs.remove(item.id)
                        start()
                    }
                }
                jobs[item.id] = job
            }
        }
    }

    private suspend fun runDownload(id: String) {
        val item = store.value.firstOrNull { it.id == id } ?: return
        if (item.status == DownloadStatus.COMPLETED) return
        if (item.container.isManifest) {
            update(id) {
                it.copy(
                    status = DownloadStatus.FAILED,
                    failure = PlaybackPolicy.downloadRejection(it.let {
                        StreamRendition(it.quality, it.remoteUrl, it.container.displayName)
                    }, false),
                    updatedAt = System.currentTimeMillis(),
                )
            }
            return
        }
        update(id) {
            it.copy(
                status = DownloadStatus.DOWNLOADING,
                failure = null,
                attempts = it.attempts + 1,
                updatedAt = System.currentTimeMillis(),
            )
        }
        try {
            download(id)
            update(id) {
                it.copy(
                    status = DownloadStatus.COMPLETED,
                    failure = null,
                    totalBytes = if (it.totalBytes > 0) it.totalBytes else it.bytesWritten,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            val finished = store.value.firstOrNull { it.id == id }
            if (finished != null) {
                val captions = runCatching { captionProvider?.invoke(finished) }.getOrNull().orEmpty()
                if (captions.isNotEmpty()) {
                    update(id) { it.copy(subtitles = captions, updatedAt = System.currentTimeMillis()) }
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: IOException) {
            update(id) {
                it.copy(
                    status = DownloadStatus.FAILED,
                    failure = error.message ?: "The transfer stopped.",
                    updatedAt = System.currentTimeMillis(),
                )
            }
        } catch (error: Exception) {
            update(id) {
                it.copy(
                    status = DownloadStatus.FAILED,
                    failure = error.message ?: "The download failed.",
                    updatedAt = System.currentTimeMillis(),
                )
            }
        }
    }

    private suspend fun download(id: String) {
        val item = store.value.firstOrNull { it.id == id } ?: return
        val part = partFile(item)
        val final = finalFile(item)
        if (final.exists() && final.length() > 0 && item.status == DownloadStatus.COMPLETED) return

        var existing = if (part.exists()) part.length() else 0L
        if (existing > 0 && item.totalBytes > 0 && existing >= item.totalBytes) {
            final.parentFile?.mkdirs()
            if (!part.renameTo(final)) {
                part.copyTo(final, overwrite = true)
                part.delete()
            }
            update(id) {
                it.copy(
                    bytesWritten = final.length(),
                    totalBytes = final.length(),
                    status = DownloadStatus.COMPLETED,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            return
        }

        val request = Request.Builder()
            .url(item.remoteUrl)
            .header("Accept", "*/*")
            .apply {
                item.cookie?.takeIf { it.isNotBlank() }?.let { header("Cookie", it) }
                if (existing > 0) header("Range", "bytes=$existing-")
            }
            .get()
            .build()

        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful && response.code != 206) {
                throw IOException("Server answered ${response.code}.")
            }
            val body = response.body ?: throw IOException("Empty response body.")
            val append = response.code == 206 && existing > 0
            if (!append) {
                existing = 0
                if (part.exists()) part.delete()
            }
            val contentLength = body.contentLength().takeIf { it > 0 } ?: 0
            val total = response.header("Content-Range")
                ?.substringAfterLast('/')
                ?.toLongOrNull()
                ?: if (contentLength > 0) existing + contentLength else 0

            update(id) {
                it.copy(
                    status = DownloadStatus.DOWNLOADING,
                    bytesWritten = existing,
                    totalBytes = total,
                    updatedAt = System.currentTimeMillis(),
                )
            }

            part.parentFile?.mkdirs()
            body.byteStream().use { input ->
                FileOutputStream(part, append).use { output ->
                    copyStream(id, input, output, existing, total)
                }
            }

            val written = part.length()
            val target = final
            if (!part.renameTo(target)) {
                part.copyTo(target, overwrite = true)
                part.delete()
            }
            update(id) {
                it.copy(
                    bytesWritten = written,
                    totalBytes = if (it.totalBytes > 0) it.totalBytes else written,
                    updatedAt = System.currentTimeMillis(),
                )
            }
        }
    }

    private suspend fun copyStream(
        id: String,
        input: InputStream,
        output: java.io.OutputStream,
        start: Long,
        total: Long,
    ) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var written = start
        var lastPublished = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
            written += read
            val now = System.currentTimeMillis()
            if (now - lastPublished >= 750) {
                lastPublished = now
                update(id) {
                    it.copy(
                        bytesWritten = written,
                        totalBytes = if (total > 0) total else it.totalBytes,
                        updatedAt = now,
                    )
                }
            }
        }
        output.flush()
        update(id) {
            it.copy(
                bytesWritten = written,
                totalBytes = if (total > 0) total else it.totalBytes,
                updatedAt = System.currentTimeMillis(),
            )
        }
    }

    private suspend fun update(id: String, transform: (DownloadItem) -> DownloadItem) {
        store.update { current ->
            current.map { if (it.id == id) transform(it) else it }
        }
    }

    private fun partFile(item: DownloadItem): File = File(directory, "${item.fileName}.part")

    private fun finalFile(item: DownloadItem): File = File(directory, item.fileName)

    private fun downloadId(request: DownloadRequest): String {
        val suffix = if (request.season != null && request.episode != null) {
            "-s${request.season}e${request.episode}"
        } else {
            ""
        }
        return sanitize("${request.subject.id}$suffix-${request.stream.quality}")
    }

    companion object {
        fun sanitize(raw: String): String =
            raw.replace(Regex("[^A-Za-z0-9._-]"), "_").take(120)
    }
}
