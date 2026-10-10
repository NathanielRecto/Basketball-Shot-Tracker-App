// swift-tools-version: 6.0

import PackageDescription

// Platform-free logic shared with the Python research repo (no Apple frameworks), so `swift test`
// runs on Linux / WSL as well as on a Mac.
let package = Package(
    name: "ShotCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ShotCore", targets: ["ShotCore"]),
    ],
    targets: [
        .target(name: "ShotCore"),
        .testTarget(name: "ShotCoreTests", dependencies: ["ShotCore"]),
    ]
)
