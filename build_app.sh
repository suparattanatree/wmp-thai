#!/bin/bash
# Builds wmp-ไทย.app - a menu bar app bundle, ad-hoc signed so macOS keeps the
# Accessibility permission attached to it between launches.
set -euo pipefail

cd "$(dirname "$0")"
APP="wmp-ไทย.app"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
REPO="suparattanatree/wmp-thai"
DEST="${1:-.}"
BUNDLE="$DEST/$APP"

echo "==> building release binary"
swift build -c release

BIN=$(swift build -c release --show-bin-path)

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/wmp" "$BUNDLE/Contents/MacOS/wmp"
cp -R "$BIN/wmp_WmpCore.bundle" "$BUNDLE/Contents/Resources/"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>wmp-ไทย</string>
    <key>CFBundleDisplayName</key><string>wmp-ไทย</string>
    <key>CFBundleExecutable</key><string>wmp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>me.xaou.wmpthai</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>WMPUpdateRepository</key><string>$REPO</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>local build</string>
</dict>
</plist>
PLIST

echo "==> signing"
# A real certificate gives the app a stable identity, so macOS keeps the
# Accessibility permission across rebuilds. Ad-hoc signatures change with every
# build, which is why the permission had to be granted again each time.
IDENTITY=$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"' || true)
fi

if [ -n "$IDENTITY" ]; then
    echo "    identity: $IDENTITY"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$BUNDLE"
else
    echo "    no certificate found, using ad-hoc"
    echo "    (Accessibility permission resets on every rebuild)"
    codesign --force --deep --sign - "$BUNDLE"
fi

echo "done: $BUNDLE"
echo
echo "Next:"
echo "  1. mv \"$BUNDLE\" /Applications/"
echo "  2. open \"/Applications/$APP\""
echo "  3. System Settings > Privacy & Security > Accessibility, switch wmp-ไทย on"
echo "  4. quit from the menu bar and open it again"
