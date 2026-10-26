package com.cinemacore.app.data.direct

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

/**
 * The MovieBox gateway request-signing contract, a byte-exact Kotlin port of
 * `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/Signing.swift` and
 * `core/sign/sign.go`.
 *
 * Every surface is pinned by `contracts/signing-vectors.json`; one byte of drift
 * breaks every signed request, so [MovieBoxSigningTest] is a release gate rather
 * than a smoke test. The canonical string is:
 *
 *     METHOD \n Accept \n Content-Type \n Content-Length \n ts_ms \n bodyMD5 \n path?sorted_query
 */
object MovieBoxSigning {

    /** `base64(GATEWAY_SECRET_ONLINE)`: 30 bytes, shared with the Go and Rust suites. */
    const val gatewaySecret: String = "76iRl07s0xSN9jqmEWAt79EBJZulIQIsV64FZr2O"

    /** Mirrors the app's `0x19000` (102400) body truncation. */
    const val bodySignatureMaxBytes: Int = 0x19000

    const val defaultAccept: String = "application/json"
    const val defaultContentType: String = "application/json;charset=UTF-8"

    // A failure here is a broken compile-time invariant, not a runtime condition;
    // this mirrors Go's fail-closed panic in TRSignature.
    private val secretKey: ByteArray = requireNotNull(gatewaySecret.decodeBase64()) {
        "sign: gateway secret is not valid base64"
    }.toByteArray()

    private const val HEX = "0123456789abcdef"
    private const val HEX_UPPER = "0123456789ABCDEF"

    /** Lowercase hex MD5 of the UTF-8 bytes, or `""` for an empty string. */
    fun md5Hex(string: String): String =
        if (string.isEmpty()) "" else md5Hex(string.toByteArray(Charsets.UTF_8))

    /** Lowercase hex MD5 of raw bytes. Signing operates on bytes, never graphemes. */
    fun md5Hex(bytes: ByteArray): String = hex(digest("MD5", bytes))

    /** Lowercase hex SHA-256 of the UTF-8 bytes, or `""` for an empty string. */
    fun sha256Hex(string: String): String =
        if (string.isEmpty()) "" else hex(digest("SHA-256", string.toByteArray(Charsets.UTF_8)))

    /** Builds `X-Client-Token`: `"<ts>,<md5(reversed ts)>"`. */
    fun clientToken(tsMillis: Long): String {
        val ts = tsMillis.toString()
        return ts + "," + md5Hex(ts.reversed())
    }

    /**
     * Builds `x-tr-signature`: `"<ts>|2|<base64(HMAC-MD5(secret, canonical))>"`.
     *
     * The body hash covers at most [bodySignatureMaxBytes] bytes, while the
     * signed length is always the full byte count.
     */
    fun trSignature(
        method: String,
        url: String,
        accept: String = defaultAccept,
        contentType: String = defaultContentType,
        body: String,
        tsMillis: Long,
    ): String {
        var bodyHash = ""
        var bodyLength = ""
        if (body.isNotEmpty()) {
            val bytes = body.toByteArray(Charsets.UTF_8)
            val signed = if (bytes.size > bodySignatureMaxBytes) {
                bytes.copyOf(bodySignatureMaxBytes)
            } else {
                bytes
            }
            bodyHash = md5Hex(signed)
            bodyLength = bytes.size.toString()
        }

        val canonical = listOf(
            method.uppercase(),
            accept,
            contentType,
            bodyLength,
            tsMillis.toString(),
            bodyHash,
            resource(url),
        ).joinToString("\n")

        val mac = Mac.getInstance("HmacMD5")
        mac.init(SecretKeySpec(secretKey, "HmacMD5"))
        val signature = mac.doFinal(canonical.toByteArray(Charsets.UTF_8))
        return "$tsMillis|2|${signature.toByteString().base64()}"
    }

    /** The canonical set of gateway headers for one request. */
    data class SignedHeaders(
        val accept: String,
        val contentType: String,
        val clientToken: String,
        val trSignature: String,
    ) {
        /** Header names exactly as the gateway expects them. */
        val dictionary: Map<String, String>
            get() = mapOf(
                "Accept" to accept,
                "Content-Type" to contentType,
                "X-Client-Token" to clientToken,
                "x-tr-signature" to trSignature,
            )
    }

    /** Signing headers for a request at [tsMillis]. */
    fun headers(
        method: String,
        url: String,
        body: String = "",
        tsMillis: Long,
    ): SignedHeaders = SignedHeaders(
        accept = defaultAccept,
        contentType = defaultContentType,
        clientToken = clientToken(tsMillis),
        trSignature = trSignature(
            method = method,
            url = url,
            body = body,
            tsMillis = tsMillis,
        ),
    )

    /** `X-Gslb-Sign`: `sha256(packageName + sha256(deviceID))`. */
    fun gslbSign(packageName: String, deviceID: String): String =
        sha256Hex(packageName + sha256Hex(deviceID))

    /** The login password transform. */
    fun passwordMD5(password: String): String = md5Hex(password)

    /**
     * Returns `"path?sorted_query"`: query pairs are URL-decoded and stably
     * sorted by key (Go byte order), then joined with `&` and not re-encoded.
     *
     * Parsed by hand rather than with `java.net.URI`, because a stray `%` is
     * normalised by the platform while Go leaves `RawQuery` untouched and
     * fails the whole parse on a bad path escape. The `resourceVectors` fixture
     * pins this agreement byte for byte.
     *
     * A query value that percent-decodes to invalid UTF-8 is not representable
     * as a Kotlin `String`, matching Swift's documented limit; every URL this
     * app builds is valid UTF-8.
     */
    internal fun resource(rawURL: String): String {
        val fragmentIndex = rawURL.indexOf('#')
        val withoutFragment = if (fragmentIndex >= 0) rawURL.substring(0, fragmentIndex) else rawURL
        val queryIndex = withoutFragment.indexOf('?')
        val pathAndAuthority = if (queryIndex >= 0) {
            withoutFragment.substring(0, queryIndex)
        } else {
            withoutFragment
        }
        val rawQuery = if (queryIndex >= 0) withoutFragment.substring(queryIndex + 1) else ""

        // A rejected path escape fails the entire parse; Go returns the input.
        val base = canonicalPath(pathAndAuthority) ?: return rawURL
        if (rawQuery.isEmpty()) return base

        val pairs = ArrayList<QueryPair>()
        var order = 0
        for (field in rawQuery.split('&')) {
            if (field.isEmpty()) continue
            val cut = field.indexOf('=')
            val key = queryUnescape(if (cut >= 0) field.substring(0, cut) else field)
            val value = queryUnescape(if (cut >= 0) field.substring(cut + 1) else "")
            pairs.add(QueryPair(key, value, order))
            order++
        }

        // Go compares strings byte-wise; Kotlin's String.compareTo compares
        // UTF-16 units, which can order non-ASCII keys differently. Stability
        // for duplicate keys is explicit because that is the contract.
        pairs.sortWith { lhs, rhs ->
            val byKey = goStringCompare(lhs.key, rhs.key)
            if (byKey != 0) byKey else lhs.order.compareTo(rhs.order)
        }
        return base + "?" + pairs.joinToString("&") { "${it.key}=${it.value}" }
    }

    /**
     * Mirrors Go's `url.QueryUnescape`: `+` means space, and a malformed escape
     * yields `""` because the Go call site discards the error.
     */
    internal fun queryUnescape(value: String): String {
        val input = value.toByteArray(Charsets.UTF_8)
        val output = ByteArray(input.size)
        var read = 0
        var write = 0
        while (read < input.size) {
            when (val byte = input[read].toInt() and 0xFF) {
                '+'.code -> {
                    output[write++] = ' '.code.toByte()
                    read++
                }
                '%'.code -> {
                    if (read + 2 >= input.size) return ""
                    val high = hexValue(input[read + 1])
                    val low = hexValue(input[read + 2])
                    if (high < 0 || low < 0) return ""
                    output[write++] = ((high shl 4) or low).toByte()
                    read += 3
                }
                else -> {
                    output[write++] = byte.toByte()
                    read++
                }
            }
        }
        return decodeUtf8(output, write) ?: ""
    }

    private data class QueryPair(val key: String, val value: String, val order: Int)

    /**
     * The escaped path, or `null` when Go's `url.Parse` would reject the URL
     * because of an invalid percent escape.
     */
    private fun canonicalPath(pathAndAuthority: String): String? {
        val rawPath = extractPath(pathAndAuthority)
        if (rawPath.isEmpty()) return "/"

        // Already valid: return verbatim so the input's own escape casing survives
        // (Go keeps RawPath).
        if (isAlreadyEscaped(rawPath)) return rawPath

        val decoded = percentDecodeUtf8(rawPath) ?: return null
        return goEscapePath(decoded)
    }

    /** Strips `scheme://authority` or a protocol-relative `//authority`. */
    private fun extractPath(value: String): String {
        val schemeIndex = value.indexOf("://")
        if (schemeIndex >= 0) {
            val rest = value.substring(schemeIndex + 3)
            val slash = rest.indexOf('/')
            return if (slash < 0) "" else rest.substring(slash)
        }
        if (value.startsWith("//")) {
            val rest = value.substring(2)
            val slash = rest.indexOf('/')
            return if (slash < 0) "" else rest.substring(slash)
        }
        return value
    }

    /** True when every byte is either allowed in a Go path or a well-formed `%XX`. */
    private fun isAlreadyEscaped(path: String): Boolean {
        val bytes = path.toByteArray(Charsets.UTF_8)
        var index = 0
        while (index < bytes.size) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte == '%'.code) {
                if (index + 2 >= bytes.size) return false
                if (hexValue(bytes[index + 1]) < 0 || hexValue(bytes[index + 2]) < 0) return false
                index += 3
                continue
            }
            if (!isAllowedPathByte(byte)) return false
            index++
        }
        return true
    }

    /** Go's `shouldEscape(c, encodePath)`: unreserved plus reserved, minus `?`. */
    private fun isAllowedPathByte(byte: Int): Boolean = when (byte) {
        in 'a'.code..'z'.code,
        in 'A'.code..'Z'.code,
        in '0'.code..'9'.code,
        '-'.code, '_'.code, '.'.code, '~'.code,
        '$'.code, '&'.code, '+'.code, ','.code,
        '/'.code, ':'.code, ';'.code, '='.code, '@'.code,
        -> true
        else -> false
    }

    /** Percent-encodes every UTF-8 byte Go would escape. */
    private fun goEscapePath(path: String): String {
        val builder = StringBuilder()
        for (raw in path.toByteArray(Charsets.UTF_8)) {
            val byte = raw.toInt() and 0xFF
            if (isAllowedPathByte(byte)) {
                builder.append(byte.toChar())
            } else {
                builder.append('%').append(HEX_UPPER[byte shr 4]).append(HEX_UPPER[byte and 0x0F])
            }
        }
        return builder.toString()
    }

    /** Percent-decodes bytes as UTF-8, rejecting a malformed escape. */
    private fun percentDecodeUtf8(value: String): String? {
        val input = value.toByteArray(Charsets.UTF_8)
        val output = ByteArray(input.size)
        var read = 0
        var write = 0
        while (read < input.size) {
            val byte = input[read].toInt() and 0xFF
            if (byte == '%'.code) {
                if (read + 2 >= input.size) return null
                val high = hexValue(input[read + 1])
                val low = hexValue(input[read + 2])
                if (high < 0 || low < 0) return null
                output[write++] = ((high shl 4) or low).toByte()
                read += 3
            } else {
                output[write++] = byte.toByte()
                read++
            }
        }
        return decodeUtf8(output, write)
    }

    private fun decodeUtf8(bytes: ByteArray, length: Int): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes, 0, length))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }

    private fun hexValue(byte: Byte): Int = when (val value = byte.toInt() and 0xFF) {
        in '0'.code..'9'.code -> value - '0'.code
        in 'a'.code..'f'.code -> value - 'a'.code + 10
        in 'A'.code..'F'.code -> value - 'A'.code + 10
        else -> -1
    }

    /** Go compares strings byte-wise; Kotlin's comparison is UTF-16 aware. */
    private fun goStringCompare(lhs: String, rhs: String): Int {
        val left = lhs.toByteArray(Charsets.UTF_8)
        val right = rhs.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(left.size, right.size)) {
            val difference = (left[index].toInt() and 0xFF) - (right[index].toInt() and 0xFF)
            if (difference != 0) return difference
        }
        return left.size - right.size
    }

    private fun digest(algorithm: String, bytes: ByteArray): ByteArray =
        MessageDigest.getInstance(algorithm).digest(bytes)

    private fun hex(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        for (index in bytes.indices) {
            val value = bytes[index].toInt() and 0xFF
            out[index * 2] = HEX[value shr 4]
            out[index * 2 + 1] = HEX[value and 0x0F]
        }
        return String(out)
    }
}
