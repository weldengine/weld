//! Minimal column-major 4×4 matrix math for the vertical-slice camera.
//!
//! Phase 0 has no general math library (only RTTI `Vec3`/`Mat4` shape
//! examples), so the slice host carries just enough to build a camera MVP:
//! a right-handed `lookAt` + a Vulkan-convention `perspective` (clip-space
//! depth `[0, 1]`, Y axis flipped vs OpenGL). Stored as `[16]f32`
//! column-major — the layout a GLSL `mat4` uniform expects, so the bytes go
//! straight into the camera uniform buffer.

const std = @import("std");

pub const Vec3 = [3]f32;

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize(v: Vec3) Vec3 {
    const len = @sqrt(dot(v, v));
    if (len == 0) return .{ 0, 0, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

/// Column-major index of element (row `r`, col `c`).
inline fn at(r: usize, c: usize) usize {
    return c * 4 + r;
}

/// `a * b` (column-major).
pub fn mul(a: [16]f32, b: [16]f32) [16]f32 {
    var out: [16]f32 = [_]f32{0} ** 16;
    for (0..4) |c| {
        for (0..4) |r| {
            var s: f32 = 0;
            for (0..4) |k| s += a[at(r, k)] * b[at(k, c)];
            out[at(r, c)] = s;
        }
    }
    return out;
}

/// Right-handed perspective, Vulkan clip convention (depth `[0, 1]`,
/// Y-flipped). `fovy` is the vertical field of view in radians.
pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) [16]f32 {
    const f = 1.0 / @tan(fovy * 0.5);
    var m: [16]f32 = [_]f32{0} ** 16;
    m[at(0, 0)] = f / aspect;
    m[at(1, 1)] = -f; // Vulkan Y points down vs OpenGL.
    m[at(2, 2)] = far / (near - far);
    m[at(3, 2)] = -1.0;
    m[at(2, 3)] = (far * near) / (near - far);
    return m;
}

/// Right-handed `lookAt`.
pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) [16]f32 {
    const fwd = normalize(sub(center, eye));
    const s = normalize(cross(fwd, up));
    const u = cross(s, fwd);
    var m: [16]f32 = [_]f32{0} ** 16;
    m[at(0, 0)] = s[0];
    m[at(0, 1)] = s[1];
    m[at(0, 2)] = s[2];
    m[at(1, 0)] = u[0];
    m[at(1, 1)] = u[1];
    m[at(1, 2)] = u[2];
    m[at(2, 0)] = -fwd[0];
    m[at(2, 1)] = -fwd[1];
    m[at(2, 2)] = -fwd[2];
    m[at(0, 3)] = -dot(s, eye);
    m[at(1, 3)] = -dot(u, eye);
    m[at(2, 3)] = dot(fwd, eye);
    m[at(3, 3)] = 1.0;
    return m;
}

test "mul identity is neutral" {
    const id = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const p = perspective(std.math.pi / 4.0, 1.5, 0.1, 100.0);
    const out = mul(p, id);
    for (0..16) |i| try std.testing.expectApproxEqAbs(p[i], out[i], 1e-6);
}
