// swift-tools-version: 6.4
import PackageDescription

// The app: SwiftUI only, built by xtool against the Darwin iOS SDK.
//
// xtool requires exactly one library product, and that product is the app.
// Everything testable lives in the sibling `CinemacoreCore` package so it can
// run under `swift test` on the Linux host.
let package = Package(
    name: "Cinemacore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Cinemacore", targets: ["Cinemacore"]),
    ],
    dependencies: [
        .package(path: "../CinemacoreCore"),
    ],
    targets: [
        .target(
            name: "Cinemacore",
            dependencies: [
                .product(name: "CinemacoreCore", package: "CinemacoreCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
