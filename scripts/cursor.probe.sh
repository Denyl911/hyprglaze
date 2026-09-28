# How closely does the daemon's cursor follow the real pointer? The probe
# shader draws a blue crosshair at iMouse; `grim -c` composites the real
# cursor sprite into the same frame (no_hardware_cursors). Calibrate the
# sprite's hotspot against the crosshair with the pointer still, then drag
# the pointer across at a steady speed and measure the gap frame by frame.
#
#   scripts/hypr-harness.sh scripts/cursor.probe.sh
#
# Timing needs full frame rate, so it calls show_harness first.

cgrab() { host_visible; WAYLAND_DISPLAY="$NESTED_WL" timeout 20 grim -c -o "$MON_B" "$OUT/shots/$1.png"; }

# "dx dy": sprite top-left minus crosshair centre, or "none".
offset() { python3 - "$OUT/shots/$1.png" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int); a[:48] = 0
blue = (a[..., 2] > 200) & (a[..., 0] < 60) & (a[..., 1] < 60)
ys, xs = np.nonzero(blue)
if not len(xs): print("none"); sys.exit()
cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
other = (a.max(axis=2) > 40) & ~blue
y0, x0 = int(max(cy - 90, 0)), int(max(cx - 90, 0))
sub = other[y0:int(cy + 90), x0:int(cx + 90)]
sy, sx = np.nonzero(sub)
if not len(sx): print("none"); sys.exit()
print(f"{sx.min() + x0 - cx:.0f} {sy.min() + y0 - cy:.0f}")
PY
}

show_harness
sed 's/^smoothing = 0.001$/smoothing = 0.0/' "$OUT/cfg/hypr/hyprglaze.toml" > "$OUT/cfg-cur.toml"
HG_CFG="$OUT/cfg-cur.toml" start_daemon "$MON_B" cur
move_cursor $((BX + 300)) $((BY + 600)) || echo "  (cursor placement off)"
# Calibrate on a settled frame: retry until the daemon has drawn the
# crosshair at the parked pointer.
OX=none
for try in 1 2 3 4 5 6; do
    sleep 0.5; cgrab cur-still; read -r OX OY <<<"$(offset cur-still)"
    [ "$OX" != none ] && break
done
echo "  still: sprite-crosshair offset = $OX $OY"
expect "[ '$OX' != none ]" "found crosshair and sprite"
[ "$OX" = none ] && return 0

# Steady drag: 12px every ~8ms (~1400px/s) for ~1s, grabbing meanwhile.
( for i in $(seq 1 90); do wl_ptr 12 0; sleep 0.008; done ) &
MOVER=$!
sleep 0.15
worst=0; n=0
for i in 1 2 3 4 5 6; do
    cgrab cur-move$i
    read -r dx dy <<<"$(offset cur-move$i)"
    [ "$dx" = none ] && continue
    ex=$(( dx - OX )); ey=$(( dy - OY )); e=${ex#-}; [ "${ey#-}" -gt "$e" ] && e=${ey#-}
    echo "  moving grab $i: error x=$ex y=$ey"
    n=$((n + 1)); [ "$e" -gt "$worst" ] && worst=$e
done
wait $MOVER
echo "  $n moving grabs, worst gap ${worst}px"
expect "[ $n -ge 3 ]" "measured the pointer in motion"
