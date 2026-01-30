// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Divelog",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Divelog", targets: ["Divelog"])
    ],
    dependencies: [
        .package(path: "../../apple/DivelogCore"),
    ],
    targets: [
        .target(
            name: "Divelog",
            dependencies: ["DivelogCore"],
            path: "Sources"
        ),
    ]
)
