// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShotTracker",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "ShotTracker",
            targets: ["ShotTracker"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/ShotCore"),
    ],
    targets: [
        .target(
            name: "ShotTracker",
            dependencies: [.product(name: "ShotCore", package: "ShotCore")],
            // AVFoundation / Core ML delegates and callbacks are not Sendable-annotated yet.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
