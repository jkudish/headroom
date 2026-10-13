#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=".build/UsageMonitor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UsageMonitor" "$APP/Contents/MacOS/UsageMonitor"
ditto "$BIN/UsageMonitor_UsageMonitor.bundle" "$APP/Contents/Resources/UsageMonitor_UsageMonitor.bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UsageMonitor</string>
<key>CFBundleIdentifier</key><string>dev.jkudish.usage-monitor-poc</string>
<key>CFBundleName</key><string>Usage Monitor</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/UsageMonitor_UsageMonitor.bundle"
codesign --force --sign - "$APP"
echo "Built $APP (local ad-hoc signature; not notarized)."
