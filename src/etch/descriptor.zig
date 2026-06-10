//! Level-B descriptor builder — the interpreter's build-structure side of
//! the M0.8 E4–E6 serialized-IR differential (LEVEL-B PROOF CONTRACT,
//! M0.8 brief journal 2026-06-10).
//!
//! `build` walks a parsed-and-validated AST and constructs one typed
//! descriptor per Level-B construct (`etch-ast-ir.md` §3.5 domain sub-ASTs).
//! `Descriptors.serialize` emits the canonical text form via the shared
//! serializer in `descriptor_types.zig` (compiled into BOTH backends from
//! the same source bytes — see that file's header).
//!
//! Expression leaves inside a descriptor are rendered to canonical text by
//! `renderExpr` — the ONE canonical expression renderer of the proof
//! contract. The codegen emit-structure side (`zig_codegen/lower.zig`) calls
//! the same renderer at cook time, so a byte difference in the differential
//! can only come from the two independent CONSTRUCT WALKS, which is exactly
//! what the Level-B differential proves. An expression kind outside the
//! supported set fails loud (`error.UnsupportedDescriptorExpr`) — never a
//! silently-wrong rendering.

const std = @import("std");
const ast_mod = @import("ast.zig");

/// Shared descriptor types + canonical serializer (`descriptor_types.zig`)
/// — the file compiled into BOTH backends (see its header contract).
pub const types = @import("descriptor_types.zig");

const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;

/// Error set of the descriptor builder — allocation plus the fail-loud
/// rejection of expression kinds outside the canonical renderer's set.
pub const BuildError = error{
    OutOfMemory,
    UnsupportedDescriptorExpr,
};

/// Owned ordered sequence of Level-B descriptors built from one AST, in
/// top-level declaration order ACROSS construct kinds (the engraved
/// canonical-form rule). Every string is gpa-owned (no arena borrows —
/// the descriptors outlive nothing but the interpreter that holds them).
pub const Descriptors = struct {
    items: []types.Descriptor = &.{},

    pub fn deinit(self: *Descriptors, gpa: std.mem.Allocator) void {
        for (self.items) |d| freeDescriptor(gpa, d);
        gpa.free(self.items);
        self.* = .{};
    }

    /// Canonical serialization of every descriptor, declaration order.
    /// The Level-B differential compares these bytes against the cooked
    /// backend's `writeDescriptors` output.
    pub fn serialize(self: *const Descriptors, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        for (self.items) |d| {
            try d.write(gpa, out);
        }
    }
};

fn freeDescriptor(gpa: std.mem.Allocator, d: types.Descriptor) void {
    switch (d) {
        .data => |t| freeData(gpa, t),
        .routine => |r| freeRoutine(gpa, r),
        .behavior => |b| freeBehavior(gpa, b),
        .quest => |q| freeQuest(gpa, q),
    }
}

fn freeQuest(gpa: std.mem.Allocator, q: types.Quest) void {
    gpa.free(q.name);
    for (q.properties) |prop| {
        gpa.free(prop.name);
        gpa.free(prop.value);
    }
    gpa.free(q.properties);
    for (q.stages) |stage| freeQuestStage(gpa, stage);
    gpa.free(q.stages);
}

fn freeQuestStage(gpa: std.mem.Allocator, stage: types.QuestStageDesc) void {
    gpa.free(stage.name);
    for (stage.elements) |elem| {
        switch (elem) {
            .objective => |o| {
                gpa.free(o.modifier);
                gpa.free(o.label);
                gpa.free(o.value);
            },
            .handler => |h| {
                gpa.free(h.kind);
                gpa.free(h.payload);
            },
            .branch => |b| {
                gpa.free(b.name);
                gpa.free(b.when);
                for (b.stages) |inner| freeQuestStage(gpa, inner);
                gpa.free(b.stages);
            },
            .statement => |text| gpa.free(text),
        }
    }
    gpa.free(stage.elements);
}

fn freeBehavior(gpa: std.mem.Allocator, b: types.Behavior) void {
    gpa.free(b.name);
    freeBTNode(gpa, b.root);
}

fn freeBTNode(gpa: std.mem.Allocator, node: types.BehaviorNode) void {
    gpa.free(node.when);
    gpa.free(node.payload);
    for (node.children) |child| freeBTNode(gpa, child);
    gpa.free(node.children);
}

fn freeRoutine(gpa: std.mem.Allocator, r: types.Routine) void {
    gpa.free(r.name);
    for (r.segments) |seg| {
        gpa.free(seg.name);
        for (seg.triggers) |t| gpa.free(t.value);
        gpa.free(seg.triggers);
        for (seg.actions) |a| gpa.free(a);
        gpa.free(seg.actions);
        for (seg.untils) |t| gpa.free(t.value);
        gpa.free(seg.untils);
    }
    gpa.free(r.segments);
    for (r.interrupts) |intr| {
        gpa.free(intr.event);
        gpa.free(intr.target);
    }
    gpa.free(r.interrupts);
}

fn freeData(gpa: std.mem.Allocator, t: types.Data) void {
    gpa.free(t.name);
    gpa.free(t.entry_type);
    for (t.entries) |e| {
        gpa.free(e.id);
        for (e.fields) |f| {
            gpa.free(f.name);
            gpa.free(f.value);
        }
        gpa.free(e.fields);
    }
    gpa.free(t.entries);
}

/// Build every Level-B descriptor from `arena`, in declaration order. The
/// AST is expected validated (the type-checker ran clean) — `build` does
/// not re-validate, it constructs.
pub fn build(gpa: std.mem.Allocator, arena: *const AstArena) BuildError!Descriptors {
    var list: std.ArrayListUnmanaged(types.Descriptor) = .empty;
    errdefer {
        for (list.items) |d| freeDescriptor(gpa, d);
        list.deinit(gpa);
    }
    const kinds = arena.items.items(.kind);
    const datas = arena.items.items(.data);
    var i: u28 = 0;
    while (i < arena.items.len) : (i += 1) {
        switch (kinds[i]) {
            .data_decl => try list.append(gpa, .{ .data = try buildData(gpa, arena, arena.data_decls.items[datas[i]]) }),
            .routine_decl => try list.append(gpa, .{ .routine = try buildRoutine(gpa, arena, arena.routine_decls.items[datas[i]]) }),
            .behavior_decl => try list.append(gpa, .{ .behavior = try buildBehavior(gpa, arena, arena.behavior_decls.items[datas[i]]) }),
            .quest_decl => try list.append(gpa, .{ .quest = try buildQuest(gpa, arena, arena.quest_decls.items[datas[i]]) }),
            else => {},
        }
    }
    return .{ .items = try list.toOwnedSlice(gpa) };
}

fn buildRoutine(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.RoutineDecl) BuildError!types.Routine {
    var segments: std.ArrayListUnmanaged(types.RoutineSegment) = .empty;
    errdefer {
        for (segments.items) |seg| {
            gpa.free(seg.name);
            for (seg.triggers) |t| gpa.free(t.value);
            gpa.free(seg.triggers);
            for (seg.actions) |a| gpa.free(a);
            gpa.free(seg.actions);
            for (seg.untils) |t| gpa.free(t.value);
            gpa.free(seg.untils);
        }
        segments.deinit(gpa);
    }
    var s: u32 = 0;
    while (s < decl.segments_len) : (s += 1) {
        const seg = arena.routine_segments.items[decl.segments_start + s];
        const triggers = try buildTriggerRun(gpa, arena, seg.triggers_start, seg.triggers_len);
        errdefer {
            for (triggers) |t| gpa.free(t.value);
            gpa.free(triggers);
        }
        const untils = try buildTriggerRun(gpa, arena, seg.untils_start, seg.untils_len);
        errdefer {
            for (untils) |t| gpa.free(t.value);
            gpa.free(untils);
        }
        var actions: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (actions.items) |a| gpa.free(a);
            actions.deinit(gpa);
        }
        var a: u32 = 0;
        while (a < seg.actions_len) : (a += 1) {
            const action: NodeId = @bitCast(arena.extra.items[seg.actions_start + a]);
            const rendered = try renderExprAlloc(gpa, arena, action);
            errdefer gpa.free(rendered);
            try actions.append(gpa, rendered);
        }
        const seg_name = try gpa.dupe(u8, arena.strings.slice(seg.name));
        errdefer gpa.free(seg_name);
        try segments.append(gpa, .{
            .name = seg_name,
            .triggers = triggers,
            .actions = try actions.toOwnedSlice(gpa),
            .untils = untils,
        });
    }
    var interrupts: std.ArrayListUnmanaged(types.RoutineInterrupt) = .empty;
    errdefer {
        for (interrupts.items) |intr| {
            gpa.free(intr.event);
            gpa.free(intr.target);
        }
        interrupts.deinit(gpa);
    }
    var it: u32 = 0;
    while (it < decl.interrupts_len) : (it += 1) {
        const intr = arena.routine_interrupts.items[decl.interrupts_start + it];
        const event = try gpa.dupe(u8, arena.strings.slice(intr.event_name));
        errdefer gpa.free(event);
        const target = try gpa.dupe(u8, arena.strings.slice(intr.target));
        errdefer gpa.free(target);
        try interrupts.append(gpa, .{ .event = event, .target = target, .is_pause = intr.is_pause });
    }
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{
        .name = name,
        .segments = try segments.toOwnedSlice(gpa),
        .interrupts = try interrupts.toOwnedSlice(gpa),
    };
}

fn buildTriggerRun(gpa: std.mem.Allocator, arena: *const AstArena, start: u32, len: u32) BuildError![]types.RoutineTrigger {
    var triggers: std.ArrayListUnmanaged(types.RoutineTrigger) = .empty;
    errdefer {
        for (triggers.items) |t| gpa.free(t.value);
        triggers.deinit(gpa);
    }
    var t: u32 = 0;
    while (t < len) : (t += 1) {
        const trig = arena.routine_triggers.items[start + t];
        const value = try gpa.dupe(u8, arena.strings.slice(trig.value));
        errdefer gpa.free(value);
        try triggers.append(gpa, .{
            .kind = switch (trig.kind) {
                .at_time => .at_time,
                .after_segment => .after_segment,
                .on_event => .on_event,
            },
            .value = value,
        });
    }
    return try triggers.toOwnedSlice(gpa);
}

fn buildData(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.DataDecl) BuildError!types.Data {
    var entries: std.ArrayListUnmanaged(types.DataEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.id);
            for (e.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.value);
            }
            gpa.free(e.fields);
        }
        entries.deinit(gpa);
    }
    var e: u32 = 0;
    while (e < decl.entries_len) : (e += 1) {
        const entry = arena.data_entries.items[decl.entries_start + e];
        var fields: std.ArrayListUnmanaged(types.DataField) = .empty;
        errdefer {
            for (fields.items) |f| {
                gpa.free(f.name);
                gpa.free(f.value);
            }
            fields.deinit(gpa);
        }
        var f: u32 = 0;
        while (f < entry.fields_len) : (f += 1) {
            const field = arena.struct_lit_fields.items[entry.fields_start + f];
            const value = try renderExprAlloc(gpa, arena, field.value);
            errdefer gpa.free(value);
            const name = try gpa.dupe(u8, if (field.name == 0) "" else arena.strings.slice(field.name));
            try fields.append(gpa, .{
                .name = name,
                .value = value,
                .is_spread = field.name == 0,
            });
        }
        const id = try gpa.dupe(u8, arena.strings.slice(entry.id));
        errdefer gpa.free(id);
        try entries.append(gpa, .{
            .id = id,
            .fields = try fields.toOwnedSlice(gpa),
        });
    }
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    const entry_type = try gpa.dupe(u8, arena.strings.slice(decl.entry_type));
    return .{
        .name = name,
        .entry_type = entry_type,
        .entries = try entries.toOwnedSlice(gpa),
    };
}

fn buildBehavior(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.BehaviorDecl) BuildError!types.Behavior {
    const root = try buildBTNode(gpa, arena, decl.root);
    errdefer freeBTNode(gpa, root);
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    return .{ .name = name, .root = root };
}

fn buildBTNode(gpa: std.mem.Allocator, arena: *const AstArena, node_idx: u32) BuildError!types.BehaviorNode {
    const node = arena.bt_nodes.items[node_idx];
    const kind: types.BehaviorNodeKind = switch (node.kind) {
        .selector => .selector,
        .sequence => .sequence,
        .condition => .condition,
        .action => .action,
    };
    switch (node.kind) {
        .selector, .sequence => {
            const when_text = if (node.when_root == ast_mod.RuleDecl.none_when)
                try gpa.dupe(u8, "")
            else
                try renderWhenAlloc(gpa, arena, node.when_root);
            errdefer gpa.free(when_text);
            var children: std.ArrayListUnmanaged(types.BehaviorNode) = .empty;
            errdefer {
                for (children.items) |child| freeBTNode(gpa, child);
                children.deinit(gpa);
            }
            var c: u32 = 0;
            while (c < node.children_len) : (c += 1) {
                try children.append(gpa, try buildBTNode(gpa, arena, arena.extra.items[node.children_start + c]));
            }
            return .{
                .kind = kind,
                .when = when_text,
                .payload = try gpa.dupe(u8, ""),
                .children = try children.toOwnedSlice(gpa),
            };
        },
        .condition, .action => {
            const payload = try renderBTPayloadAlloc(gpa, arena, node);
            errdefer gpa.free(payload);
            return .{
                .kind = kind,
                .when = try gpa.dupe(u8, ""),
                .payload = payload,
                .children = try gpa.alloc(types.BehaviorNode, 0),
            };
        },
    }
}

fn buildQuest(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.QuestDecl) BuildError!types.Quest {
    var properties: std.ArrayListUnmanaged(types.QuestPropDesc) = .empty;
    errdefer {
        for (properties.items) |prop| {
            gpa.free(prop.name);
            gpa.free(prop.value);
        }
        properties.deinit(gpa);
    }
    var p: u32 = 0;
    while (p < decl.properties_len) : (p += 1) {
        const prop = arena.quest_properties.items[decl.properties_start + p];
        const value = try renderExprAlloc(gpa, arena, prop.value);
        errdefer gpa.free(value);
        const name = try gpa.dupe(u8, arena.strings.slice(prop.name));
        errdefer gpa.free(name);
        try properties.append(gpa, .{ .name = name, .value = value });
    }
    var stages: std.ArrayListUnmanaged(types.QuestStageDesc) = .empty;
    errdefer {
        for (stages.items) |stage| freeQuestStage(gpa, stage);
        stages.deinit(gpa);
    }
    var st: u32 = 0;
    while (st < decl.stages_len) : (st += 1) {
        try stages.append(gpa, try buildQuestStage(gpa, arena, arena.extra.items[decl.stages_start + st]));
    }
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    return .{
        .name = name,
        .properties = try properties.toOwnedSlice(gpa),
        .stages = try stages.toOwnedSlice(gpa),
    };
}

fn buildQuestStage(gpa: std.mem.Allocator, arena: *const AstArena, stage_idx: u32) BuildError!types.QuestStageDesc {
    const stage = arena.quest_stages.items[stage_idx];
    var elements: std.ArrayListUnmanaged(types.QuestElementDesc) = .empty;
    errdefer {
        for (elements.items) |elem| {
            switch (elem) {
                .objective => |o| {
                    gpa.free(o.modifier);
                    gpa.free(o.label);
                    gpa.free(o.value);
                },
                .handler => |h| {
                    gpa.free(h.kind);
                    gpa.free(h.payload);
                },
                .branch => |b| {
                    gpa.free(b.name);
                    gpa.free(b.when);
                    for (b.stages) |inner| freeQuestStage(gpa, inner);
                    gpa.free(b.stages);
                },
                .statement => |text| gpa.free(text),
            }
        }
        elements.deinit(gpa);
    }
    var e: u32 = 0;
    while (e < stage.elems_len) : (e += 1) {
        const elem = arena.quest_elems.items[stage.elems_start + e];
        switch (elem.kind) {
            .objective => {
                const obj = arena.quest_objectives.items[elem.index];
                const value = try renderExprAlloc(gpa, arena, obj.value);
                errdefer gpa.free(value);
                const modifier = try gpa.dupe(u8, switch (obj.modifier) {
                    .none => "",
                    .main => "main",
                    .optional => "optional",
                });
                errdefer gpa.free(modifier);
                const label = try gpa.dupe(u8, if (obj.label == 0) "" else arena.strings.slice(obj.label));
                errdefer gpa.free(label);
                try elements.append(gpa, .{ .objective = .{ .modifier = modifier, .label = label, .value = value } });
            },
            .handler => {
                const h = arena.quest_handlers.items[elem.index];
                const payload = try renderQuestHandlerPayload(gpa, arena, h);
                errdefer gpa.free(payload);
                const kind_text = try gpa.dupe(u8, switch (h.kind) {
                    .on_start => "on_start",
                    .on_complete => "on_complete",
                    .on_fail => "on_fail",
                });
                errdefer gpa.free(kind_text);
                try elements.append(gpa, .{ .handler = .{ .kind = kind_text, .payload = payload } });
            },
            .branch => {
                const branch = arena.quest_branches.items[elem.index];
                const when_text = if (branch.when_root == ast_mod.RuleDecl.none_when)
                    try gpa.dupe(u8, "")
                else
                    try renderWhenAlloc(gpa, arena, branch.when_root);
                errdefer gpa.free(when_text);
                var inner: std.ArrayListUnmanaged(types.QuestStageDesc) = .empty;
                errdefer {
                    for (inner.items) |st2| freeQuestStage(gpa, st2);
                    inner.deinit(gpa);
                }
                var bs: u32 = 0;
                while (bs < branch.stages_len) : (bs += 1) {
                    try inner.append(gpa, try buildQuestStage(gpa, arena, arena.extra.items[branch.stages_start + bs]));
                }
                const bname = try gpa.dupe(u8, arena.strings.slice(branch.name));
                errdefer gpa.free(bname);
                try elements.append(gpa, .{ .branch = .{ .name = bname, .when = when_text, .stages = try inner.toOwnedSlice(gpa) } });
            },
            .statement => {
                const stmt: NodeId = @bitCast(elem.index);
                try elements.append(gpa, .{ .statement = try renderStmtAlloc(gpa, arena, stmt) });
            },
        }
    }
    const name = try gpa.dupe(u8, arena.strings.slice(stage.name));
    return .{
        .name = name,
        .is_async = stage.is_async,
        .elements = try elements.toOwnedSlice(gpa),
    };
}

/// Render a quest handler payload (M0.8 E4): on_start/on_complete carry an
/// emit or a block; on_fail renders `<cond> -> <action>[(branch)]`.
pub fn renderQuestHandlerPayloadAlloc(gpa: std.mem.Allocator, arena: *const AstArena, h: ast_mod.QuestHandler) BuildError![]u8 {
    return renderQuestHandlerPayload(gpa, arena, h);
}

fn renderQuestHandlerPayload(gpa: std.mem.Allocator, arena: *const AstArena, h: ast_mod.QuestHandler) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    if (h.kind == .on_fail) {
        try renderExpr(gpa, arena, h.fail_cond, &buf);
        try buf.appendSlice(gpa, " -> ");
        try buf.appendSlice(gpa, switch (h.fail_action) {
            .restart_stage => "restart_stage",
            .fail_quest => "fail_quest",
            .switch_branch => "switch_branch",
        });
        if (h.fail_action == .switch_branch) {
            try buf.appendSlice(gpa, "(");
            try buf.appendSlice(gpa, arena.strings.slice(h.fail_branch));
            try buf.appendSlice(gpa, ")");
        }
        return try buf.toOwnedSlice(gpa);
    }
    if (h.payload_is_stmt) {
        const text = try renderStmtAlloc(gpa, arena, h.payload);
        buf.deinit(gpa);
        return text;
    }
    try renderBlock(gpa, arena, h.payload, &buf);
    return try buf.toOwnedSlice(gpa);
}

/// Render one statement to canonical text (M0.8 E4 — quest handler blocks
/// and stage statements). Bounded to the script-shaped kinds (`let` /
/// `emit` / expression / assignment); anything else fails loud.
pub fn renderStmtAlloc(gpa: std.mem.Allocator, arena: *const AstArena, stmt: NodeId) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try renderStmt(gpa, arena, stmt, &buf);
    return try buf.toOwnedSlice(gpa);
}

fn renderStmt(gpa: std.mem.Allocator, arena: *const AstArena, stmt: NodeId, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    switch (arena.stmtKind(stmt)) {
        .let_stmt => {
            const let = arena.let_stmts.items[arena.stmtData(stmt)];
            try out.appendSlice(gpa, "let ");
            if (let.is_mut) try out.appendSlice(gpa, "mut ");
            try out.appendSlice(gpa, arena.strings.slice(let.name));
            try out.appendSlice(gpa, " = ");
            try renderExpr(gpa, arena, let.value, out);
        },
        .emit_stmt => {
            const em = arena.emit_stmts.items[arena.stmtData(stmt)];
            try out.appendSlice(gpa, "emit ");
            try out.appendSlice(gpa, arena.strings.slice(em.event_type));
            if (em.fields_len == 0) {
                try out.appendSlice(gpa, " {}");
            } else {
                try out.appendSlice(gpa, " { ");
                var f: u32 = 0;
                while (f < em.fields_len) : (f += 1) {
                    if (f != 0) try out.appendSlice(gpa, ", ");
                    const field = arena.struct_lit_fields.items[em.fields_start + f];
                    try out.appendSlice(gpa, arena.strings.slice(field.name));
                    try out.appendSlice(gpa, ": ");
                    try renderExpr(gpa, arena, field.value, out);
                }
                try out.appendSlice(gpa, " }");
            }
        },
        .expr_stmt => try renderExpr(gpa, arena, @bitCast(arena.stmtData(stmt)), out),
        .assign_stmt => {
            const a = arena.assign_stmts.items[arena.stmtData(stmt)];
            try renderExpr(gpa, arena, a.target, out);
            try out.appendSlice(gpa, switch (a.op) {
                .assign => " = ",
                .add_assign => " += ",
                .sub_assign => " -= ",
                .mul_assign => " *= ",
                .div_assign => " /= ",
                else => return error.UnsupportedDescriptorExpr,
            });
            try renderExpr(gpa, arena, a.value, out);
        },
        else => return error.UnsupportedDescriptorExpr,
    }
}

/// Render a block expression payload as `{ stmt; …[; value] }`.
fn renderBlock(gpa: std.mem.Allocator, arena: *const AstArena, block: NodeId, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    const b = arena.block_exprs.items[arena.exprData(block)];
    try out.appendSlice(gpa, "{ ");
    var first = true;
    var i: u32 = 0;
    while (i < b.body_len) : (i += 1) {
        if (!first) try out.appendSlice(gpa, "; ");
        first = false;
        const stmt: NodeId = @bitCast(arena.extra.items[b.body_start + i]);
        try renderStmt(gpa, arena, stmt, out);
    }
    if (!b.value.isNone()) {
        if (!first) try out.appendSlice(gpa, "; ");
        try renderExpr(gpa, arena, b.value, out);
    }
    try out.appendSlice(gpa, " }");
}

/// Render a behavior leaf payload (M0.8 E4): the item-2 PATCHED action
/// forms — `let <name> = <expr>` / `emit T { f: v, … }` / an expression —
/// plus the plain condition expression.
pub fn renderBTPayloadAlloc(gpa: std.mem.Allocator, arena: *const AstArena, node: ast_mod.BTNode) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    if (!node.payload_is_stmt) {
        try renderExpr(gpa, arena, node.payload, &buf);
        return try buf.toOwnedSlice(gpa);
    }
    switch (arena.stmtKind(node.payload)) {
        .let_stmt => {
            const let = arena.let_stmts.items[arena.stmtData(node.payload)];
            try buf.appendSlice(gpa, "let ");
            if (let.is_mut) try buf.appendSlice(gpa, "mut ");
            try buf.appendSlice(gpa, arena.strings.slice(let.name));
            try buf.appendSlice(gpa, " = ");
            try renderExpr(gpa, arena, let.value, &buf);
        },
        .emit_stmt => {
            const em = arena.emit_stmts.items[arena.stmtData(node.payload)];
            try buf.appendSlice(gpa, "emit ");
            try buf.appendSlice(gpa, arena.strings.slice(em.event_type));
            if (em.fields_len == 0) {
                try buf.appendSlice(gpa, " {}");
            } else {
                try buf.appendSlice(gpa, " { ");
                var f: u32 = 0;
                while (f < em.fields_len) : (f += 1) {
                    if (f != 0) try buf.appendSlice(gpa, ", ");
                    const field = arena.struct_lit_fields.items[em.fields_start + f];
                    try buf.appendSlice(gpa, arena.strings.slice(field.name));
                    try buf.appendSlice(gpa, ": ");
                    try renderExpr(gpa, arena, field.value, &buf);
                }
                try buf.appendSlice(gpa, " }");
            }
        },
        else => return error.UnsupportedDescriptorExpr,
    }
    return try buf.toOwnedSlice(gpa);
}

/// Render a §6 when tree to its canonical text (M0.8 E4 — behavior
/// composite when clauses; the ONE canonical renderer family). Composites
/// parenthesize; leaves render their structured form.
pub fn renderWhenAlloc(gpa: std.mem.Allocator, arena: *const AstArena, when_idx: u32) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try renderWhen(gpa, arena, when_idx, &buf);
    return try buf.toOwnedSlice(gpa);
}

fn renderWhen(gpa: std.mem.Allocator, arena: *const AstArena, when_idx: u32, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    const node = arena.when_nodes.items[when_idx];
    switch (node.kind) {
        .logical_and, .logical_or => {
            try out.appendSlice(gpa, "(");
            try renderWhen(gpa, arena, node.lhs, out);
            try out.appendSlice(gpa, if (node.kind == .logical_and) " and " else " or ");
            try renderWhen(gpa, arena, node.rhs, out);
            try out.appendSlice(gpa, ")");
        },
        .logical_not => {
            try out.appendSlice(gpa, "(not ");
            try renderWhen(gpa, arena, node.lhs, out);
            try out.appendSlice(gpa, ")");
        },
        .has, .has_changed, .has_with_filter, .has_expr_filter => {
            try out.appendSlice(gpa, arena.strings.slice(node.entity_name));
            try out.appendSlice(gpa, " has ");
            try out.appendSlice(gpa, arena.strings.slice(node.type_name));
            switch (node.kind) {
                .has_changed => try out.appendSlice(gpa, " changed"),
                .has_with_filter => {
                    try out.appendSlice(gpa, " { ");
                    try out.appendSlice(gpa, arena.strings.slice(node.field_name));
                    try out.appendSlice(gpa, " == ");
                    try renderExpr(gpa, arena, node.filter_value, out);
                    try out.appendSlice(gpa, " }");
                },
                .has_expr_filter => {
                    try out.appendSlice(gpa, " { ");
                    try renderExpr(gpa, arena, node.filter_value, out);
                    try out.appendSlice(gpa, " }");
                },
                else => {},
            }
        },
        .resource, .resource_changed, .resource_filter => {
            try out.appendSlice(gpa, "resource ");
            try out.appendSlice(gpa, arena.strings.slice(node.type_name));
            switch (node.kind) {
                .resource_changed => try out.appendSlice(gpa, " changed"),
                .resource_filter => {
                    try out.appendSlice(gpa, " { ");
                    try renderExpr(gpa, arena, node.filter_value, out);
                    try out.appendSlice(gpa, " }");
                },
                else => {},
            }
        },
        .expr_cond => try renderExpr(gpa, arena, node.filter_value, out),
        .tag_filter => {
            const tf = arena.tag_filters.items[node.aux];
            try out.appendSlice(gpa, arena.strings.slice(node.entity_name));
            try out.appendSlice(gpa, " ");
            try out.appendSlice(gpa, @tagName(tf.op));
            try out.appendSlice(gpa, " ");
            if (tf.operand_len > 1) try out.appendSlice(gpa, "[");
            var oi: u32 = 0;
            while (oi < tf.operand_len) : (oi += 1) {
                if (oi != 0) try out.appendSlice(gpa, ", ");
                try renderTagPath(gpa, arena, arena.tag_operands.items[tf.operand_start + oi], out);
            }
            if (tf.operand_len > 1) try out.appendSlice(gpa, "]");
        },
    }
}

fn renderTagPath(gpa: std.mem.Allocator, arena: *const AstArena, path_node: NodeId, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    const tp = arena.tag_paths.items[arena.exprData(path_node)];
    var i: u32 = 0;
    while (i < tp.segs_len) : (i += 1) {
        try out.appendSlice(gpa, ".");
        try out.appendSlice(gpa, arena.strings.slice(arena.tag_path_segs.items[tp.segs_start + i]));
    }
}

/// Render one expression to its canonical text, allocated.
pub fn renderExprAlloc(gpa: std.mem.Allocator, arena: *const AstArena, id: NodeId) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try renderExpr(gpa, arena, id, &buf);
    return try buf.toOwnedSlice(gpa);
}

/// THE canonical expression renderer (proof contract, item 3). Literals
/// render their interned source lexeme (exact source bytes); strings
/// re-quote the decoded content with the §1.4 escapes; composites render
/// fully parenthesized so the form is precedence-free. Kinds outside the
/// supported set fail loud.
pub fn renderExpr(gpa: std.mem.Allocator, arena: *const AstArena, id: NodeId, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    const data = arena.exprData(id);
    switch (arena.exprKind(id)) {
        .int_lit, .float_lit, .bool_lit => try out.appendSlice(gpa, arena.strings.slice(data)),
        .string_lit => try renderQuoted(gpa, arena.strings.slice(data), out),
        .none_lit => try out.appendSlice(gpa, "none"),
        .some_lit => {
            try out.appendSlice(gpa, "some(");
            try renderExpr(gpa, arena, @bitCast(data), out);
            try out.appendSlice(gpa, ")");
        },
        .tag_path => {
            // Expression-position `.variant` shorthand — the variant ident is
            // the expr data directly (single segment; multi-segment paths are
            // tag-operand-only encodings).
            try out.appendSlice(gpa, ".");
            try out.appendSlice(gpa, arena.strings.slice(data));
        },
        .ident, .path => try out.appendSlice(gpa, arena.strings.slice(data)),
        .tag_query => {
            const tq = arena.tag_query_exprs.items[data];
            try renderExpr(gpa, arena, tq.receiver, out);
            const tf = arena.tag_filters.items[tq.filter];
            try out.appendSlice(gpa, " ");
            try out.appendSlice(gpa, @tagName(tf.op));
            try out.appendSlice(gpa, " ");
            if (tf.operand_len > 1) try out.appendSlice(gpa, "[");
            var oi: u32 = 0;
            while (oi < tf.operand_len) : (oi += 1) {
                if (oi != 0) try out.appendSlice(gpa, ", ");
                try renderTagPath(gpa, arena, arena.tag_operands.items[tf.operand_start + oi], out);
            }
            if (tf.operand_len > 1) try out.appendSlice(gpa, "]");
        },
        .fn_call => {
            const call = arena.call_exprs.items[data];
            try renderExpr(gpa, arena, call.callee, out);
            try out.appendSlice(gpa, "(");
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (i != 0) try out.appendSlice(gpa, ", ");
                if (call.names_start != ast_mod.no_arg_names) {
                    const label = arena.call_arg_names.items[call.names_start + i];
                    if (label != 0) {
                        try out.appendSlice(gpa, arena.strings.slice(label));
                        try out.appendSlice(gpa, ": ");
                    }
                }
                const arg: NodeId = @bitCast(arena.extra.items[call.args_start + i]);
                try renderExpr(gpa, arena, arg, out);
            }
            try out.appendSlice(gpa, ")");
        },
        .field_access => {
            const fa = arena.field_accesses.items[data];
            if (fa.opt_chain) return error.UnsupportedDescriptorExpr;
            try renderExpr(gpa, arena, fa.receiver, out);
            try out.appendSlice(gpa, ".");
            try out.appendSlice(gpa, arena.strings.slice(fa.field_name));
        },
        .method_get, .method_get_mut => {
            const mg = arena.method_gets.items[data];
            if (!mg.receiver.isNone()) {
                try renderExpr(gpa, arena, mg.receiver, out);
                try out.appendSlice(gpa, ".");
            }
            try out.appendSlice(gpa, if (arena.exprKind(id) == .method_get) "get(" else "get_mut(");
            try out.appendSlice(gpa, arena.strings.slice(mg.type_name));
            try out.appendSlice(gpa, ")");
        },
        .method_call => {
            const mcall = arena.method_calls.items[data];
            if (mcall.opt_chain) return error.UnsupportedDescriptorExpr;
            try renderExpr(gpa, arena, mcall.receiver, out);
            try out.appendSlice(gpa, ".");
            try out.appendSlice(gpa, arena.strings.slice(mcall.method_name));
            try out.appendSlice(gpa, "(");
            var i: u32 = 0;
            while (i < mcall.args_len) : (i += 1) {
                if (i != 0) try out.appendSlice(gpa, ", ");
                if (mcall.names_start != ast_mod.no_arg_names) {
                    const label = arena.call_arg_names.items[mcall.names_start + i];
                    if (label != 0) {
                        try out.appendSlice(gpa, arena.strings.slice(label));
                        try out.appendSlice(gpa, ": ");
                    }
                }
                const arg: NodeId = @bitCast(arena.extra.items[mcall.args_start + i]);
                try renderExpr(gpa, arena, arg, out);
            }
            try out.appendSlice(gpa, ")");
        },
        .unary => {
            const un = arena.unary_exprs.items[data];
            switch (un.op) {
                .neg => {
                    try out.appendSlice(gpa, "(-");
                    try renderExpr(gpa, arena, un.operand, out);
                    try out.appendSlice(gpa, ")");
                },
                .logical_not => {
                    try out.appendSlice(gpa, "(not ");
                    try renderExpr(gpa, arena, un.operand, out);
                    try out.appendSlice(gpa, ")");
                },
                .force_unwrap => {
                    try out.appendSlice(gpa, "(");
                    try renderExpr(gpa, arena, un.operand, out);
                    try out.appendSlice(gpa, "!)");
                },
            }
        },
        .binary => {
            const bin = arena.binary_exprs.items[data];
            try out.appendSlice(gpa, "(");
            try renderExpr(gpa, arena, bin.lhs, out);
            try out.appendSlice(gpa, " ");
            try out.appendSlice(gpa, binaryOpText(bin.op));
            try out.appendSlice(gpa, " ");
            try renderExpr(gpa, arena, bin.rhs, out);
            try out.appendSlice(gpa, ")");
        },
        .struct_lit => {
            const sl = arena.struct_lits.items[data];
            if (sl.type_name == 0) {
                try out.appendSlice(gpa, ".");
            } else {
                try out.appendSlice(gpa, arena.strings.slice(sl.type_name));
                try out.appendSlice(gpa, " ");
            }
            if (sl.fields_len == 0) {
                try out.appendSlice(gpa, "{}");
                return;
            }
            try out.appendSlice(gpa, "{ ");
            var f: u32 = 0;
            while (f < sl.fields_len) : (f += 1) {
                if (f != 0) try out.appendSlice(gpa, ", ");
                const field = arena.struct_lit_fields.items[sl.fields_start + f];
                if (field.name == 0) {
                    try out.appendSlice(gpa, "..");
                } else {
                    try out.appendSlice(gpa, arena.strings.slice(field.name));
                    try out.appendSlice(gpa, ": ");
                }
                try renderExpr(gpa, arena, field.value, out);
            }
            try out.appendSlice(gpa, " }");
        },
        .array_lit => {
            const al = arena.array_lits.items[data];
            if (al.is_fill) {
                try out.appendSlice(gpa, "[");
                const elem: NodeId = @bitCast(arena.extra.items[al.elements_start]);
                try renderExpr(gpa, arena, elem, out);
                try out.appendSlice(gpa, "; ");
                try renderExpr(gpa, arena, al.fill_count, out);
                try out.appendSlice(gpa, "]");
                return;
            }
            try out.appendSlice(gpa, "[");
            var i: u32 = 0;
            while (i < al.elements_len) : (i += 1) {
                if (i != 0) try out.appendSlice(gpa, ", ");
                const elem: NodeId = @bitCast(arena.extra.items[al.elements_start + i]);
                try renderExpr(gpa, arena, elem, out);
            }
            try out.appendSlice(gpa, "]");
        },
        .map_lit => {
            const ml = arena.map_lits.items[data];
            if (ml.entries_len == 0) {
                try out.appendSlice(gpa, "[:]");
                return;
            }
            try out.appendSlice(gpa, "[");
            var i: u32 = 0;
            while (i < ml.entries_len) : (i += 1) {
                if (i != 0) try out.appendSlice(gpa, ", ");
                const entry = arena.map_entries.items[ml.entries_start + i];
                try renderExpr(gpa, arena, entry.key, out);
                try out.appendSlice(gpa, ": ");
                try renderExpr(gpa, arena, entry.value, out);
            }
            try out.appendSlice(gpa, "]");
        },
        else => return error.UnsupportedDescriptorExpr,
    }
}

fn binaryOpText(op: ast_mod.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "%",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .logical_and => "and",
        .logical_or => "or",
        .coalesce => "??",
    };
}

/// Quote + escape a decoded string per the §1.4 escape set (`\"`, `\\`,
/// `\n`, `\t`, `\r`, `\{` — `{` must re-escape or the rendering would read
/// as an interpolation head).
fn renderQuoted(gpa: std.mem.Allocator, s: []const u8, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '{' => try out.appendSlice(gpa, "\\{"),
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}

const parser_mod = @import("parser.zig");

test "descriptor build + serialize: data table golden form (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var pr = try parser_mod.parse(gpa,
        \\enum Rarity { common, uncommon }
        \\struct Item {
        \\  rarity: Rarity = .common
        \\  weight: float = 0.0
        \\  display_name: string = ""
        \\  value: int
        \\}
        \\data ItemDatabase: Item {
        \\  iron_sword: {
        \\    rarity: .uncommon,
        \\    weight: 3.5,
        \\    display_name: "Iron \"Sword\"",
        \\    value: 50,
        \\  },
        \\  iron_sword_enchanted: {
        \\    ..ItemDatabase.iron_sword,
        \\    value: -120,
        \\  },
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var descs = try build(gpa, &pr.ast);
    defer descs.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), descs.items.len);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try descs.serialize(gpa, &out);
    try std.testing.expectEqualStrings(
        \\data ItemDatabase {
        \\  entry_type: Item
        \\  entry iron_sword {
        \\    field rarity = .uncommon
        \\    field weight = 3.5
        \\    field display_name = "Iron \"Sword\""
        \\    field value = 50
        \\  }
        \\  entry iron_sword_enchanted {
        \\    spread ItemDatabase.iron_sword
        \\    field value = (-120)
        \\  }
        \\}
        \\
    , out.items);
}

test "descriptor renderer fails loud on an unsupported expression kind (M0.8 E4)" {
    const gpa = std.testing.allocator;
    // A closure as a data value parses; the renderer must reject it rather
    // than emit a silently-wrong canonical form (Level-B fail-loud).
    var pr = try parser_mod.parse(gpa,
        \\data Table: Spec {
        \\  a: { f: |x| x },
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectError(error.UnsupportedDescriptorExpr, build(gpa, &pr.ast));
}
