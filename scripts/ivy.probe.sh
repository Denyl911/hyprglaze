# Probe for ivy's lifecycle: growth that keeps going past the old length
# cap, plants that survive a workspace round-trip, and dieback on close.
#
#   scripts/hypr-harness.sh scripts/ivy.probe.sh
#
# growth = 10 runs the plant's clock 10x (leaf lives included), so a
# minute here is ten at the default pace. Produces $OUT/shots/ivy-*.png.

# Garden metrics from a shot, off the flat surface colour (its most common
# pixel), with the probe windows themselves masked out:
#   lit SHOT            garden pixels on the whole output
#   clad SHOT X Y W H   % of the rect's frame with ivy alongside it
#   band SHOT X Y W H   garden pixels within 25px outside the rect
garden() { python3 - "$OUT/shots/$1.png" "${@:2}" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
vals, counts = np.unique(a.reshape(-1, 3), axis=0, return_counts=True)
m = np.abs(a - vals[counts.argmax()]).max(axis=2) > 14
for x, y, w, h in ((200, 200, 500, 400), (850, 300, 500, 500)):
    m[y:y + h, x:x + w] = False
mode = sys.argv[2]
if mode == "lit":
    print(int(m.sum()))
    sys.exit()
x, y, w, h = map(int, sys.argv[3:7])
if mode == "band":
    print(int(m[max(y - 25, 0):y + h + 25, max(x - 25, 0):x + w + 25].sum()))
    sys.exit()
hits = total = 0
for t in range(0, w, 8):   # top and bottom edges
    for yy in (y - 22, y + h + 2):
        total += 1; hits += m[max(yy, 0):yy + 20, x + t:x + t + 8].any()
for t in range(0, h, 8):   # left and right edges
    for xx in (x - 22, x + w + 2):
        total += 1; hits += m[y + t:y + t + 8, max(xx, 0):xx + 20].any()
print(100 * hits // total)
PY
}
lit() { garden "$1" lit; }

mkdir -p "$OUT/cfg-ivy/hypr"
{ cat "$OUT/cfg/hypr/hyprglaze.toml"; printf '\n[ivy]\ngrowth = 10.0\n'; } > "$OUT/cfg-ivy/hypr/hyprglaze.toml"
for ws in 12 13; do
    E "hl.workspace_rule({ workspace = '$ws', monitor = '$MON_B', persistent = true })" >/dev/null
done

place ivy-a 11 200 200 500 400
place ivy-b 11 850 300 500 500
PID_B=${CLIENT_PIDS[-1]}

env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
    XDG_CONFIG_HOME="$OUT/cfg-ivy" XDG_STATE_HOME="$OUT/state" \
    "$BIN" --config "$OUT/cfg-ivy/hypr/hyprglaze.toml" \
           --effect ivy --theme "Rosé Pine" \
           --output "$MON_B" >"$OUT/hyprglaze-ivy.log" 2>&1 &
DAEMON_PIDS+=($!)
IVY_PID=$!
wait_for "hcj layers | jq -e --arg m '$MON_B' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15

RA="200 200 500 400"; RB="850 300 500 500"
for t in 1 3 8 20 35; do
    sleep $(( t - ${prev:-0} )); prev=$t
    shot ivy-t$t $MON_B
    eval "CA$t=\$(garden ivy-t$t clad $RA); CB$t=\$(garden ivy-t$t clad $RB)"
    echo "  t=${t}s clad A=$(eval echo \$CA$t)% B=$(eval echo \$CB$t)%"
done
L35=$(lit ivy-t35)
echo "  cpu=$(ps -o %cpu= -p $IVY_PID)%"
# The old fixed-length vines covered at most ~60% of a frame this size.
expect "[ $CA35 -ge 85 ] && [ $CB35 -ge 85 ]" "both frames fully clad"
expect "[ $CA8 -gt $CA1 ] && [ $CA35 -ge $CA8 ]" "coverage only ever grows"

# Workspace round-trips: to the neighbour (the windows ride the strip
# off-screen) and to a far workspace (they leave the snapshot: dormant).
# Either way the plant returns as it was. Border creepers stay regardless.
for ws in 12 13; do
    E "hl.dispatch(hl.dsp.focus({ workspace = $ws }))" >/dev/null
    sleep 3; shot ivy-away$ws $MON_B; LAWAY=$(lit ivy-away$ws)
    E "hl.dispatch(hl.dsp.focus({ workspace = 11 }))" >/dev/null
    sleep 2; shot ivy-back$ws $MON_B; LBACK=$(lit ivy-back$ws)
    echo "  lit: away($ws)=$LAWAY back=$LBACK (before=$L35)"
    expect "[ $LAWAY -lt $(( L35 * 3 / 4 )) ]" "window plants hidden on workspace $ws"
    expect "[ $LBACK -gt $(( L35 * 9 / 10 )) ]" "garden intact after the round-trip to $ws"
done

# Long run: frame fully clad, maturing; leaves turn over (~30-60s here).
for i in 1 2 3 4 5 6; do sleep 8; shot ivy-m$i $MON_B; done
echo "  cpu while mature=$(ps -o %cpu= -p $IVY_PID)%"

# Moving a window still wilts its plant (and only its plant): the ivy
# around A's old upper half dies, B's is untouched.
shot ivy-premove $MON_B
OLD0=$(garden ivy-premove band 200 200 500 200); BB0=$(garden ivy-premove band $RB)
ADDR_A=$(hcj clients | jq -r '.[]|select(.class=="ivy-a")|.address')
E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_A' }))" >/dev/null; sleep 0.3
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 200)), y = $((BY + 700)), relative = false }))" >/dev/null
sleep 0.5; shot ivy-moving $MON_B
sleep 1.5; shot ivy-moved $MON_B
OLD1=$(garden ivy-moved band 200 200 500 200); BB1=$(garden ivy-moved band $RB)
echo "  old A band: $OLD0 -> $OLD1   band B: $BB0 -> $BB1"
expect "[ $OLD1 -lt $(( OLD0 * 3 / 10 )) ]" "a move wilts the moved window's plant"
expect "[ $BB1 -gt $(( BB0 * 8 / 10 )) ]" "the other window's plant is untouched by the move"
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 200)), y = $((BY + 200)), relative = false }))" >/dev/null
sleep 6; shot ivy-regrown $MON_B

# Close ivy-b: its plant dies back where it stood; ivy-a's lives on.
BB0=$(garden ivy-regrown band $RB); BA0=$(garden ivy-regrown band $RA)
kill "$PID_B"
sleep 0.5; shot ivy-closing $MON_B
sleep 2.5; shot ivy-closed $MON_B
BB1=$(garden ivy-closed band $RB); BA1=$(garden ivy-closed band $RA)
echo "  band B: $BB0 -> $BB1   band A: $BA0 -> $BA1"
expect "[ $BB1 -lt $(( BB0 / 5 )) ]" "closed window's plant is gone"
expect "[ $BA1 -gt $(( BA0 * 8 / 10 )) ]" "the other window's plant survives"

expect "kill -0 $IVY_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-ivy.log" "no errors in the daemon log"
