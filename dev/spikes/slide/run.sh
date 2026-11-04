#!/bin/sh
# Launches the signed bundle through LaunchServices, so macOS attributes Screen
# Recording to SlideSpike, then prints its log. SLIDE_* variables pass through.
set -e
cd "$(dirname "$0")"
binary=build/SlideSpike.app/Contents/MacOS/SlideSpike
if [ ! -x "$binary" ] || [ slide.m -nt "$binary" ]; then ./build.sh; fi
log="${TMPDIR:-/tmp/}slide-spike.log"
: > "$log"
set --
for name in SLIDE_MODE SLIDE_MS SLIDE_BOUNCE_MS SLIDE_COVER_MS SLIDE_WAIT_MS SLIDE_SCALE SLIDE_CURVE SLIDE_OVERLAP; do
    eval "value=\${$name:-}"
    [ -n "$value" ] && set -- "$@" --env "$name=$value"
done
open -n -W --stdout "$log" --stderr "$log" "$@" build/SlideSpike.app
cat "$log"
