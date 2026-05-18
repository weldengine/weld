#version 450

// Fullscreen-triangle generator — no VBO, no vertex input. Vertex
// indices 0, 1, 2 trace out a triangle that covers the entire
// `[-1, 1] × [-1, 1]` clip-space rectangle (the third vertex lies
// off-screen but the triangle's clipped area covers the full view).
// UV is derived from the position so the fragment shader can sample
// the viewport texture with a `[0, 1] × [0, 1]` coordinate.
//
// Source: Sascha Willems' fullscreen-triangle technique.
//
//   index 0 → pos (-1, -1) → uv (0, 0)
//   index 1 → pos ( 3, -1) → uv (2, 0)
//   index 2 → pos (-1,  3) → uv (0, 2)
//
// The visible portion after clipping is uv ∈ [0, 1]² mapped onto the
// canonical screen quad.

layout(location = 0) out vec2 vUv;

void main() {
    vUv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(vUv * 2.0 - 1.0, 0.0, 1.0);
}
