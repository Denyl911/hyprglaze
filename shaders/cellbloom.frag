#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Music (all zero / iBloomFlow steady in silence → a quiet tissue).
uniform float iBloomFlow;     // CPU drift clock, quickens with energy
uniform float iBloomBands[6]; // smoothed AGC'd bands, low to high
uniform float iBloomBass;     // smoothed low end
uniform float iBloomBeat;     // kick envelope, ~200ms decay
// Ambient daughter seeds (mother = k / 2, sister = k ^ 1), coincident
// while the mother is whole: position px, window weight, mother's split.
uniform vec4 iBloomSeeds[48];

out vec4 fragColor;

// Seed index space: windows, then the cursor, then ambient daughters
// (mother = k / 2, sister = k ^ 1).
const int CURSOR = 32;
const int AMBIENT = 33;
const int N_SEEDS = AMBIENT + 48;

// Corner rounding of the cells: the smooth-min radius over their walls.
const float K = 28.0;

vec3 pal[6];
vec3 accent;

float focusOf(int i) {
    float f = 0.0;
    if (i == iFocusedIndex) f = max(f, smoothstep(0.0, 1.0, iTransition));
    if (i == iPrevIndex)    f = max(f, 1.0 - smoothstep(0.0, 1.0, iTransition));
    return f;
}

// Distance from p to seed idx and its unit gradient. False for an empty
// window slot.
bool seedDist(int idx, vec2 p, out float d, out vec2 g) {
    if (idx < CURSOR) {
        if (idx >= iWindowCount) return false;
        vec4 win = iWindows[idx];
        if (win.z < 1.0 || win.w < 1.0) return false;
        // Rounded box; the focused window claims more territory.
        vec2 q = p - (win.xy + win.zw * 0.5);
        vec2 w = abs(q) - win.zw * 0.5 + 12.0;
        float out_d = max(w.x, w.y);
        d = length(max(w, 0.0)) + min(out_d, 0.0) - 12.0;
        d -= ((1.0 - iTransition) * 80.0 + 15.0) * focusOf(idx); // 95px → 15px
        g = out_d > 0.0 ? normalize(max(w, 0.0)) : (w.x > w.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
        g *= vec2(q.x < 0.0 ? -1.0 : 1.0, q.y < 0.0 ? -1.0 : 1.0);
        return true;
    }
    vec4 s = idx == CURSOR ? vec4(iMouse.xy, 0.0, 0.0) : iBloomSeeds[idx - AMBIENT];
    vec2 v = p - s.xy;
    d = length(v);
    g = v / max(d, 1e-3);
    d += s.z; // window weight
    return true;
}

// Tint, band level and fill strength of the cell a seed owns.
void seedLook(int idx, out vec3 tint, out float level, out float strength) {
    if (idx < CURSOR) {
        int ci = idx % 6;
        tint = mix(pal[ci], accent, focusOf(idx));
        level = iBloomBands[ci];
        strength = 1.0;
    } else if (idx == CURSOR) {
        tint = accent;
        level = 0.0;
        strength = 0.7;
    } else {
        // A daughter shares her mother's tint and band while whole and
        // drifts to her own only once the furrow between them has closed,
        // so a dividing cell never shows a seam without a wall.
        int k = idx - AMBIENT;
        int m = k / 2;
        int ci = (m + 3) % 6;
        int bi = m % 6;
        float split = (k % 2 == 1) ? smoothstep(0.75, 1.0, iBloomSeeds[k].w) : 0.0;
        tint = mix(pal[ci], pal[(ci + 2) % 6], split);
        level = mix(iBloomBands[bi], iBloomBands[(bi + 3) % 6], split);
        strength = 0.6;
    }
}

float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);
    pal[0] = (iPaletteSize > 1) ? iPalette[1] : vec3(0.9, 0.4, 0.6);
    pal[1] = (iPaletteSize > 2) ? iPalette[2] : vec3(0.6, 0.8, 0.8);
    pal[2] = (iPaletteSize > 3) ? iPalette[3] : vec3(0.9, 0.7, 0.5);
    pal[3] = (iPaletteSize > 4) ? iPalette[4] : vec3(0.2, 0.4, 0.6);
    pal[4] = (iPaletteSize > 5) ? iPalette[5] : vec3(0.7, 0.6, 0.9);
    pal[5] = (iPaletteSize > 6) ? iPalette[6] : vec3(0.9, 0.7, 0.7);

    // Organic wobble: the tissue is sampled through a slow sine warp, so
    // every membrane undulates. Paced by the music flow clock.
    vec2 p = fc + vec2(
        sin(fc.y * 0.013 + iBloomFlow * 2.2),
        cos(fc.x * 0.011 + iBloomFlow * 1.8)) * 5.0;

    // --- Pass 1: which cell owns this pixel ---
    float d1 = 1e9;
    vec2 g1 = vec2(0.0);
    int own = -1;
    for (int i = 0; i < N_SEEDS; i++) {
        float d; vec2 g;
        if (!seedDist(i, p, d, g)) continue;
        if (d < d1) { d1 = d; g1 = g; own = i; }
    }

    // --- Pass 2: distance to the owner's walls ---
    // (d - d1) / |g - g1| is the first-order distance to the bisector,
    // exact for two points and right for box/point parabolas too, so
    // walls keep one width everywhere. A smooth min over every wall
    // rounds the cells' corners.
    int sister = own >= AMBIENT ? AMBIENT + ((own - AMBIENT) ^ 1) : -1;
    float furrow = 0.0;
    if (sister >= 0) {
        // The wall between sisters only grows in as they split: held back
        // by an offset, the smooth min pinches it in from the rim first,
        // like a cleavage furrow, until it closes across the cell.
        // The offset runs to infinity as the split goes to zero, so a whole
        // cell carries no crease where the wall will be.
        float f = smoothstep(0.0, 0.75, iBloomSeeds[own - AMBIENT].w);
        furrow = (K + 12.0) * (1.0 - f) / max(f, 1e-3);
    }
    float D = 1e5;
    float nb_b = 1e5;
    int nb = own;
    for (int i = 0; i < N_SEEDS; i++) {
        if (i == own) continue;
        float d; vec2 g;
        if (!seedDist(i, p, d, g)) continue;
        // |g - g1| <= 2, so this wall is at least (d - d1) / 2 away: past
        // the inner glow plus the rounding radius it changes nothing.
        if (d - d1 > 2.0 * (64.0 + K)) continue;
        float b = (d - d1) / max(length(g - g1), 0.05);
        if (i == sister) b += furrow;
        D = smin(D, b, K);
        if (b < nb_b) { nb_b = b; nb = i; }
    }

    vec3 tint, nb_tint;
    float level, strength, nb_level, nb_strength;
    seedLook(own, tint, level, strength);
    seedLook(nb, nb_tint, nb_level, nb_strength);

    // --- Shade: membranes inset from the walls, a dark channel between ---
    float gap = 3.0 + min(iBloomBass, 1.2) * 1.5;   // bass swells the channels
    // A cell being crowded out by a window draws its membrane in and fades
    // into the channel, so it is gone before it dwindles to a speck.
    float vis = 1.0;
    if (own > CURSOR) {
        float w = iBloomSeeds[own - AMBIENT].z;
        gap += w * 0.2;
        vis = 1.0 - smoothstep(20.0, 80.0, w);
    }
    float edge = D - gap;                             // > 0 inside the cell
    float lvl = min(level, 1.2);

    // Flat fill, lit by the cell's band; windows bloom an aura around them.
    float lit = (0.08 + lvl * 0.30) * strength;
    if (own < CURSOR) lit *= mix(0.6, 1.5, exp(-max(d1, 0.0) / 140.0));
    vec3 cell = mix(bg, tint, min(lit, 0.5));
    // Glow just inside the membrane only; the interior stays flat.
    cell += tint * (0.10 + lvl * 0.12 + iBloomBeat * 0.15) * exp(-max(edge, 0.0) / 14.0);

    // The channel picks up both neighbours' tints, meeting halfway at
    // the wall, so there is no seam where ownership flips.
    vec3 chan_tint = mix(tint, nb_tint, 0.5 * (1.0 - clamp(D / gap, 0.0, 1.0)));
    vec3 chan = bg * 0.55 + chan_tint * 0.06;

    vec3 col = mix(chan, cell, smoothstep(-0.75, 0.75, edge) * vis);

    // Membrane: a crisp line on the cell's rim. Kicks flash it, and it
    // brightens near the cursor.
    float membrane = 1.0 - smoothstep(0.5, 1.6, abs(edge));
    float cursor_near = exp(-distance(fc, iMouse.xy) / 150.0);
    vec3 mem_col = mix(tint, vec3(1.0), 0.15 + iBloomBeat * 0.25);
    col = mix(col, mem_col, membrane * vis * min(0.55 + lvl * 0.2 + iBloomBeat * 0.35 + cursor_near * 0.3, 0.95));

    fragColor = vec4(col, 1.0);
}
