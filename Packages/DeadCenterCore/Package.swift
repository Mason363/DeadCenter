// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeadCenterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DCModel", targets: ["DCModel"]),
        .library(name: "DCEngine", targets: ["DCEngine"]),
        .library(name: "DCIngest", targets: ["DCIngest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "DCModel"),
        .target(name: "DCEngine", dependencies: ["DCModel"]),
        .target(
            name: "DCIngest",
            dependencies: ["DCModel", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "DCEngineTests", dependencies: ["DCEngine"]),
        .testTarget(name: "DCIngestTests", dependencies: ["DCIngest"], resources: [.copy("Fixtures")]),
    ]
)
