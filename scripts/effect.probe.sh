# Visual probe for any effect: two windows on MON_B, the cursor parked in
# open space, and a run of grabs over time to watch it move.
#
#   HG_EFFECT=flux scripts/hypr-harness.sh scripts/effect.probe.sh
#
# HG_SHOTS (4) and HG_GAP (1.5s) set the run of grabs; HG_THEME the theme.
# Produces $OUT/shots/<effect>-*.png.

FX=${HG_EFFECT:?set HG_EFFECT to the effect to probe}
# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
place fx-a 11 250 300 500 350
place fx-b 11 950 550 400 400
start_effect "$MON_B" fx "$FX"

move_cursor $((BX + 700)) $((BY + 150)) || true
sleep 2
for i in $(seq 1 "${HG_SHOTS:-4}"); do
    sleep "${HG_GAP:-1.5}"; grab "$FX-$i" "$MON_B"
done
echo "  cpu=$(ps -o %cpu= -p $EFFECT_PID)%"
expect "kill -0 $EFFECT_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
