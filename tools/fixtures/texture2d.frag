// GLSL ES 2 style texture lookup; the wrapper aliases texture2D to texture.
void mainImage(out vec4 color, in vec2 coord) {
    vec2 uv = coord / iResolution.xy;
    color = texture2D(iChannel0, uv);
}
