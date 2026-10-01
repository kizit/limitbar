#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${APP_PATH:-LimitBar.app}"
CACHE="$(mktemp -d "${TMPDIR:-/tmp}/limitbar-swift-cache.XXXXXX")"
trap 'rm -rf "$CACHE"' EXIT
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$CACHE" Source/main.swift -o "$APP/Contents/MacOS/LimitBar" -framework AppKit -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LimitBar</string>
<key>CFBundleIdentifier</key><string>com.kizit.limitbar</string>
<key>CFBundleName</key><string>LimitBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
