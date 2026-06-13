#version 450

// Samples the runtime-written viewport framebuffer texture and outputs the
// unmodified RGBA value. The texture is uploaded each frame by the editor's
// GAL command recording (host-visible staging buffer → copyBufferToTexture)
// from the shm region's currently-published slot.
//
// SEPARATE descriptors (the GAL convention established in E4): the GAL binds a
// sampled image and a sampler as DISTINCT descriptors (binding_type
// .sampled_texture + .sampler → Vulkan .sampled_image + .sampler), not a
// combined `sampler2D`. The blit has no uniform, so the texture/sampler take
// bindings 0/1; `sampler2D(tex, samp)` recombines them in the shader.

layout(set = 0, binding = 0) uniform texture2D viewportTex;
layout(set = 0, binding = 1) uniform sampler viewportSamp;
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = texture(sampler2D(viewportTex, viewportSamp), vUv);
}
