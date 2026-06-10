//! Level-B descriptor types + canonical serialization (M0.8 E4–E6).
//!
//! SELF-CONTAINED BY CONTRACT: this file imports `std` only. It is compiled
//! twice from the same source bytes — (1) imported by `weld_etch`
//! (`descriptor.zig`, the interpreter build-structure side) and (2) embedded
//! verbatim into the consolidated codegen output as a nested namespace
//! (`zig_codegen/consolidate.zig`, the emit-structure side). Single source,
//! two compilations, no module dependency — so the cooked file keeps its
//! weld_core-only import surface and the serialized-IR differential compares
//! one canonical form produced by the same serializer on both backends.
//!
//! Canonical serialization form (engraved at the E4 launch, M0.8 brief
//! journal 2026-06-10): line-oriented indented text dump, declaration order
//! only (never hash order), named fields in fixed descriptor-schema order,
//! expression leaves pre-rendered to canonical text by ONE renderer
//! (`descriptor.zig`), LF endings, two-space indent. An internal proof tool,
//! not a public file format.

const std = @import("std");

/// `data` table descriptor (`etch-ast-ir.md` §3.5: `Data { entry_type,
/// entries }`). Strings are caller-owned slices; the cooked emit-structure
/// side points them at static string literals.
pub const Data = struct {
    name: []const u8,
    entry_type: []const u8,
    entries: []const DataEntry,
};

/// One validated `data` entry, fields in declaration order.
pub const DataEntry = struct {
    id: []const u8,
    fields: []const DataField,
};

/// One field initializer of a data entry. `value` is the canonical rendering
/// of the value expression; a spread (`..Table.entry`) carries the rendered
/// reference in `value` with `is_spread = true` and an empty `name`.
pub const DataField = struct {
    name: []const u8,
    value: []const u8,
    is_spread: bool,
};

fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

/// Canonical serialization of one `data` descriptor.
pub fn writeData(d: Data, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try appendFmt(gpa, out, "data {s} {{\n", .{d.name});
    try appendFmt(gpa, out, "  entry_type: {s}\n", .{d.entry_type});
    for (d.entries) |e| {
        try appendFmt(gpa, out, "  entry {s} {{\n", .{e.id});
        for (e.fields) |f| {
            if (f.is_spread) {
                try appendFmt(gpa, out, "    spread {s}\n", .{f.value});
            } else {
                try appendFmt(gpa, out, "    field {s} = {s}\n", .{ f.name, f.value });
            }
        }
        try out.appendSlice(gpa, "  }\n");
    }
    try out.appendSlice(gpa, "}\n");
}

test "writeData canonical form is stable" {
    const gpa = std.testing.allocator;
    const d: Data = .{
        .name = "ItemDatabase",
        .entry_type = "Item",
        .entries = &.{
            .{ .id = "iron_sword", .fields = &.{
                .{ .name = "value", .value = "50", .is_spread = false },
            } },
            .{ .id = "iron_sword_enchanted", .fields = &.{
                .{ .name = "", .value = "ItemDatabase.iron_sword", .is_spread = true },
                .{ .name = "value", .value = "120", .is_spread = false },
            } },
        },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try writeData(d, gpa, &out);
    try std.testing.expectEqualStrings(
        \\data ItemDatabase {
        \\  entry_type: Item
        \\  entry iron_sword {
        \\    field value = 50
        \\  }
        \\  entry iron_sword_enchanted {
        \\    spread ItemDatabase.iron_sword
        \\    field value = 120
        \\  }
        \\}
        \\
    , out.items);
}
