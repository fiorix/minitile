# Sourced by smoke.sh --fullscreen after it opened five documents: a, b, c and d on page 1, e on page 2.
# A window that goes full screen takes a page of its own; minitile moves the display between that window's
# fullscreen Space and the desktop itself, and finds the window again after a restart.
d=${ids[3]}
title_a=$(jq -r ".windows[] | select(.id == $a) | .title" "$report/state.json")

# Waits until every display shows its visible desktop ("visible"), or one shows the given Space.
wait_space() {
    local wanted=$1 deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
        "$mntl" --json debug spaces > "$report/spaces.json"
        if [ "$wanted" = visible ]; then
            if jq -e 'all(.[]; .current == .info.visibleSpace)' "$report/spaces.json" >/dev/null; then return; fi
        elif jq -e --argjson space "$wanted" 'any(.[]; .current == $space)' "$report/spaces.json" >/dev/null; then return
        fi
        sleep 0.1
    done
    echo "The display did not reach Space $wanted; see $report/spaces.json." >&2
    return 1
}

pages() { jq -c '[.displays[].workspaces[].pages[].windows]' "$report/state.json"; }

expect_pages() {
    if [ "$(pages)" != "$1" ]; then echo "Expected pages $1, found $(pages)" >&2; return 1; fi
}

"$mntl" window show "$a"
wait_state ".windows[] | select(.id == $a) | .shown"
wait_space visible

echo 'Entering full screen from a shared page.'
build/smoke-support fullscreen "$textedit_pid" "$title_a" on
wait_state ".windows[] | select(.id == $a) | .fullscreen and .shown and .page == 2"
expect_pages "[[$b,$c,$d],[$a],[$e]]"
# The window lands on its fullscreen Space once the animation ends.
for ((attempt=0; attempt<50; attempt++)); do
    fullscreen_space=$("$mntl" --json debug windows | jq -r ".[] | select(.id == $a) | .spaces[0] // empty")
    "$mntl" --json debug spaces > "$report/spaces.json"
    if [ -n "$fullscreen_space" ] && jq -e --argjson space "$fullscreen_space" \
        'any(.[]; .current == $space and any(.spaces[]; .id == $space and .type == 4))' "$report/spaces.json" >/dev/null; then break; fi
    fullscreen_space=""
    sleep 0.1
done
if [ -z "$fullscreen_space" ]; then echo 'The window did not reach a fullscreen Space.' >&2; exit 1; fi
jq -e '.suspended | not' <("$mntl" --json debug health) >/dev/null
"$mntl" --json debug scene > "$report/fullscreen-scene.json"
jq -e --argjson id "$a" '[.displays[] | (.visible + .stashed)[] | select(. == $id)] | length == 0' "$report/fullscreen-scene.json" >/dev/null

echo 'Leaving the full screen page and coming back.'
"$mntl" page prev
wait_state ".windows[] | select(.id == $b) | .shown"
wait_space visible
"$mntl" page next
wait_state ".windows[] | select(.id == $a) | .shown"
wait_space "$fullscreen_space"

echo 'Moves pass over the page, and the window keeps it.'
if "$mntl" window nudge "$a" left 2>/dev/null; then echo 'A full screen window was nudged.' >&2; exit 1; fi
"$mntl" window move "$e" page 1
wait_state ".windows[] | select(.id == $e) | .page == 1 and .shown"
expect_pages "[[$b,$c,$d,$e],[$a]]"
wait_space visible

echo 'An empty page past the full screen one shows the desktop.'
"$mntl" window show "$a"
wait_space "$fullscreen_space"
"$mntl" page next
wait_state '[.displays[].workspaces[].pages[]] | length == 3'
wait_space visible
"$mntl" page prev
wait_state ".windows[] | select(.id == $a) | .shown"
wait_space "$fullscreen_space"

echo 'Restarting with the window full screen and off screen.'
"$mntl" page prev
wait_state ".windows[] | select(.id == $b) | .shown"
wait_space visible
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
wait_state ".windows | length == 5"
wait_state ".windows[] | select(.id == $a) | .fullscreen and .page == 2"
"$mntl" --json state | grid > "$report/after-restart.json"
diff -u "$report/before-restart.json" "$report/after-restart.json"

echo 'Leaving full screen.'
"$mntl" window show "$a"
wait_space "$fullscreen_space"
build/smoke-support fullscreen "$textedit_pid" "$title_a" off
wait_state ".windows[] | select(.id == $a) | (.fullscreen | not) and .shown and .page == 2"
expect_pages "[[$b,$c,$d,$e],[$a]]"
wait_space visible
"$mntl" --json debug scene > "$report/left-scene.json"
jq -e --argjson id "$a" 'any(.displays[]; (.visible | index($id)) != null and .frames[($id | tostring)] != null)' "$report/left-scene.json" >/dev/null
"$mntl" --json debug timings > "$report/fullscreen-timings.json"
echo 'Full screen assertions passed; cleaning up test documents.'
