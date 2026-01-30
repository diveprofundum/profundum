// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Divelog",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Divelog", targets: ["Divelog"])
    ],
    dependencies: [
        .package(path: "../../apple/DivelogCore"),
    ],
    targets: [
        .executableTarget(
            name: "Divelog",
            dependencies: ["DivelogCore"],
            path: "Sources"
        ),
    ]
)
