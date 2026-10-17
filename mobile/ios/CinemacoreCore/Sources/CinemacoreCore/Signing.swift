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
    static func resource(_ rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL) else { return rawURL }

        var base = components.percentEncodedPath
        if base.isEmpty { base = "/" }

        guard let rawQuery = components.percentEncodedQuery, !rawQuery.isEmpty else {
            return base
        }

        var pairs: [(key: String, value: String)] = []
        for field in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            if field.isEmpty { continue }
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = queryUnescape(String(parts[0]))
            let value = parts.count > 1 ? queryUnescape(String(parts[1])) : ""
            pairs.append((key, value))
        }

        // Stable sort by key only; original order breaks ties, matching Go's
        // `sort.SliceStable`.
        let sorted = pairs.enumerated()
            .sorted { lhs, rhs in
                lhs.element.key == rhs.element.key
                    ? lhs.offset < rhs.offset
                    : lhs.element.key < rhs.element.key
            }
            .map(\.element)

        let query = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return base + "?" + query
    }

    /// Mirrors Go's `url.QueryUnescape`: `+` means space, and a malformed
    /// escape yields `""` because the Go call site discards the error.
    static func queryUnescape(_ value: String) -> String {
        let plusDecoded = value.replacingOccurrences(of: "+", with: " ")
        guard let decoded = plusDecoded.removingPercentEncoding else { return "" }
        return decoded
    }
}
