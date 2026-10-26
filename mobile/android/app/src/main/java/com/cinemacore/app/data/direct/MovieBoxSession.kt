package com.cinemacore.app.data.direct

import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer

/** Typed failures at the session boundary; the repository maps these to `CinemacoreError`. */
sealed class MovieBoxSessionException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {

    class NoHosts : MovieBoxSessionException("No gateway hosts configured.")

    class Http(
        val status: Int,
        val body: String? = null,
    ) : MovieBoxSessionException("The gateway answered $status.")

    class Transport(
        val timedOut: Boolean = false,
        val detail: String? = null,
        cause: Throwable? = null,
    ) : MovieBoxSessionException(detail ?: "The gateway could not be reached.", cause)

    class BadResponse : MovieBoxSessionException("The gateway response could not be read.")
}

/**
 * The signed HTTP client for the MovieBox gateway: host failover, request
 * signing, the guest token, and a small GET cache.
 *
 * A Kotlin port of the Swift actor
 * `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/MovieBoxSession.swift`,
 * which mirrors `core/session/session.go`. Identity headers mirror the
 * MovieBox/4.0.02 Android client the gateway filters on; they are not cosmetic.
 *
 * @param hosts gateway host pool; schemes are optional.
 * @param http the shared OkHttp client. A derived client applies [timeoutMillis].
 * @param timeoutMillis whole-call timeout, matching the Go/Swift 20 s default.
 * @param cacheTtlMillis GET cache lifetime; 0 disables cache hits.
 * @param now milliseconds since the epoch, injectable for cache tests.
 */
class MovieBoxSession(
    private val hosts: List<String> = defaultHosts,
    http: OkHttpClient,
    timeoutMillis: Long = 20_000,
    private val cacheTtlMillis: Long = 300_000,
    private val now: () -> Long = { System.currentTimeMillis() },
) {

    private data class Identity(
        val userAgent: String = "MovieBox/4.0.02 (Android 14; Pixel 6)",
        val appId: String = "4U01pxRu278GqCZKY9",
        val region: String = "IN",
        val lang: String = "en",
        val os: String = "android",
        val appVersion: String = "4.0.02",
        val signVersion: String = "2.0",
        val clientInfo: String =
            """{"device_id":"868203051234567","device_type":"android","device_brand":"google","device_model":"Pixel 6","os_version":"14","app_version":"4.0.02","lang":"en","region":"IN"}""",
    )

    private data class Outcome(val status: Int, val data: ByteArray) {
        val bodyText: String?
            get() = if (status in 200..299) {
                null
            } else {
                String(data, 0, minOf(512, data.size), Charsets.UTF_8)
            }
    }

    private data class WireResponse(val status: Int, val data: ByteArray, val userHeader: String?)

    private data class CacheEntry(val expiresAt: Long, val data: ByteArray)

    private val identity = Identity()
    private val client = http.newBuilder()
        .callTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
        .build()

    private val stateLock = Any()
    private val loginLock = Mutex()

    private var token = ""
    private var hostIndex = 0
    private val cache = LinkedHashMap<String, CacheEntry>()

    /** The current bearer token, or `""` before a guest login. */
    fun currentToken(): String = synchronized(stateLock) { token }

    /**
     * Signs and sends one request, failing over across hosts on 403/429/5xx and
     * transport failures, then re-bootstrapping the guest session once on a
     * missing/expired token (441/401). GET responses are cached for the TTL.
     */
    suspend fun call(method: String, path: String, body: String? = null): ByteArray {
        val isGet = method.equals("GET", ignoreCase = true)
        val cacheKey = "$method $path"
        if (isGet) cached(cacheKey)?.let { return it }
        if (hosts.isEmpty()) throw MovieBoxSessionException.NoHosts()

        var outcome = attempt(method, path, body)
        if (outcome.status == 441 || outcome.status == 401) {
            // Content endpoints answer 441 until a guest bearer is presented:
            // drop any stale token, mint a fresh one, and replay once.
            setToken("")
            val loggedIn = try {
                guestLogin()
                true
            } catch (error: CancellationException) {
                throw error
            } catch (_: MovieBoxSessionException) {
                false
            }
            if (loggedIn) outcome = attempt(method, path, body)
        }
        if (outcome.status !in 200..299) {
            throw MovieBoxSessionException.Http(outcome.status, outcome.bodyText)
        }
        if (isGet) store(cacheKey, outcome.data)
        return outcome.data
    }

    /** Acquires an anonymous token (visitor-login). Idempotent. */
    suspend fun guestLogin(): String {
        currentToken().takeIf { it.isNotEmpty() }?.let { return it }
        return loginLock.withLock {
            currentToken().takeIf { it.isNotEmpty() }?.let { return@withLock it }
            val outcome = attempt("POST", GUEST_LOGIN_PATH, "{}")
            if (outcome.status !in 200..299) {
                throw MovieBoxSessionException.Http(outcome.status, outcome.bodyText)
            }
            val fresh = parseGuestToken(outcome.data) ?: throw MovieBoxSessionException.BadResponse()
            setToken(fresh)
            fresh
        }
    }

    private suspend fun attempt(method: String, path: String, body: String?): Outcome {
        var lastError: MovieBoxSessionException? = null

        for (attempt in hosts.indices) {
            val base = currentBase()
            val rawURL = base + withHost(path, hostOf(base))
            val ts = now()
            val signed = MovieBoxSigning.headers(
                method = method,
                url = rawURL,
                body = body ?: "",
                tsMillis = ts,
            )
            val request = try {
                buildRequest(method, rawURL, body, ts, signed, base)
            } catch (_: IllegalArgumentException) {
                throw MovieBoxSessionException.BadResponse()
            }

            val response = try {
                execute(request)
            } catch (error: CancellationException) {
                // The caller went away; asking the next host the same question
                // would keep a dismissed screen's request alive.
                throw error
            } catch (error: IOException) {
                rotate()
                lastError = MovieBoxSessionException.Transport(
                    timedOut = error is InterruptedIOException,
                    detail = error.message,
                    cause = error,
                )
                continue
            } catch (error: Exception) {
                rotate()
                lastError = MovieBoxSessionException.Transport(
                    detail = error.message,
                    cause = error,
                )
                continue
            }

            // The gateway rotates the guest token via the x-user header.
            response.userHeader?.let { raw -> tokenFromXUser(raw)?.let(::setToken) }

            if (response.status in 200..299) {
                return Outcome(response.status, response.data)
            }
            if (retryable(response.status)) {
                rotate()
                lastError = MovieBoxSessionException.Http(
                    response.status,
                    String(response.data, 0, minOf(512, response.data.size), Charsets.UTF_8),
                )
                continue
            }
            // 401/441 are returned so call() can re-login once; other statuses are
            // rejected by call() with the same typed error.
            return Outcome(response.status, response.data)
        }

        throw lastError ?: MovieBoxSessionException.NoHosts()
    }

    private fun buildRequest(
        method: String,
        rawURL: String,
        body: String?,
        ts: Long,
        signed: MovieBoxSigning.SignedHeaders,
        base: String,
    ): Request {
        val url = rawURL.toHttpUrlOrNull()
            ?: throw IllegalArgumentException("session: invalid URL")

        val builder = Request.Builder()
            .url(url)
            .header("User-Agent", identity.userAgent)
            .header("Accept", signed.accept)
            .header("Content-Type", signed.contentType)
            .header("X-Client-Token", signed.clientToken)
            .header("x-tr-signature", signed.trSignature)
            .header("X-M-Version", identity.appVersion)
            .header("X-Sign-Version", identity.signVersion)
            .header("X-Play-Mode", "2")
            .header("X-Timestamp", ts.toString())
            .header("X-Client-Status", "0")
            .header("appid", identity.appId)
            .header("region", identity.region)
            .header("lang", identity.lang)
            .header("os", identity.os)
            .header("Referer", base + "/")
            .header("X-Client-Info", identity.clientInfo)

        val current = currentToken()
        if (current.isNotEmpty()) builder.header("Authorization", "Bearer $current")

        val upperMethod = method.uppercase()
        val mediaType = signed.contentType.toMediaType()
        val requestBody = if (upperMethod == "GET" || upperMethod == "HEAD") {
            null
        } else {
            (body ?: "").toByteArray(Charsets.UTF_8).toRequestBody(mediaType)
        }
        builder.method(upperMethod, requestBody)

        return builder.build()
    }

    private suspend fun execute(request: Request): WireResponse = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    response.use {
                        val body = response.body
                        val data = if (body == null) ByteArray(0) else readCapped(body)
                        if (continuation.isActive) {
                            continuation.resume(
                                WireResponse(
                                    status = response.code,
                                    data = data,
                                    userHeader = response.header("x-user"),
                                ),
                            )
                        }
                    }
                } catch (error: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
        })
    }

    /** Reads at most 8 MiB, matching Go's `io.LimitReader` rather than rejecting. */
    private fun readCapped(body: okhttp3.ResponseBody): ByteArray {
        val source = body.source()
        val buffer = Buffer()
        val cap = MAX_RESPONSE_BYTES.toLong()
        var total = 0L
        while (total < cap) {
            val read = source.read(buffer, minOf(8192L, cap - total))
            if (read == -1L) break
            total += read
        }
        return buffer.readByteArray()
    }

    private fun currentBase(): String {
        val host = synchronized(stateLock) { hosts[hostIndex] }
        return if (host.contains("://")) host else "https://$host"
    }

    private fun rotate() {
        synchronized(stateLock) {
            if (hosts.isNotEmpty()) hostIndex = (hostIndex + 1) % hosts.size
        }
    }

    private fun setToken(value: String) {
        synchronized(stateLock) { token = value }
    }

    private fun cached(key: String): ByteArray? = synchronized(stateLock) {
        val entry = cache[key] ?: return null
        if (entry.expiresAt > now()) {
            entry.data
        } else {
            cache.remove(key)
            null
        }
    }

    private fun store(key: String, data: ByteArray) {
        val expiresAt = now() + cacheTtlMillis
        synchronized(stateLock) {
            if (cache.size >= CACHE_CAPACITY) {
                cache.remove(cache.keys.first())
            }
            cache[key] = CacheEntry(expiresAt, data)
        }
    }

    private fun parseGuestToken(data: ByteArray): String? = try {
        Json.parseToJsonElement(data.decodeToString())
            .jsonObject["data"]
            ?.jsonObject
            ?.get("token")
            ?.jsonPrimitive
            ?.contentOrNull
            ?.takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }

    companion object {
        val defaultHosts: List<String> = listOf(
            "api6.aoneroom.com",
            "api5.aoneroom.com",
            "api.aoneroom.com",
            "api.inmoviebox.com",
        )

        private const val GUEST_LOGIN_PATH = "/wefeed-mobile-bff/user-api/visitor-login"
        private const val MAX_RESPONSE_BYTES = 8 shl 20
        private const val CACHE_CAPACITY = 256

        /**
         * The gateway's mandatory `host` query parameter, which is covered by
         * the request signature. Appends rather than replacing, matching the
         * Swift client; a host value is always a DNS name or `host:port`.
         */
        internal fun withHost(path: String, host: String): String {
            if (host.isEmpty()) return path

            val fragmentIndex = path.indexOf('#')
            val head = if (fragmentIndex >= 0) path.substring(0, fragmentIndex) else path
            val fragment = if (fragmentIndex >= 0) path.substring(fragmentIndex) else ""
            val queryIndex = head.indexOf('?')
            val base = if (queryIndex >= 0) head.substring(0, queryIndex) else head
            val query = if (queryIndex >= 0) head.substring(queryIndex + 1) else ""

            val pair = "host=" + escapeQueryValue(host)
            val merged = if (query.isEmpty()) pair else "$query&$pair"
            return "$base?$merged$fragment"
        }

        /** `host[:port]` of a base URL, preserving an explicit port. */
        internal fun hostOf(base: String): String {
            if (base.isEmpty()) return base
            val schemeIndex = base.indexOf("://")
            val authority = when {
                schemeIndex >= 0 -> base.substring(schemeIndex + 3)
                base.startsWith("//") -> base.substring(2)
                else -> return base
            }
            val end = authority.indexOfFirst { it == '/' || it == '?' || it == '#' }
            var hostPort = if (end >= 0) authority.substring(0, end) else authority
            val userInfo = hostPort.lastIndexOf('@')
            if (userInfo >= 0) hostPort = hostPort.substring(userInfo + 1)
            return hostPort.ifEmpty { base }
        }

        internal fun retryable(status: Int): Boolean =
            status == 403 || status == 429 || status >= 500

        /**
         * Extracts a rotated guest token from `x-user`. The live gateway may
         * send either the raw token or `{"token":"..."}`.
         */
        internal fun tokenFromXUser(raw: String): String? {
            val value = raw.trim()
            if (value.isEmpty()) return null
            if (value.startsWith("{")) {
                return try {
                    Json.parseToJsonElement(value)
                        .jsonObject["token"]
                        ?.jsonPrimitive
                        ?.contentOrNull
                        ?.takeIf { it.isNotEmpty() }
                } catch (_: Exception) {
                    null
                }
            }
            // A raw token is a single opaque value; headers carrying prose or a
            // stray brace are noise rather than credentials.
            if (value.any { it.isWhitespace() || it == '{' || it == '}' }) return null
            return value
        }

        private fun escapeQueryValue(value: String): String {
            val builder = StringBuilder()
            for (raw in value.toByteArray(Charsets.UTF_8)) {
                val byte = raw.toInt() and 0xFF
                when (byte) {
                    in 'a'.code..'z'.code,
                    in 'A'.code..'Z'.code,
                    in '0'.code..'9'.code,
                    '-'.code, '_'.code, '.'.code, '~'.code,
                    ':'.code, '['.code, ']'.code,
                    -> builder.append(byte.toChar())
                    else -> builder.append('%').append(HEX[byte shr 4]).append(HEX[byte and 0x0F])
                }
            }
            return builder.toString()
        }

        private const val HEX = "0123456789ABCDEF"
    }
}
