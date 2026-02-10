#!/bin/bash
set -e

# Verify that the VERSION file, Cargo.toml, and Xcode project all agree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')

if [ -z "$VERSION" ]; then
    echo "ERROR: VERSION file is empty"
    exit 1
fi

echo "Expected version: $VERSION"
FAIL=0

# Check Cargo.toml
CARGO_VERSION=$(grep '^version' "$PROJECT_ROOT/core/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ "$CARGO_VERSION" = "$VERSION" ]; then
    echo "  [OK] core/Cargo.toml: $CARGO_VERSION"
else
    echo "  [MISMATCH] core/Cargo.toml: $CARGO_VERSION (expected $VERSION)"
    FAIL=1
fi

# Check Xcode MARKETING_VERSION
XCODE_VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_ROOT/Profundum/Profundum.xcodeproj/project.pbxproj" | head -1 | sed 's/.*= *\(.*\);/\1/' | tr -d '[:space:]')
if [ "$XCODE_VERSION" = "$VERSION" ]; then
    echo "  [OK] Profundum MARKETING_VERSION: $XCODE_VERSION"
else
    echo "  [MISMATCH] Profundum MARKETING_VERSION: $XCODE_VERSION (expected $VERSION)"
    FAIL=1
fi

if [ $FAIL -ne 0 ]; then
    echo ""
    echo "Version mismatch detected. Run 'make version-sync' to fix."
    exit 1
fi

echo ""
echo "All versions consistent: $VERSION"
