#!/bin/bash
set -e

# Sync the VERSION file to all component manifests.
# Usage:
#   ./scripts/sync-version.sh          # sync current VERSION to all manifests
#   ./scripts/sync-version.sh 0.2.0    # set new version and sync everywhere

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -n "$1" ]; then
    echo "$1" > "$PROJECT_ROOT/VERSION"
    echo "Set VERSION to $1"
fi

VERSION=$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')

if [ -z "$VERSION" ]; then
    echo "ERROR: VERSION file is empty"
    exit 1
fi

echo "Syncing version $VERSION to all manifests..."

# Cargo.toml — update the version line in [package]
sed -i.bak "s/^version = \".*\"/version = \"$VERSION\"/" "$PROJECT_ROOT/core/Cargo.toml"
rm -f "$PROJECT_ROOT/core/Cargo.toml.bak"
echo "  Updated core/Cargo.toml"

# Xcode project — update MARKETING_VERSION
sed -i.bak "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/g" \
    "$PROJECT_ROOT/Profundum/Profundum.xcodeproj/project.pbxproj"
rm -f "$PROJECT_ROOT/Profundum/Profundum.xcodeproj/project.pbxproj.bak"
echo "  Updated Profundum MARKETING_VERSION"

echo ""
echo "Done. All manifests set to $VERSION"
echo "Run 'make version-check' to verify."
