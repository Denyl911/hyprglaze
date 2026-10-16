#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iIvyTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Ivy geometry from ivy.zig, rebuilt every frame. Each prim is two
// texels in iPrims (row-major, 1024 wide):
//   stem: (x1, y1, x2, y2), (brightness, width, 0, 0)
//   leaf: (x, y, angle, size), (alpha, autumn tint, hash, 1)
// iTiles holds (offset, count) per iTilePx screen tile into iRefs, the
// flat list of prim indices binned to each tile.
uniform highp sampler2D iPrims;
uniform highp usampler2D iTiles;
uniform highp usampler2D iRefs;
uniform int iTilePx;
uniform vec4 iFall[40];    // falling leaves (x, y, angle, size)
uniform float iBass;
uniform float iTreble;
uniform float iBeat;
uniform float iBright;

out vec4 fragColor;

// ---------- palette ----------

// Foliage: theme greens pulled toward true ivy green — themes like Rosé
// Pine have teal ANSI greens, and leaves should still read as a plant.
vec3 leafColor() {
    vec3 theme_green = (iPaletteSize > 10) ? mix(iPalette[2], iPalette[10], 0.35) : vec3(0.25, 0.65, 0.42);
    return mix(theme_green, vec3(0.16, 0.45, 0.18), 0.55);
}

vec3 stemColor() {
    vec3 leaf = leafColor();
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.85);
    // Woody green-brown, only faintly lifted toward fg.
    return mix(mix(leaf, vec3(0.35, 0.30, 0.16), 0.35), fg, 0.12);
}

// ---------- leaf ----------

// Ivy (hedera) leaf in its local frame: +x toward the tip, origin at the
// petiole attachment. Classic juvenile hedera silhouette: five lobes —
// a long pointed central lobe, two mid side lobes at ~72°, two small
// basal flanges at ~144° — with deep sinuses between them and a base
// that narrows to a notch where the petiole enters. Returns
// (fill, vein highlight).
vec2 leafShape(vec2 q, float size) {
    // Shift so the blade sits ahead of the attachment point.
    vec2 p = q - vec2(size * 0.55, 0.0);
    float r = length(p);
    if (r > size * 1.75) return vec2(0.0);
    float th = atan(p.y, p.x);
    // Five lobes from |cos(2.5θ)|: peaks at 0, ±72°, ±144°. The floor
    // sets sinus depth between lobes.
    float lb = pow(abs(cos(th * 2.5)), 0.42);
    float lobes = 0.52 + 0.48 * lb;
    // Broad blade tapering toward the base; the ±144° peaks become the
    // small basal flanges, and cos(2.5π)=0 notches the very base.
    float taper = 0.62 + 0.38 * cos(th);
    // The central lobe reaches farther and comes to a point; a whisper of
    // edge ripple keeps the margin from reading machine-perfect.
    float elong = 1.0 + 0.25 * exp(-th * th * 2.6);
    float target = size * lobes * taper * elong * 1.25 * (1.0 + 0.02 * sin(th * 9.0));
    float d = r - target;
    float fill = smoothstep(1.1, -1.1, d);
    // Palmate veins: one ray into each lobe, fading toward the rim.
    float vein = pow(abs(cos(th * 2.5)), 18.0) * fill * (1.0 - smoothstep(0.0, target, r) * 0.72);
    return vec2(fill, vein);
}

// Petiole: the short stalk from the stem node to the leaf base.
float petiole(vec2 q, float size) {
    float h = clamp(q.x / max(size * 0.45, 1e-3), 0.0, 1.0);
    float d = length(q - vec2(size * 0.45 * h, 0.0));
    return exp(-d * d * 1.4);
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88);
    vec3 leaf_c = leafColor();
    vec3 stem_c = stemColor();
    // Old wood: a thick stem browns and stops glowing much.
    vec3 bark_c = mix(stem_c, vec3(0.30, 0.22, 0.12), 0.55);

    // Flat theme surface behind the garden.
    vec3 col = (iPaletteSize > 0) ? iPalette[0] : vec3(0.15, 0.14, 0.23);

    vec3 light = vec3(0.0);

    ivec2 tile = ivec2(fc) / iTilePx;
    uvec2 hdr = texelFetch(iTiles, tile, 0).xy;
    for (uint k = 0u; k < hdr.y; k++) {
        uint r = hdr.x + k;
        int pi = int(texelFetch(iRefs, ivec2(int(r & 1023u), int(r >> 10u)), 0).x) * 2;
        vec4 A = texelFetch(iPrims, ivec2(pi & 1023, pi >> 10), 0);
        vec4 B = texelFetch(iPrims, ivec2((pi + 1) & 1023, (pi + 1) >> 10), 0);

        if (B.w < 0.5) {
            // ---- stem: thin glowing tendril, the growing tip brightest;
            // pipe-model width, so old trunks read thick and woody ----
            float b = B.x;
            vec2 pa = fc - A.xy;
            vec2 ba = A.zw - A.xy;
            float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
            float d = length(pa - ba * h);
            float w = B.y * (1.0 + iBass * 0.15);
            float wood = smoothstep(1.1, 2.4, B.y);
            vec3 sc = mix(stem_c, bark_c, wood);
            // Bias-subtracted so the bin's reach never shows as an edge.
            float cut = exp(-40.0 * 0.35 / w);
            light += sc * max(exp(-d * 0.35 / w) - cut, 0.0) * b * 0.45 * (1.0 - 0.6 * wood);
            light += mix(sc, fg, 0.22 * (1.0 - wood)) * exp(-d * d * 0.6 / (w * w)) * b * 0.70;
        } else {
            // ---- leaf: lobed hedera shape on a petiole, treble shimmer ----
            vec2 dp = fc - A.xy;
            float rr = A.w * 3.4;
            if (dot(dp, dp) > rr * rr) continue;
            float ca = cos(A.z), sa = sin(A.z);
            vec2 q = vec2(ca * dp.x + sa * dp.y, -sa * dp.x + ca * dp.y);
            vec2 lf = leafShape(q, A.w);
            float lh = B.z;
            float tw = 0.85 + 0.15 * sin(iIvyTime * 2.6 + lh * 40.0);
            float shine = tw * (0.55 + iTreble * 0.3) * B.x;
            // Age varies the green: young (small) leaves lighter yellow-green,
            // mature blades deep and solid — like the reference photo.
            float young = clamp(1.3 - A.w / 9.0, 0.0, 0.8);
            vec3 lc = mix(leaf_c * 0.8, mix(leaf_c, vec3(0.55, 0.68, 0.24), 0.55), young);
            // Individual variation: no two leaves share the exact same green
            // or brightness.
            lc = mix(lc, vec3(0.50, 0.60, 0.20), lh * 0.20);
            // A leaf at the end of its life yellows before it drops.
            lc = mix(lc, vec3(0.78, 0.62, 0.20), B.y * 0.8);
            shine *= 0.80 + 0.40 * lh;
            light += lc * lf.x * 0.85 * shine;
            light += mix(lc, fg, 0.35) * lf.y * 0.40 * shine;
            light += stem_c * petiole(q, A.w) * 0.30 * shine;
        }
    }

    // ---- leaves shaken loose, tumbling on the breeze ----
    for (int i = 0; i < 40; i++) {
        vec4 P = iFall[i];
        if (P.w < 0.4) continue;
        vec2 dp = fc - P.xy;
        float rr = P.w * 3.0;
        if (dot(dp, dp) > rr * rr) continue;
        float ca = cos(P.z), sa = sin(P.z);
        vec2 q = vec2(ca * dp.x + sa * dp.y, -sa * dp.x + ca * dp.y);
        vec2 lf = leafShape(q, P.w);
        light += mix(leaf_c, vec3(0.75, 0.65, 0.25), 0.35) * lf.x * 0.5;
        light += mix(leaf_c, fg, 0.4) * lf.y * 0.35;
    }

    // Soft Reinhard so dense foliage stays colored instead of clipping.
    col += light * iBright / (1.0 + 0.35 * light * iBright);

    // Beat: the garden breathes, barely.
    col += leaf_c * iBeat * 0.015;

    fragColor = vec4(col, 1.0);
}
