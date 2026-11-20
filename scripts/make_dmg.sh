#!/bin/bash
# Builds NotchViewer.dmg (app + Applications shortcut, custom volume icon).
set -e
cd "$(dirname "$0")/.."
./scripts/build_app.sh
STAGE=$(mktemp -d)
cp -R NotchViewer.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true
rm -f NotchViewer.dmg
hdiutil create -volname "NotchViewer" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ NotchViewer.dmg >/dev/null
rm -rf "$STAGE"
echo "Built NotchViewer.dmg"
