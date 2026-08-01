#!/bin/zsh
# Builds Tally and assembles Tally.app in ./build
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Building (release)…"
swift build -c release

APP="build/Tally.app"
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp .build/release/Tally "$APP/Contents/MacOS/Tally"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
echo "  Run it with:  open $APP"
echo "  Install it:   cp -R $APP /Applications/"
