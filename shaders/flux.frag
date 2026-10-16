#version 300 es
precision highp float;

uniform vec3 iResolution;
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

// Magnet poles from flux.zig: (x, y, charge +-1, window index; -1 none,
// -2 the cursor's compass needle). North poles are +1.
uniform vec4 iFluxPoles[82];
uniform int iFluxPoleCount;
uniform float iFluxLines;   // field lines leaving each pole
uniform float iFluxFlow;    // pulse clock, quickens with music energy
uniform float iFluxBass;    // smoothed low end
uniform float iFluxBeat;    // kick envelope

out vec4 fragColor;

const float TAU = 6.2831853;

float focusOf(int i) {
    float f = 0.0;
    if (i == iFocusedIndex) f = max(f, smoothstep(0.0, 1.0, iTransition));
    if (i == iPrevIndex)    f = max(f, 1.0 - smoothstep(0.0, 1.0, iTransition));
    return f;
}

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 north = (iPaletteSize > 1) ? iPalette[1] : vec3(0.92, 0.43, 0.57);
    vec3 south = (iPaletteSize > 4) ? iPalette[4] : vec3(0.36, 0.62, 0.78);

    // f(z) = sum q log(z - z_i): its imaginary part is the stream function
    // (field lines are its contours), its real part the scalar potential
    // (the pulses ride its contours, crossing the lines at right angles).
    // Both superpose exactly, and |grad psi| = |grad phi| = |B|.
    float psi = 0.0;
    float phi = 0.0;
    vec2 grad = vec2(0.0);
    vec2 grad_focus = vec2(0.0);
    for (int i = 0; i < iFluxPoleCount && i < 82; i++) {
        vec4 P = iFluxPoles[i];
        vec2 d = fc - P.xy;
        float r2 = max(dot(d, d), 1.0);
        vec2 g = P.z * vec2(-d.y, d.x) / r2;
        psi += P.z * atan(d.y, d.x);
        phi -= P.z * 0.5 * log(r2);
        grad += g;
        if (P.w >= 0.0) grad_focus += g * focusOf(int(P.w));
    }

    // Contours of psi every TAU / lines. Each pole's branch cut jumps psi
    // by TAU, a whole number of spacings, so the lines cross it unbroken.
    float s = iFluxLines / TAU;
    float t = psi * s;
    float density = length(grad) * s;              // lines per pixel
    float dist = abs(t - floor(t + 0.5)) / max(density, 1e-6);
    // Near a pole the lines converge to a point; fade them before they
    // crowd closer than a few pixels and alias into mush.
    float spacing = 1.0 / max(density, 1e-6);
    float thin = smoothstep(2.5, 7.0, spacing);

    float line = (1.0 - smoothstep(0.5, 1.4, dist)) * thin;
    // Minor lines, three between each pair of majors, like an engraved
    // field diagram: faint, and they drop out first where lines crowd.
    float tm = t * 4.0;
    float dist_m = abs(tm - floor(tm + 0.5)) / max(density * 4.0, 1e-6);
    float minor = (1.0 - smoothstep(0.4, 1.1, dist_m)) * smoothstep(3.0, 8.0, spacing * 0.25);
    float glow = exp(-dist / 5.0) * thin;

    // Pulses flow along every line from north to south: bright fronts on
    // the potential's contours, one every four line spacings.
    float u = phi * s * 0.25 + iFluxFlow;
    float pulse = pow(0.5 + 0.5 * cos(TAU * u), 10.0);

    // Pole colouring: lines glow north-coloured near north poles, south-
    // coloured near south, blending through the middle.
    vec3 tint = mix(south, north, smoothstep(-1.2, 1.2, phi));

    // The focused window's own field burns brighter.
    float own = clamp(length(grad_focus) / max(length(grad), 1e-6), 0.0, 1.0);

    float beat = min(iFluxBeat, 1.5);
    float a = 0.45 + own * 0.25 + pulse * (0.5 + beat * 0.3) + min(iFluxBass, 1.2) * 0.08;
    vec3 col = bg;
    col += tint * glow * (0.06 + pulse * 0.10 + beat * 0.05);
    col = mix(col, tint, minor * (0.10 + pulse * 0.12));
    col = mix(col, mix(tint, vec3(1.0), 0.15 + pulse * 0.35), min(line * a, 1.0));

    fragColor = vec4(col, 1.0);
}
