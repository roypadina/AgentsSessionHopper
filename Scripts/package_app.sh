#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentsSessionHopper"
BUNDLE_ID="com.padina.agents-session-hopper"
VERSION="0.1.2"
BUILD_NUMBER="2"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
# RELEASE=1: also zip the app into dist/AgentsSessionHopper.zip for GitHub Releases and the Homebrew cask.
RELEASE="${RELEASE:-}"

cd "$ROOT_DIR"

# Universal binaries (Apple Silicon + Intel). The output dir differs per build system, so ask SwiftPM for it.
BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}" --product AgentsSessionHopper
swift build "${BUILD_ARGS[@]}" --product sessionhopper
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Helpers" "$CONTENTS_DIR/Resources"

cp "$BIN_DIR/AgentsSessionHopper" "$CONTENTS_DIR/MacOS/$APP_NAME"
cp Assets/icons/menubar.png Assets/icons/menubar@2x.png "$CONTENTS_DIR/Resources/"
# The CLI lives in Helpers/, not MacOS/: the cask links it with a `binary` stanza.
cp "$BIN_DIR/sessionhopper" "$CONTENTS_DIR/Helpers/sessionhopper"
[[ -f Assets/icons/AppIcon.icns ]] && cp Assets/icons/AppIcon.icns "$CONTENTS_DIR/Resources/"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Roy Padina</string>
</dict>
</plist>
PLIST

chmod +x "$CONTENTS_DIR/MacOS/$APP_NAME" "$CONTENTS_DIR/Helpers/sessionhopper"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F '"' '/valid identities found/ { next } /".+"/ { print $2; exit }'
    )"
fi
SIGN="${SIGNING_IDENTITY:--}"
[[ "$SIGN" == "-" ]] && echo "note: no code-signing identity found; ad hoc signing" >&2
# Helper first, then the bundle (no --deep: it is deprecated and signs nested code in the wrong order).
codesign --force --sign "$SIGN" --identifier "$BUNDLE_ID.cli" "$CONTENTS_DIR/Helpers/sessionhopper"
codesign --force --sign "$SIGN" --identifier "$BUNDLE_ID" "$APP_DIR"

if [[ -n "$RELEASE" ]]; then
    ZIP="$DIST_DIR/$APP_NAME.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP"
    shasum -a 256 "$ZIP"
fi

echo "$APP_DIR"
