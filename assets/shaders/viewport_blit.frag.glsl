#version 450

// Samples the runtime-written viewport framebuffer texture and
// outputs the unmodified RGBA value. The texture is uploaded each
// frame by the editor's command-buffer recording (CPU staging buffer
// → image transfer) from the shm region's currently-published slot.

layout(binding = 0) uniform sampler2D viewportTex;
layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = texture(viewportTex, vUv);
}
