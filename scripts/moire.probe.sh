# Visual probe for moire: two windows on MON_B, the cursor parked in
# open space, and a run of grabs over time to watch the field.
#
#   scripts/hypr-harness.sh scripts/moire.probe.sh
#
# Produces $OUT/shots/moire-*.png.

show_harness
place mo-a 11 250 300 500 350
place mo-b 11 950 550 400 400
env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
    "$BIN" --config "$OUT/cfg/hypr/hyprglaze.toml" --effect moire --theme "${HG_THEME:-Rosé Pine}" \
           --output "$MON_B" >"$OUT/hyprglaze-moire.log" 2>&1 &
DAEMON_PIDS+=($!)
M_PID=$!
wait_for "hcj layers | jq -e --arg m '$MON_B' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
sleep 2

move_cursor $((BX + 700)) $((BY + 150)) || true
for i in $(seq 1 "${HG_SHOTS:-4}"); do
    sleep "${HG_GAP:-1.5}"; grab moire-$i "$MON_B"
done
echo "  cpu=$(ps -o %cpu= -p $M_PID)%"
expect "kill -0 $M_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-moire.log" "no errors in the daemon log"
