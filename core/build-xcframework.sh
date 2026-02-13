#!/bin/bash
set -e

# Build script for DivelogCompute XCFramework
# Produces a universal XCFramework for macOS, iOS, and iOS Simulator

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FRAMEWORK_NAME="DivelogComputeFFI"
BUILD_DIR="$SCRIPT_DIR/target"
XCFRAMEWORK_DIR="$PROJECT_ROOT/apple/DivelogCore"

echo "Building DivelogCompute for all Apple platforms..."

# Build for macOS (arm64)
echo "Building for macOS arm64..."
cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml" --release --target aarch64-apple-darwin

# Build for macOS (x86_64)
echo "Building for macOS x86_64..."
cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml" --release --target x86_64-apple-darwin

# Build for iOS (arm64)
echo "Building for iOS arm64..."
cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml" --release --target aarch64-apple-ios

# Build for iOS Simulator (arm64)
echo "Building for iOS Simulator arm64..."
cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml" --release --target aarch64-apple-ios-sim

# Build for iOS Simulator (x86_64)
echo "Building for iOS Simulator x86_64..."
cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml" --release --target x86_64-apple-ios

# Create output directories
MACOS_DIR="$BUILD_DIR/macos-universal"
IOS_DIR="$BUILD_DIR/ios-arm64"
SIM_DIR="$BUILD_DIR/ios-simulator-universal"

rm -rf "$MACOS_DIR" "$IOS_DIR" "$SIM_DIR"
mkdir -p "$MACOS_DIR" "$IOS_DIR" "$SIM_DIR"

# Create universal macOS binary
echo "Creating universal macOS binary..."
lipo -create \
    "$BUILD_DIR/aarch64-apple-darwin/release/libdivelog_compute.a" \
    "$BUILD_DIR/x86_64-apple-darwin/release/libdivelog_compute.a" \
    -output "$MACOS_DIR/libdivelog_compute.a"

# Copy iOS binary
cp "$BUILD_DIR/aarch64-apple-ios/release/libdivelog_compute.a" "$IOS_DIR/"

# Create universal iOS Simulator binary
echo "Creating universal iOS Simulator binary..."
lipo -create \
    "$BUILD_DIR/aarch64-apple-ios-sim/release/libdivelog_compute.a" \
    "$BUILD_DIR/x86_64-apple-ios/release/libdivelog_compute.a" \
    -output "$SIM_DIR/libdivelog_compute.a"

# Generate UniFFI bindings (Swift source + C header + modulemap)
GENERATED_DIR="$PROJECT_ROOT/apple/DivelogCore/Sources/RustBridge/Generated"
mkdir -p "$GENERATED_DIR"
cargo run --manifest-path "$SCRIPT_DIR/Cargo.toml" --features=uniffi/cli \
    --bin uniffi-bindgen generate "$SCRIPT_DIR/src/divelog_compute.udl" \
    --language swift \
    --out-dir "$GENERATED_DIR"

# Create include directories with headers
for DIR in "$MACOS_DIR" "$IOS_DIR" "$SIM_DIR"; do
    mkdir -p "$DIR/include"
    cp "$GENERATED_DIR/divelog_computeFFI.h" "$DIR/include/"
    cp "$GENERATED_DIR/divelog_computeFFI.modulemap" "$DIR/include/module.modulemap"
done

# Remove old XCFramework if it exists
rm -rf "$XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework"

# Create XCFramework
echo "Creating XCFramework..."
xcodebuild -create-xcframework \
    -library "$MACOS_DIR/libdivelog_compute.a" \
    -headers "$MACOS_DIR/include" \
    -library "$IOS_DIR/libdivelog_compute.a" \
    -headers "$IOS_DIR/include" \
    -library "$SIM_DIR/libdivelog_compute.a" \
    -headers "$SIM_DIR/include" \
    -output "$XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework"

echo "XCFramework created at: $XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework"

# Show the structure
echo ""
echo "XCFramework structure:"
ls -la "$XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework/"
