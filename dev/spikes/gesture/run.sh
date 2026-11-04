#!/bin/sh
# Launches the signed bundle through LaunchServices, so macOS attributes
# Accessibility to GestureSpike, then prints its log. GESTURE_* variables pass through.
set -e
cd "$(dirname "$0")"
binary=build/GestureSpike.app/Contents/MacOS/GestureSpike
if [ ! -x "$binary" ] || [ gesture.m -nt "$binary" ]; then ./build.sh; fi
log="${TMPDIR:-/tmp/}gesture-spike.log"
: > "$log"
set --
for name in GESTURE_MODE GESTURE_SECONDS GESTURE_TYPES GESTURE_TAP; do
    eval "value=\${$name:-}"
    [ -n "$value" ] && set -- "$@" --env "$name=$value"
done
open -n -W --stdout "$log" --stderr "$log" "$@" build/GestureSpike.app
cat "$log"
