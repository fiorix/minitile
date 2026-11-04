#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
interactive=0
display_test=0
activation_test=0
build=1
recovery_directory=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --interactive) interactive=1 ;;
        --displays) display_test=1 ;;
        --activation) activation_test=1 ;;
        --no-build) build=0 ;;
        --cleanup)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo '--cleanup requires a test directory.' >&2; exit 2; fi
            recovery_directory=$2
            shift
            ;;
        --help|-h) echo 'Usage: smoke.sh [--interactive | --displays | --activation | --cleanup TEST_DIRECTORY] [--no-build]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$activation_test" = 1 ] && { [ "$interactive" = 1 ] || [ "$display_test" = 1 ] || [ -n "$recovery_directory" ]; }; then
    echo '--activation cannot be combined with --interactive, --displays or --cleanup.' >&2
    exit 2
fi
if [ "$display_test" = 1 ] && { [ "$interactive" = 1 ] || [ -n "$recovery_directory" ]; }; then
    echo '--displays cannot be combined with --interactive or --cleanup.' >&2
    exit 2
fi
if [ -n "$recovery_directory" ]; then
    if [ "$interactive" = 1 ]; then echo '--cleanup cannot be combined with --interactive.' >&2; exit 2; fi
    task_tmp=$(cd "${TMPDIR:-/tmp}" && pwd -P)
    recovery_directory=$(cd "$recovery_directory" && pwd -P)
    if [ "$(dirname "$recovery_directory")" != "$task_tmp" ] ||
        [[ $(basename "$recovery_directory") != minitile-smoke.* ]] ||
        [ ! -f "$recovery_directory/minitile.toml" ] || [ ! -f "$recovery_directory/state.json" ]; then
        echo '--cleanup accepts only a saved minitile-smoke directory directly inside TMPDIR.' >&2
        exit 2
    fi
fi
if { [ "$interactive" = 1 ] || [ "$display_test" = 1 ]; } && [ ! -t 0 ]; then
    echo "Interactive checks require a Terminal." >&2
    exit 2
fi
command -v jq >/dev/null
if pgrep -x minitile >/dev/null; then
    echo "Stop the existing minitile instance before the smoke test." >&2
    exit 1
fi
if [ "$build" = 1 ]; then
    scripts/build-app.sh
    swiftc -module-cache-path "$PWD/.build/clang-cache" scripts/smoke-support.swift -o build/smoke-support
else
    for executable in build/Minitile.app/Contents/MacOS/minitile build/mntl build/smoke-support; do
        if [ ! -x "$executable" ]; then echo 'Build first by omitting --no-build.' >&2; exit 1; fi
    done
    codesign --verify --strict build/Minitile.app
fi

if [ -n "$recovery_directory" ]; then
    testdir=$recovery_directory
else
    testdir=$(mktemp -d "${TMPDIR:-/tmp/}minitile-smoke.XXXXXX")
fi
prefix=$(basename "$testdir")
report="$PWD/build/smoke-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$report"
export MINITILE_CONFIG="$testdir/minitile.toml"
export MINITILE_STATE="$testdir/state.json"
export MINITILE_SOCKET="$testdir/socket"
export MINITILE_SMOKE_DIRECTORY="$testdir"
export MINITILE_SMOKE_WINDOWS=""
export MINITILE_TRACE_KEYS="$interactive"
if [ -n "$recovery_directory" ]; then
    # SavedState encodes UInt32 dictionary keys as alternating IDs and values.
    # Keep the original IDs if startup cannot rediscover every saved window.
    if [ ! -f "$testdir/cleanup-original-state.json" ]; then
        cp "$MINITILE_STATE" "$testdir/cleanup-original-state.json"
    fi
    MINITILE_SMOKE_WINDOWS=$(jq -r --arg prefix "$prefix" '
        [.windows[] | select(type == "object") | .info |
         select(.bundleID == "com.apple.TextEdit" and (.title | contains($prefix))) |
         "\(.id):\(.pid)"] | join(",")' "$testdir/cleanup-original-state.json")
fi
front_pid=$(build/smoke-support front)
textedit_was_running=0
if pgrep -x TextEdit >/dev/null; then textedit_was_running=1; fi
app_pid=""
textedit_pid=""
cleaning=0
documents_opened=0
if [ -n "$recovery_directory" ]; then documents_opened=1; fi
watch_pid=""
mntl="$PWD/build/mntl"

cleanup() {
    local result=$?
    if [ "$cleaning" = 1 ]; then return; fi
    cleaning=1
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null; fi
    local remaining=$documents_opened ids=""
    if "$mntl" --json state > "$report/cleanup-state.json" 2>/dev/null; then
        ids=$(jq -r --arg prefix "$prefix" '.windows[] | select(.bundle_id == "com.apple.TextEdit" and (.title | contains($prefix))) | .id' "$report/cleanup-state.json")
        for id in $ids; do
            if ! wait_active; then break; fi
            "$mntl" window show "$id" >/dev/null
            if ! wait_active; then break; fi
            "$mntl" window close "$id" >/dev/null
        done
        for ((attempt=0; attempt<40; attempt++)); do
            remaining=$("$mntl" --json state 2>/dev/null | jq '.windows | length')
            if [ "$remaining" = 0 ] && [ -n "$recovery_directory" ]; then
                if "$mntl" --json debug windows > "$report/cleanup-windows.json"; then
                    remaining=$(jq --arg pairs "$MINITILE_SMOKE_WINDOWS" --arg prefix "$prefix" '
                        ($pairs | split(",")) as $known |
                        [.[] | . as $window |
                         select(.bundleID == "com.apple.TextEdit" and
                           ((.title | contains($prefix)) or
                            ($known | index("\($window.id):\($window.pid)") != null)))] | length
                        ' "$report/cleanup-windows.json")
                else
                    remaining=1
                fi
            fi
            if [ "$remaining" = 0 ]; then break; fi
            sleep 0.1
        done
        "$mntl" --json debug spaces > "$report/final-spaces.json"
        "$mntl" --json debug timings > "$report/timings.json"
        "$mntl" quit >/dev/null
    elif [ -n "$app_pid" ]; then
        if [ "$documents_opened" = 0 ]; then
            echo "Stopping minitile before any test documents were opened." >&2
        else
            remaining=1
            echo "Lost contact with minitile; stopping it. Test windows may be on the stash in Mission Control." >&2
        fi
        kill -TERM "$app_pid" 2>/dev/null
    fi
    if [ -n "$app_pid" ]; then
        for ((attempt=0; attempt<50; attempt++)); do
            if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$app_pid" 2>/dev/null; then kill -KILL "$app_pid" 2>/dev/null; fi
    fi
    if [ "$textedit_was_running" = 0 ] && [ -n "$textedit_pid" ] && [ "$remaining" = 0 ]; then
        build/smoke-support quit-empty "$textedit_pid"
    fi
    build/smoke-support restore "$front_pid"
    cp "$testdir"/*.log "$report/" 2>/dev/null
    if [ "$remaining" = 0 ]; then
        rm -rf "$testdir"
    else
        result=1
        echo "Preserved test files at $testdir; close their remaining windows when convenient." >&2
    fi
    echo "Smoke report: $report"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

write_config() {
    cat > "$MINITILE_CONFIG" <<'CONFIG'
only_apps = ["com.apple.TextEdit"]
padding = 8
gaps = 8
CONFIG
}

wait_active() {
    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
        if ! "$mntl" --json debug health > "$report/latest-health.json"; then return 1; fi
        if jq -e '.started and (.suspended | not)' "$report/latest-health.json" >/dev/null; then return; fi
        sleep 0.1
    done
    echo "Session remained suspended; see $report/latest-health.json." >&2
    return 1
}

launch() {
    local deadline=$((SECONDS + 60)) next_notice=$SECONDS
    open -n -g --env "MINITILE_CONFIG=$MINITILE_CONFIG" --env "MINITILE_STATE=$MINITILE_STATE" \
        --env "MINITILE_SOCKET=$MINITILE_SOCKET" --env "MINITILE_SMOKE_DIRECTORY=$MINITILE_SMOKE_DIRECTORY" \
        --env "MINITILE_SMOKE_WINDOWS=$MINITILE_SMOKE_WINDOWS" \
        --env "MINITILE_TRACE_KEYS=$MINITILE_TRACE_KEYS" \
        --stdout "$testdir/stdout.log" --stderr "$testdir/stderr.log" "$PWD/build/Minitile.app"
    while ((SECONDS < deadline)); do
        if [ -z "$app_pid" ]; then app_pid=$(pgrep -n -x minitile || true); fi
        if "$mntl" --json debug health > "$report/health.json" 2>/dev/null && jq -e '.started' "$report/health.json" >/dev/null; then
            app_pid=$(jq -r '.pid' "$report/health.json")
            return
        fi
        if ((SECONDS >= next_notice)); then
            echo "Waiting for Minitile; grant its Accessibility permission if prompted."
            next_notice=$((SECONDS + 10))
        fi
        sleep 0.1
    done
    echo "Minitile did not start. Inspect its menu warning and $testdir/stderr.log." >&2
    cat "$testdir/stderr.log" >&2
    return 1
}

wait_state() {
    local filter=$1 deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
        if "$mntl" --json state > "$report/state.json" && jq -e "$filter" "$report/state.json" >/dev/null; then check_scene; return; fi
        sleep 0.1
    done
    echo "State assertion failed: $filter" >&2
    cat "$report/state.json" >&2
    "$mntl" --json debug health > "$report/failure-health.json" || true
    "$mntl" --json debug spaces > "$report/failure-spaces.json" || true
    return 1
}

check_scene() {
    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
        "$mntl" --json debug scene > "$report/scene.json"
        "$mntl" --json debug windows > "$report/windows.json"
        "$mntl" --json debug spaces > "$report/spaces.json"
        if jq -en --slurpfile scene "$report/scene.json" --slurpfile windows "$report/windows.json" --slurpfile spaces "$report/spaces.json" '
            ($windows[0] | map({key: (.id | tostring), value: .}) | from_entries) as $actual |
            all($scene[0].displays | to_entries[];
                .key as $display | .value as $wanted |
                ($spaces[0][] | select(.info.id == $display) | .info) as $native |
                all($wanted.visible[]; $actual[tostring].spaces | index($native.visibleSpace) != null) and
                all($wanted.stashed[]; $actual[tostring].spaces | index($native.stashSpace) != null) and
                all($wanted.frames | to_entries[];
                    .key as $id | .value as $frame |
                    all(["x", "y", "width", "height"][]; . as $axis | (($actual[$id].frame[$axis] - $frame[$axis]) | fabs) <= 20)))
        ' >/dev/null; then return; fi
        sleep 0.1
    done
    echo "WindowServer placement or AX frames did not match the desired scene; see $report." >&2
    return 1
}

grid() {
    jq -S '{displays: [.displays[] | {id, workspace, workspaces: [.workspaces[] | {home, page, pages: [.pages[] | {id, variant, r1, r2, windows}]}]}], windows: [.windows[] | {id, hidden, floating}]}'
}

if [ -z "$recovery_directory" ]; then write_config; fi
launch
"$mntl" --json config info > "$report/config.json"
jq -e '.only_apps == ["com.apple.TextEdit"]' "$report/config.json" >/dev/null
if [ -n "$recovery_directory" ]; then
    echo 'Recovered the saved test session; closing its documents through normal cleanup.'
    exit 0
fi
"$mntl" --json debug spaces > "$report/initial-spaces.json"
if ! jq -e 'length > 0 and all(.[]; .info.unmanagedReason == null)' "$report/initial-spaces.json" >/dev/null; then
    echo 'Smoke test cannot manage the current displays:' >&2
    jq -r 'if length == 0 then "  No displays were discovered."
        else .[] | select(.info.unmanagedReason != null) | "  \(.info.id): \(.info.unmanagedReason)" end
        ' "$report/initial-spaces.json" >&2
    exit 1
fi
if [ "$interactive" = 1 ] && ! jq -e '.key_trace_enabled' "$report/health.json" >/dev/null; then
    echo 'Shortcut tracing is unavailable. Rebuild by omitting --no-build.' >&2
    exit 1
fi
if [ "$display_test" = 1 ] && ! jq -e 'length == 1' "$report/initial-spaces.json" >/dev/null; then
    echo 'Start --displays with the external monitor unplugged and the laptop display active.' >&2
    exit 1
fi
if [ "$display_test" = 1 ] && ! jq -e '.grid_indicator_displays == 1' "$report/health.json" >/dev/null; then
    echo 'The position grid is unavailable. Rebuild by omitting --no-build.' >&2
    exit 1
fi
echo 'This run manages only its five test files; unsaved Cmd+N documents are ignored.'
for ((index=1; index<=5; index++)); do
    printf 'minitile smoke document %s\n' "$index" > "$testdir/$prefix-$index.txt"
    open -a TextEdit "$testdir/$prefix-$index.txt"
    documents_opened=$index
    wait_state ".windows | length == $index"
done
"$mntl" --json debug windows > "$report/initial-windows.json"
textedit_pid=$(jq -r '.windows[0].pid' "$report/state.json")
display_id=$(jq -r '.windows[0].display' "$report/state.json")
read -r -a ids <<< "$(jq -r '.windows | sort_by(.id) | map(.id | tostring) | join(" ")' "$report/state.json")"
a=${ids[0]}; b=${ids[1]}; c=${ids[2]}; e=${ids[4]}

if [ "$activation_test" = 1 ]; then
    if [ "$front_pid" = "$textedit_pid" ] || [ "$front_pid" = 0 ]; then
        echo 'Start the activation test from Terminal with Terminal frontmost.' >&2
        exit 1
    fi
    for ((round=1; round<=10; round++)); do
        wait_active
        for id in "$a" "$b" "$c"; do "$mntl" window focus "$id"; done
        "$mntl" workspace next
        build/smoke-support restore "$front_pid"
        sleep 0.2
        if [ "$(build/smoke-support front)" != "$front_pid" ]; then
            echo 'Could not activate the original Terminal; activation sample would be invalid.' >&2
            exit 1
        fi
        build/smoke-support restore "$textedit_pid"
        wait_state 'any(.windows[]; .shown)'
        "$mntl" --json debug spaces > "$report/activation-$round-spaces.json"
        jq -e 'all(.[]; .current == .info.visibleSpace)' "$report/activation-$round-spaces.json" >/dev/null
    done
    "$mntl" --json debug timings > "$report/activation-timings.json"
    jq -e --argjson pid "$textedit_pid" '[.activation_moves[] | select(.pid == $pid)] | length >= 10' "$report/activation-timings.json" >/dev/null
    jq '{activation_moves, full_scans, full_scan_ms, recheck_requests, recheck_passes}' "$report/activation-timings.json"
    echo 'Activation samples captured; cleaning up test documents.'
    exit 0
fi

if [ "$display_test" = 1 ]; then
    # shellcheck source=scripts/smoke-displays.sh
    source scripts/smoke-displays.sh
    exit 0
fi

if [ "$interactive" = 1 ]; then
    "$mntl" window show "$a"
    wait_state ".windows[] | select(.id == $a) | .shown"
    "$mntl" --json state > "$report/manual-start.json"
    "$mntl" --json watch > "$report/manual-events.jsonl" &
    watch_pid=$!
    cat <<'INSTRUCTIONS'
Ready for real keys, starting with four TextEdit windows on workspace 1, page 1:
  Ctrl+Right: one window on the next page.
  Ctrl+Left: four windows again.
  Ctrl+Down: an empty workspace.
  Ctrl+Up: four windows again, without Mission Control or App Expose opening.

Further checks, starting on the four-window page:
  1. Window moves: click a test document to focus it.
     Press Ctrl+Shift+Right twice, then Ctrl+Shift+Left twice.
     Expect one, two, one, then four windows; focus follows the moved window.
     Ctrl+Shift+Down then Ctrl+Shift+Up should show one, then four windows.
  2. Activation: Ctrl+Down to an empty workspace, Cmd+Tab to this Terminal,
     then Cmd+Tab back to TextEdit. Its previous page should return without
     macOS switching to the stash desktop.
  3. Resize: drag an inner edge of a tile about 100 points, then release.
     The shared divider should stay at the new position and tiles should fit.
  4. Swap: drag a title bar onto another tile and release over its center.
     The two documents should exchange tiles.
  5. Drag keys: start moving a title bar, hold the mouse down and press
     Ctrl+Right. That document should move to its own page. Release, then
     Ctrl+Shift+Left should return it to the four-window page.
  6. Trackpad: swipe toward the second native desktop. Minitile should
     return to the first desktop with the same page visible.
If a check fails, stop the sequence and report its number and what happened.
Report skipped checks as skipped. Leave monitor unplug/replug for a separate run.
Ctrl+arrow traces are saved in the smoke report's stderr.log.

Return to this Terminal with Cmd+Tab, describe what happened, then press Return.
Keep minitile running until this prompt finishes so it can close the test documents.
Then minitile will stop. Ctrl+C also runs cleanup.
INSTRUCTIONS
    read -r -p 'Observed result: ' observation
    jq -n --arg observation "$observation" '{observation: $observation}' > "$report/manual-observation.json"
    "$mntl" --json state > "$report/manual-end.json"
    "$mntl" --json debug health > "$report/manual-health.json"
    check_scene
    echo 'Manual observation and watch events recorded.'
    exit 0
fi

"$mntl" window show "$a"
"$mntl" page next
wait_state ".windows[] | select(.id == $e) | .shown"
"$mntl" page prev
wait_state ".windows[] | select(.id == $a) | .shown"
"$mntl" window nudge "$b" right
wait_state ".windows[] | select(.id == $b) | .page == 2 and .shown"
"$mntl" window nudge "$b" right
wait_state "[.windows[] | select(.id == $b or .id == $e) | .page] | unique | length == 1"
"$mntl" window move "$b" workspace next
wait_state ".windows[] | select(.id == $b) | .workspace == 2 and .shown"
"$mntl" workspace next
wait_state "[.displays[] | select(.id == \"$display_id\") | .workspaces[]] | length == 3"
"$mntl" workspace next
wait_state "[.displays[] | select(.id == \"$display_id\") | .workspaces[]] | length == 3"
"$mntl" workspace prev
"$mntl" window show "$a"
"$mntl" window hide "$a"
wait_state ".windows[] | select(.id == $a) | .hidden and (.shown | not)"
"$mntl" window show "$a"
"$mntl" window float "$a" on
wait_state ".windows[] | select(.id == $a) | .floating and .shown"
"$mntl" window resize "$a" 500x400
"$mntl" window float "$a" off
wait_state ".windows[] | select(.id == $a) | .floating | not"
slot_a=$(jq -r ".windows[] | select(.id == $a) | .slot" "$report/state.json")
slot_c=$(jq -r ".windows[] | select(.id == $c) | .slot" "$report/state.json")
"$mntl" window swap "$a" "$c"
wait_state "any(.windows[]; .id == $a and .slot == $slot_c) and any(.windows[]; .id == $c and .slot == $slot_a)"
"$mntl" page variant
"$mntl" page ratio 0.4 0.7

printf 'padding = "invalid"\n' > "$MINITILE_CONFIG"
if "$mntl" config reload; then echo "Invalid config was accepted" >&2; exit 1; fi
"$mntl" --json config info | jq -e '.padding == 8' >/dev/null
write_config
"$mntl" config reload
"$mntl" --json state | grid > "$report/before-restart.json"
MINITILE_SMOKE_WINDOWS=$("$mntl" --json state | jq -r '[.windows[] | "\(.id):\(.pid)"] | join(",")')
"$mntl" quit
for ((attempt=0; attempt<50; attempt++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$app_pid" 2>/dev/null; then echo "Minitile did not quit" >&2; exit 1; fi
app_pid=""
launch
wait_state '.windows | length == 5'
"$mntl" --json state | grid > "$report/after-restart.json"
diff -u "$report/before-restart.json" "$report/after-restart.json"
"$mntl" window close "$a"
wait_state "all(.windows[]; .id != $a)"
echo "Smoke assertions passed; cleaning up test documents."
