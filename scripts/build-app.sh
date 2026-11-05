#!/bin/bash
# Build build/Minitile.app, with mntl inside it, and a copy of mntl at build/mntl.
#
# Environment:
#   MINITILE_SIGN_IDENTITY  signing identity (default "Apple Development"; "-" signs ad hoc)
#   MINITILE_CONFIGURATION  debug or release (default debug)
#   MINITILE_VERSION        CFBundleShortVersionString (default 0.0.0)
#   MINITILE_BUILD          CFBundleVersion (default 1)
#   MINITILE_HARDENED       1 signs with the hardened runtime and a secure timestamp, as notarization requires
#   MINITILE_CHANNEL        dev (default) or release; dev builds are "Minitile Dev" with their own bundle ID, so
#                           macOS keeps their privacy permissions apart from an installed release
set -euo pipefail
cd "$(dirname "$0")/.."

identity=${MINITILE_SIGN_IDENTITY:-Apple Development}
configuration=${MINITILE_CONFIGURATION:-debug}
version=${MINITILE_VERSION:-0.0.0}
build=${MINITILE_BUILD:-1}
case ${MINITILE_CHANNEL:-dev} in
    dev) bundle_id=app.minitile.dev name="Minitile Dev" ;;
    release) bundle_id=app.minitile name=Minitile ;;
    *) echo "MINITILE_CHANNEL must be dev or release" >&2; exit 2 ;;
esac

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
flags=(-c "$configuration" --disable-sandbox --cache-path "${MINITILE_BUILD_CACHE:-$PWD/.build/cache}" --config-path .build/config --security-path .build/security)
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)
app="$PWD/build/Minitile.app"
mkdir -p "$app/Contents/MacOS"
# Copying over a signed binary in place makes macOS kill it at launch, so replace the files instead.
rm -f "$app/Contents/MacOS/minitile" "$app/Contents/MacOS/mntl" build/mntl
cp "$bin/minitile" "$app/Contents/MacOS/minitile"
cp "$bin/mntl" "$app/Contents/MacOS/mntl"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>minitile</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppSleepDisabled</key><true/>
</dict></plist>
PLIST

sign=(codesign --force --sign "$identity")
if [ "${MINITILE_HARDENED:-}" = 1 ]; then sign+=(--options runtime --timestamp); fi
# Nested code is signed before the bundle that seals it.
"${sign[@]}" --identifier "$bundle_id.mntl" "$app/Contents/MacOS/mntl"
"${sign[@]}" "$app"
codesign --verify --strict --deep "$app"
cp "$app/Contents/MacOS/mntl" build/mntl
printf '%s\n' "$app" "$PWD/build/mntl"
