#!/bin/bash
# Packages wmp-ไทย.app into a DMG and notarizes it, so it can be handed to
# anyone without Gatekeeper blocking it.
#
# Needs, one time:
#   1. a "Developer ID Application" certificate in the keychain
#      (Apple Developer account > Certificates > Developer ID Application)
#   2. notarytool credentials:
#      xcrun notarytool store-credentials wmp-notary \
#          --apple-id <apple id> --team-id <team id> --password <app-specific password>
#
# Then: ./package_dmg.sh
set -euo pipefail

cd "$(dirname "$0")"
APP="wmp-ไทย.app"
DMG="wmp-ไทย.dmg"
KEYCHAIN_PROFILE="${1:-wmp-notary}"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "No 'Developer ID Application' certificate found."
    echo "An 'Apple Development' certificate is enough to run the app locally,"
    echo "but notarization requires a Developer ID one."
    exit 1
fi

./build_app.sh

echo "==> building $DMG"
rm -f "$DMG"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "wmp-ไทย" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> notarizing (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "done: $DMG"
