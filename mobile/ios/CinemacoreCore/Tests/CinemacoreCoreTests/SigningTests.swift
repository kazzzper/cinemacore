import Testing
import Foundation
@testable import CinemacoreCore

/// The golden vectors are copied verbatim from `core/sign/sign_test.go`, which
/// itself agrees byte-for-byte with the Python reference implementation
/// (`moviebox-internal-api/moviebox_api/utils.py`). These five cases are the P1
/// gate: if any of them regress, every signed request to the gateway breaks.
@Suite("Signing — golden vectors")
struct SigningGoldenVectorTests {

    @Test("client token")
    func clientToken() {
        #expect(
            Signing.clientToken(tsMillis: 1_700_000_000_000)
                == "1700000000000,e41bb805cc23fdc5541917da93d608d5"
        )
    }

    @Test(
        "TR signature",
        arguments: [
            (
                "get with query",
                "GET",
                "https://apig.inmoviebox.com/wefeed-mobile-bff/subject-api/detail?subjectId=123&page=1&tab=0",
                "",
                Int64(1_700_000_000_000),
                "1700000000000|2|5i4LuyUxUltzHNIEBhHQVA=="
            ),
            (
                "post json body",
                "POST",
                "https://apig.inmoviebox.com/wefeed-mobile-bff/user-api/visitor-login",
                #"{"clientInfo":{"package_name":"com.community.oneroom"}}"#,
                Int64(1_700_000_000_001),
                "1700000000001|2|M9uRwz5I5tm5vSBI8KEIzg=="
            ),
            (
                "get no query",
                "GET",
                "https://apig.inmoviebox.com/wefeed-mobile-bff/search",
                "",
                Int64(1_700_000_000_002),
                "1700000000002|2|V6DlEMNh1yxoNFQh540fzQ=="
            ),
            (
                "body truncated at 102400",
                "POST",
                "https://apig.inmoviebox.com/x",
                String(repeating: "a", count: 102_400) + "TRAILING_MUST_BE_IGNORED",
                Int64(1_700_000_000_003),
                "1700000000003|2|pyBOv/j+5I0FP6C30+yt5Q=="
            ),
            (
                "duplicate + blank query keys",
                "GET",
                "https://apig.inmoviebox.com/p?b=2&a=1&a=3&c=",
                "",
                Int64(1_700_000_000_004),
                "1700000000004|2|vD/OjEvR95UT2iXamt5jbA=="
            ),
        ]
    )
    func trSignature(
        name: String,
        method: String,
        url: String,
        body: String,
        ts: Int64,
        want: String
    ) {
        let got = Signing.trSignature(method: method, url: url, body: body, tsMillis: ts)
        #expect(got == want, "\(name): got \(got), want \(want)")
    }

    @Test("gslb sign and password md5")
    func gslbAndPassword() {
        #expect(
            Signing.gslbSign(packageName: "com.community.oneroom", deviceID: "868203051234567")
                == "9071b411e7812cd20d564c3b523dda1c1b0abed0e9824273ff59cf3d903bb17d"
        )
        #expect(Signing.passwordMD5("secret123") == "5d7845ac6ee7cfffafc5fe5f35cf666d")
    }
}

@Suite("Signing — contract details")
struct SigningContractTests {

    @Test("gateway secret decodes to the documented 30 bytes")
    func secretLength() throws {
        let data = try #require(Data(base64Encoded: Signing.gatewaySecret))
        #expect(data.count == 30)
    }

    @Test("empty bodies sign an empty hash and length, matching Go")
    func emptyBody() {
        // MD5/SHA of "" collapse to "" rather than to the digest of no bytes.
        #expect(Signing.md5Hex("") == "")
        #expect(Signing.sha256Hex("") == "")
    }

    @Test("empty-body signature matches the no-body vector")
    func emptyBodySignature() {
        let headers = Signing.headers(
            method: "GET",
            url: "https://apig.inmoviebox.com/wefeed-mobile-bff/search",
            tsMillis: 1_700_000_000_002
        )
        #expect(headers.trSignature == "1700000000002|2|V6DlEMNh1yxoNFQh540fzQ==")
        #expect(headers.clientToken == "1700000000002,e41bb805cc23fdc5541917da93d608d5")
        #expect(headers.accept == "application/json")
        #expect(headers.contentType == "application/json;charset=UTF-8")
    }

    @Test("header names match the gateway contract")
    func headerNames() {
        let headers = Signing.headers(method: "GET", url: "https://x.dev/", tsMillis: 1)
        let dictionary = headers.dictionary
        #expect(dictionary["X-Client-Token"] != nil)
        #expect(dictionary["x-tr-signature"] != nil)
        #expect(dictionary["Accept"] == "application/json")
        #expect(dictionary["Content-Type"] == "application/json;charset=UTF-8")
    }

    @Test("method casing does not change the signature")
    func methodIsUppercased() {
        let lower = Signing.trSignature(method: "get", url: "https://x.dev/a?b=1", body: "", tsMillis: 7)
        let upper = Signing.trSignature(method: "GET", url: "https://x.dev/a?b=1", body: "", tsMillis: 7)
        #expect(lower == upper)
    }

    @Test("body length is the full byte count even when the hash truncates")
    func truncatedBodySignsFullLength() {
        let exactly = String(repeating: "a", count: Signing.bodySignatureMaxBytes)
        let over = exactly + "b"
        // Same truncated hash (the prefix is identical)…
        let hashOf = { Signing.md5Hex(Array($0.utf8).prefix(Signing.bodySignatureMaxBytes)) }
        #expect(hashOf(exactly) == hashOf(over))
        // …but a different signature, because the signed length differs.
        #expect(
            Signing.trSignature(method: "POST", url: "https://x.dev/", body: exactly, tsMillis: 1)
                != Signing.trSignature(method: "POST", url: "https://x.dev/", body: over, tsMillis: 1)
        )
    }

    @Test("query pairs are sorted by key and decoded, not re-encoded")
    func resourceSortsAndDecodes() {
        #expect(
            Signing.resource("https://h/p?b=2&a=1&a=3&c=") == "/p?a=1&a=3&b=2&c="
        )
        // '+' decodes to a space, and the decoded value is emitted raw.
        #expect(Signing.resource("https://h/p?q=a+b") == "/p?q=a b")
        // Percent escapes decode too.
        #expect(Signing.resource("https://h/p?q=a%2Fb") == "/p?q=a/b")
    }

    @Test("a missing path becomes '/'")
    func emptyPath() {
        #expect(Signing.resource("https://apig.inmoviebox.com") == "/")
        #expect(Signing.resource("https://apig.inmoviebox.com?x=1") == "/?x=1")
    }

    @Test("a malformed percent escape yields an empty key, matching Go's discarded error")
    func malformedEscape() {
        #expect(Signing.queryUnescape("%zz") == "")
        // A well-formed escape still decodes.
        #expect(Signing.queryUnescape("a%20b") == "a b")
    }

    @Test("sorting is stable for duplicate keys")
    func stableDuplicateOrder() {
        #expect(Signing.resource("https://h/p?a=2&a=1&a=3") == "/p?a=2&a=1&a=3")
    }
}
