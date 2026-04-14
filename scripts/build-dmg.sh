#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/build-dmg.sh <version>
# Example: ./scripts/build-dmg.sh 1.0.7

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"
RELEASE_DIR="$BUILD_DIR/release"
STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_DIR="$STAGING_DIR/CodeBubble.app"
CONTENTS_DIR="$APP_DIR/Contents"
OUTPUT_DMG="$BUILD_DIR/CodeBubble.dmg"

echo "==> Building CodeBubble ${VERSION} (universal)"

# Build for both architectures
cd "$REPO_ROOT"
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM_DIR="$BUILD_DIR/arm64-apple-macosx/release"
X86_DIR="$BUILD_DIR/x86_64-apple-macosx/release"

echo "==> Assembling .app bundle"

# Clean and recreate staging
rm -rf "$STAGING_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
mkdir -p "$CONTENTS_DIR/Helpers"
mkdir -p "$CONTENTS_DIR/Resources"

# Create universal binaries
lipo -create "$ARM_DIR/CodeBubble" "$X86_DIR/CodeBubble" \
     -output "$CONTENTS_DIR/MacOS/CodeBubble"
lipo -create "$ARM_DIR/codebubble-bridge" "$X86_DIR/codebubble-bridge" \
     -output "$CONTENTS_DIR/Helpers/codebubble-bridge"

# Write Info.plist (use the root Info.plist as base, update version)
CURRENT_VER=$(defaults read "$REPO_ROOT/Info.plist" CFBundleShortVersionString)
sed -e "s/<string>${CURRENT_VER}<\/string>/<string>${VERSION}<\/string>/g" \
    "$REPO_ROOT/Info.plist" > "$CONTENTS_DIR/Info.plist"

# Compile app icon and asset catalog
xcrun actool \
    --output-format human-readable-text \
    --notices --warnings --errors \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist /dev/null \
    --compile "$CONTENTS_DIR/Resources" \
    "$REPO_ROOT/Assets.xcassets" \
    "$REPO_ROOT/AppIcon.icon"

# Copy AppIcon.icns (actool with .icon bundle may not produce .icns)
cp "$REPO_ROOT/Sources/CodeBubble/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

# Copy SPM resource bundles into Contents/Resources/ (required for code signing)
for bundle in "$BUILD_DIR"/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$CONTENTS_DIR/Resources/"
        break
    fi
done

echo "==> App bundle assembled at $APP_DIR"

# Ad-hoc sign with stable identifier so Accessibility persists across installs.
# For distribution, set SIGN_ID to a Developer ID certificate.
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -v "REVOKED" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi

if [ -n "$SIGN_ID" ]; then
    echo "==> Code signing ($SIGN_ID)"
    codesign --force --options runtime \
        --sign "$SIGN_ID" \
        --identifier "com.codebubble.bridge" \
        "$CONTENTS_DIR/Helpers/codebubble-bridge"
    codesign --force --options runtime \
        --sign "$SIGN_ID" \
        --identifier "com.codebubble.app" \
        --entitlements "$REPO_ROOT/CodeBubble.entitlements" \
        "$APP_DIR"
else
    echo "==> Ad-hoc signing (no certificate found)"
    codesign --force --sign - \
        --identifier "com.codebubble.bridge" \
        "$CONTENTS_DIR/Helpers/codebubble-bridge"
    codesign --force --sign - \
        --identifier "com.codebubble.app" \
        --entitlements "$REPO_ROOT/CodeBubble.entitlements" \
        "$APP_DIR"
fi

echo "==> Creating DMG"

# Remove previous DMG if exists
rm -f "$OUTPUT_DMG"

create-dmg \
    --volname "CodeBubble ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "CodeBubble.app" 175 190 \
    --hide-extension "CodeBubble.app" \
    --app-drop-link 425 190 \
    "$OUTPUT_DMG" \
    "$STAGING_DIR/"

# ---------------------------------------------------------------------------
# Notarization (uncomment after Developer ID signing)
# ---------------------------------------------------------------------------
# BUNDLE_ID="com.codebubble.app"
# APPLE_ID="your@apple.id"
# APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # app-specific password
#
# xcrun notarytool submit "$OUTPUT_DMG" \
#     --apple-id "$APPLE_ID" \
#     --password "$APP_PASSWORD" \
#     --team-id "$TEAM_ID" \
#     --wait
#
# xcrun stapler staple "$OUTPUT_DMG"
# ---------------------------------------------------------------------------

echo "==> Done: $OUTPUT_DMG"
