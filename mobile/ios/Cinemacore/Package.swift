// swift-tools-version: 6.4
import PackageDescription

// The app: SwiftUI only. Local builds go through xtool against the Darwin iOS
// SDK; releases build the checked-in `Cinemacore.xcodeproj`, whose app target
// compiles this target's sources and links it the same way.
//
// xtool requires exactly one library product, and that product is the app.
// Everything testable lives in the sibling `CinemacoreCore` package so it can
// run under `swift test` on the Linux host and under `xcodebuild test` on iOS.
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
