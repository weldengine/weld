//! `Mat4` across the tier boundary: the layout it committed to before it moved
//! down into `foundation/math`, and the plugin C twin that layout mirrors.
//!
//! The operational tests — products, TRS order, affine inverse — live beside
//! the type in `src/foundation/math/mat4.zig`. What lives HERE is what needs
//! both sides of the boundary in one compilation unit: `foundation` for the
//! declaration and `weld_core` for the reflection alias and the ABI twin.

const std = @import("std");

const foundation = @import("foundation");
const core = @import("weld_core");

const math = foundation.math;
const rtti = core.rtti;
const desc = core.plugin_loader.desc;

const testing = std.testing;

/// Field-by-field structural equality of two `extern struct`s.
///
/// Compares NAMES, TYPES and OFFSETS, not just the aggregate size. Two ABI
/// twins can agree on `@sizeOf` while disagreeing on everything inside it —
/// which is why the size assertion alone, the only guard these types carried,
/// could not have caught a reshuffle.
fn structurallyIdentical(comptime A: type, comptime B: type) bool {
    const fa = @typeInfo(A).@"struct".fields;
    const fb = @typeInfo(B).@"struct".fields;
    if (fa.len != fb.len) return false;
    if (@sizeOf(A) != @sizeOf(B)) return false;
    if (@alignOf(A) != @alignOf(B)) return false;
    inline for (fa, fb) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (x.type != y.type) return false;
        if (@offsetOf(A, x.name) != @offsetOf(B, y.name)) return false;
    }
    return true;
}

test "Mat4 keeps its committed layout and its C twin" {
    // The layout the type carried while it was declared in the reflection
    // module. Moving the declaration must change none of it.
    try testing.expectEqual(@as(usize, 64), @sizeOf(rtti.Mat4));
    try testing.expectEqual(@as(usize, 4), @alignOf(rtti.Mat4));
    try testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(rtti.Mat4).@"struct".layout);

    // The twin. Before this assertion existed the two declarations were
    // related by a doc comment and by nothing else — `WeldMat4` has no use
    // site, so no compilation anywhere would have noticed them diverging.
    try testing.expect(structurallyIdentical(rtti.Mat4, desc.WeldMat4));

    // The witness that the comparison can fail: `WeldMat3` is the same family,
    // the same file, the same column-major convention, and a different width.
    // Without it, `structurallyIdentical` returning true proves nothing about
    // whether it is capable of returning false.
    try testing.expect(!structurallyIdentical(rtti.Mat4, desc.WeldMat3));
}

test "the reflection alias is the foundation type itself, not a copy" {
    // Type IDENTITY, not structural equality: `classifyField` matches on
    // `T == Mat4`, so a field declared against either name must classify as
    // `.mat4`. A structurally identical but distinct declaration would fall
    // through to `.nested_struct` and the schema would change shape in silence.
    try testing.expectEqual(rtti.Mat4, math.Mat4f);

    const Probe = extern struct {
        via_foundation: math.Mat4f = .{},
        via_rtti: rtti.Mat4 = .{},
    };
    const built = comptime rtti.buildTypeInfo(Probe, .component);
    try testing.expectEqual(@as(usize, 2), built.fields.len);
    try testing.expectEqual(rtti.FieldKind.mat4, built.fields[0].kind);
    try testing.expectEqual(rtti.FieldKind.mat4, built.fields[1].kind);
}

test "the default value is the identity in column-major order" {
    // The identity is symmetric, so it cannot discriminate row- from
    // column-major on its own. What it CAN pin is that the default is the
    // identity at all: a default of zeroes collapses every transform to the
    // origin and is invisible to a size assertion.
    const d = rtti.Mat4{};
    try testing.expectEqual(@as(f32, 1), d.m[0]);
    try testing.expectEqual(@as(f32, 1), d.m[5]);
    try testing.expectEqual(@as(f32, 1), d.m[10]);
    try testing.expectEqual(@as(f32, 1), d.m[15]);
    var zeros: usize = 0;
    for (d.m) |e| {
        if (e == 0) zeros += 1;
    }
    try testing.expectEqual(@as(usize, 12), zeros);
}
