#!/bin/bash
# Builds NotchViewer.app in the project root.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=NotchViewer.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchViewer "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NotchViewer</string>
<key>CFBundleIdentifier</key><string>dev.notchviewer.app</string>
<key>CFBundleExecutable</key><string>NotchViewer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connects to your remote Mac over VNC.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
