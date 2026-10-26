package com.cinemacore.app.data

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json

/**
 * A tiny JSON-on-disk state store. The mobile data sets are small (hundreds of
 * entries at most), so Room/SQLite would add schema machinery without buying
 * anything. Writes are atomic within the directory and serialized by a mutex.
 */
class JsonStateStore<T>(
    private val file: File,
    private val serializer: KSerializer<T>,
    private val defaultValue: T,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
        encodeDefaults = true
        prettyPrint = true
    },
) {
    private val mutex = Mutex()
    private val mutable = MutableStateFlow(read())
    val state: StateFlow<T> = mutable.asStateFlow()

    val value: T
        get() = mutable.value

    suspend fun update(transform: (T) -> T): T = withContext(Dispatchers.IO) {
        mutex.withLock {
            val next = transform(mutable.value)
            write(next)
            mutable.value = next
            next
        }
    }

    suspend fun replace(next: T): T = update { next }

    private fun read(): T {
        if (!file.exists()) return defaultValue
        return runCatching {
            json.decodeFromString(serializer, file.readText())
        }.getOrDefault(defaultValue)
    }

    private fun write(value: T) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(json.encodeToString(serializer, value))
        if (!temp.renameTo(file)) {
            file.writeText(temp.readText())
            temp.delete()
        }
    }
}
