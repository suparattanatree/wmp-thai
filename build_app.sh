#!/bin/bash
# Builds wmp-ไทย.app - a menu bar app bundle, ad-hoc signed so macOS keeps the
# Accessibility permission attached to it between launches.
set -euo pipefail

cd "$(dirname "$0")"
APP="wmp-ไทย.app"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
REPO="suparattanatree/wmp-thai"
FEED="https://raw.githubusercontent.com/$REPO/main/appcast.xml"
PUBLIC_KEY="PHXKGwqMCkSIbyTO2XE9xgesIyPr4ACaCFDsU4+q3Gs="
DEST="${1:-.}"
BUNDLE="$DEST/$APP"

echo "==> building release binary"
swift build -c release

BIN=$(swift build -c release --show-bin-path)

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/wmp" "$BUNDLE/Contents/MacOS/wmp"
# SwiftPM links with an rpath next to the executable; frameworks live one level
# up in a bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/wmp" 2>/dev/null || true
cp -R "$BIN/wmp_WmpCore.bundle" "$BUNDLE/Contents/Resources/"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
mkdir -p "$BUNDLE/Contents/Frameworks"
cp -R "$BIN/Sparkle.framework" "$BUNDLE/Contents/Frameworks/"

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
    <key>SUFeedURL</key><string>$FEED</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUAutomaticallyUpdate</key><false/>
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

[ -n "$IDENTITY" ] || echo "    no certificate found, using ad-hoc (permission resets on every rebuild)"
SIGN="${IDENTITY:--}"
[ -n "$IDENTITY" ] && echo "    identity: $IDENTITY"

# Nested code signs from the inside out; --deep is not enough for Sparkle.
SPARKLE="$BUNDLE/Contents/Frameworks/Sparkle.framework"
for target in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE"
do
    [ -e "$target" ] && codesign --force --options runtime --timestamp=none --sign "$SIGN" "$target"
done
codesign --force --options runtime --timestamp=none --sign "$SIGN" "$BUNDLE"

echo "done: $BUNDLE"
echo
echo "Next:"
echo "  1. mv \"$BUNDLE\" /Applications/"
echo "  2. open \"/Applications/$APP\""
echo "  3. System Settings > Privacy & Security > Accessibility, switch wmp-ไทย on"
echo "  4. quit from the menu bar and open it again"
