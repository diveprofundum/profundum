# Rust Bridge Integration

This directory contains the Swift interface to the Rust compute core.

## Current State

`DivelogCompute.swift` contains a Swift-native placeholder implementation of the compute functions. This allows the Swift package to build and be tested independently of the Rust layer.

## UniFFI Integration

To integrate the actual Rust compute core via UniFFI:

### 1. Generate Swift Bindings

```bash
cd ../../core
cargo build --release

# Generate Swift bindings
cargo run --bin uniffi-bindgen -- generate \
    --library target/release/libdivelog_compute.dylib \
    --language swift \
    --out-dir ../apple/DivelogCore/Sources/RustBridge/Generated
```

### 2. Build XCFramework

```bash
# For macOS
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

# Create universal binary
lipo -create \
    target/aarch64-apple-darwin/release/libdivelog_compute.dylib \
    target/x86_64-apple-darwin/release/libdivelog_compute.dylib \
    -output libdivelog_compute.dylib

# For iOS (requires iOS SDK)
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

# Package as XCFramework
xcodebuild -create-xcframework \
    -library libdivelog_compute_macos.a -headers include/ \
    -library libdivelog_compute_ios.a -headers include/ \
    -library libdivelog_compute_ios_sim.a -headers include/ \
    -output DivelogCompute.xcframework
```

### 3. Update Package.swift

Add the XCFramework as a binary target:

```swift
targets: [
    .binaryTarget(
        name: "DivelogComputeFFI",
        path: "DivelogCompute.xcframework"
    ),
    .target(
        name: "DivelogCore",
        dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            "DivelogComputeFFI",
        ],
        path: "Sources"
    ),
]
```

### 4. Replace Placeholder Implementation

Once the UniFFI-generated `divelog_compute.swift` is available, update `DivelogCompute.swift` to call through to the generated bindings:

```swift
import Foundation

// Import the UniFFI-generated module
import DivelogComputeFFI

public enum DivelogCompute {
    public static func validateFormula(_ expression: String) -> String? {
        return divelog_compute.validateFormula(expression)
    }

    public static func evaluateFormula(_ expression: String, variables: [String: Double]) throws -> Double {
        return try divelog_compute.evaluateFormula(expression, variables: variables)
    }

    // ... etc
}
```

## File Structure After Integration

```
RustBridge/
├── README.md              # This file
├── DivelogCompute.swift   # Public Swift API
└── Generated/             # UniFFI-generated files
    ├── divelog_compute.swift
    └── divelog_computeFFI.h
```

## Type Mapping

| Rust Type | Swift Type |
|-----------|------------|
| `DiveInput` | `DiveInput` (mirrored) |
| `SampleInput` | `SampleInput` (mirrored) |
| `DiveStats` | `DiveStats` (mirrored) |
| `SegmentStats` | `SegmentStats` (mirrored) |
| `FormulaError` | `FormulaError` (mirrored) |
| `HashMap<String, f64>` | `[String: Double]` |

The types are intentionally mirrored between Swift and Rust for clarity and type safety.
