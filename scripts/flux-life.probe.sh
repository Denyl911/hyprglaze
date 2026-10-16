# Lifecycle probe for flux: bursts of grabs across the transitions that
# could snap the field: the first window opening on an empty workspace
# (the default magnet hands over), a window closing back to empty, and a
# workspace round-trip.
#
#   scripts/hypr-harness.sh scripts/flux-life.probe.sh
#
# Produces $OUT/shots/life-*.png.

show_harness
E "hl.dispatch(hl.dsp.focus({ workspace = 11 }))" >/dev/null
env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
    "$BIN" --config "$OUT/cfg/hypr/hyprglaze.toml" --effect flux --theme "${HG_THEME:-Rosé Pine}" \
           --output "$MON_B" >"$OUT/hyprglaze-flux.log" 2>&1 &
DAEMON_PIDS+=($!)
F_PID=$!
wait_for "hcj layers | jq -e --arg m '$MON_B' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
move_cursor $((BX + 60)) $((BY + 60)) || true
sleep 2
grab life-empty "$MON_B"

burst() {   # PREFIX N
    local k
    for k in $(seq 1 "$2"); do grab "$1-$k" "$MON_B"; done
}

# Empty -> one window (the default magnet hands over).
place fx-a 11 400 300 600 380
burst life-open 6
sleep 1; grab life-one "$MON_B"

place fx-b 11 1200 650 420 420
sleep 1; grab life-two "$MON_B"

# Close B (a neighbour vanishes), then A (back to empty).
kill "${CLIENT_PIDS[-1]}"
burst life-closeb 6
kill "${CLIENT_PIDS[-2]}"
burst life-closea 6
sleep 1; grab life-empty2 "$MON_B"

# Workspace round-trip with a window on 11.
place fx-c 11 500 400 700 400
sleep 1; grab life-ws0 "$MON_B"
E "hl.dispatch(hl.dsp.focus({ workspace = 12 }))" >/dev/null
burst life-away 6
E "hl.dispatch(hl.dsp.focus({ workspace = 11 }))" >/dev/null
burst life-back 6

echo "  cpu=$(ps -o %cpu= -p $F_PID)%"
expect "kill -0 $F_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-flux.log" "no errors in the daemon log"
