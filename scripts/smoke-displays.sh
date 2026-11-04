# shellcheck shell=bash
# Sourced by smoke.sh with its isolated session, fixtures and cleanup trap.

display_snapshot() {
    local stage=$1
    check_scene
    "$mntl" --json state > "$report/$stage-state.json"
    "$mntl" --json debug health > "$report/$stage-health.json"
    cp "$report/spaces.json" "$report/$stage-spaces.json"
    cp "$report/windows.json" "$report/$stage-windows.json"
    cp "$report/scene.json" "$report/$stage-scene.json"
    if ! jq -e 'all(.[]; .current == .info.visibleSpace)' "$report/$stage-spaces.json" >/dev/null; then
        echo "A display is showing its native stash; see $report/$stage-spaces.json." >&2
        return 1
    fi
}

home_display=$display_id
d=${ids[3]}
"$mntl" --json watch > "$report/display-events.jsonl" &
watch_pid=$!
printf '%s\n' 'Page/workspace changes show the display grid in the upper-right for 1.5 seconds; the blue cell is the current page.'
printf '%s\n' 'Connect the external monitor. On that display, ensure Mission Control has two native desktops.'
printf '%s\n' 'After adding a desktop, exit Mission Control and allow about five seconds for setup. The grid is transient; health does not require it to stay visible.'
read -r -p 'Return to this Terminal and press Return when ready: '
wait_state '.displays | length == 2 and all(.[]; .unmanaged_reason == null)'
external_display=$(jq -r --arg home "$home_display" '.displays[] | select(.id != $home) | .id' "$report/state.json")

for id in "$c" "$d" "$e"; do "$mntl" window move "$id" display "$external_display"; done
"$mntl" window nudge "$e" right
"$mntl" window focus "$a"
"$mntl" window focus "$e"
wait_state ".windows | length == 5 and all(.[]; if .id == $a or .id == $b then .display == \"$home_display\" else .display == \"$external_display\" end)"
display_snapshot connected

# Flip each display while comparing the other display's entire desired scene.
for anchor in "$c" "$a"; do
    if [ "$anchor" = "$c" ]; then other=$home_display; else other=$external_display; fi
    "$mntl" window focus "$anchor"
    wait_state "any(.windows[]; .id == $anchor and .shown)"
    "$mntl" --json debug scene | jq -S --arg id "$other" '.displays[$id]' > "$report/other-$anchor-before.json"
    "$mntl" page next
    wait_state "any(.windows[]; .id == $anchor and (.shown | not))"
    "$mntl" --json debug scene | jq -S --arg id "$other" '.displays[$id]' > "$report/other-$anchor-after-next.json"
    diff -u "$report/other-$anchor-before.json" "$report/other-$anchor-after-next.json"
    "$mntl" page prev
    wait_state "any(.windows[]; .id == $anchor and .shown)"
    "$mntl" --json debug scene | jq -S --arg id "$other" '.displays[$id]' > "$report/other-$anchor-after-prev.json"
    diff -u "$report/other-$anchor-before.json" "$report/other-$anchor-after-prev.json"
done
display_snapshot independent-pages

# Hide TextEdit on both displays so activation must recover the external page.
"$mntl" window focus "$a"
"$mntl" workspace next
"$mntl" window focus "$e"
"$mntl" workspace next
wait_state 'all(.windows[]; .shown | not)'
display_snapshot before-activation
cat <<'INSTRUCTIONS'
Both displays now show empty workspaces. Cmd+Tab to this Terminal, then Cmd+Tab
back to TextEdit. Document 5 should return on the external monitor without a
native desktop switch. Return here to record what happened; keep minitile running.
INSTRUCTIONS
read -r -p 'Activation observation: ' observation
jq -n --arg observation "$observation" '{observation: $observation}' > "$report/display-activation-observation.json"
wait_state "any(.windows[]; .id == $e and .shown and .display == \"$external_display\")"
display_snapshot after-activation

"$mntl" window focus "$a"
"$mntl" window focus "$e"
wait_state "any(.windows[]; .id == $a and .shown) and any(.windows[]; .id == $e and .shown)"
display_snapshot before-unplug
grid < "$report/before-unplug-state.json" > "$report/grid-before-unplug.json"
read -r -p 'Unplug the external monitor, then press Return here: '
wait_state ".displays | length == 1 and .[0].id == \"$home_display\" and any(.[0].workspaces[]; .home == \"$external_display\" and (.pages | length) == 2)"
wait_state ".windows | length == 5 and all(.[]; .display == \"$home_display\")"
display_snapshot unplugged
for id in "$c" "$e"; do
    "$mntl" window focus "$id"
    wait_state "any(.windows[]; .id == $id and .shown)"
done
display_snapshot merged-pages

read -r -p 'Reconnect the same external monitor, then press Return here: '
wait_state '.displays | length == 2 and all(.[]; .unmanaged_reason == null)'
wait_state ".windows | length == 5 and all(.[]; if .id == $a or .id == $b then .display == \"$home_display\" else .display == \"$external_display\" end)"
display_snapshot reconnected
grid < "$report/reconnected-state.json" > "$report/grid-after-reconnect.json"
diff -u "$report/grid-before-unplug.json" "$report/grid-after-reconnect.json"
printf '%s\n' 'Display assertions passed. Both original grids returned, including their page views.'
read -r -p 'Unplug/replug observation (including any visible glitches): ' observation
jq -n --arg observation "$observation" '{observation: $observation}' > "$report/display-hotplug-observation.json"
printf '%s\n' 'Display observations recorded; cleaning up test documents.'
