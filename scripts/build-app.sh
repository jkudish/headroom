#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=".build/Headroom.app"
BUILD_VERSION="$(git rev-list --count HEAD)"
# Personal Apple Development: Joachim Kudish (XZYM397R6X), team K7RS6S7JX2.
# Override explicitly for another certificate or '-' for a local ad-hoc build.
# Fail if the selected identity is unavailable; never silently fall back.
SIGNING_IDENTITY="${HEADROOM_SIGNING_IDENTITY-2368502C79FF15509186BCC97AD27B3D7A2D1B26}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UsageMonitor" "$APP/Contents/MacOS/UsageMonitor"
ditto "$BIN/UsageMonitor_UsageMonitor.bundle" "$APP/Contents/Resources/UsageMonitor_UsageMonitor.bundle"
ICON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/headroom-icon.XXXXXX")"
trap 'rm -rf "$ICON_DIR"' EXIT
xcrun actool Assets/Headroom.icon --compile "$ICON_DIR" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon Headroom --output-partial-info-plist "$ICON_DIR/icon-info.plist"
cp "$ICON_DIR/Headroom.icns" "$ICON_DIR/Assets.car" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UsageMonitor</string>
<key>CFBundleIdentifier</key><string>dev.jkudish.usage-monitor-poc</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Headroom</string>
<key>CFBundleDisplayName</key><string>Headroom</string>
<key>CFBundleIconFile</key><string>Headroom.icns</string>
<key>CFBundleIconName</key><string>Headroom</string>
<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/UsageMonitor_UsageMonitor.bundle"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signing identity: $SIGNING_IDENTITY; not notarized)."
