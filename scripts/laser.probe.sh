# Visual probe for the laser: fired from the bottom-left corner toward the
# cursor, it reflects off windows and the screen's edges, dimming at each
# bounce. Aims at a few points and grabs each.
#
#   scripts/hypr-harness.sh scripts/laser.probe.sh
#
# Produces $OUT/shots/laser-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
place lz-a 11 250 300 500 350
place lz-b 11 950 550 400 400
start_effect "$MON_B" laser laser
L_PID=$EFFECT_PID
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
