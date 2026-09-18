#!/bin/bash
# Assemble build/FunkyShadow.app from the SwiftPM release build.
#   SIGN_ID="My Codesign Cert" Scripts/bundle.sh   # stable identity (no Keychain re-prompts)
#   Scripts/bundle.sh                               # ad-hoc signature
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/FunkyShadow.app"
BUNDLE_ID="dev.caramelfur.funkyshadow"
RES_BUNDLE="FunkyShadow_FunkyShadowUI.bundle"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FunkyShadow" "$APP/Contents/MacOS/FunkyShadow"
cp -R "$BIN/$RES_BUNDLE" "$APP/Contents/Resources/$RES_BUNDLE"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign "${SIGN_ID:--}" --identifier "$BUNDLE_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)' || true

# Register with Launch Services so tech.shadow:// can be delivered to us. This
# does not change the default handler; the app claims it only during login.
"$LSREGISTER" -f "$APP"

echo "built $APP"
