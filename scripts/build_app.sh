#!/bin/bash
# Builds NotchViewer.app in the project root.
set -e
cd "$(dirname "$0")/.."
PRODUCT="NotchViewer"
BUNDLE_ID="dev.notchviewer.app"
swift build -c release
APP="$PRODUCT.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp ".build/release/$PRODUCT" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$PRODUCT</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$PRODUCT</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.2.0</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connects to your remote Mac over VNC.</string>
</dict></plist>
PLIST
# A stable signing identity keeps Keychain access ("Always Allow") across rebuilds.
IDENTITY="${NOTCHVIEWER_SIGN_ID:-NotchViewer Local Signing}"
if ! codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "note: signed ad-hoc (no '$IDENTITY' identity); Keychain may re-prompt after each rebuild"
fi
echo "Built $APP"
