// Default shader for the `shadertoy` effect — a plain Shadertoy body.
//
// hyprglaze wraps this file before compiling it (src/core/shadertoy.zig): it
// injects `#version 300 es`, the Shadertoy uniforms and the `main()` that
// calls mainImage. So this file must declare NONE of those, and it is not a
// complete shader on its own — which is why it lives outside `shaders/*.frag`.
//
// Run any other Shadertoy-style shader with:
//     hyprglaze --effect shadertoy --shader /path/to/thing.frag
//
// iPalette / iPaletteSize / iPaletteBg / iPaletteFg are hyprglaze additions,
// so a shader can follow the active theme; a stock Shadertoy shader simply
// ignores them.

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
    float s = 0.0;
    float a = 0.5;
    const mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
    for (int i = 0; i < 5; i++) {
        s += a * noise(p);
        p = rot * p * 2.02;
        a *= 0.5;
    }
    return s;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 p = (uv - 0.5) * vec2(iResolution.x / iResolution.y, 1.0) * 2.5;

    float t = iTime * 0.06;
    // Domain warp: q bends p, then p+q bends again. Two levels is where it
    // stops looking like noise and starts looking like silk.
    vec2 q = vec2(fbm(p + t), fbm(p + vec2(5.2, 1.3) - t));
    float f = fbm(p + 2.0 * q);

    vec3 bg = iPaletteSize > 0 ? iPaletteBg : vec3(0.02, 0.02, 0.03);
    vec3 fg = iPaletteSize > 0 ? iPaletteFg : vec3(0.85, 0.90, 1.00);
    int n = max(iPaletteSize, 1);
    vec3 lo = iPaletteSize > 0 ? iPalette[0] : fg;
    vec3 hi = iPaletteSize > 1 ? iPalette[n - 1] : fg;

    vec3 col = mix(lo, hi, clamp(f * 1.35 - 0.18, 0.0, 1.0));
    col = mix(bg, col, clamp(length(q) * 1.4, 0.0, 1.0) * 0.85 + 0.15);
    col *= 1.0 - 0.22 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
