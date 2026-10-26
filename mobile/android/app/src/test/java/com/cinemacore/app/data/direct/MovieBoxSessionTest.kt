package com.cinemacore.app.data.direct

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MovieBoxSessionTest {

    private val servers = mutableListOf<TestServer>()

    @After
    fun tearDown() {
        servers.forEach { server -> runCatching { server.close() } }
    }

    private fun server(handler: (RecordedRequest) -> StubResponse): TestServer =
        TestServer(handler).also { servers += it }

    private fun session(
        vararg hosts: String,
        timeoutMillis: Long = 20_000,
        cacheTtlMillis: Long = 300_000,
        now: () -> Long = { System.currentTimeMillis() },
    ): MovieBoxSession = MovieBoxSession(
        hosts = hosts.toList(),
        http = OkHttpClient(),
        timeoutMillis = timeoutMillis,
        cacheTtlMillis = cacheTtlMillis,
        now = now,
    )

    @Test
    fun `guest login acquires and reuses the token`() = runBlocking {
        val gateway = server { StubResponse(200, """{"data":{"token":"tok-1"}}""") }
        val client = session(gateway.baseUrl)

        assertEquals("tok-1", client.guestLogin())
        assertEquals("tok-1", client.currentToken())
        assertEquals("tok-1", client.guestLogin())
        assertEquals(1, gateway.requestCount)
        assertTrue(
            gateway.requests.single().path.startsWith("/wefeed-mobile-bff/user-api/visitor-login?"),
        )
        assertEquals("{}", gateway.requests.single().body)
    }

    @Test
    fun `identity and signing headers are exactly the gateway contract`() = runBlocking {
        val gateway = server { StubResponse(200, "ok") }
        val client = session(gateway.baseUrl)

        client.call("GET", "/x")
        val request = gateway.requests.single()

        assertEquals("MovieBox/4.0.02 (Android 14; Pixel 6)", request.header("User-Agent"))
        assertEquals("application/json", request.header("Accept"))
        assertEquals("application/json;charset=UTF-8", request.header("Content-Type"))
        assertEquals("4U01pxRu278GqCZKY9", request.header("appid"))
        assertEquals("IN", request.header("region"))
        assertEquals("en", request.header("lang"))
        assertEquals("android", request.header("os"))
        assertEquals("4.0.02", request.header("X-M-Version"))
        assertEquals("2.0", request.header("X-Sign-Version"))
        assertEquals("2", request.header("X-Play-Mode"))
        assertEquals("0", request.header("X-Client-Status"))
        assertEquals(gateway.baseUrl + "/", request.header("Referer"))
        assertTrue(request.path.contains("host=127.0.0.1:"))
        val ts = request.header("X-Timestamp")
        assertTrue(request.header("X-Client-Token")!!.startsWith("$ts,"))
        assertTrue(request.header("x-tr-signature")!!.startsWith("$ts|2|"))
    }

    @Test
    fun `no hosts produces a typed error`() = runBlocking {
        val client = MovieBoxSession(hosts = emptyList(), http = OkHttpClient())

        val error = runCatching {
            client.call("GET", "/x")
        }.exceptionOrNull()

        assertTrue("was $error", error is MovieBoxSessionException.NoHosts)
    }

    @Test
    fun `bearer is replayed on later calls`() = runBlocking {
        val gateway = server { request ->
            if (request.path.startsWith("/wefeed-mobile-bff/user-api/visitor-login")) {
                StubResponse(200, """{"data":{"token":"tok-1"}}""")
            } else {
                StubResponse(200, "ok")
            }
        }
        val client = session(gateway.baseUrl)

        client.guestLogin()
        assertEquals("ok", client.call("GET", "/content").decodeToString())

        val content = gateway.requests.last { it.path.startsWith("/content") }
        assertEquals("Bearer tok-1", content.header("Authorization"))
    }

    @Test
    fun `401 and 441 re-login once and replay`() = runBlocking {
        for (status in listOf(401, 441)) {
            var contentCalls = 0
            val gateway = server { request ->
                if (request.path.startsWith("/wefeed-mobile-bff/user-api/visitor-login")) {
                    StubResponse(200, """{"data":{"token":"tok-$status"}}""")
                } else {
                    contentCalls++
                    if (contentCalls == 1) {
                        StubResponse(status, """{"message":"missing token"}""")
                    } else {
                        StubResponse(200, "ok-$status")
                    }
                }
            }
            val client = session(gateway.baseUrl)

            assertEquals("ok-$status", client.call("GET", "/content").decodeToString())
            assertEquals(1, gateway.requests.count { it.path.contains("visitor-login") })
            assertEquals(2, gateway.requests.count { it.path.startsWith("/content") })
            assertEquals("Bearer tok-$status", gateway.requests.last().header("Authorization"))
        }
    }

    @Test
    fun `403 429 and 5xx fail over to the next host`() = runBlocking {
        for (status in listOf(403, 429, 500, 503)) {
            val first = server { StubResponse(status, "unavailable") }
            val second = server { StubResponse(200, "ok-$status") }
            val client = session(first.baseUrl, second.baseUrl)

            assertEquals("ok-$status", client.call("GET", "/x").decodeToString())
            assertEquals(1, first.requestCount)
            assertEquals(1, second.requestCount)
        }
    }

    @Test
    fun `non-retryable statuses do not fail over`() {
        val first = server { StubResponse(404, """{"message":"missing"}""") }
        val second = server { StubResponse(200, "ok") }
        val client = session(first.baseUrl, second.baseUrl)

        val error = runCatching {
            runBlocking { client.call("GET", "/x") }
        }.exceptionOrNull()

        assertTrue("was $error", error is MovieBoxSessionException.Http)
        assertEquals(404, (error as MovieBoxSessionException.Http).status)
        assertEquals(0, second.requestCount)
    }

    @Test
    fun `transport failures fail over to the next host`() = runBlocking {
        val closedPort = ServerSocket(0).use { it.localPort }
        val second = server { StubResponse(200, "ok") }
        val client = session("http://127.0.0.1:$closedPort", second.baseUrl)

        assertEquals("ok", client.call("GET", "/x").decodeToString())
        assertEquals(1, second.requestCount)
    }

    @Test
    fun `x-user rotates the token as json`() = runBlocking {
        val gateway = server {
            StubResponse(200, "ok", mapOf("x-user" to """{"token":"rotated-1"}"""))
        }
        val client = session(gateway.baseUrl)

        client.call("GET", "/x")

        assertEquals("rotated-1", client.currentToken())
    }

    @Test
    fun `x-user rotates the token as a plain string`() = runBlocking {
        val gateway = server {
            StubResponse(200, "ok", mapOf("x-user" to "rotated-plain"))
        }
        val client = session(gateway.baseUrl)

        client.call("GET", "/x")

        assertEquals("rotated-plain", client.currentToken())
    }

    @Test
    fun `GET responses are cached until the ttl expires`() = runBlocking {
        var clock = 1_000L
        var served = 0
        val gateway = server {
            served++
            StubResponse(200, "body-$served")
        }
        val client = session(gateway.baseUrl, cacheTtlMillis = 5_000, now = { clock })

        assertEquals("body-1", client.call("GET", "/cached").decodeToString())
        clock += 4_999
        assertEquals("body-1", client.call("GET", "/cached").decodeToString())
        assertEquals(1, served)

        clock += 2
        assertEquals("body-2", client.call("GET", "/cached").decodeToString())
        assertEquals(2, served)
    }

    @Test
    fun `POST responses are never cached`() = runBlocking {
        var served = 0
        val gateway = server {
            served++
            StubResponse(200, "body-$served")
        }
        val client = session(gateway.baseUrl, cacheTtlMillis = 300_000)

        assertEquals("body-1", client.call("POST", "/write", "{}").decodeToString())
        assertEquals("body-2", client.call("POST", "/write", "{}").decodeToString())
        assertEquals(2, served)
    }

    @Test
    fun `the response body is capped at eight mebibytes`() = runBlocking {
        val limit = 8 * 1024 * 1024
        val oversized = "x".repeat(limit + 128)
        val gateway = server { StubResponse(200, oversized) }
        val client = session(gateway.baseUrl)

        val data = client.call("GET", "/big")

        assertEquals(limit, data.size)
    }

    @Test
    fun `a slow response becomes a timed-out transport error`() {
        val gateway = server {
            Thread.sleep(500)
            StubResponse(200, "late")
        }
        val client = session(gateway.baseUrl, timeoutMillis = 100)

        val error = runCatching {
            runBlocking { client.call("GET", "/slow") }
        }.exceptionOrNull()

        assertTrue("was $error", error is MovieBoxSessionException.Transport)
        assertTrue((error as MovieBoxSessionException.Transport).timedOut)
    }

    @Test
    fun `cancellation is rethrown rather than wrapped`() = runBlocking {
        val gateway = server {
            Thread.sleep(2_000)
            StubResponse(200, "late")
        }
        val client = session(gateway.baseUrl)

        val error = runCatching {
            withTimeout(150) { client.call("GET", "/slow") }
        }.exceptionOrNull()

        assertTrue("was $error", error is TimeoutCancellationException)
    }

    @Test
    fun `withHost appends the signed host parameter`() {
        assertEquals(
            "/p?a=1&host=api6.aoneroom.com",
            MovieBoxSession.withHost("/p?a=1", "api6.aoneroom.com"),
        )
        assertEquals("/p?host=h", MovieBoxSession.withHost("/p", "h"))
        assertEquals("/p?host=h", MovieBoxSession.withHost("/p?", "h"))
        assertEquals("/p?a=1&host=h:8080", MovieBoxSession.withHost("/p?a=1", "h:8080"))
        assertEquals("/p?a=1&host=h#frag", MovieBoxSession.withHost("/p?a=1#frag", "h"))
        assertEquals("/p?a=1", MovieBoxSession.withHost("/p?a=1", ""))
    }

    @Test
    fun `hostOf preserves an explicit port and falls back for hostless inputs`() {
        assertEquals("h:8080", MovieBoxSession.hostOf("http://h:8080"))
        assertEquals("h", MovieBoxSession.hostOf("https://h"))
        assertEquals("h:8080", MovieBoxSession.hostOf("https://user@h:8080/path"))
        assertEquals("api6.aoneroom.com", MovieBoxSession.hostOf("api6.aoneroom.com"))
    }

    @Test
    fun `retryable covers 403 429 and 5xx`() {
        assertTrue(MovieBoxSession.retryable(403))
        assertTrue(MovieBoxSession.retryable(429))
        assertTrue(MovieBoxSession.retryable(500))
        assertTrue(MovieBoxSession.retryable(503))
        assertTrue(!MovieBoxSession.retryable(401))
        assertTrue(!MovieBoxSession.retryable(404))
        assertTrue(!MovieBoxSession.retryable(441))
    }

    @Test
    fun `tokenFromXUser accepts plain and json forms`() {
        assertEquals("plain", MovieBoxSession.tokenFromXUser("plain"))
        assertEquals("json", MovieBoxSession.tokenFromXUser("""{"token":"json"}"""))
        assertNull(MovieBoxSession.tokenFromXUser(""))
        assertNull(MovieBoxSession.tokenFromXUser("{}"))
        assertNull(MovieBoxSession.tokenFromXUser("""{"token":""}"""))
        assertNull(MovieBoxSession.tokenFromXUser("not json {"))
    }

    private data class RecordedRequest(
        val method: String,
        val path: String,
        val headers: Map<String, List<String>>,
        val body: String,
    ) {
        fun header(name: String): String? =
            headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }
                ?.value
                ?.firstOrNull()
    }

    private data class StubResponse(
        val status: Int,
        val body: String,
        val headers: Map<String, String> = emptyMap(),
    )

    private class TestServer(handler: (RecordedRequest) -> StubResponse) : AutoCloseable {
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        private val executor: ExecutorService = Executors.newCachedThreadPool()
        val requests = CopyOnWriteArrayList<RecordedRequest>()
        val baseUrl: String

        init {
            server.createContext("/") { exchange ->
                val body = exchange.requestBody.use { it.readBytes() }.toString(Charsets.UTF_8)
                val request = RecordedRequest(
                    method = exchange.requestMethod,
                    path = exchange.requestURI.rawPath +
                        (exchange.requestURI.rawQuery?.let { "?$it" } ?: ""),
                    headers = exchange.requestHeaders.entries.associate { it.key to it.value.toList() },
                    body = body,
                )
                requests += request
                val response = handler(request)
                response.headers.forEach { (name, value) -> exchange.responseHeaders.add(name, value) }
                val bytes = response.body.toByteArray(Charsets.UTF_8)
                exchange.sendResponseHeaders(response.status, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
            server.executor = executor
            server.start()
            baseUrl = "http://127.0.0.1:${server.address.port}"
        }

        val requestCount: Int
            get() = requests.size

        override fun close() {
            server.stop(0)
            executor.shutdownNow()
            executor.awaitTermination(1, TimeUnit.SECONDS)
        }
    }
}
