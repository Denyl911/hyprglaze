# Visual probe for cellbloom: two windows on MON_B, the cursor parked in
# open space, and a run of grabs over time to watch the lattice drift.
#
#   scripts/hypr-harness.sh scripts/cellbloom.probe.sh
#
# Produces $OUT/shots/cellbloom-*.png.

show_harness
place cb-a 11 250 300 500 350
place cb-b 11 950 550 400 400
env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
    "$BIN" --config "$OUT/cfg/hypr/hyprglaze.toml" --effect cellbloom --theme "${HG_THEME:-Rosé Pine}" \
           --output "$MON_B" >"$OUT/hyprglaze-cellbloom.log" 2>&1 &
DAEMON_PIDS+=($!)
C_PID=$!
wait_for "hcj layers | jq -e --arg m '$MON_B' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
sleep 2

move_cursor $((BX + 700)) $((BY + 150)) || true
for i in $(seq 1 "${HG_SHOTS:-4}"); do
    sleep "${HG_GAP:-1.5}"; grab cellbloom-$i "$MON_B"
done
echo "  cpu=$(ps -o %cpu= -p $C_PID)%"
expect "kill -0 $C_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-cellbloom.log" "no errors in the daemon log"
