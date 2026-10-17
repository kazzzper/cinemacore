import Foundation
@testable import CinemacoreCore

/// Loads `contracts/signing-vectors.json`, the fixture shared with the Go suite
/// (`core/sign/sign_test.go`).
///
/// The file is located by walking up from this source file rather than being
/// copied into the package as a resource: a copy is precisely the drift this
/// fixture exists to prevent.
enum SigningVectorFixture {

    enum Failure: Error, CustomStringConvertible {
        case notFound
        case unreadable(String)
        case malformed(String)

        var description: String {
            switch self {
            case .notFound:
                "contracts/signing-vectors.json not found above \(#filePath)"
            case .unreadable(let detail):
                "contracts/signing-vectors.json could not be read: \(detail)"
            case .malformed(let detail):
                "contracts/signing-vectors.json did not parse: \(detail)"
            }
        }
    }

    static func load(startingAt file: String = #filePath) throws -> SigningVectors {
        guard let url = locate(from: file) else { throw Failure.notFound }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        do {
            return try JSONDecoder().decode(SigningVectors.self, from: data)
        } catch {
            throw Failure.malformed(String(describing: error))
        }
    }

    /// Walks up from the test source looking for the fixture, so a package
    /// moved within the repo keeps working without a hard-coded depth.
    private static func locate(from file: String) -> URL? {
        var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("contracts/signing-vectors.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

/// The fixture's shape. Optional members mirror the JSON's optional fields.
struct SigningVectors: Decodable {
    struct ClientToken: Decodable {
        let tsMillis: Int64
        let token: String
    }

    struct TRCase: Decodable {
        let name: String
        let method: String
        let url: String
        let body: String?
        let bodyRepeatChar: String?
        let bodyRepeatCount: Int?
        let bodyAppend: String?
        let tsMillis: Int64
        let expected: String

        /// The 102400-byte truncation case is expressed as a repeat so the
        /// fixture does not carry a 100 KB literal.
        var resolvedBody: String {
            if let char = bodyRepeatChar, let count = bodyRepeatCount, count > 0 {
                return String(repeating: char, count: count) + (bodyAppend ?? "")
            }
            return body ?? ""
        }
    }

    struct Gslb: Decodable {
        let packageName: String
        let deviceID: String
        let expected: String
    }

    struct Password: Decodable {
        let input: String
        let expected: String
    }

    struct ResourceCase: Decodable {
        let input: String
        let expected: String
    }

    struct ResourceVectors: Decodable {
        let cases: [ResourceCase]
    }

    let gatewaySecretBase64: String
    let bodySignatureMaxBytes: Int
    let defaultAccept: String
    let defaultContentType: String
    let clientTokens: [ClientToken]
    let trSignatures: [TRCase]
    let gslbSign: Gslb
    let passwordMD5: Password
    let resourceVectors: ResourceVectors
}
