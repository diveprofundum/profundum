#!/bin/bash
set -euo pipefail

# Build script for LibDivecomputerFFI XCFramework
# Produces a universal XCFramework for macOS, iOS, and iOS Simulator
#
# Prerequisites:
#   brew install autoconf automake libtool
#   git submodule update --init (to populate libdivecomputer/src/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FRAMEWORK_NAME="LibDivecomputerFFI"
SRC_DIR="$SCRIPT_DIR/src"
BUILD_DIR="$SCRIPT_DIR/build"
INCLUDE_DIR="$SCRIPT_DIR/include"
XCFRAMEWORK_DIR="$PROJECT_ROOT/apple/DivelogCore"

# Homebrew libtool (glibtoolize) must be on PATH for autoreconf
export PATH="/opt/homebrew/opt/libtool/libexec/gnubin:$PATH"

# Verify source exists
if [ ! -f "$SRC_DIR/configure.ac" ]; then
    echo "Error: libdivecomputer source not found at $SRC_DIR"
    echo "Run: git submodule update --init"
    exit 1
fi

echo "Building libdivecomputer for all Apple platforms..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Generate configure script if needed
pushd "$SRC_DIR" > /dev/null
if [ ! -f configure ]; then
    echo "Running autoreconf..."
    autoreconf --install
fi
popd > /dev/null

# Build for a single target using out-of-tree builds
# Usage: build_target <arch> <host-triple> <sdk> <output-dir> <min-version-flag>
build_target() {
    local ARCH="$1"
    local HOST="$2"
    local SDK="$3"
    local OUTPUT="$4"
    local MIN_VERSION_FLAG="$5"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    local CC
    CC=$(xcrun --sdk "$SDK" --find clang)

    local CFLAGS="-arch $ARCH -isysroot $SDK_PATH $MIN_VERSION_FLAG"
    local LDFLAGS="-arch $ARCH -isysroot $SDK_PATH $MIN_VERSION_FLAG"

    # Out-of-tree build directory (avoids conflicts between targets)
    local BUILD_SUBDIR="$BUILD_DIR/_build_${ARCH}_${SDK}"
    rm -rf "$BUILD_SUBDIR"
    mkdir -p "$BUILD_SUBDIR"
    mkdir -p "$OUTPUT"

    echo "  Building for $ARCH ($SDK)..."

    pushd "$BUILD_SUBDIR" > /dev/null

    "$SRC_DIR/configure" \
        --host="$HOST" \
        --prefix="$OUTPUT" \
        --disable-shared \
        --enable-static \
        --disable-examples \
        --disable-doc \
        CC="$CC" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        > "$OUTPUT/configure.log" 2>&1

    make -j"$(sysctl -n hw.ncpu)" > "$OUTPUT/make.log" 2>&1
    make install > "$OUTPUT/install.log" 2>&1

    popd > /dev/null
}

# --- macOS ---
echo "Building for macOS..."
build_target "arm64" "aarch64-apple-darwin" "macosx" \
    "$BUILD_DIR/macos-arm64" "-mmacosx-version-min=13.0"
build_target "x86_64" "x86_64-apple-darwin" "macosx" \
    "$BUILD_DIR/macos-x86_64" "-mmacosx-version-min=13.0"

# --- iOS ---
echo "Building for iOS..."
build_target "arm64" "aarch64-apple-darwin" "iphoneos" \
    "$BUILD_DIR/ios-arm64" "-miphoneos-version-min=16.0"

# --- iOS Simulator ---
echo "Building for iOS Simulator..."
build_target "arm64" "aarch64-apple-darwin" "iphonesimulator" \
    "$BUILD_DIR/sim-arm64" "-mios-simulator-version-min=16.0"
build_target "x86_64" "x86_64-apple-darwin" "iphonesimulator" \
    "$BUILD_DIR/sim-x86_64" "-mios-simulator-version-min=16.0"

# --- Create universal binaries ---
echo "Creating universal binaries..."

MACOS_UNIVERSAL="$BUILD_DIR/macos-universal"
SIM_UNIVERSAL="$BUILD_DIR/sim-universal"
mkdir -p "$MACOS_UNIVERSAL/lib" "$SIM_UNIVERSAL/lib"

lipo -create \
    "$BUILD_DIR/macos-arm64/lib/libdivecomputer.a" \
    "$BUILD_DIR/macos-x86_64/lib/libdivecomputer.a" \
    -output "$MACOS_UNIVERSAL/lib/libdivecomputer.a"

lipo -create \
    "$BUILD_DIR/sim-arm64/lib/libdivecomputer.a" \
    "$BUILD_DIR/sim-x86_64/lib/libdivecomputer.a" \
    -output "$SIM_UNIVERSAL/lib/libdivecomputer.a"

# --- Prepare headers ---
echo "Preparing headers..."

# Use headers from one of the builds (they're identical across platforms)
HEADER_SRC="$BUILD_DIR/macos-arm64/include/libdivecomputer"

for DIR in "$MACOS_UNIVERSAL" "$BUILD_DIR/ios-arm64" "$SIM_UNIVERSAL"; do
    # module.modulemap + umbrella header go inside LibDivecomputerFFI/
    # to avoid collision with DivelogComputeFFI.xcframework's module.modulemap.
    # libdivecomputer/ headers stay at include/ root so <libdivecomputer/common.h> resolves.
    mkdir -p "$DIR/include/LibDivecomputerFFI"
    cp "$INCLUDE_DIR/LibDivecomputerFFI.h" "$DIR/include/LibDivecomputerFFI/"
    cp "$INCLUDE_DIR/module.modulemap" "$DIR/include/LibDivecomputerFFI/"
    if [ -d "$HEADER_SRC" ]; then
        cp -r "$HEADER_SRC" "$DIR/include/libdivecomputer"
    fi
done

# --- Create XCFramework ---
echo "Creating XCFramework..."
rm -rf "$XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework"

xcodebuild -create-xcframework \
    -library "$MACOS_UNIVERSAL/lib/libdivecomputer.a" \
    -headers "$MACOS_UNIVERSAL/include" \
    -library "$BUILD_DIR/ios-arm64/lib/libdivecomputer.a" \
    -headers "$BUILD_DIR/ios-arm64/include" \
    -library "$SIM_UNIVERSAL/lib/libdivecomputer.a" \
    -headers "$SIM_UNIVERSAL/include" \
    -output "$XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework"

echo ""
echo "XCFramework created at: $XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework"
echo ""
echo "XCFramework structure:"
ls -la "$XCFRAMEWORK_DIR/$FRAMEWORK_NAME.xcframework/"
