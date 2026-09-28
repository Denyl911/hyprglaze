# Visual probe for the particle physics: balls fall into the focused
# window's gravity well and settle against its frame, stream to the other
# window when focus moves, and get batted when a window moves into them.
#
#   scripts/hypr-harness.sh scripts/particles.probe.sh
#
# Calls show_harness so the physics runs at full frame rate. Produces
# $OUT/shots/pp-*.png and pp-grid-*.png.

grid() {   # OUT NAME... — tile shots 2 wide at half size
    python3 - "$OUT/shots" "$@" <<'PY'
import sys
from PIL import Image
d, out, names = sys.argv[1], sys.argv[2], sys.argv[3:]
ims = [Image.open(f"{d}/{n}.png") for n in names]
w, h = ims[0].size[0] // 2, ims[0].size[1] // 2
g = Image.new("RGB", (w * 2, h * ((len(ims) + 1) // 2)))
for k, im in enumerate(ims):
    g.paste(im.resize((w, h)), ((k % 2) * w, (k // 2) * h))
g.save(f"{d}/{out}.png")
PY
}

show_harness
mkdir -p "$OUT/cfg-p/hypr"
{ sed '/^\[geometry\]/,/^smoothing/d' "$OUT/cfg/hypr/hyprglaze.toml"; printf '\n[geometry]\nsmoothing = 0.0\n[particles]\ncount = 90\n'; } > "$OUT/cfg-p/hypr/hyprglaze.toml"
E "hl.animation({ leaf = 'windows', enabled = true, speed = 4, bezier = 'default' })" >/dev/null

place pp-b 11 950 250 450 500
place pp-a 11 150 350 450 400
ADDR_A=$(hcj clients | jq -r '.[]|select(.class=="pp-a")|.address')
ADDR_B=$(hcj clients | jq -r '.[]|select(.class=="pp-b")|.address')

env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    XDG_CONFIG_HOME="$OUT/cfg-p" XDG_STATE_HOME="$OUT/state" \
    "$BIN" --config "$OUT/cfg-p/hypr/hyprglaze.toml" --effect particles --theme "Rosé Pine" \
           --output "$MON_B" >"$OUT/hyprglaze-p.log" 2>&1 &
DAEMON_PIDS+=($!)
P_PID=$!
wait_for "hcj layers | jq -e --arg m '$MON_B' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15

E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_A' }))" >/dev/null
for t in 1 3 6 10; do sleep $(( t - ${prev:-0} )); prev=$t; grab pp-a$t "$MON_B"; done
echo "  cpu=$(ps -o %cpu= -p $P_PID)%"
grid pp-grid-focusA pp-a1 pp-a3 pp-a6 pp-a10

E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_B' }))" >/dev/null
for t in 1 2 4 8; do sleep 1; [ $t -gt 2 ] && sleep $(( t / 2 )); grab pp-b$t "$MON_B"; done
grid pp-grid-focusB pp-b1 pp-b2 pp-b4 pp-b8

# Swing A into the balls settled around B.
E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_A' }))" >/dev/null; sleep 0.3
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 700)), y = $((BY + 350)), relative = false }))" >/dev/null
for i in 1 2 3 4; do grab pp-bat$i "$MON_B"; done
sleep 1; grab pp-bat5 "$MON_B"
grid pp-grid-bat pp-bat1 pp-bat2 pp-bat4 pp-bat5

expect "kill -0 $P_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-p.log" "no errors in the daemon log"
