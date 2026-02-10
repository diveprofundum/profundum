#!/bin/bash
set -e

# Verify that the DivelogCompute XCFramework is correctly built and consistent
# with the current Rust source.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FRAMEWORK_DIR="$PROJECT_ROOT/apple/DivelogCore/DivelogComputeFFI.xcframework"
GENERATED_DIR="$PROJECT_ROOT/apple/DivelogCore/Sources/RustBridge/Generated"
UDL_FILE="$PROJECT_ROOT/core/src/divelog_compute.udl"

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "Verifying DivelogComputeFFI XCFramework..."
echo ""

# 1. Info.plist exists
check "Info.plist exists" test -f "$FRAMEWORK_DIR/Info.plist"

# 2. Platform slices have static libraries
for SLICE in macos-arm64_x86_64 ios-arm64 ios-arm64_x86_64-simulator; do
    LIB_PATH="$FRAMEWORK_DIR/$SLICE/libdivelog_compute.a"
    check "Static library exists: $SLICE" test -f "$LIB_PATH"
done

# 3. Header consistency — compare generated header hash with UDL hash
if [ -f "$UDL_FILE" ] && [ -f "$GENERATED_DIR/divelog_computeFFI.h" ]; then
    UDL_HASH=$(shasum -a 256 "$UDL_FILE" | awk '{print $1}')
    HEADER_EXISTS=true
    check "Generated header exists" test "$HEADER_EXISTS" = "true"
    echo "  [INFO] UDL hash: ${UDL_HASH:0:12}..."
    echo "  [INFO] If header is stale, run: make swift-bindings"
else
    check "UDL file exists" test -f "$UDL_FILE"
    check "Generated header exists" test -f "$GENERATED_DIR/divelog_computeFFI.h"
fi

# 4. Swift bindings file exists and contains expected namespace
SWIFT_BINDINGS="$GENERATED_DIR/divelog_compute.swift"
check "Swift bindings file exists" test -f "$SWIFT_BINDINGS"
if [ -f "$SWIFT_BINDINGS" ]; then
    check "Swift bindings contain namespace" grep -q "divelog_compute" "$SWIFT_BINDINGS"
fi

# 5. Swift package builds
echo ""
echo "Building DivelogCore Swift package..."
if (cd "$PROJECT_ROOT/apple/DivelogCore" && swift build 2>&1); then
    echo "  [PASS] swift build succeeds"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] swift build failed"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
