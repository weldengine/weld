#version 450

// M0.9 vertical-slice forward pass — fragment stage.
//
// Samples the M0.6-cooked albedo texture. The GAL binds the texture image and
// the sampler as SEPARATE descriptors (binding_type .sampled_texture + .sampler
// → Vulkan .sampled_image + .sampler), so the GLSL uses the separate
// `texture2D` + `sampler` types recombined with `sampler2D(tex, samp)` rather
// than a combined `sampler2D` uniform.

layout(set = 0, binding = 1) uniform texture2D albedoTex;
layout(set = 0, binding = 2) uniform sampler albedoSamp;

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(sampler2D(albedoTex, albedoSamp), vUv);
}
