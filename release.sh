#!/bin/bash
# Cuts a release: bumps the version, builds, notarizes if possible, and publishes
# a GitHub release that the in-app update check reads.
#
#   ./release.sh 1.1.0
#
# Needs `gh` logged in. Notarization is skipped (with a warning) when there is no
# Developer ID certificate: the build still works on this Mac, but other people's
# Macs will refuse to open it.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: ./release.sh <version>   e.g. ./release.sh 1.1.0"
    exit 1
fi

APP="wmp-ไทย.app"
ZIP="wmp-thai-$VERSION.zip"

echo "$VERSION" > VERSION
git add VERSION
git commit -m "Release $VERSION" || true

./build_app.sh

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "==> notarizing"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-wmp-notary}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
else
    echo "!! no Developer ID certificate: skipping notarization"
    echo "!! this build runs here but Gatekeeper will block it on other Macs"
fi

echo "==> packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> publishing"
git tag "v$VERSION" -f
git push origin main --tags
gh release create "v$VERSION" "$ZIP" \
    --title "wmp-ไทย $VERSION" \
    --notes "ดาวน์โหลด ZIP แตกไฟล์แล้วลากเข้า /Applications จากนั้นเปิดสิทธิ์ Accessibility ให้"

echo "done: v$VERSION"
