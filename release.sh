#!/bin/bash
# Cuts a release: builds, packages, signs the update, publishes it to GitHub and
# updates the appcast Sparkle reads.
#
#   ./release.sh 0.0.2
#
# Needs gh logged in and the Sparkle signing key in the keychain (generate_keys).
# Notarization runs when a Developer ID certificate is present; without one the
# build works on this Mac but Gatekeeper blocks it elsewhere.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh <version>"
    exit 1
fi

APP="wmp-ไทย.app"
ZIP="wmp-thai-$VERSION.zip"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

echo "$VERSION" > VERSION
./build_app.sh

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "==> notarizing"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-wmp-notary}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    NOTES="Download the zip, unpack it, move the app to /Applications, then grant Accessibility access."
    PRERELEASE=""
else
    echo "!! no Developer ID certificate: skipping notarization"
    echo "!! Gatekeeper will block this build on other Macs"
    NOTES="Not notarized yet. On first launch macOS will refuse to open it: go to System Settings, Privacy and Security, and press Open Anyway near the bottom. Only needed once.

Move the app to /Applications, open it, then grant Accessibility access in System Settings under Privacy and Security. It starts working as soon as permission is given."
    PRERELEASE=""
fi

echo "==> packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> signing the update"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")
DATE=$(date -R)
URL="https://github.com/suparattanatree/wmp-thai/releases/download/v$VERSION/$ZIP"

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>wmp-ไทย</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

echo "==> publishing"
git add VERSION appcast.xml
git commit -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push origin main
git push -f origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "$VERSION" --notes "$NOTES" $PRERELEASE

echo "done: v$VERSION"
