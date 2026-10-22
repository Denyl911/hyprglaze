// A shader that still carries its own GLSL ES 2 header and main(); both are
// blanked by the wrapper. The brace in the comment trips naive scanners.
#version 330 core
precision mediump float;

void mainImage(out vec4 color, in vec2 coord) {
    color = vec4(coord / iResolution.xy, 0.0, 1.0);
}

void main() {
    vec4 color;
    mainImage(color, gl_FragCoord.xy);
    gl_FragColor = color; // brace in a comment: }
}
