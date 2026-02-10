// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// Conditionally include LibDivecomputerFFI if the xcframework has been built.
// Build it with: libdivecomputer/build-xcframework.sh
let packageDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let includeLibDivecomputer = FileManager.default.fileExists(
    atPath: packageDir + "/LibDivecomputerFFI.xcframework/Info.plist"
)

var targets: [Target] = [
    // Binary target for the Rust FFI library
    .binaryTarget(
        name: "DivelogComputeFFI",
        path: "DivelogComputeFFI.xcframework"
    ),
    // C helper for zlib/gzip decompression
    .target(
        name: "CZlibHelper",
        path: "Sources/CZlibHelper",
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("z")]
    ),
    .testTarget(
        name: "DivelogCoreTests",
        dependencies: ["DivelogCore"],
        path: "Tests"
    ),
]

var coreDepends: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    "DivelogComputeFFI",
    "CZlibHelper",
]

if includeLibDivecomputer {
    targets.append(.binaryTarget(
        name: "LibDivecomputerFFI",
        path: "LibDivecomputerFFI.xcframework"
    ))
    coreDepends.append("LibDivecomputerFFI")
}

targets.append(.target(
    name: "DivelogCore",
    dependencies: coreDepends,
    path: "Sources",
    exclude: ["RustBridge/README.md", "CZlibHelper"]
))

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
    targets: targets
)
