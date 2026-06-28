//! M1.0.4 — scene cook negative cases. Each ill-formed scene yields a typed
//! `CookError` (never a panic) and produces no `.scene.bin`.

const std = @import("std");
const weld_etch = @import("weld_etch");

const scene_cook = weld_etch.scene_cook;

fn expectCookError(comptime want: anyerror, src: []const u8) !void {
    const gpa = std.testing.allocator;
    var msg: []const u8 = "";
    try std.testing.expectError(want, scene_cook.cook(gpa, src, &msg));
    // A clear diagnostic accompanies the error (the brief: "a clear cook
    // diagnostic, never a panic").
    try std.testing.expect(msg.len > 0);
}

test "instance of without a prefab resolver errors BasePrefabMissing" {
    // M1.0.6 E3 replaced the M1.0.4 `InstanceOfUnsupported` boundary with real
    // flattening: `cook` (the resolver-less wrapper) can no longer locate the
    // referenced prefab, so an instance now errors `BasePrefabMissing` rather than
    // a blanket "unsupported". Flattening with a resolver is covered in
    // `tests/scene/prefab_flatten_test.zig`.
    try expectCookError(error.BasePrefabMissing,
        \\scene "S" {
        \\  instance of "Torch" "T1" { }
        \\}
    );
}

test "unsupported component field kind is rejected" {
    // `Vec3` type-checks in the resolver but the runtime registry rejects it at
    // registration (error.InvalidProgram → UnsupportedFieldKind), surfaced as a
    // cook diagnostic rather than a panic.
    try expectCookError(error.UnsupportedFieldKind,
        \\component Spin { axis: Vec3 = [0, 0, 0] }
        \\scene "S" {
        \\  entity "E" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" Spin { } }
        \\}
    );
}

test "undeclared resource type is rejected" {
    try expectCookError(error.UndeclaredType,
        \\scene "S" {
        \\  resources { Bogus { x: 1 } }
        \\}
    );
}

test "entity without uuid is rejected" {
    try expectCookError(error.MissingUuid,
        \\component Position { x: f32 = 0.0 }
        \\scene "S" {
        \\  entity "E" { Position { } }
        \\}
    );
}

test "undeclared component type on an entity is rejected" {
    try expectCookError(error.UndeclaredType,
        \\scene "S" {
        \\  entity "E" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" Ghost { } }
        \\}
    );
}

test "unknown field on a declared component is rejected" {
    try expectCookError(error.UnknownField,
        \\component Position { x: f32 = 0.0 }
        \\scene "S" {
        \\  entity "E" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" Position { z: 1.0 } }
        \\}
    );
}

test "malformed uuid is rejected" {
    try expectCookError(error.BadUuid,
        \\component Position { x: f32 = 0.0 }
        \\scene "S" {
        \\  entity "E" { uuid: "not-a-uuid" Position { } }
        \\}
    );
}
