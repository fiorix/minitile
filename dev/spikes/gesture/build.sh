#!/bin/sh
# Builds GestureSpike.app and signs it, so Accessibility is granted to the
# bundle rather than to the terminal that launches it.
set -e
cd "$(dirname "$0")"
app=build/GestureSpike.app
mkdir -p "$app/Contents/MacOS"
rm -f "$app/Contents/MacOS/GestureSpike"
clang -fobjc-arc -O1 -Wall -mmacosx-version-min=14.0 -framework AppKit -framework ApplicationServices \
    gesture.m -o "$app/Contents/MacOS/GestureSpike"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.github.fiorix.minitile.gesture-spike</string>
    <key>CFBundleExecutable</key><string>GestureSpike</string>
    <key>CFBundleName</key><string>GestureSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "${MINITILE_SIGN_IDENTITY:-Apple Development}" "$app"
