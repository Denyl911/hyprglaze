// KDE-style parameterless entry point: it writes the host's fragColor global
// and reads fragCoord, both supplied by the wrapper.
vec4 palette(float t) {
    return vec4(t, 0.5, 0.5, 1.0);
}

void mainImage() {
    fragColor = palette(fragCoord.x / iResolution.x);
}
