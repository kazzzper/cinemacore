import Foundation
import Crypto

/// The MovieBox gateway request-signing contract.
///
/// A byte-exact Swift port of `core/sign/sign.go`, which is itself the single
/// source of truth shared with the Python API (`moviebox_api/utils.py`) and the
/// Rust TUI (`moviebox-crypto`). Every function here is pinned by the same
/// golden vectors as the Go implementation; one byte of drift breaks every
/// signed request, so `SigningTests` is a release gate, not a smoke test.
///
/// Canonical string:
///
///     METHOD \n Accept \n Content-Type \n Content-Length \n ts_ms \n bodyMD5 \n path?sorted_query
public enum Signing {

    // MARK: - Contract constants

    /// `base64(GATEWAY_SECRET_ONLINE)`: 30 bytes, byte-identical to the Rust
    /// `DEFAULT_SECRET_BYTES` constant.
    static let gatewaySecret = "76iRl07s0xSN9jqmEWAt79EBJZulIQIsV64FZr2O"

    /// Mirrors the app's `0x19000` (102400) body truncation.
    public static let bodySignatureMaxBytes = 0x19000

    public static let defaultAccept = "application/json"
    public static let defaultContentType = "application/json;charset=UTF-8"

    /// Decoded once. The literal is valid base64, so a failure is a broken
    /// compile-time invariant rather than a runtime condition — this mirrors
    /// Go's fail-closed `panic` in `TRSignature`.
    private static let secretKey: SymmetricKey = {
        guard let data = Data(base64Encoded: gatewaySecret) else {
            preconditionFailure("sign: gateway secret is not valid base64")
        }
        return SymmetricKey(data: data)
    }()

    // MARK: - Digests

    /// Lowercase hex MD5 of the UTF-8 bytes, or `""` for an empty string
    /// (matching Python's `hashlib` usage in the reference).
    public static func md5Hex(_ string: String) -> String {
        guard !string.isEmpty else { return "" }
        return md5Hex(Array(string.utf8))
    }

    /// Lowercase hex MD5 of raw bytes. Signing operates on bytes, never on
    /// grapheme clusters, so the body path uses this overload directly.
    public static func md5Hex(_ bytes: [UInt8]) -> String {
        hex(Insecure.MD5.hash(data: Data(bytes)))
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes, or `""` for an empty string.
    public static func sha256Hex(_ string: String) -> String {
        guard !string.isEmpty else { return "" }
        return hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Header values

    /// Builds the `X-Client-Token`: `"<ts>,<md5(reversed ts)>"`.
    public static func clientToken(tsMillis: Int64) -> String {
        let ts = String(tsMillis)
        return ts + "," + md5Hex(String(ts.reversed()))
    }

    /// Builds `x-tr-signature`: `"<ts>|2|<base64(HMAC-MD5(secret, canonical))>"`.
    public static func trSignature(
        method: String,
        url: String,
        accept: String = defaultAccept,
        contentType: String = defaultContentType,
        body: String,
        tsMillis: Int64
    ) -> String {
        var bodyHash = ""
        var bodyLength = ""
        if !body.isEmpty {
            let bytes = Array(body.utf8)
            let signed = bytes.count > bodySignatureMaxBytes
                ? Array(bytes[0..<bodySignatureMaxBytes])
                : bytes
            bodyHash = md5Hex(signed)
            // The full length is signed even when the hash is truncated.
            bodyLength = String(bytes.count)
        }

        let canonical = [
            method.uppercased(),
            accept,
            contentType,
            bodyLength,
            String(tsMillis),
            bodyHash,
            resource(url),
        ].joined(separator: "\n")

        let mac = HMAC<Insecure.MD5>.authenticationCode(
            for: Data(canonical.utf8),
            using: secretKey
        )
        return "\(tsMillis)|2|\(Data(mac).base64EncodedString())"
    }

    /// The canonical set of gateway headers for one request.
    public struct SignedHeaders: Hashable, Sendable {
        public let accept: String
        public let contentType: String
        public let clientToken: String
        public let trSignature: String

        /// Header names exactly as the gateway expects them.
        public var dictionary: [String: String] {
            [
                "Accept": accept,
                "Content-Type": contentType,
                "X-Client-Token": clientToken,
                "x-tr-signature": trSignature,
            ]
        }
    }

    /// Signing headers for a request at `tsMillis`.
    public static func headers(
        method: String,
        url: String,
        body: String = "",
        tsMillis: Int64
    ) -> SignedHeaders {
        SignedHeaders(
            accept: defaultAccept,
            contentType: defaultContentType,
            clientToken: clientToken(tsMillis: tsMillis),
            trSignature: trSignature(method: method, url: url, body: body, tsMillis: tsMillis)
        )
    }

    /// `X-Gslb-Sign`: `sha256(packageName + sha256(deviceID))`.
    public static func gslbSign(packageName: String, deviceID: String) -> String {
        sha256Hex(packageName + sha256Hex(deviceID))
    }

    /// The login password transform.
    public static func passwordMD5(_ password: String) -> String {
        md5Hex(password)
    }

    // MARK: - Canonical resource

    /// Returns `"path?sorted_query"`: query pairs are URL-decoded and stably
    /// sorted by key, then joined with `&` and **not** re-encoded.
    ///
    /// Parsed by hand rather than with `URLComponents`, because Foundation
    /// normalises a stray `%` to `%25` and re-encodes paths, while Go leaves
    /// `RawQuery` untouched and fails the whole parse on a bad path escape. The
    /// two must agree byte for byte; `resourceVectors` in
    /// `contracts/signing-vectors.json` pins that agreement, and those vectors
    /// were generated from the Go reference.
    ///
    /// Known limit: a query value that percent-decodes to *invalid* UTF-8 (for
    /// example `%FF`) is representable in a Go string but not in a Swift
    /// `String`, so that one class is documented rather than matched. Every URL
    /// this app builds is valid UTF-8.
    static func resource(_ rawURL: String) -> String {
        let withoutFragment = rawURL.prefix { $0 != "#" }
        let parts = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawQuery = parts.count > 1 ? String(parts[1]) : ""

        // A rejected path escape fails the entire parse, and Go returns the
        // input unchanged in that case.
        guard let base = canonicalPath(String(parts[0])) else { return rawURL }

        // An absent query returns the bare path; a present-but-empty one still
        // contributes its `?`.
        guard !rawQuery.isEmpty else { return base }

        var pairs: [(key: String, value: String, order: Int)] = []
        for (order, field) in rawQuery.split(separator: "&", omittingEmptySubsequences: false).enumerated() {
            if field.isEmpty { continue }
            let cut = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = queryUnescape(String(cut[0]))
            let value = cut.count > 1 ? queryUnescape(String(cut[1])) : ""
            pairs.append((key, value, order))
        }

        // Sorted by key alone, with the original position breaking ties:
        // Swift's `sorted` is not guaranteed stable, so stability is explicit.
        let sorted = pairs.sorted { lhs, rhs in
            lhs.key == rhs.key ? lhs.order < rhs.order : goStringLess(lhs.key, rhs.key)
        }
        return base + "?" + sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    /// The escaped path, or `nil` when Go's `url.Parse` would have rejected the
    /// URL because of an invalid percent escape.
    private static func canonicalPath(_ pathAndAuthority: String) -> String? {
        let rawPath = extractPath(pathAndAuthority)
        if rawPath.isEmpty { return "/" }

        // A path that is already a valid encoding is returned verbatim, which
        // preserves the input's own escape casing (Go keeps `RawPath`).
        if isAlreadyEscaped(rawPath) { return rawPath }
        // Not already escaped: either it needs encoding, or it is malformed.
        guard let decoded = rawPath.removingPercentEncoding else { return nil }
        return goEscapePath(decoded)
    }

    /// Strips `scheme://authority` or a protocol-relative `//authority`.
    private static func extractPath(_ value: String) -> String {
        if let range = value.range(of: "://") {
            let rest = value[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return "" }
            return String(rest[slash...])
        }
        if value.hasPrefix("//") {
            let rest = value.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return "" }
            return String(rest[slash...])
        }
        return value
    }

    /// True when every byte is either allowed in a Go path or part of a
    /// well-formed `%XX` escape.
    private static func isAlreadyEscaped(_ path: String) -> Bool {
        var iterator = path.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = iterator.next(), let low = iterator.next(),
                      isHexDigit(high), isHexDigit(low)
                else { return false }
                continue
            }
            guard isAllowedPathByte(byte) else { return false }
        }
        return true
    }

    /// Go's `shouldEscape(c, encodePath)`: unreserved characters plus the
    /// reserved set, minus `?`.
    private static func isAllowedPathByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"),
             UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "+"), UInt8(ascii: ","),
             UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "="),
             UInt8(ascii: "@"):
            true
        default:
            false
        }
    }

    /// Percent-encodes every byte Go would escape, operating on UTF-8 bytes.
    private static func goEscapePath(_ path: String) -> String {
        var out = ""
        for byte in path.utf8 {
            if isAllowedPathByte(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "a")...UInt8(ascii: "f"),
             UInt8(ascii: "A")...UInt8(ascii: "F"):
            true
        default:
            false
        }
    }

    /// Go compares strings byte-wise; Swift's `<` is Unicode-aware, which can
    /// order non-ASCII keys differently.
    private static func goStringLess(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        for index in 0..<min(left.count, right.count) where left[index] != right[index] {
            return left[index] < right[index]
        }
        return left.count < right.count
    }

    /// Mirrors Go's `url.QueryUnescape`: `+` means space, and a malformed
    /// escape yields `""` because the Go call site discards the error.
    static func queryUnescape(_ value: String) -> String {
        let plusDecoded = value.replacingOccurrences(of: "+", with: " ")
        guard let decoded = plusDecoded.removingPercentEncoding else { return "" }
        return decoded
    }
}
