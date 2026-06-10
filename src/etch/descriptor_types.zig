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

/// One quest property (`name = rendered value`).
pub const QuestPropDesc = struct {
    name: []const u8,
    value: []const u8,
};

/// One quest objective (modifier/label may be empty).
pub const QuestObjectiveDesc = struct {
    modifier: []const u8,
    label: []const u8,
    value: []const u8,
};

/// One quest handler. `payload` is the canonical text: an emit / a block
/// for on_start/on_complete, `<cond> -> <action>[(branch)]` for on_fail.
pub const QuestHandlerDesc = struct {
    kind: []const u8,
    payload: []const u8,
};

/// One quest branch — recursive stages.
pub const QuestBranchDesc = struct {
    name: []const u8,
    when: []const u8,
    stages: []const QuestStageDesc,
};

/// One stage element, DECLARATION ORDER preserved across kinds.
pub const QuestElementDesc = union(enum) {
    objective: QuestObjectiveDesc,
    handler: QuestHandlerDesc,
    branch: QuestBranchDesc,
    statement: []const u8,
};

/// One `[async] stage` with its ordered elements.
pub const QuestStageDesc = struct {
    name: []const u8,
    is_async: bool,
    elements: []const QuestElementDesc,
};

/// `quest` descriptor (`etch-ast-ir.md` §3.5 — handlers live per stage in
/// the PATCHED §8.3 grammar; the §3.5 principal shape is indicative).
pub const Quest = struct {
    name: []const u8,
    properties: []const QuestPropDesc,
    stages: []const QuestStageDesc,
};

/// One dialogue line (text + optional condition, canonical texts).
pub const DialogueLineDesc = struct {
    text: []const u8,
    when: []const u8,
};

/// One `speaker "id" { lines }` block.
pub const DialogueSpeakerDesc = struct {
    id: []const u8,
    lines: []const DialogueLineDesc,
};

/// One choice option (`target` is `end` or a branch label).
pub const DialogueOptionDesc = struct {
    text: []const u8,
    when: []const u8,
    target: []const u8,
};

/// One dialogue emit (payload + the item-11 trailing condition).
pub const DialogueEmitDesc = struct {
    payload: []const u8,
    when: []const u8,
};

/// One dialogue branch — elements recurse.
pub const DialogueBranchDesc = struct {
    name: []const u8,
    elements: []const DialogueElementDesc,
};

/// One dialogue element, declaration order preserved.
pub const DialogueElementDesc = union(enum) {
    speaker: DialogueSpeakerDesc,
    choice: []const DialogueOptionDesc,
    branch: DialogueBranchDesc,
    emit: DialogueEmitDesc,
    goto: []const u8,
};

/// `dialogue` descriptor (`etch-ast-ir.md` §3.5 — the oriented graph as
/// the ordered element list; transitions are `goto` / option targets).
pub const Dialogue = struct {
    name: []const u8,
    elements: []const DialogueElementDesc,
};

/// One ability property (`name: rendered value`, §8.5 declaration order).
pub const AbilityPropDesc = struct {
    name: []const u8,
    value: []const u8,
};

/// `ability` descriptor (`etch-ast-ir.md` §3.5 indicative shape transposed
/// onto the PATCHED §8.5 grammar — items 12-15 ruling: properties +
/// optional embedded rule). `rule` is the canonical single-line rule text
/// ("" when absent).
pub const Ability = struct {
    name: []const u8,
    properties: []const AbilityPropDesc,
    rule: []const u8,
};

/// One Level-B descriptor, tagged by construct kind. Kept as ONE ordered
/// sequence per program so the canonical dump follows top-level
/// declaration order across construct kinds (engraved form).
pub const Descriptor = union(enum) {
    data: Data,
    routine: Routine,
    behavior: Behavior,
    quest: Quest,
    dialogue: Dialogue,
    ability: Ability,

    /// Canonical serialization of one descriptor, dispatched on its kind.
    pub fn write(self: Descriptor, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        switch (self) {
            .data => |d| try writeData(d, gpa, out),
            .routine => |r| try writeRoutine(r, gpa, out),
            .behavior => |b| try writeBehavior(b, gpa, out),
            .quest => |q| try writeQuest(q, gpa, out),
            .dialogue => |d| try writeDialogue(d, gpa, out),
            .ability => |a| try writeAbility(a, gpa, out),
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

/// Canonical serialization of one `quest` descriptor (stages recurse
/// through branches).
pub fn writeQuest(q: Quest, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try appendFmt(gpa, out, "quest {s} {{\n", .{q.name});
    for (q.properties) |prop| {
        try appendFmt(gpa, out, "  property {s} = {s}\n", .{ prop.name, prop.value });
    }
    for (q.stages) |stage| {
        try writeQuestStage(stage, 1, gpa, out);
    }
    try out.appendSlice(gpa, "}\n");
}

fn writeIndent(depth: u32, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    var d: u32 = 0;
    while (d < depth) : (d += 1) try out.appendSlice(gpa, "  ");
}

fn writeQuestStage(stage: QuestStageDesc, depth: u32, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try writeIndent(depth, gpa, out);
    try appendFmt(gpa, out, "stage {s}{s} {{\n", .{ stage.name, if (stage.is_async) " async" else "" });
    for (stage.elements) |elem| {
        switch (elem) {
            .objective => |o| {
                try writeIndent(depth + 1, gpa, out);
                try out.appendSlice(gpa, "objective");
                if (o.modifier.len != 0) try appendFmt(gpa, out, " {s}", .{o.modifier});
                if (o.label.len != 0) try appendFmt(gpa, out, " {s}", .{o.label});
                try appendFmt(gpa, out, ": {s}\n", .{o.value});
            },
            .handler => |h| {
                try writeIndent(depth + 1, gpa, out);
                try appendFmt(gpa, out, "{s}: {s}\n", .{ h.kind, h.payload });
            },
            .branch => |b| {
                try writeIndent(depth + 1, gpa, out);
                try out.appendSlice(gpa, "branch ");
                try out.appendSlice(gpa, b.name);
                if (b.when.len != 0) try appendFmt(gpa, out, " when {s}", .{b.when});
                try out.appendSlice(gpa, " {\n");
                for (b.stages) |inner| {
                    try writeQuestStage(inner, depth + 2, gpa, out);
                }
                try writeIndent(depth + 1, gpa, out);
                try out.appendSlice(gpa, "}\n");
            },
            .statement => |text| {
                try writeIndent(depth + 1, gpa, out);
                try appendFmt(gpa, out, "statement {s}\n", .{text});
            },
        }
    }
    try writeIndent(depth, gpa, out);
    try out.appendSlice(gpa, "}\n");
}

/// Canonical serialization of one `dialogue` descriptor (branches recurse).
pub fn writeDialogue(d: Dialogue, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try appendFmt(gpa, out, "dialogue {s} {{\n", .{d.name});
    for (d.elements) |elem| {
        try writeDialogueElement(elem, 1, gpa, out);
    }
    try out.appendSlice(gpa, "}\n");
}

fn writeDialogueElement(elem: DialogueElementDesc, depth: u32, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try writeIndent(depth, gpa, out);
    switch (elem) {
        .speaker => |sp| {
            try appendFmt(gpa, out, "speaker \"{s}\" {{\n", .{sp.id});
            for (sp.lines) |line| {
                try writeIndent(depth + 1, gpa, out);
                try appendFmt(gpa, out, "line {s}", .{line.text});
                if (line.when.len != 0) try appendFmt(gpa, out, " when {s}", .{line.when});
                try out.appendSlice(gpa, "\n");
            }
            try writeIndent(depth, gpa, out);
            try out.appendSlice(gpa, "}\n");
        },
        .choice => |options| {
            try out.appendSlice(gpa, "choice {\n");
            for (options) |opt| {
                try writeIndent(depth + 1, gpa, out);
                try appendFmt(gpa, out, "option {s}", .{opt.text});
                if (opt.when.len != 0) try appendFmt(gpa, out, " when {s}", .{opt.when});
                try appendFmt(gpa, out, " -> {s}\n", .{opt.target});
            }
            try writeIndent(depth, gpa, out);
            try out.appendSlice(gpa, "}\n");
        },
        .branch => |b| {
            try appendFmt(gpa, out, "branch {s} {{\n", .{b.name});
            for (b.elements) |inner| {
                try writeDialogueElement(inner, depth + 1, gpa, out);
            }
            try writeIndent(depth, gpa, out);
            try out.appendSlice(gpa, "}\n");
        },
        .emit => |em| {
            try appendFmt(gpa, out, "{s}", .{em.payload});
            if (em.when.len != 0) try appendFmt(gpa, out, " when {s}", .{em.when});
            try out.appendSlice(gpa, "\n");
        },
        .goto => |target| try appendFmt(gpa, out, "goto {s}\n", .{target}),
    }
}

/// Canonical serialization of one `ability` descriptor.
pub fn writeAbility(a: Ability, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try appendFmt(gpa, out, "ability {s} {{\n", .{a.name});
    for (a.properties) |prop| {
        try writeIndent(1, gpa, out);
        try appendFmt(gpa, out, "{s}: {s}\n", .{ prop.name, prop.value });
    }
    if (a.rule.len != 0) {
        try writeIndent(1, gpa, out);
        try appendFmt(gpa, out, "{s}\n", .{a.rule});
    }
    try out.appendSlice(gpa, "}\n");
}

test "writeAbility canonical form is stable" {
    const gpa = std.testing.allocator;
    const a: Ability = .{
        .name = "Fireball",
        .properties = &.{
            .{ .name = "cost", .value = "{ mana: 20.0 }" },
            .{ .name = "cooldown", .value = "3.0" },
            .{ .name = "tags_required", .value = "[.character.status.alive]" },
        },
        .rule = "rule activate(caster: Entity) { emit Boom { x: 1 } }",
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try writeAbility(a, gpa, &out);
    try std.testing.expectEqualStrings(
        \\ability Fireball {
        \\  cost: { mana: 20.0 }
        \\  cooldown: 3.0
        \\  tags_required: [.character.status.alive]
        \\  rule activate(caster: Entity) { emit Boom { x: 1 } }
        \\}
        \\
    , out.items);
}

test "writeDialogue canonical form is stable" {
    const gpa = std.testing.allocator;
    const d: Dialogue = .{
        .name = "Greeting",
        .elements = &.{
            .{ .speaker = .{ .id = "merchant", .lines = &.{
                .{ .text = "\"Welcome!\"", .when = "" },
            } } },
            .{ .choice = &.{
                .{ .text = "\"Bye\"", .when = "", .target = "end" },
            } },
            .{ .branch = .{ .name = "wares", .elements = &.{
                .{ .emit = .{ .payload = "emit OpenShopUI { shop: 1 }", .when = "(not x)" } },
                .{ .goto = "end" },
            } } },
        },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try writeDialogue(d, gpa, &out);
    try std.testing.expectEqualStrings(
        \\dialogue Greeting {
        \\  speaker "merchant" {
        \\    line "Welcome!"
        \\  }
        \\  choice {
        \\    option "Bye" -> end
        \\  }
        \\  branch wares {
        \\    emit OpenShopUI { shop: 1 } when (not x)
        \\    goto end
        \\  }
        \\}
        \\
    , out.items);
}

test "writeQuest canonical form is stable" {
    const gpa = std.testing.allocator;
    const q: Quest = .{
        .name = "Escort",
        .properties = &.{
            .{ .name = "required_level", .value = "5" },
        },
        .stages = &.{
            .{ .name = "talk", .is_async = false, .elements = &.{
                .{ .objective = .{ .modifier = "main", .label = "", .value = "interact_with(\"m\")" } },
                .{ .handler = .{ .kind = "on_fail", .payload = "died() -> fail_quest" } },
                .{ .branch = .{ .name = "alt", .when = "true", .stages = &.{
                    .{ .name = "inner", .is_async = true, .elements = &.{} },
                } } },
            } },
        },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try writeQuest(q, gpa, &out);
    try std.testing.expectEqualStrings(
        \\quest Escort {
        \\  property required_level = 5
        \\  stage talk {
        \\    objective main: interact_with("m")
        \\    on_fail: died() -> fail_quest
        \\    branch alt when true {
        \\      stage inner async {
        \\      }
        \\    }
        \\  }
        \\}
        \\
    , out.items);
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
