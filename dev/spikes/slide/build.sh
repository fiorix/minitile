#!/bin/sh
# Builds SlideSpike.app and signs it, so Screen Recording is granted to the
# bundle rather than to the terminal that launches it.
set -e
cd "$(dirname "$0")"
app=build/SlideSpike.app
mkdir -p "$app/Contents/MacOS"
clang -fobjc-arc -O1 -Wall -mmacosx-version-min=14.0 \
    -framework AppKit -framework QuartzCore -framework ScreenCaptureKit -framework CoreVideo \
    slide.m -o "$app/Contents/MacOS/SlideSpike"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.github.fiorix.minitile.slide-spike</string>
    <key>CFBundleExecutable</key><string>SlideSpike</string>
    <key>CFBundleName</key><string>SlideSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force --sign "${MINITILE_SIGN_IDENTITY:-Apple Development}" "$app"
