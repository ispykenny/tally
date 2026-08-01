#!/bin/zsh
# Cuts a Tally release: bumps the version, commits, tags v<version>, and
# pushes. GitHub Actions (.github/workflows/release.yml) takes it from
# there — building, signing, notarizing, and publishing the GitHub
# Release with the dmg, zip, and Sparkle appcast attached.
#
# Usage: ./release.sh 1.1
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.1}"
TAG="v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ Uncommitted changes — commit or stash first." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    echo "✗ Tag $TAG already exists." >&2
    exit 1
fi

echo "▸ Setting version $VERSION in Info.plist…"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Resources/Info.plist
# Build number = commit count (incl. the release commit below):
# monotonically increasing with no bookkeeping, and Sparkle compares it
# to decide whether an update is newer.
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(($(git rev-list --count HEAD) + 1))" Resources/Info.plist

git add Resources/Info.plist
git commit -m "Release $VERSION"
git tag -a "$TAG" -m "Tally $VERSION"
git push origin HEAD "$TAG"

echo "✓ Pushed $TAG — GitHub Actions is building and publishing the release."
echo "  Watch it:  gh run watch"
