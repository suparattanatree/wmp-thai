#!/bin/bash
# Regenerates AppIcon.icns from Tools/make_icon.swift
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d)
swiftc -O Tools/make_icon.swift -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD"
mkdir -p Resources
iconutil -c icns "$BUILD/wmp.iconset" -o Resources/AppIcon.icns
cp "$BUILD/wmp.iconset/icon_512x512.png" "$BUILD/preview.png" 2>/dev/null || true
echo "preview: $BUILD/preview.png"
echo "wrote Resources/AppIcon.icns"
