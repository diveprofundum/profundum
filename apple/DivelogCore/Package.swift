// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DivelogCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DivelogCore",
            targets: ["DivelogCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    ],
    targets: [
        // Binary target for the Rust FFI library
        .binaryTarget(
            name: "DivelogComputeFFI",
            path: "DivelogComputeFFI.xcframework"
        ),
        .target(
            name: "DivelogCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "DivelogComputeFFI",
            ],
            path: "Sources",
            exclude: ["RustBridge/README.md"]
        ),
        .testTarget(
            name: "DivelogCoreTests",
            dependencies: ["DivelogCore"],
            path: "Tests"
        ),
    ]
)
