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

/// Kind of one routine trigger alternative (`etch-grammar.md` §8.2).
pub const RoutineTriggerKind = enum { at_time, after_segment, on_event };

/// One routine trigger alternative. `value` holds the `DD:DD` time lexeme,
/// the referenced segment name, or the event type name, per kind.
pub const RoutineTrigger = struct {
    kind: RoutineTriggerKind,
    value: []const u8,
};

/// One routine segment, clauses in the §8.2 fixed order. Actions are
/// canonical-rendered call expressions.
pub const RoutineSegment = struct {
    name: []const u8,
    triggers: []const RoutineTrigger,
    actions: []const []const u8,
    untils: []const RoutineTrigger,
};

/// One `on_xxx -> target` routine interrupt.
pub const RoutineInterrupt = struct {
    event: []const u8,
    target: []const u8,
    is_pause: bool,
};

/// `routine` descriptor (`etch-ast-ir.md` §3.5: `Routine { segments }`).
pub const Routine = struct {
    name: []const u8,
    segments: []const RoutineSegment,
    interrupts: []const RoutineInterrupt,
};

/// Kind of one behavior-tree descriptor node (§8.1).
pub const BehaviorNodeKind = enum { selector, sequence, condition, action };

/// One behavior-tree node (M0.8 E4, `etch-ast-ir.md` §3.5: `Behavior {
/// root }` tree). `when` / `payload` are canonical-rendered texts ("" when
/// absent); `children` recurse for composites. NOTE (item-2 ruling): an
/// action `let` binds for later actions of its composite — the binding's
/// runtime SCOPE is pinned by Cortex Phase 1+, the descriptor carries the
/// structure only.
pub const BehaviorNode = struct {
    kind: BehaviorNodeKind,
    when: []const u8,
    payload: []const u8,
    children: []const BehaviorNode,
};

/// `behavior` descriptor (§3.5: `Behavior { root: BTNodeId }`).
pub const Behavior = struct {
    name: []const u8,
    root: BehaviorNode,
};

/// One Level-B descriptor, tagged by construct kind. Kept as ONE ordered
/// sequence per program so the canonical dump follows top-level
/// declaration order across construct kinds (engraved form).
pub const Descriptor = union(enum) {
    data: Data,
    routine: Routine,
    behavior: Behavior,

    /// Canonical serialization of one descriptor, dispatched on its kind.
    pub fn write(self: Descriptor, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        switch (self) {
            .data => |d| try writeData(d, gpa, out),
            .routine => |r| try writeRoutine(r, gpa, out),
            .behavior => |b| try writeBehavior(b, gpa, out),
        }
    }
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

fn triggerKindText(kind: RoutineTriggerKind) []const u8 {
    return switch (kind) {
        .at_time => "at",
        .after_segment => "after",
        .on_event => "on_event",
    };
}

/// Canonical serialization of one `routine` descriptor.
pub fn writeRoutine(r: Routine, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try appendFmt(gpa, out, "routine {s} {{\n", .{r.name});
    for (r.segments) |seg| {
        try appendFmt(gpa, out, "  segment {s} {{\n", .{seg.name});
        for (seg.triggers) |t| {
            try appendFmt(gpa, out, "    trigger {s} {s}\n", .{ triggerKindText(t.kind), t.value });
        }
        for (seg.actions) |a| {
            try appendFmt(gpa, out, "    action {s}\n", .{a});
        }
        for (seg.untils) |t| {
            try appendFmt(gpa, out, "    until {s} {s}\n", .{ triggerKindText(t.kind), t.value });
        }
        try out.appendSlice(gpa, "  }\n");
    }
    for (r.interrupts) |intr| {
        try appendFmt(gpa, out, "  interrupt {s} -> {s}\n", .{ intr.event, intr.target });
    }
    try out.appendSlice(gpa, "}\n");
}

/// Canonical serialization of one `behavior` descriptor (recursive tree).
pub fn writeBehavior(b: Behavior, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try appendFmt(gpa, out, "behavior {s} {{\n", .{b.name});
    try writeBTNode(b.root, 1, gpa, out);
    try out.appendSlice(gpa, "}\n");
}

fn writeBTNode(node: BehaviorNode, depth: u32, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    var d: u32 = 0;
    while (d < depth) : (d += 1) try out.appendSlice(gpa, "  ");
    switch (node.kind) {
        .selector, .sequence => {
            try out.appendSlice(gpa, if (node.kind == .selector) "selector" else "sequence");
            if (node.when.len != 0) {
                try appendFmt(gpa, out, " when {s}", .{node.when});
            }
            try out.appendSlice(gpa, " {\n");
            for (node.children) |child| {
                try writeBTNode(child, depth + 1, gpa, out);
            }
            d = 0;
            while (d < depth) : (d += 1) try out.appendSlice(gpa, "  ");
            try out.appendSlice(gpa, "}\n");
        },
        .condition => try appendFmt(gpa, out, "condition {s}\n", .{node.payload}),
        .action => try appendFmt(gpa, out, "action {s}\n", .{node.payload}),
    }
}

test "writeBehavior canonical form is stable" {
    const gpa = std.testing.allocator;
    const b: Behavior = .{
        .name = "CombatBehavior",
        .root = .{
            .kind = .selector,
            .when = "",
            .payload = "",
            .children = &.{
                .{ .kind = .sequence, .when = "self has Health { (current < (max * 0.2)) }", .payload = "", .children = &.{
                    .{ .kind = .action, .when = "", .payload = "let cover = find_cover(target)", .children = &.{} },
                } },
                .{ .kind = .condition, .when = "", .payload = "(hp > 0)", .children = &.{} },
            },
        },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try writeBehavior(b, gpa, &out);
    try std.testing.expectEqualStrings(
        \\behavior CombatBehavior {
        \\  selector {
        \\    sequence when self has Health { (current < (max * 0.2)) } {
        \\      action let cover = find_cover(target)
        \\    }
        \\    condition (hp > 0)
        \\  }
        \\}
        \\
    , out.items);
}

test "writeRoutine canonical form is stable" {
    const gpa = std.testing.allocator;
    const r: Routine = .{
        .name = "BlacksmithDaily",
        .segments = &.{
            .{
                .name = "Working",
                .triggers = &.{
                    .{ .kind = .at_time, .value = "06:00" },
                    .{ .kind = .after_segment, .value = "Sleeping" },
                },
                .actions = &.{"use_smart_object(\"forge_anvil\")"},
                .untils = &.{
                    .{ .kind = .on_event, .value = "MealCallReceived" },
                },
            },
        },
        .interrupts = &.{
            .{ .event = "on_dialogue_request", .target = "pause_segment", .is_pause = true },
        },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try writeRoutine(r, gpa, &out);
    try std.testing.expectEqualStrings(
        \\routine BlacksmithDaily {
        \\  segment Working {
        \\    trigger at 06:00
        \\    trigger after Sleeping
        \\    action use_smart_object("forge_anvil")
        \\    until on_event MealCallReceived
        \\  }
        \\  interrupt on_dialogue_request -> pause_segment
        \\}
        \\
    , out.items);
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
