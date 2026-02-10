# UniFFI XCFramework Build Pipeline

This document explains how the Rust compute core is compiled into an XCFramework for use in the Swift DivelogCore package.

## Prerequisites

1. **Rust toolchain** (via rustup):
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

2. **Apple platform targets**:
   ```bash
   rustup target add aarch64-apple-darwin
   rustup target add x86_64-apple-darwin
   rustup target add aarch64-apple-ios
   rustup target add aarch64-apple-ios-sim
   rustup target add x86_64-apple-ios
   ```

3. **Xcode Command Line Tools** (for `xcodebuild`, `lipo`):
   ```bash
   xcode-select --install
   ```

4. **UniFFI CLI** (installed automatically via `cargo run --features=uniffi/cli`)

## How It Works

### Step 1: Build Static Libraries

`core/build-xcframework.sh` compiles the Rust crate for 5 targets:

| Target                      | Platform             |
|-----------------------------|----------------------|
| `aarch64-apple-darwin`      | macOS (Apple Silicon)|
| `x86_64-apple-darwin`       | macOS (Intel)        |
| `aarch64-apple-ios`         | iOS (device)         |
| `aarch64-apple-ios-sim`     | iOS Simulator (AS)   |
| `x86_64-apple-ios`          | iOS Simulator (Intel)|

### Step 2: Create Universal Binaries

`lipo` combines architecture-specific `.a` files into universal binaries:
- macOS: `arm64 + x86_64`
- iOS Simulator: `arm64 + x86_64`
- iOS device: `arm64` only

### Step 3: Package as XCFramework

`xcodebuild -create-xcframework` bundles the three platform slices with their C headers and modulemap into `DivelogComputeFFI.xcframework`.

### Step 4: Generate Swift Bindings

UniFFI reads `core/src/divelog_compute.udl` and generates:
- `divelog_computeFFI.h` — C header for the FFI interface
- `divelog_computeFFI.modulemap` — Clang module map
- `divelog_compute.swift` — Swift wrapper with type-safe API

These are written to `apple/DivelogCore/Sources/RustBridge/Generated/`.

## Common Commands

```bash
# Full rebuild (XCFramework + bindings)
make xcframework
make swift-bindings

# Run all tests
make test

# Verify the build
./scripts/verify-xcframework.sh

# Clean everything
make clean
```

## When to Rebuild

Rebuild the XCFramework when any of these change:
- Any `.rs` file in `core/src/`
- `core/Cargo.toml` (dependencies or features)
- `core/src/divelog_compute.udl` (FFI interface definition)

Regenerate Swift bindings when:
- `core/src/divelog_compute.udl` changes (new functions, types, or signatures)

## Troubleshooting

### Missing Rust targets
```
error[E0463]: can't find crate for `std`
```
Install the missing target: `rustup target add <target-triple>`

### Linker errors in Xcode
If Xcode reports undefined symbols from the Rust crate:
1. Verify the XCFramework was built: `ls apple/DivelogCore/DivelogComputeFFI.xcframework/`
2. Check that `Package.swift` references the XCFramework as a binary target
3. Rebuild: `make clean && make xcframework`

### Header mismatch
If Swift compilation fails with type mismatches after changing the UDL:
1. Regenerate bindings: `make swift-bindings`
2. Rebuild the XCFramework: `make xcframework`
3. Clean Xcode's derived data if needed

### Architecture mismatch
```
building for iOS Simulator, but linking in object file built for iOS
```
This means the wrong slice is being linked. Verify the XCFramework structure:
```bash
./scripts/verify-xcframework.sh
```
