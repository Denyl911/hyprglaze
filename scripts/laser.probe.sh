# Visual probe for the laser: fired from the bottom-left corner toward the
# cursor, it reflects off windows and the screen's edges, dimming at each
# bounce. Aims at a few points and grabs each.
#
#   scripts/hypr-harness.sh scripts/laser.probe.sh
#
# Produces $OUT/shots/laser-*.png.

show_harness
place lz-a 11 250 300 500 350
place lz-b 11 950 550 400 400
env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
    "$BIN" --config "$OUT/cfg/hypr/hyprglaze.toml" --effect laser --theme "Rosé Pine" \
           --output "$MON_B" >"$OUT/hyprglaze-laser.log" 2>&1 &
DAEMON_PIDS+=($!)
L_PID=$!
wait_for "hcj layers | jq -e --arg m '$MON_B' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
# The beam first reaches the screen ~1.5s after the layer maps (frames are
# drawn at full rate from the first; the cause is not yet understood), so
# settle before measuring.
sleep 2

# Monitor-local aim points (y down, as Hyprland counts).
i=0
for pt in "600 200" "900 450" "1450 300" "200 1000"; do
    set -- $pt; i=$((i + 1))
    move_cursor $((BX + $1)) $((BY + $2)) || true
    sleep 0.4; grab laser-$i "$MON_B"
done
echo "  cpu=$(ps -o %cpu= -p $L_PID)%"
expect "kill -0 $L_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-laser.log" "no errors in the daemon log"
