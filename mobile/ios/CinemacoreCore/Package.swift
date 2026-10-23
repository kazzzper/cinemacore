// swift-tools-version: 6.4
import PackageDescription

// Pure Foundation — no SwiftUI, no UIKit.
//
// There is no iOS Simulator on Linux, so every rule that can be checked without
// a screen lives here and is covered by `swift test` on the host. Keeping this a
// separate package (rather than a sibling target) makes the boundary real: this
// package cannot import SwiftUI even by accident, and `swift test` never has to
// build the app target.
//
// `swift-crypto` is Apple's own cross-platform build of CryptoKit and exposes
// the identical API on Linux, so the signing contract has exactly one
// implementation on both surfaces (`CryptoKit` is not importable on Linux).
let package = Package(
    name: "CinemacoreCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CinemacoreCore", targets: ["CinemacoreCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        // The progressive download server is a real HTTP/1.1 server on
        // loopback; NIO is the project's approved server stack and keeps the
        // range/parser behavior testable on Linux.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "CinemacoreCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "CinemacoreCoreTests", dependencies: ["CinemacoreCore"]),
    ],
    swiftLanguageModes: [.v6]
)
