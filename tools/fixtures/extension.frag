// The extension must be hoisted above the wrapper's precision qualifiers and
// uniforms; the shader's own #version/precision are blanked.
#version 300 es
#extension GL_OES_standard_derivatives : enable
precision highp float;

void mainImage(out vec4 color, in vec2 coord) {
    float d = fwidth(coord.x * 0.01);
    color = vec4(vec3(d), 1.0);
}
