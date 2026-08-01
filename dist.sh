#!/bin/zsh
# Builds a distributable Tally.app (universal), signs, packages, and
# optionally notarizes.
#
# Usage:
#   ./dist.sh                          ad-hoc signed zip + dmg (local/testing)
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./dist.sh
#                                      Developer ID signed, ready to notarize
#   DEVELOPER_ID="..." NOTARY_PROFILE=tally ./dist.sh
#                                      also notarizes + staples (see README)
#   DEVELOPER_ID="..." NOTARY_KEY_FILE=key.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=… ./dist.sh
#                                      notarizes with an App Store Connect
#                                      API key instead (what CI uses)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DIST="dist"
APP="$DIST/Tally.app"
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "▸ Building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/apple/Products/Release/Tally "$APP/Contents/MacOS/Tally"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "▸ Signing with Developer ID (hardened runtime)…"
    # Sparkle's nested helpers must be signed inside-out before the
    # framework, then the app (per Sparkle's non-Xcode signing docs).
    codesign -f -o runtime --timestamp -s "$DEVELOPER_ID" \
        "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    codesign -f -o runtime --timestamp --preserve-metadata=entitlements -s "$DEVELOPER_ID" \
        "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
    codesign -f -o runtime --timestamp -s "$DEVELOPER_ID" "$FRAMEWORK/Versions/B/Autoupdate"
    codesign -f -o runtime --timestamp -s "$DEVELOPER_ID" "$FRAMEWORK/Versions/B/Updater.app"
    codesign -f -o runtime --timestamp -s "$DEVELOPER_ID" "$FRAMEWORK"
    codesign -f -o runtime --timestamp -s "$DEVELOPER_ID" "$APP"
else
    echo "▸ No DEVELOPER_ID set — ad-hoc signing (won't pass Gatekeeper on other Macs)"
    codesign --force --deep --sign - "$FRAMEWORK"
    codesign --force --sign - "$APP"
fi

ZIP="$DIST/Tally-$VERSION.zip"
DMG="$DIST/Tally-$VERSION.dmg"

package() {
    ditto -c -k --keepParent "$APP" "$ZIP"
    local staging
    staging=$(mktemp -d)
    cp -R "$APP" "$staging/"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "Tally" -srcfolder "$staging" -ov -format UDZO "$DMG" > /dev/null
    rm -rf "$staging"
}

echo "▸ Packaging…"
package

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_FILE:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi

if [[ -n "${DEVELOPER_ID:-}" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
    echo "▸ Notarizing (this can take a few minutes)…"
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
    echo "▸ Stapling ticket to the app and rebuilding packages…"
    xcrun stapler staple "$APP"
    package
    xcrun stapler staple "$DMG" || true
    echo "✓ Notarized and stapled."
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "ℹ Signed but NOT notarized. To notarize:"
    echo "    xcrun notarytool store-credentials tally --apple-id you@example.com --team-id TEAMID"
    echo "    NOTARY_PROFILE=tally DEVELOPER_ID=\"$DEVELOPER_ID\" ./dist.sh"
fi

echo ""
echo "✓ Artifacts in $DIST/:"
ls -lh "$DIST" | tail -n +2
