package com.cinemacore.app.data.direct

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okio.ByteString.Companion.decodeBase64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The golden vectors live in `contracts/signing-vectors.json` and are shared
 * with the Go and Swift implementations. This suite is the Android release gate
 * for the signing contract; one byte of drift breaks every signed request.
 */
class MovieBoxSigningTest {

    private fun vectors(): JsonObject {
        val start = File(System.getProperty("user.dir") ?: ".").absoluteFile
        var directory: File? = start
        while (directory != null) {
            val candidate = File(directory, "contracts/signing-vectors.json")
            if (candidate.isFile) {
                return Json.parseToJsonElement(candidate.readText()).jsonObject
            }
            directory = directory.parentFile
        }
        throw AssertionError("contracts/signing-vectors.json not found above $start")
    }

    private fun JsonObject.string(key: String): String =
        getValue(key).jsonPrimitive.content

    private fun JsonObject.int(key: String): Int =
        getValue(key).jsonPrimitive.content.toInt()

    private fun JsonObject.long(key: String): Long =
        getValue(key).jsonPrimitive.content.toLong()

    @Test
    fun `the fixture agrees with the compiled-in constants`() {
        val root = vectors()
        assertEquals(root.string("gatewaySecretBase64"), MovieBoxSigning.gatewaySecret)
        assertEquals(root.int("bodySignatureMaxBytes"), MovieBoxSigning.bodySignatureMaxBytes)
        assertEquals(root.string("defaultAccept"), MovieBoxSigning.defaultAccept)
        assertEquals(root.string("defaultContentType"), MovieBoxSigning.defaultContentType)
    }

    @Test
    fun `gateway secret decodes to the documented 30 bytes`() {
        val decoded = requireNotNull(MovieBoxSigning.gatewaySecret.decodeBase64())
        assertEquals(30, decoded.size)
    }

    @Test
    fun `every client token matches`() {
        val tokens = vectors().getValue("clientTokens").jsonArray
        assertTrue(tokens.isNotEmpty())
        for (vector in tokens) {
            val objectValue = vector.jsonObject
            val ts = objectValue.long("tsMillis")
            assertEquals(
                "ts $ts",
                objectValue.string("token"),
                MovieBoxSigning.clientToken(ts),
            )
        }
    }

    @Test
    fun `every tr signature matches`() {
        val root = vectors()
        val accept = root.string("defaultAccept")
        val contentType = root.string("defaultContentType")
        val cases = root.getValue("trSignatures").jsonArray
        assertTrue(cases.isNotEmpty())
        for (vector in cases) {
            val objectValue = vector.jsonObject
            val name = objectValue.string("name")
            val body = when {
                objectValue["bodyRepeatChar"] != null -> {
                    val char = objectValue.string("bodyRepeatChar")
                    val count = objectValue.int("bodyRepeatCount")
                    val append = objectValue["bodyAppend"]?.jsonPrimitive?.content ?: ""
                    buildString {
                        repeat(count) { append(char) }
                        append(append)
                    }
                }
                objectValue["body"] != null -> objectValue.string("body")
                else -> ""
            }
            val signature = MovieBoxSigning.trSignature(
                method = objectValue.string("method"),
                url = objectValue.string("url"),
                accept = accept,
                contentType = contentType,
                body = body,
                tsMillis = objectValue.long("tsMillis"),
            )
            assertEquals(name, objectValue.string("expected"), signature)
        }
    }

    @Test
    fun `gslb sign matches`() {
        val gslb = vectors().getValue("gslbSign").jsonObject
        assertEquals(
            gslb.string("expected"),
            MovieBoxSigning.gslbSign(
                packageName = gslb.string("packageName"),
                deviceID = gslb.string("deviceID"),
            ),
        )
    }

    @Test
    fun `password md5 matches`() {
        val password = vectors().getValue("passwordMD5").jsonObject
        assertEquals(
            password.string("expected"),
            MovieBoxSigning.passwordMD5(password.string("input")),
        )
    }

    @Test
    fun `every canonical resource vector matches`() {
        val cases = vectors()
            .getValue("resourceVectors")
            .jsonObject
            .getValue("cases")
            .jsonArray
        assertTrue(cases.isNotEmpty())
        for (vector in cases) {
            val objectValue = vector.jsonObject
            val input = objectValue.string("input")
            assertEquals(input, objectValue.string("expected"), MovieBoxSigning.resource(input))
        }
    }

    @Test
    fun `empty bodies sign an empty hash and length`() {
        assertEquals("", MovieBoxSigning.md5Hex(""))
        assertEquals("", MovieBoxSigning.sha256Hex(""))
    }

    @Test
    fun `empty body signature matches the no-body vector`() {
        val headers = MovieBoxSigning.headers(
            method = "GET",
            url = "https://apig.inmoviebox.com/wefeed-mobile-bff/search",
            tsMillis = 1_700_000_000_002L,
        )
        assertEquals("1700000000002|2|V6DlEMNh1yxoNFQh540fzQ==", headers.trSignature)
        assertEquals("1700000000002,b407eba694405ab44e9c4924d3d1f195", headers.clientToken)
        assertEquals("application/json", headers.accept)
        assertEquals("application/json;charset=UTF-8", headers.contentType)
    }

    @Test
    fun `header names match the gateway contract`() {
        val dictionary = MovieBoxSigning.headers(
            method = "GET",
            url = "https://x.dev/",
            tsMillis = 1,
        ).dictionary
        assertTrue(dictionary.containsKey("X-Client-Token"))
        assertTrue(dictionary.containsKey("x-tr-signature"))
        assertEquals("application/json", dictionary["Accept"])
        assertEquals("application/json;charset=UTF-8", dictionary["Content-Type"])
    }

    @Test
    fun `method casing does not change the signature`() {
        assertEquals(
            MovieBoxSigning.trSignature(method = "GET", url = "https://x.dev/a?b=1", body = "", tsMillis = 7),
            MovieBoxSigning.trSignature(method = "get", url = "https://x.dev/a?b=1", body = "", tsMillis = 7),
        )
    }

    @Test
    fun `body length is the full byte count even when the hash truncates`() {
        val exactly = "a".repeat(MovieBoxSigning.bodySignatureMaxBytes)
        val over = exactly + "b"
        assertEquals(
            MovieBoxSigning.md5Hex(exactly.toByteArray().copyOf(MovieBoxSigning.bodySignatureMaxBytes)),
            MovieBoxSigning.md5Hex(over.toByteArray().copyOf(MovieBoxSigning.bodySignatureMaxBytes)),
        )
        assertTrue(
            MovieBoxSigning.trSignature(method = "POST", url = "https://x.dev/", body = exactly, tsMillis = 1) !=
                MovieBoxSigning.trSignature(method = "POST", url = "https://x.dev/", body = over, tsMillis = 1),
        )
    }

    @Test
    fun `query unescape decodes plus and percent escapes`() {
        assertEquals("a b", MovieBoxSigning.queryUnescape("a+b"))
        assertEquals("a b", MovieBoxSigning.queryUnescape("a%20b"))
        assertEquals("a+b", MovieBoxSigning.queryUnescape("a%2Bb"))
        assertEquals("", MovieBoxSigning.queryUnescape("%zz"))
        assertEquals("", MovieBoxSigning.queryUnescape("%E4%B8%"))
    }

    @Test
    fun `sorting is stable for duplicate keys`() {
        assertEquals(
            "/p?a=2&a=1&a=3",
            MovieBoxSigning.resource("https://h/p?a=2&a=1&a=3"),
        )
    }
}
