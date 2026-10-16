#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=".build/Headroom.app"
# Personal Apple Development: Joachim Kudish (XZYM397R6X), team K7RS6S7JX2.
# Fail if this certificate is unavailable; never silently change to an ad-hoc identity.
SIGNING_IDENTITY="2368502C79FF15509186BCC97AD27B3D7A2D1B26"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UsageMonitor" "$APP/Contents/MacOS/UsageMonitor"
ditto "$BIN/UsageMonitor_UsageMonitor.bundle" "$APP/Contents/Resources/UsageMonitor_UsageMonitor.bundle"
ICON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headroom-icon.XXXXXX")"
trap 'rm -rf "$ICON_DIR"' EXIT
ICONSET="$ICON_DIR/Headroom.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Sources/UsageMonitor/Resources/headroom-icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Sources/UsageMonitor/Resources/headroom-icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Headroom.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UsageMonitor</string>
<key>CFBundleIdentifier</key><string>dev.jkudish.usage-monitor-poc</string>
<key>CFBundleName</key><string>Headroom</string>
<key>CFBundleDisplayName</key><string>Headroom</string>
<key>CFBundleIconFile</key><string>Headroom.icns</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/UsageMonitor_UsageMonitor.bundle"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (personal Apple Development signature; not notarized)."
