//! M1.0.6 E5 — `extensions:` clause: parse + AST + descriptors (Claude.ai
//! amendment). The clause `extensions: [STRING_LITERAL]` on `entity`/`instance`
//! (after `uuid`/`parent`, before components) records active-extension prefab
//! names by name (like `parent:` / cross-refs, D-B).
//!
//! The cook/binary portions of E5/E6 (Entity Extensions Table + Prefab ID Table,
//! the `extends` cook + `.prefab.bin` hooks section, `applyExtensions` + the
//! `on_attach` dispatch at load) land here once the `.prefab.bin` hooks-section
//! shape blocker is resolved — see `briefs/M1.0.6-…` Blockers.

const std = @import("std");
const weld_etch = @import("weld_etch");

const parser = weld_etch.parser;
const descriptor = weld_etch.descriptor;

test "entity and instance extensions clauses parse to AST names" {
    const gpa = std.testing.allocator;
    const src =
        \\component Health { current: i32 = 100 }
        \\scene "S" {
        \\  entity "A" {
        \\    uuid: "00000000-0000-0000-0000-000000000001"
        \\    extensions: ["CombatModule", "DialogueModule"]
        \\    Health { current: 50 }
        \\  }
        \\  instance of "Base" "I" {
        \\    uuid: "00000000-0000-0000-0000-000000000002"
        \\    extensions: ["MerchantModule"]
        \\  }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    const ast = &pr.ast;

    const a = ast.scene_entities.items[0];
    try std.testing.expectEqual(@as(u32, 2), a.extensions_len);
    try std.testing.expectEqualStrings("CombatModule", ast.strings.slice(ast.scene_extensions.items[a.extensions_start]));
    try std.testing.expectEqualStrings("DialogueModule", ast.strings.slice(ast.scene_extensions.items[a.extensions_start + 1]));

    const inst = ast.scene_instances.items[0];
    try std.testing.expectEqual(@as(u32, 1), inst.extensions_len);
    try std.testing.expectEqualStrings("MerchantModule", ast.strings.slice(ast.scene_extensions.items[inst.extensions_start]));
}

test "empty extensions list and trailing comma parse" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  entity "A" { uuid: "00000000-0000-0000-0000-000000000001" extensions: [] }
        \\  entity "B" { uuid: "00000000-0000-0000-0000-000000000002" extensions: ["X",] }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    const ast = &pr.ast;

    try std.testing.expectEqual(@as(u32, 0), ast.scene_entities.items[0].extensions_len);
    const b = ast.scene_entities.items[1];
    try std.testing.expectEqual(@as(u32, 1), b.extensions_len);
    try std.testing.expectEqualStrings("X", ast.strings.slice(ast.scene_extensions.items[b.extensions_start]));
}

test "an entity with no extensions clause has an empty run" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  entity "A" { uuid: "00000000-0000-0000-0000-000000000001" }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 0), pr.ast.scene_entities.items[0].extensions_len);
}

test "descriptors carry the extensions names" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  entity "A" {
        \\    uuid: "00000000-0000-0000-0000-000000000001"
        \\    extensions: ["X", "Y"]
        \\  }
        \\  instance of "Base" "I" {
        \\    uuid: "00000000-0000-0000-0000-000000000002"
        \\    extensions: ["Z"]
        \\  }
        \\}
    ;
    var pr = try parser.parse(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var descs = try descriptor.build(gpa, &pr.ast);
    defer descs.deinit(gpa);

    var saw_scene = false;
    for (descs.items) |d| switch (d) {
        .scene => |sc| {
            saw_scene = true;
            try std.testing.expectEqual(@as(usize, 1), sc.entities.len);
            try std.testing.expectEqual(@as(usize, 2), sc.entities[0].extensions.len);
            try std.testing.expectEqualStrings("X", sc.entities[0].extensions[0]);
            try std.testing.expectEqualStrings("Y", sc.entities[0].extensions[1]);
            try std.testing.expectEqual(@as(usize, 1), sc.instances.len);
            try std.testing.expectEqual(@as(usize, 1), sc.instances[0].extensions.len);
            try std.testing.expectEqualStrings("Z", sc.instances[0].extensions[0]);
        },
        else => {},
    };
    try std.testing.expect(saw_scene);
}
