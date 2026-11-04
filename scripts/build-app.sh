#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
flags=(--disable-sandbox --cache-path "${MINITILE_BUILD_CACHE:-$PWD/.build/cache}" --config-path .build/config --security-path .build/security)
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)
app="$PWD/build/Minitile.app"
mkdir -p "$app/Contents/MacOS"
# Copying over a signed binary in place makes macOS kill it at launch, so replace the files instead.
rm -f "$app/Contents/MacOS/minitile" build/mntl
cp "$bin/minitile" "$app/Contents/MacOS/minitile"
cp "$bin/mntl" build/mntl
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.github.fiorix.minitile</string>
    <key>CFBundleName</key><string>Minitile</string>
    <key>CFBundleExecutable</key><string>minitile</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppSleepDisabled</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${MINITILE_SIGN_IDENTITY:-Apple Development}" "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app" "$PWD/build/mntl"
