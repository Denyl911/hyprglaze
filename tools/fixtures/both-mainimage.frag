// Both overloads: the parameterless one is dead code and must be stripped so
// the canonical call in the footer is unambiguous.
void mainImage() {
    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
}

void mainImage(out vec4 color, in vec2 coord) {
    color = vec4(coord / iResolution.xy, 0.0, 1.0);
}
