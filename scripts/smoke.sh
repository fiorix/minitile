#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
interactive=0
build=1
for argument in "$@"; do
    case "$argument" in
        --interactive) interactive=1 ;;
        --no-build) build=0 ;;
        --help|-h) echo 'Usage: smoke.sh [--interactive] [--no-build]'; exit 0 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done
if [ "$interactive" = 1 ] && [ ! -t 0 ]; then
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

testdir=$(mktemp -d "${TMPDIR:-/tmp/}minitile-smoke.XXXXXX")
prefix=$(basename "$testdir")
report="$PWD/build/smoke-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$report"
export MINITILE_CONFIG="$testdir/minitile.toml"
export MINITILE_STATE="$testdir/state.json"
export MINITILE_SOCKET="$testdir/socket"
export MINITILE_SMOKE_DIRECTORY="$testdir"
export MINITILE_SMOKE_WINDOWS=""
front_pid=$(build/smoke-support front)
textedit_was_running=0
if pgrep -x TextEdit >/dev/null; then textedit_was_running=1; fi
app_pid=""
textedit_pid=""
cleaning=0
documents_opened=0
watch_pid=""
mntl="$PWD/build/mntl"

cleanup() {
    local result=$?
    if [ "$cleaning" = 1 ]; then return; fi
    cleaning=1
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null; fi
    local remaining=0 ids=""
    if "$mntl" --json state > "$report/cleanup-state.json" 2>/dev/null; then
        ids=$(jq -r --arg prefix "$prefix" '.windows[] | select(.bundle_id == "com.apple.TextEdit" and (.title | contains($prefix))) | .id' "$report/cleanup-state.json")
        for id in $ids; do
            "$mntl" window show "$id" >/dev/null
            "$mntl" window close "$id" >/dev/null
        done
        for ((attempt=0; attempt<40; attempt++)); do
            remaining=$("$mntl" --json state 2>/dev/null | jq '.windows | length')
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

launch() {
    local deadline=$((SECONDS + 60)) next_notice=$SECONDS
    open -n -g --env "MINITILE_CONFIG=$MINITILE_CONFIG" --env "MINITILE_STATE=$MINITILE_STATE" \
        --env "MINITILE_SOCKET=$MINITILE_SOCKET" --env "MINITILE_SMOKE_DIRECTORY=$MINITILE_SMOKE_DIRECTORY" \
        --env "MINITILE_SMOKE_WINDOWS=$MINITILE_SMOKE_WINDOWS" \
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

write_config
launch
"$mntl" --json config info | jq -e '.only_apps == ["com.apple.TextEdit"]' >/dev/null
"$mntl" --json debug spaces > "$report/initial-spaces.json"
jq -e 'length > 0 and all(.[]; .info.unmanagedReason == null)' "$report/initial-spaces.json" >/dev/null
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

Return to this Terminal with Cmd+Tab, describe what happened, then press Return.
The test documents will close and minitile will stop. Ctrl+C also cleans up.
INSTRUCTIONS
    read -r -p 'Observed result: ' observation
    jq -n --arg observation "$observation" '{observation: $observation}' > "$report/manual-observation.json"
    "$mntl" --json state > "$report/manual-end.json"
    "$mntl" --json debug health > "$report/manual-health.json"
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
