#version 450

// M0.9 vertical-slice forward pass — vertex stage.
//
// Per-vertex cube geometry (position + UV) is instanced once per ECS entity;
// the per-instance offset is the entity's live `Position` (x, y) read from the
// world each frame and mapped to world-space (x, 0, y). The camera MVP arrives
// in a uniform buffer (set 0, binding 0). Texture sampling lives in the
// fragment stage; this stage just forwards the UV.

layout(location = 0) in vec3 inPos;     // cube vertex, model space
layout(location = 1) in vec2 inUv;      // cube UV
layout(location = 2) in vec3 inOffset;  // per-instance world offset (entity Position)

layout(set = 0, binding = 0) uniform Camera {
    mat4 mvp;
} cam;

layout(location = 0) out vec2 vUv;

void main() {
    gl_Position = cam.mvp * vec4(inPos + inOffset, 1.0);
    vUv = inUv;
}
