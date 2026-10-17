import Testing
import Foundation
@testable import CinemacoreCore

/// The golden vectors live in `contracts/signing-vectors.json` and are shared
/// with the Go implementation (`core/sign/sign_test.go`). One byte of drift
/// breaks every signed request, so this suite is the P1 gate — and the shared
/// file is what stops the two implementations diverging silently.
@Suite("Signing — golden vectors")
struct SigningGoldenVectorTests {

    @Test("the fixture agrees with the compiled-in constants")
    func constantsMatchFixture() throws {
        let vectors = try SigningVectorFixture.load()
        #expect(vectors.gatewaySecretBase64 == Signing.gatewaySecret)
        #expect(vectors.bodySignatureMaxBytes == Signing.bodySignatureMaxBytes)
        #expect(vectors.defaultAccept == Signing.defaultAccept)
        #expect(vectors.defaultContentType == Signing.defaultContentType)
    }

    @Test("client tokens")
    func clientTokens() throws {
        for vector in try SigningVectorFixture.load().clientTokens {
            #expect(
                Signing.clientToken(tsMillis: vector.tsMillis) == vector.token,
                "ts \(vector.tsMillis)"
            )
        }
    }

    @Test("TR signatures")
    func trSignatures() throws {
        let vectors = try SigningVectorFixture.load()
        for vector in vectors.trSignatures {
            let got = Signing.trSignature(
                method: vector.method,
                url: vector.url,
                accept: vectors.defaultAccept,
                contentType: vectors.defaultContentType,
                body: vector.resolvedBody,
                tsMillis: vector.tsMillis
            )
            #expect(got == vector.expected, "\(vector.name): got \(got)")
        }
    }

    @Test("canonical resource matches the Go reference byte for byte")
    func resourceVectors() throws {
        let cases = try SigningVectorFixture.load().resourceVectors.cases
        #expect(!cases.isEmpty)
        for vector in cases {
            let got = Signing.resource(vector.input)
            #expect(got == vector.expected, "resource(\(vector.input)) = \(got)")
        }
    }

    @Test("gslb sign and password md5")
    func gslbAndPassword() throws {
        let vectors = try SigningVectorFixture.load()
        #expect(
            Signing.gslbSign(
                packageName: vectors.gslbSign.packageName,
                deviceID: vectors.gslbSign.deviceID
            ) == vectors.gslbSign.expected
        )
        #expect(Signing.passwordMD5(vectors.passwordMD5.input) == vectors.passwordMD5.expected)
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
        // The digest covers the *reversed* timestamp, so the token for ts=…002
        // is not the token for ts=…000. Value derived independently (hashlib).
        #expect(headers.clientToken == "1700000000002,b407eba694405ab44e9c4924d3d1f195")
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
        let hashOf: (String) -> String = { body in
            Signing.md5Hex(Array(Array(body.utf8).prefix(Signing.bodySignatureMaxBytes)))
        }
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
