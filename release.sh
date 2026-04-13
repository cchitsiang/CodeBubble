#!/usr/bin/env bash
set -euo pipefail

# CodeBubble release script
#
# Usage:
#   ./release.sh <version> [--dry-run]
#
# Example:
#   ./release.sh 1.0.0
#
# Steps:
#   1. Sanity checks (clean git, on main branch, tools installed)
#   2. Update version in Info.plist
#   3. Build universal DMG (arm64 + x86_64)
#   4. Strip quarantine, create git tag
#   5. Create GitHub release, attach DMG
#   6. Publishing the release auto-triggers the homebrew-tap workflow
#
# Prerequisites:
#   brew install create-dmg gh
#   gh auth login
#

VERSION="${1:-}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
    esac
done

if [[ -z "$VERSION" || "$VERSION" == --* ]]; then
    echo "Usage: $0 <version> [--dry-run]" >&2
    echo "Example: $0 1.0.0" >&2
    exit 1
fi

# Strip any leading 'v' from version
VERSION="${VERSION#v}"
TAG="v${VERSION}"
REPO="cchitsiang/CodeBubble"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DMG_PATH="$REPO_ROOT/.build/CodeBubble.dmg"
INFO_PLIST="$REPO_ROOT/Info.plist"

# ---- Pretty-print helpers ----
cyan()   { printf "\033[36m%s\033[0m\n" "$1"; }
green()  { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }
red()    { printf "\033[31m%s\033[0m\n" "$1" >&2; }

step()   { cyan "==> $1"; }

# ---- 1. Sanity checks ----
step "Sanity checks"

for tool in create-dmg gh swift lipo xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        red "Missing required tool: $tool"
        exit 1
    fi
done

GH_AUTH_OUTPUT=$(gh auth status 2>&1 || true)
if ! echo "$GH_AUTH_OUTPUT" | grep -q "Logged in"; then
    red "GitHub CLI not authenticated. Run: gh auth login"
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    red "Working tree has uncommitted changes. Commit or stash first."
    git status --short
    exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    yellow "Warning: not on main branch (currently on $CURRENT_BRANCH)"
    read -rp "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    red "Tag $TAG already exists. Delete with: git tag -d $TAG && git push --delete origin $TAG"
    exit 1
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    red "Release $TAG already exists on GitHub."
    exit 1
fi

green "✓ Sanity checks passed"

# ---- 2. Update version in Info.plist ----
step "Updating Info.plist to version $VERSION"

CURRENT_VER=$(defaults read "$INFO_PLIST" CFBundleShortVersionString)
if [[ "$CURRENT_VER" != "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"
    green "✓ Info.plist: $CURRENT_VER → $VERSION"
else
    green "✓ Info.plist already at $VERSION"
fi

# ---- 3. Build universal DMG ----
step "Building universal DMG"

if [[ "$DRY_RUN" == "true" ]]; then
    yellow "[dry-run] Would run: ./scripts/build-dmg.sh $VERSION"
else
    "$REPO_ROOT/scripts/build-dmg.sh" "$VERSION"
fi

if [[ "$DRY_RUN" != "true" && ! -f "$DMG_PATH" ]]; then
    red "DMG not found at $DMG_PATH after build"
    exit 1
fi

if [[ -f "$DMG_PATH" ]]; then
    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
    green "✓ DMG built: $DMG_SIZE"
    echo "  SHA256: $DMG_SHA"
fi

# ---- 4. Commit version bump + tag ----
step "Committing version bump and creating tag $TAG"

if [[ -n "$(git status --porcelain Info.plist 2>/dev/null || true)" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        yellow "[dry-run] Would commit Info.plist and tag $TAG"
    else
        git add Info.plist
        git commit -m "chore: bump version to $VERSION"
        git tag "$TAG"
        git push origin main
        git push origin "$TAG"
        green "✓ Pushed commit + tag"
    fi
else
    if [[ "$DRY_RUN" == "true" ]]; then
        yellow "[dry-run] Would create tag $TAG (no version change)"
    else
        git tag "$TAG"
        git push origin "$TAG"
        green "✓ Tag pushed (no version change)"
    fi
fi

# ---- 5. Create GitHub release with DMG attached ----
step "Creating GitHub release $TAG"

RELEASE_NOTES="## What's New

See the [commit log](https://github.com/${REPO}/compare/...${TAG}) for changes.

## Install

\`\`\`
brew install --cask cchitsiang/tap/codebubble
\`\`\`

Or download the DMG below.

> **Note:** On first launch, macOS may block the app since it's not notarized.
> Run \`xattr -cr /Applications/CodeBubble.app\` to clear the quarantine flag."

if [[ "$DRY_RUN" == "true" ]]; then
    yellow "[dry-run] Would run: gh release create $TAG $DMG_PATH --title 'CodeBubble $VERSION'"
else
    gh release create "$TAG" "$DMG_PATH" \
        --repo "$REPO" \
        --title "CodeBubble $VERSION" \
        --notes "$RELEASE_NOTES"
    green "✓ Release created: https://github.com/${REPO}/releases/tag/${TAG}"
fi

# ---- 6. Inform about workflow ----
step "Homebrew workflow"

if [[ "$DRY_RUN" == "true" ]]; then
    yellow "[dry-run] Publishing the release would trigger the homebrew-tap workflow"
else
    green "✓ The release workflow will auto-update cchitsiang/homebrew-tap"
    echo "  Monitor at: https://github.com/${REPO}/actions"
fi

green ""
green "🎉 Release $TAG complete!"
