#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iMoireTime;
uniform vec4 iMouse;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Wave sources (invisibly orbiting bodies), packed by moire.zig:
// (x, y, size, color_idx + 16*age). Age 0 is the head; 1..4 are trail samples.
uniform vec4 iParticles[300];
uniform int iParticleCount;
uniform float iBass;
// 1.0 = wave-packet interference fuzz (default), 0.0 = comet dots + trails.
uniform float iFuzz;
// Outward-ripple phase clock, accumulated CPU-side; speeds up with energy.
uniform float iFlow;
// Six-band spectrum; each body breathes on the band picked by its color index.
uniform float iBands[6];
// Sharp beat-pulse envelope — flashes brightness and pops the rings outward.
uniform float iBeat;
// Per-body velocity (px/s), indexed by body = particle_index / 5. Drives the
// Doppler wavefront compression.
uniform vec2 iVel[60];

out vec4 fragColor;

// Wave-packet ring frequency (rad/px) — set from the `wavelength` config
// param (2*pi / wavelength). Lower packs the rings looser, opening larger
// gaps of plain surface between fringes.
uniform float iRingFreq;

// Thin rings drawn per wavelength (config: grating): the grating whose
// overlaps make moire.
uniform float iGrating;

// ---------- gravitational deflection ----------

// Aggregate gravitational-lens deflection at p: each window bends space toward
// itself with the classic point-lens 1/r falloff (Plummer-softened). The
// interference field is sampled through this deflection, so its fringes bend
// and magnify toward heavy windows.
vec2 deflect(vec2 p) {
    vec2 D = vec2(0.0);
    // Constant well depth — the warp holds a steady shape and does not react
    // to the music (only the rings/brightness/shockwaves/bodies do). Kept
    // moderate so the bending frames the field without overpowering it.
    float depth = 20.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 8.0 || win.w < 8.0) continue;
        vec2 cen = win.xy + win.zw * 0.5;
        float m = sqrt(win.z * win.w);
        if (i == iFocusedIndex) m *= mix(1.0, 2.0, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    m *= mix(2.0, 1.0, smoothstep(0.0, 1.0, iTransition));
        vec2 d = cen - p;
        float r = length(d) + 1.0;
        D += (d / r) * (m * depth / (r + 140.0));
    }
    // The cursor-comet bends space a little too.
    vec2 dm = iMouse.xy - p;
    float rm = length(dm) + 1.0;
    D += (dm / rm) * (180.0 * depth * 0.6 / (rm + 140.0));
    return D;
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.01, 0.012, 0.025);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.85);

    vec2 D = deflect(fc);
    // Gravitationally-warped sample position: the interference pattern is read
    // through the lens, so its rings bend and magnify toward heavy windows.
    vec2 wfc = fc + D * 1.4;

    // Backdrop is the theme's surface tone itself, so the field rests as
    // plain background and only the fringes rise out of it.
    vec3 col = bg;

    if (iFuzz > 0.5) {
        // RING MOIRE: every body radiates its own fine ring grating, and
        // the gratings are overlaid, each weighted by how much its body
        // dominates here. Inside one body's reach its rings stay clean;
        // where two reaches meet, two gratings cross and the eye reads the
        // beat between them: moire. (A plain sum of every wave collapses
        // into random-phase speckle and clips to white.) Only body heads
        // radiate; trail samples are for comet mode.
        float lines = 0.0;     // sum of env^3 * line
        vec3 lcol = vec3(0.0);
        float band = 0.0;      // sum of env^3 * soft wave crest
        vec3 bcol = vec3(0.0);
        float w2 = 0.0;        // sum of env^6
        float env_sum = 0.0;
        for (int i = 0; i < iParticleCount && i < 300; i += 5) {
            vec4 P = iParticles[i];

            vec2 d = wfc - P.xy; // read through the gravitational lens
            if (abs(d.x) > 600.0 || abs(d.y) > 600.0) continue;

            int cid = int(mod(P.w, 16.0));
            vec3 pc = (iPaletteSize > cid) ? iPalette[cid] : vec3(0.7, 0.8, 1.0);

            // Each body breathes on its assigned band: that slice loosens its
            // ring spacing, so bass bodies pulse on kicks, treble on hats.
            // The beat punch pops every ring outward briefly.
            float be = min(iBands[cid % 6], 1.4);
            float rf = iRingFreq * (1.0 - be * 0.30 - min(iBeat, 1.6) * 0.18);
            float sigma = P.z * 26.0;
            float r = length(d);

            // Real Doppler: a moving source bunches its wavefronts ahead of its
            // motion and stretches them behind.
            vec2 vel = iVel[i / 5];
            float sp = length(vel);
            float dopp = 1.0 + clamp(sp / 1100.0, 0.0, 0.45)
                       * dot(d / max(r, 1.0), vel / max(sp, 1.0));

            // Lorentzian reach, tapered to zero before the square reject box.
            float window = smoothstep(600.0, 420.0, r);
            float env = (1.0 / (1.0 + (r * r) / (sigma * sigma * 4.0))) * window;
            // Small moons recede: a fainter reach, so the big bodies' clean
            // ring systems carry the composition.
            env *= mix(0.3, 1.0, smoothstep(1.5, 5.0, P.z));
            float k = rf * dopp;                       // rad per px
            float phase = r * k - iFlow + float(cid) * 2.4;

            // The grating: iGrating thin rings per wavelength, measured in px
            // from the nearest one so they stay ~1.5px wide at any spacing.
            float fine = phase * iGrating;
            float dist = abs(mod(fine + 3.1415927, 6.2831853) - 3.1415927) / (k * iGrating);
            float line = 1.0 - smoothstep(0.5, 1.4, dist);

            // Cubed weights: the dominant body takes over sharply, so only a
            // narrow seam carries two crossed gratings.
            float e2 = env * env * env;
            lines += e2 * line;
            lcol += pc * e2 * line;
            float crest = 0.5 + 0.5 * sin(phase);
            crest *= crest * crest;
            band += e2 * crest;
            bcol += pc * e2 * crest;
            w2 += e2 * e2;
            env_sum += env;
        }

        if (w2 > 1e-12) {
            // Normalized by sqrt(sum env^6): 1 inside one body's reach,
            // ~0.7 each where two meet evenly, so overlaps stay in range.
            float norm = inversesqrt(w2);
            // Rings fade well before the bodies' reach runs out, leaving
            // plain surface between systems.
            float presence = smoothstep(0.04, 0.55, env_sum);
            float punch = 1.0 + min(iBeat, 1.6) * 0.5;

            vec3 lc = lcol / max(lines, 1e-6);
            vec3 bc = bcol / max(band, 1e-6);
            float L = min(lines * norm, 1.4);
            float B = min(band * norm, 1.0);

            // The slow wave survives as a soft glow under the grating, so
            // the rings still read as ripples flowing outward.
            vec3 inter = bc * B * 0.16 + mix(lc, vec3(1.0), 0.2) * L * 0.55;
            col += inter * presence * punch;
        }
    } else {
        // Comet mode: tight additive dots with fading trails.
        for (int i = 0; i < iParticleCount && i < 300; i++) {
            vec4 P = iParticles[i];
            vec2 d = fc - P.xy;
            if (abs(d.x) > 60.0 || abs(d.y) > 60.0) continue;

            float age = floor(P.w / 16.0);
            int cid = int(mod(P.w, 16.0));
            vec3 pc = (iPaletteSize > cid) ? iPalette[cid] : vec3(0.7, 0.8, 1.0);

            float fade = 1.0 / (1.0 + age * 1.1);
            float r2 = dot(d, d);
            float sz = P.z * fade;
            float core = exp(-r2 / (sz * sz * 3.5));
            float halo = exp(-r2 / (sz * sz * 30.0)) * 0.4;
            // Heads burn a touch hotter than their palette color.
            vec3 body_col = mix(pc, fg, age < 0.5 ? 0.25 : 0.0);
            col += (body_col * (core + halo)) * fade * 1.35;
        }
    }

    // Whisper of vignette so the field has depth.
    vec2 uv = fc / iResolution.xy;
    col *= 1.0 - 0.25 * dot(uv - 0.5, uv - 0.5) * 4.0 * 0.5;

    fragColor = vec4(col, 1.0);
}
