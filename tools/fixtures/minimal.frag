// Canonical Shadertoy entry point: exercises the common path.
void mainImage(out vec4 color, in vec2 coord) {
    vec2 uv = coord / iResolution.xy;
    color = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
