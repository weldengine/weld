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
        .dialogue => |dlg| freeDialogue(gpa, dlg),
        .ability => |a| freeAbility(gpa, a),
        .theme => |t| freeTheme(gpa, t),
        .motion => |m| freeMotion(gpa, m),
        .input_mapping => |im| freeInputMapping(gpa, im),
        .widget => |w| freeWidget(gpa, w),
        .locale => |l| freeLocale(gpa, l),
        .effect => |e| freeEffect(gpa, e),
        .audio_graph => |ag| freeAudioGraph(gpa, ag),
    }
}

fn freeInputMapping(gpa: std.mem.Allocator, m: types.InputMapping) void {
    gpa.free(m.name);
    gpa.free(m.context);
    gpa.free(m.priority);
    gpa.free(m.consume_input);
    for (m.actions) |act| freeInputAction(gpa, act);
    gpa.free(m.actions);
    for (m.combos) |c| freeInputCombo(gpa, c);
    gpa.free(m.combos);
}

fn freeInputAction(gpa: std.mem.Allocator, act: types.InputActionDesc) void {
    gpa.free(act.name);
    gpa.free(act.type_name);
    gpa.free(act.output);
    for (act.binds) |bd| freeInputBind(gpa, bd);
    gpa.free(act.binds);
}

fn freeInputBind(gpa: std.mem.Allocator, bd: types.InputBindDesc) void {
    gpa.free(bd.source);
    gpa.free(bd.modifiers);
    gpa.free(bd.triggers);
    gpa.free(bd.output_mapping);
}

fn freeInputCombo(gpa: std.mem.Allocator, c: types.InputComboDesc) void {
    gpa.free(c.name);
    gpa.free(c.type_name);
    gpa.free(c.sequence);
    gpa.free(c.window);
}

fn freeTheme(gpa: std.mem.Allocator, t: types.Theme) void {
    gpa.free(t.name);
    for (t.entries) |e| {
        gpa.free(e.key);
        gpa.free(e.value);
    }
    gpa.free(t.entries);
}

fn freeMotion(gpa: std.mem.Allocator, m: types.Motion) void {
    gpa.free(m.name);
    for (m.states) |st| {
        gpa.free(st.name);
        for (st.fields) |f| {
            gpa.free(f.name);
            gpa.free(f.value);
        }
        gpa.free(st.fields);
    }
    gpa.free(m.states);
    for (m.transitions) |tr| {
        gpa.free(tr.source);
        gpa.free(tr.target);
        gpa.free(tr.animator);
    }
    gpa.free(m.transitions);
}

fn freeAbility(gpa: std.mem.Allocator, a: types.Ability) void {
    gpa.free(a.name);
    for (a.properties) |prop| {
        gpa.free(prop.name);
        gpa.free(prop.value);
    }
    gpa.free(a.properties);
    gpa.free(a.rule);
}

fn freeDialogue(gpa: std.mem.Allocator, d: types.Dialogue) void {
    gpa.free(d.name);
    freeDialogueElements(gpa, d.elements);
}

fn freeDialogueElements(gpa: std.mem.Allocator, elements: []const types.DialogueElementDesc) void {
    for (elements) |elem| {
        switch (elem) {
            .speaker => |sp| {
                gpa.free(sp.id);
                for (sp.lines) |line| {
                    gpa.free(line.text);
                    gpa.free(line.when);
                }
                gpa.free(sp.lines);
            },
            .choice => |options| {
                for (options) |opt| {
                    gpa.free(opt.text);
                    gpa.free(opt.when);
                    gpa.free(opt.target);
                }
                gpa.free(options);
            },
            .branch => |b| {
                gpa.free(b.name);
                freeDialogueElements(gpa, b.elements);
            },
            .emit => |em| {
                gpa.free(em.payload);
                gpa.free(em.when);
            },
            .goto => |target| gpa.free(target),
        }
    }
    gpa.free(elements);
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
            .dialogue_decl => try list.append(gpa, .{ .dialogue = try buildDialogue(gpa, arena, arena.dialogue_decls.items[datas[i]]) }),
            .ability_decl => try list.append(gpa, .{ .ability = try buildAbility(gpa, arena, arena.ability_decls.items[datas[i]]) }),
            .theme_decl => try list.append(gpa, .{ .theme = try buildTheme(gpa, arena, arena.theme_decls.items[datas[i]]) }),
            .motion_decl => try list.append(gpa, .{ .motion = try buildMotion(gpa, arena, arena.motion_decls.items[datas[i]]) }),
            .input_mapping_decl => try list.append(gpa, .{ .input_mapping = try buildInputMapping(gpa, arena, arena.input_mapping_decls.items[datas[i]]) }),
            .widget_decl => try list.append(gpa, .{ .widget = try buildWidget(gpa, arena, arena.widget_decls.items[datas[i]]) }),
            .locale_decl => try list.append(gpa, .{ .locale = try buildLocale(gpa, arena, arena.locale_decls.items[datas[i]]) }),
            .effect_decl => try list.append(gpa, .{ .effect = try buildEffect(gpa, arena, arena.effect_decls.items[datas[i]]) }),
            .audio_graph_decl => try list.append(gpa, .{ .audio_graph = try buildAudioGraph(gpa, arena, arena.audio_graph_decls.items[datas[i]]) }),
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

fn buildTheme(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.ThemeDecl) BuildError!types.Theme {
    var entries: std.ArrayListUnmanaged(types.ThemeEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.key);
            gpa.free(e.value);
        }
        entries.deinit(gpa);
    }
    var e: u32 = 0;
    while (e < decl.entries_len) : (e += 1) {
        const entry = arena.theme_entries.items[decl.entries_start + e];
        const value = try renderExprAlloc(gpa, arena, entry.value);
        errdefer gpa.free(value);
        const key = try gpa.dupe(u8, arena.strings.slice(entry.key));
        errdefer gpa.free(key);
        try entries.append(gpa, .{ .key = key, .value = value });
    }
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    return .{ .name = name, .entries = try entries.toOwnedSlice(gpa) };
}

/// Build a `motion` descriptor (M0.8 E5): states with canonical-rendered
/// property fields + transitions with flat-text animators. Mirrors `buildData`
/// (states ↔ entries+fields) and `buildRoutine` (transitions ↔ interrupts).
fn buildMotion(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.MotionDecl) BuildError!types.Motion {
    var states: std.ArrayListUnmanaged(types.MotionStateDesc) = .empty;
    errdefer {
        for (states.items) |st| {
            gpa.free(st.name);
            for (st.fields) |f| {
                gpa.free(f.name);
                gpa.free(f.value);
            }
            gpa.free(st.fields);
        }
        states.deinit(gpa);
    }
    var s: u32 = 0;
    while (s < decl.states_len) : (s += 1) {
        const st = arena.motion_states.items[decl.states_start + s];
        const fields = try buildMotionFields(gpa, arena, st.fields_start, st.fields_len);
        errdefer {
            for (fields) |f| {
                gpa.free(f.name);
                gpa.free(f.value);
            }
            gpa.free(fields);
        }
        const name = try gpa.dupe(u8, arena.strings.slice(st.name));
        errdefer gpa.free(name);
        try states.append(gpa, .{ .name = name, .fields = fields });
    }

    var transitions: std.ArrayListUnmanaged(types.MotionTransitionDesc) = .empty;
    errdefer {
        for (transitions.items) |tr| {
            gpa.free(tr.source);
            gpa.free(tr.target);
            gpa.free(tr.animator);
        }
        transitions.deinit(gpa);
    }
    var t: u32 = 0;
    while (t < decl.transitions_len) : (t += 1) {
        const tr = arena.motion_transitions.items[decl.transitions_start + t];
        const source = try dupMotionEndpoint(gpa, arena, tr.source, tr.source_wildcard);
        errdefer gpa.free(source);
        const target = try dupMotionEndpoint(gpa, arena, tr.target, tr.target_wildcard);
        errdefer gpa.free(target);
        const animator = try renderMotionAnimatorAlloc(gpa, arena, tr.animator);
        errdefer gpa.free(animator);
        try transitions.append(gpa, .{ .source = source, .target = target, .animator = animator });
    }

    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{
        .name = name,
        .states = try states.toOwnedSlice(gpa),
        .transitions = try transitions.toOwnedSlice(gpa),
    };
}

/// Render a `struct_literal_body` field run into a `MotionFieldDesc[]` (each
/// value through the SHARED canonical renderer). Spread fields (`name == 0`)
/// render as the `..` marker (the `data` precedent).
fn buildMotionFields(gpa: std.mem.Allocator, arena: *const AstArena, fields_start: u32, fields_len: u32) BuildError![]types.MotionFieldDesc {
    var fields: std.ArrayListUnmanaged(types.MotionFieldDesc) = .empty;
    errdefer {
        for (fields.items) |f| {
            gpa.free(f.name);
            gpa.free(f.value);
        }
        fields.deinit(gpa);
    }
    var f: u32 = 0;
    while (f < fields_len) : (f += 1) {
        const field = arena.struct_lit_fields.items[fields_start + f];
        const value = try renderExprAlloc(gpa, arena, field.value);
        errdefer gpa.free(value);
        const name = try gpa.dupe(u8, if (field.name == 0) ".." else arena.strings.slice(field.name));
        try fields.append(gpa, .{ .name = name, .value = value });
    }
    return try fields.toOwnedSlice(gpa);
}

/// Duplicate a transition endpoint — `"*"` for the wildcard, else the state name.
fn dupMotionEndpoint(gpa: std.mem.Allocator, arena: *const AstArena, name: ast_mod.StringId, wildcard: bool) BuildError![]u8 {
    return try gpa.dupe(u8, if (wildcard) "*" else arena.strings.slice(name));
}

/// Render a `motion_animator` (RECURSIVE via `stagger`) to canonical flat
/// text — used by BOTH backends (interp build + codegen emit) so the bytes
/// are identical (the proof contract). Forms (`etch-grammar.md` §10.3):
///   `animate(<dur>[, <easing>])`
///   `keyframes [ <t>: { <fields> }[, …] ] over <dur>[, <easing>]`
///   `stagger(<delay>, <inner>)`
pub fn renderMotionAnimatorAlloc(gpa: std.mem.Allocator, arena: *const AstArena, animator_idx: u32) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try renderMotionAnimator(gpa, arena, animator_idx, &buf);
    return try buf.toOwnedSlice(gpa);
}

fn renderMotionAnimator(gpa: std.mem.Allocator, arena: *const AstArena, animator_idx: u32, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    const a = arena.motion_animators.items[animator_idx];
    switch (a.kind) {
        .animate => {
            try out.appendSlice(gpa, "animate(");
            try renderExpr(gpa, arena, a.duration, out);
            if (!a.easing.isNone()) {
                try out.appendSlice(gpa, ", ");
                try renderExpr(gpa, arena, a.easing, out);
            }
            try out.appendSlice(gpa, ")");
        },
        .keyframes => {
            try out.appendSlice(gpa, "keyframes [ ");
            var k: u32 = 0;
            while (k < a.keyframes_len) : (k += 1) {
                if (k != 0) try out.appendSlice(gpa, ", ");
                const kf = arena.motion_keyframes.items[a.keyframes_start + k];
                try renderExpr(gpa, arena, kf.time, out);
                try out.appendSlice(gpa, ": ");
                try renderMotionFieldsBody(gpa, arena, kf.fields_start, kf.fields_len, out);
            }
            try out.appendSlice(gpa, " ] over ");
            try renderExpr(gpa, arena, a.duration, out);
            if (!a.easing.isNone()) {
                try out.appendSlice(gpa, ", ");
                try renderExpr(gpa, arena, a.easing, out);
            }
        },
        .stagger => {
            try out.appendSlice(gpa, "stagger(");
            try renderExpr(gpa, arena, a.duration, out);
            try out.appendSlice(gpa, ", ");
            try renderMotionAnimator(gpa, arena, a.inner, out);
            try out.appendSlice(gpa, ")");
        },
    }
}

/// Render a keyframe `struct_literal_body` as inline `{ a: x, b: y }` (the
/// `renderExpr` struct-lit form, mirrored for a raw field run).
fn renderMotionFieldsBody(gpa: std.mem.Allocator, arena: *const AstArena, fields_start: u32, fields_len: u32, out: *std.ArrayListUnmanaged(u8)) BuildError!void {
    if (fields_len == 0) {
        try out.appendSlice(gpa, "{}");
        return;
    }
    try out.appendSlice(gpa, "{ ");
    var f: u32 = 0;
    while (f < fields_len) : (f += 1) {
        if (f != 0) try out.appendSlice(gpa, ", ");
        const field = arena.struct_lit_fields.items[fields_start + f];
        if (field.name == 0) {
            try out.appendSlice(gpa, "..");
        } else {
            try out.appendSlice(gpa, arena.strings.slice(field.name));
            try out.appendSlice(gpa, ": ");
        }
        try renderExpr(gpa, arena, field.value, out);
    }
    try out.appendSlice(gpa, " }");
}

/// Render an optional expression: `""` when absent, else the shared canonical
/// rendering (M0.8 E5 input_mapping properties / bind options / combo fields).
fn renderOptExprAlloc(gpa: std.mem.Allocator, arena: *const AstArena, node: NodeId) BuildError![]u8 {
    if (node.isNone()) return try gpa.dupe(u8, "");
    return try renderExprAlloc(gpa, arena, node);
}

/// Build an `input_mapping` descriptor (M0.8 E5 Level B STRICT): properties +
/// actions (binds) + combos. `output_mapping` (a closure) is presence-marked
/// `"<closure>"` — the renderer rejects closures (the data-closure precedent),
/// so the body is structurally noted, never silently-wrong.
fn buildInputMapping(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.InputMappingDecl) BuildError!types.InputMapping {
    const context = try renderOptExprAlloc(gpa, arena, decl.context);
    errdefer gpa.free(context);
    const priority = try renderOptExprAlloc(gpa, arena, decl.priority);
    errdefer gpa.free(priority);
    const consume_input = try renderOptExprAlloc(gpa, arena, decl.consume_input);
    errdefer gpa.free(consume_input);

    var actions: std.ArrayListUnmanaged(types.InputActionDesc) = .empty;
    errdefer {
        for (actions.items) |act| freeInputAction(gpa, act);
        actions.deinit(gpa);
    }
    var a: u32 = 0;
    while (a < decl.actions_len) : (a += 1) {
        try actions.append(gpa, try buildInputAction(gpa, arena, arena.input_actions.items[decl.actions_start + a]));
    }

    var combos: std.ArrayListUnmanaged(types.InputComboDesc) = .empty;
    errdefer {
        for (combos.items) |c| freeInputCombo(gpa, c);
        combos.deinit(gpa);
    }
    var c: u32 = 0;
    while (c < decl.combos_len) : (c += 1) {
        try combos.append(gpa, try buildInputCombo(gpa, arena, arena.input_combos.items[decl.combos_start + c]));
    }

    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{
        .name = name,
        .context = context,
        .priority = priority,
        .consume_input = consume_input,
        .actions = try actions.toOwnedSlice(gpa),
        .combos = try combos.toOwnedSlice(gpa),
    };
}

fn buildInputAction(gpa: std.mem.Allocator, arena: *const AstArena, action: ast_mod.InputAction) BuildError!types.InputActionDesc {
    var binds: std.ArrayListUnmanaged(types.InputBindDesc) = .empty;
    errdefer {
        for (binds.items) |bd| freeInputBind(gpa, bd);
        binds.deinit(gpa);
    }
    var b: u32 = 0;
    while (b < action.binds_len) : (b += 1) {
        try binds.append(gpa, try buildInputBind(gpa, arena, arena.input_binds.items[action.binds_start + b]));
    }
    const name = try gpa.dupe(u8, arena.strings.slice(action.name));
    errdefer gpa.free(name);
    const type_name = try gpa.dupe(u8, if (action.type_name == 0) "" else arena.strings.slice(action.type_name));
    errdefer gpa.free(type_name);
    const output = try gpa.dupe(u8, if (action.output_name == 0) "" else arena.strings.slice(action.output_name));
    return .{ .name = name, .type_name = type_name, .output = output, .binds = try binds.toOwnedSlice(gpa) };
}

fn buildInputBind(gpa: std.mem.Allocator, arena: *const AstArena, bind: ast_mod.InputBind) BuildError!types.InputBindDesc {
    const modifiers = try renderOptExprAlloc(gpa, arena, bind.modifiers);
    errdefer gpa.free(modifiers);
    const triggers = try renderOptExprAlloc(gpa, arena, bind.triggers);
    errdefer gpa.free(triggers);
    const output_mapping = try gpa.dupe(u8, if (bind.output_mapping.isNone()) "" else "<closure>");
    errdefer gpa.free(output_mapping);
    const source = try gpa.dupe(u8, arena.strings.slice(bind.source));
    return .{ .source = source, .modifiers = modifiers, .triggers = triggers, .output_mapping = output_mapping };
}

fn buildInputCombo(gpa: std.mem.Allocator, arena: *const AstArena, combo: ast_mod.InputCombo) BuildError!types.InputComboDesc {
    const sequence = try renderOptExprAlloc(gpa, arena, combo.sequence);
    errdefer gpa.free(sequence);
    const window = try renderOptExprAlloc(gpa, arena, combo.window);
    errdefer gpa.free(window);
    const name = try gpa.dupe(u8, arena.strings.slice(combo.name));
    errdefer gpa.free(name);
    const type_name = try gpa.dupe(u8, if (combo.type_name == 0) "" else arena.strings.slice(combo.type_name));
    return .{ .name = name, .type_name = type_name, .sequence = sequence, .window = window };
}

// ── widget (M0.8 E5 Level B) ──────────────────────────────────────────────

fn freeWidget(gpa: std.mem.Allocator, w: types.Widget) void {
    gpa.free(w.name);
    gpa.free(w.annotations);
    gpa.free(w.when);
    for (w.params) |p| {
        gpa.free(p.name);
        gpa.free(p.type_name);
    }
    gpa.free(w.params);
    for (w.tree) |node| freeUiNode(gpa, node);
    gpa.free(w.tree);
}

fn freeUiNode(gpa: std.mem.Allocator, node: types.UiNodeDesc) void {
    gpa.free(node.head);
    for (node.children) |child| freeUiNode(gpa, child);
    gpa.free(node.children);
    for (node.else_children) |child| freeUiNode(gpa, child);
    gpa.free(node.else_children);
}

/// Build a `widget` descriptor (M0.8 E5): placement annotations + params +
/// optional when clause + the recursive `ui_tree`. Mirrors `buildMotion`
/// (multi-slice) + `buildBTNode` (recursive tree).
fn buildWidget(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.WidgetDecl) BuildError!types.Widget {
    const annotations = try buildWidgetAnnotations(gpa, arena, decl);
    errdefer gpa.free(annotations);
    const when_text = if (decl.when_root == ast_mod.RuleDecl.none_when)
        try gpa.dupe(u8, "")
    else
        try renderWhenAlloc(gpa, arena, decl.when_root);
    errdefer gpa.free(when_text);

    var params: std.ArrayListUnmanaged(types.WidgetParamDesc) = .empty;
    errdefer {
        for (params.items) |pp| {
            gpa.free(pp.name);
            gpa.free(pp.type_name);
        }
        params.deinit(gpa);
    }
    var p: u32 = 0;
    while (p < decl.params_len) : (p += 1) {
        const param = arena.widget_params.items[decl.params_start + p];
        const pname = try gpa.dupe(u8, arena.strings.slice(param.name));
        errdefer gpa.free(pname);
        const ptype = try gpa.dupe(u8, arena.strings.slice(param.type_name));
        errdefer gpa.free(ptype);
        try params.append(gpa, .{ .name = pname, .type_name = ptype });
    }

    const tree = try buildUiTree(gpa, arena, decl.tree_start, decl.tree_len);
    errdefer {
        for (tree) |node| freeUiNode(gpa, node);
        gpa.free(tree);
    }
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{
        .name = name,
        .annotations = annotations,
        .when = when_text,
        .params = try params.toOwnedSlice(gpa),
        .tree = tree,
    };
}

/// Space-join the placement-annotation names as `@name` (declaration order).
/// `@screen` / `@worldspace` arrive as `.custom`-kind annotations distinguished
/// by name; their args are structural and omitted from the Level-B descriptor.
pub fn buildWidgetAnnotations(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.WidgetDecl) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    var i: u32 = 0;
    while (i < decl.annotations_len) : (i += 1) {
        const annot = arena.annot_pool.items[decl.annotations_extra + i];
        if (i != 0) try buf.appendSlice(gpa, " ");
        try buf.appendSlice(gpa, "@");
        try buf.appendSlice(gpa, arena.strings.slice(annot.name));
    }
    return try buf.toOwnedSlice(gpa);
}

/// Build a `(start, len)` run of `ui_elems` into a `UiNodeDesc[]` (RECURSIVE —
/// child runs build their own subtree, the `buildBTNode` / `buildDialogueElements`
/// precedent).
fn buildUiTree(gpa: std.mem.Allocator, arena: *const AstArena, start: u32, len: u32) BuildError![]types.UiNodeDesc {
    var nodes: std.ArrayListUnmanaged(types.UiNodeDesc) = .empty;
    errdefer {
        for (nodes.items) |n| freeUiNode(gpa, n);
        nodes.deinit(gpa);
    }
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        try nodes.append(gpa, try buildUiNode(gpa, arena, arena.ui_elems.items[start + i]));
    }
    return try nodes.toOwnedSlice(gpa);
}

fn buildUiNode(gpa: std.mem.Allocator, arena: *const AstArena, elem: ast_mod.UiElem) BuildError!types.UiNodeDesc {
    switch (elem.kind) {
        .widget_call => {
            const wc = arena.ui_widget_calls.items[elem.index];
            const head = try renderUiCallAlloc(gpa, arena, wc.call);
            errdefer gpa.free(head);
            const children = try buildUiTree(gpa, arena, wc.children_start, wc.children_len);
            errdefer {
                for (children) |c| freeUiNode(gpa, c);
                gpa.free(children);
            }
            return .{ .kind = .call, .head = head, .children = children, .else_children = try gpa.alloc(types.UiNodeDesc, 0) };
        },
        .if_ => {
            const uif = arena.ui_ifs.items[elem.index];
            const head = try renderExprAlloc(gpa, arena, uif.cond);
            errdefer gpa.free(head);
            const then_children = try buildUiTree(gpa, arena, uif.then_start, uif.then_len);
            errdefer {
                for (then_children) |c| freeUiNode(gpa, c);
                gpa.free(then_children);
            }
            const else_children = try buildUiTree(gpa, arena, uif.else_start, uif.else_len);
            return .{ .kind = .if_, .head = head, .children = then_children, .else_children = else_children };
        },
        .for_ => {
            const uf = arena.ui_fors.items[elem.index];
            const head = try buildForHead(gpa, arena, uf);
            errdefer gpa.free(head);
            const children = try buildUiTree(gpa, arena, uf.body_start, uf.body_len);
            errdefer {
                for (children) |c| freeUiNode(gpa, c);
                gpa.free(children);
            }
            return .{ .kind = .for_, .head = head, .children = children, .else_children = try gpa.alloc(types.UiNodeDesc, 0) };
        },
        .statement => {
            const stmt: NodeId = @bitCast(elem.index);
            const head = try renderStmtAlloc(gpa, arena, stmt);
            errdefer gpa.free(head);
            return .{ .kind = .statement, .head = head, .children = try gpa.alloc(types.UiNodeDesc, 0), .else_children = try gpa.alloc(types.UiNodeDesc, 0) };
        },
    }
}

/// Render a `for` head (`var[, idx] in iterable`) to canonical text.
pub fn buildForHead(gpa: std.mem.Allocator, arena: *const AstArena, uf: ast_mod.UiFor) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, arena.strings.slice(uf.var_name));
    if (uf.index_name != 0) {
        try buf.appendSlice(gpa, ", ");
        try buf.appendSlice(gpa, arena.strings.slice(uf.index_name));
    }
    try buf.appendSlice(gpa, " in ");
    try renderExpr(gpa, arena, uf.iterable, &buf);
    return try buf.toOwnedSlice(gpa);
}

/// Render a `ui_widget_call` head (`callee(args)`) to canonical text. Mirrors
/// the `renderExpr` `.fn_call` arm (callee + positional/named args through the
/// SHARED `renderExpr`) but with a per-arg closure guard: an on-click closure
/// argument renders as the `<closure>` presence marker (the `buildInputBind`
/// precedent — the renderer rejects closures, never silently-wrong).
pub fn renderUiCallAlloc(gpa: std.mem.Allocator, arena: *const AstArena, call_node: NodeId) BuildError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    const call = arena.call_exprs.items[arena.exprData(call_node)];
    try renderExpr(gpa, arena, call.callee, &buf);
    try buf.appendSlice(gpa, "(");
    var i: u32 = 0;
    while (i < call.args_len) : (i += 1) {
        if (i != 0) try buf.appendSlice(gpa, ", ");
        if (call.names_start != ast_mod.no_arg_names) {
            const label = arena.call_arg_names.items[call.names_start + i];
            if (label != 0) {
                try buf.appendSlice(gpa, arena.strings.slice(label));
                try buf.appendSlice(gpa, ": ");
            }
        }
        const arg: NodeId = @bitCast(arena.extra.items[call.args_start + i]);
        if (arena.exprKind(arg) == .closure) {
            try buf.appendSlice(gpa, "<closure>");
        } else {
            try renderExpr(gpa, arena, arg, &buf);
        }
    }
    try buf.appendSlice(gpa, ")");
    return try buf.toOwnedSlice(gpa);
}

// ── locale (M0.8 E5 Level B) ──────────────────────────────────────────────

fn freeLocale(gpa: std.mem.Allocator, l: types.Locale) void {
    gpa.free(l.name);
    for (l.entries) |e| {
        gpa.free(e.key);
        gpa.free(e.value);
    }
    gpa.free(l.entries);
}

/// Build a `locale` descriptor (M0.8 E5): flat `key = value` string entries (the
/// `buildTheme` precedent, both sides decoded string-literal content).
fn buildLocale(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.LocaleDecl) BuildError!types.Locale {
    var entries: std.ArrayListUnmanaged(types.LocaleEntryDesc) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.key);
            gpa.free(e.value);
        }
        entries.deinit(gpa);
    }
    var e: u32 = 0;
    while (e < decl.entries_len) : (e += 1) {
        const entry = arena.locale_entries.items[decl.entries_start + e];
        const key = try gpa.dupe(u8, arena.strings.slice(entry.key));
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, arena.strings.slice(entry.value));
        errdefer gpa.free(value);
        try entries.append(gpa, .{ .key = key, .value = value });
    }
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{ .name = name, .entries = try entries.toOwnedSlice(gpa) };
}

/// Render an `annotated_field` type to canonical text (named types only — the
/// `renderAbilityRuleAlloc` precedent; a generic/compound type fails loud).
/// SHARED by both backends so a params-block field renders identically.
pub fn renderFieldTypeAlloc(gpa: std.mem.Allocator, arena: *const AstArena, type_node: NodeId) BuildError![]u8 {
    if (arena.typeNodeKind(type_node) != .named) return error.UnsupportedDescriptorExpr;
    return try gpa.dupe(u8, arena.strings.slice(arena.named_types.items[arena.typeNodeData(type_node)].name));
}

/// Render a statement run (a `(start, len)` slice of `arena.extra`) to "; "-joined
/// canonical text (the `renderAbilityRuleAlloc` body precedent). SHARED by both
/// backends so an effect event-handler body renders identically.
pub fn renderStmtRunAlloc(gpa: std.mem.Allocator, arena: *const AstArena, body_start: u32, body_len: u32) BuildError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var st: u32 = 0;
    while (st < body_len) : (st += 1) {
        const stmt: NodeId = @bitCast(arena.extra.items[body_start + st]);
        const text = try renderStmtAlloc(gpa, arena, stmt);
        defer gpa.free(text);
        if (st != 0) try out.appendSlice(gpa, "; ");
        try out.appendSlice(gpa, text);
    }
    return try out.toOwnedSlice(gpa);
}

fn freeEffect(gpa: std.mem.Allocator, e: types.Effect) void {
    gpa.free(e.name);
    for (e.params) |p| {
        gpa.free(p.name);
        gpa.free(p.type_name);
        gpa.free(p.default);
    }
    gpa.free(e.params);
    for (e.emitters) |em| {
        gpa.free(em.name);
        for (em.props) |pr| {
            gpa.free(pr.name);
            gpa.free(pr.value);
        }
        gpa.free(em.props);
    }
    gpa.free(e.emitters);
    for (e.handlers) |h| {
        gpa.free(h.emitter);
        gpa.free(h.event);
        gpa.free(h.body);
    }
    gpa.free(e.handlers);
}

/// Build an `effect` descriptor (M0.8 E6): optional annotated params, emitters
/// of bare `name: value` properties, and `on Emitter.event { body }` handlers.
/// All values flow through the shared canonical renderer (byte-identical with
/// the codegen emit side).
fn buildEffect(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.EffectDecl) BuildError!types.Effect {
    var params: std.ArrayListUnmanaged(types.EffectParamDesc) = .empty;
    errdefer {
        for (params.items) |p| {
            gpa.free(p.name);
            gpa.free(p.type_name);
            gpa.free(p.default);
        }
        params.deinit(gpa);
    }
    var pi: u32 = 0;
    while (pi < decl.params_len) : (pi += 1) {
        const field = arena.fields.items[decl.params_start + pi];
        const pname = try gpa.dupe(u8, arena.strings.slice(field.name));
        errdefer gpa.free(pname);
        const ptype = try renderFieldTypeAlloc(gpa, arena, field.type_node);
        errdefer gpa.free(ptype);
        const pdefault = if (field.default_value.isNone())
            try gpa.dupe(u8, "")
        else
            try renderExprAlloc(gpa, arena, field.default_value);
        errdefer gpa.free(pdefault);
        try params.append(gpa, .{ .name = pname, .type_name = ptype, .default = pdefault });
    }

    var emitters: std.ArrayListUnmanaged(types.EffectEmitterDesc) = .empty;
    errdefer {
        for (emitters.items) |em| {
            gpa.free(em.name);
            for (em.props) |pr| {
                gpa.free(pr.name);
                gpa.free(pr.value);
            }
            gpa.free(em.props);
        }
        emitters.deinit(gpa);
    }
    var ei: u32 = 0;
    while (ei < decl.emitters_len) : (ei += 1) {
        const em = arena.effect_emitters.items[decl.emitters_start + ei];
        var props: std.ArrayListUnmanaged(types.EffectPropDesc) = .empty;
        errdefer {
            for (props.items) |pr| {
                gpa.free(pr.name);
                gpa.free(pr.value);
            }
            props.deinit(gpa);
        }
        var fi: u32 = 0;
        while (fi < em.props_len) : (fi += 1) {
            const prop = arena.struct_lit_fields.items[em.props_start + fi];
            const value = try renderExprAlloc(gpa, arena, prop.value);
            errdefer gpa.free(value);
            const pname = try gpa.dupe(u8, arena.strings.slice(prop.name));
            try props.append(gpa, .{ .name = pname, .value = value });
        }
        const ename = try gpa.dupe(u8, arena.strings.slice(em.name));
        errdefer gpa.free(ename);
        try emitters.append(gpa, .{ .name = ename, .props = try props.toOwnedSlice(gpa) });
    }

    var handlers: std.ArrayListUnmanaged(types.EffectHandlerDesc) = .empty;
    errdefer {
        for (handlers.items) |h| {
            gpa.free(h.emitter);
            gpa.free(h.event);
            gpa.free(h.body);
        }
        handlers.deinit(gpa);
    }
    var hi: u32 = 0;
    while (hi < decl.handlers_len) : (hi += 1) {
        const h = arena.effect_event_handlers.items[decl.handlers_start + hi];
        const body = try renderStmtRunAlloc(gpa, arena, h.body_start, h.body_len);
        errdefer gpa.free(body);
        const emitter = try gpa.dupe(u8, arena.strings.slice(h.emitter));
        errdefer gpa.free(emitter);
        const event = try gpa.dupe(u8, arena.strings.slice(h.event));
        errdefer gpa.free(event);
        try handlers.append(gpa, .{ .emitter = emitter, .event = event, .body = body });
    }

    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .emitters = try emitters.toOwnedSlice(gpa),
        .handlers = try handlers.toOwnedSlice(gpa),
    };
}

fn freeAudioGraph(gpa: std.mem.Allocator, ag: types.AudioGraph) void {
    gpa.free(ag.name);
    for (ag.params) |p| {
        gpa.free(p.name);
        gpa.free(p.type_name);
        gpa.free(p.default);
    }
    gpa.free(ag.params);
    gpa.free(ag.body);
    gpa.free(ag.output);
}

/// Build an `audio_graph` descriptor (M0.8 E6): optional annotated params, the
/// DSP statements rendered "; "-joined, and the mandatory output sink — all
/// through the shared canonical renderers (byte-identical with the emit side).
fn buildAudioGraph(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.AudioGraphDecl) BuildError!types.AudioGraph {
    var params: std.ArrayListUnmanaged(types.AudioGraphParamDesc) = .empty;
    errdefer {
        for (params.items) |p| {
            gpa.free(p.name);
            gpa.free(p.type_name);
            gpa.free(p.default);
        }
        params.deinit(gpa);
    }
    var pi: u32 = 0;
    while (pi < decl.params_len) : (pi += 1) {
        const field = arena.fields.items[decl.params_start + pi];
        const pname = try gpa.dupe(u8, arena.strings.slice(field.name));
        errdefer gpa.free(pname);
        const ptype = try renderFieldTypeAlloc(gpa, arena, field.type_node);
        errdefer gpa.free(ptype);
        const pdefault = if (field.default_value.isNone())
            try gpa.dupe(u8, "")
        else
            try renderExprAlloc(gpa, arena, field.default_value);
        errdefer gpa.free(pdefault);
        try params.append(gpa, .{ .name = pname, .type_name = ptype, .default = pdefault });
    }

    const body = try renderStmtRunAlloc(gpa, arena, decl.body_start, decl.body_len);
    errdefer gpa.free(body);
    const output = try renderExprAlloc(gpa, arena, decl.output);
    errdefer gpa.free(output);
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    errdefer gpa.free(name);
    return .{
        .name = name,
        .params = try params.toOwnedSlice(gpa),
        .body = body,
        .output = output,
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

fn buildDialogue(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.DialogueDecl) BuildError!types.Dialogue {
    const elements = try buildDialogueElements(gpa, arena, decl.elems_start, decl.elems_len);
    errdefer freeDialogueElements(gpa, elements);
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    return .{ .name = name, .elements = elements };
}

fn buildDialogueElements(gpa: std.mem.Allocator, arena: *const AstArena, start: u32, len: u32) BuildError![]types.DialogueElementDesc {
    var elements: std.ArrayListUnmanaged(types.DialogueElementDesc) = .empty;
    errdefer {
        const slice = elements.toOwnedSlice(gpa) catch &.{};
        freeDialogueElements(gpa, slice);
    }
    var e: u32 = 0;
    while (e < len) : (e += 1) {
        const elem = arena.dialogue_elems.items[start + e];
        switch (elem.kind) {
            .speaker => {
                const sp = arena.dialogue_speakers.items[elem.index];
                var lines: std.ArrayListUnmanaged(types.DialogueLineDesc) = .empty;
                errdefer {
                    for (lines.items) |line| {
                        gpa.free(line.text);
                        gpa.free(line.when);
                    }
                    lines.deinit(gpa);
                }
                var l: u32 = 0;
                while (l < sp.lines_len) : (l += 1) {
                    const line = arena.dialogue_lines.items[sp.lines_start + l];
                    const text = try renderExprAlloc(gpa, arena, line.text);
                    errdefer gpa.free(text);
                    const when_text = if (line.when_root == ast_mod.RuleDecl.none_when)
                        try gpa.dupe(u8, "")
                    else
                        try renderWhenAlloc(gpa, arena, line.when_root);
                    errdefer gpa.free(when_text);
                    try lines.append(gpa, .{ .text = text, .when = when_text });
                }
                const id = try gpa.dupe(u8, arena.strings.slice(sp.id));
                errdefer gpa.free(id);
                try elements.append(gpa, .{ .speaker = .{ .id = id, .lines = try lines.toOwnedSlice(gpa) } });
            },
            .choice => {
                const ch = arena.dialogue_choices.items[elem.index];
                var options: std.ArrayListUnmanaged(types.DialogueOptionDesc) = .empty;
                errdefer {
                    for (options.items) |opt| {
                        gpa.free(opt.text);
                        gpa.free(opt.when);
                        gpa.free(opt.target);
                    }
                    options.deinit(gpa);
                }
                var o: u32 = 0;
                while (o < ch.options_len) : (o += 1) {
                    const opt = arena.dialogue_options.items[ch.options_start + o];
                    const text = try renderExprAlloc(gpa, arena, opt.text);
                    errdefer gpa.free(text);
                    const when_text = if (opt.when_root == ast_mod.RuleDecl.none_when)
                        try gpa.dupe(u8, "")
                    else
                        try renderWhenAlloc(gpa, arena, opt.when_root);
                    errdefer gpa.free(when_text);
                    const target = try gpa.dupe(u8, if (opt.is_end) "end" else arena.strings.slice(opt.target));
                    errdefer gpa.free(target);
                    try options.append(gpa, .{ .text = text, .when = when_text, .target = target });
                }
                try elements.append(gpa, .{ .choice = try options.toOwnedSlice(gpa) });
            },
            .branch => {
                const branch = arena.dialogue_branches.items[elem.index];
                const inner = try buildDialogueElements(gpa, arena, branch.elems_start, branch.elems_len);
                errdefer freeDialogueElements(gpa, inner);
                const bname = try gpa.dupe(u8, arena.strings.slice(branch.name));
                errdefer gpa.free(bname);
                try elements.append(gpa, .{ .branch = .{ .name = bname, .elements = inner } });
            },
            .emit => {
                const em = arena.dialogue_emits.items[elem.index];
                const payload = try renderStmtAlloc(gpa, arena, em.stmt);
                errdefer gpa.free(payload);
                const when_text = if (em.when_root == ast_mod.RuleDecl.none_when)
                    try gpa.dupe(u8, "")
                else
                    try renderWhenAlloc(gpa, arena, em.when_root);
                errdefer gpa.free(when_text);
                try elements.append(gpa, .{ .emit = .{ .payload = payload, .when = when_text } });
            },
            .goto => {
                const g = arena.dialogue_gotos.items[elem.index];
                try elements.append(gpa, .{ .goto = try gpa.dupe(u8, if (g.is_end) "end" else arena.strings.slice(g.target)) });
            },
        }
    }
    return try elements.toOwnedSlice(gpa);
}

fn buildAbility(gpa: std.mem.Allocator, arena: *const AstArena, decl: ast_mod.AbilityDecl) BuildError!types.Ability {
    var props: std.ArrayListUnmanaged(types.AbilityPropDesc) = .empty;
    errdefer {
        for (props.items) |prop| {
            gpa.free(prop.name);
            gpa.free(prop.value);
        }
        props.deinit(gpa);
    }
    var p: u32 = 0;
    while (p < decl.props_len) : (p += 1) {
        const prop = arena.ability_props.items[decl.props_start + p];
        const value = if (prop.kind == .cost)
            try renderAbilityCostAlloc(gpa, arena, prop.cost_fields_start, prop.cost_fields_len)
        else
            try renderExprAlloc(gpa, arena, prop.value);
        errdefer gpa.free(value);
        const pname = try gpa.dupe(u8, arena.strings.slice(prop.name));
        errdefer gpa.free(pname);
        try props.append(gpa, .{ .name = pname, .value = value });
    }
    const rule_text = if (decl.rule_idx == ast_mod.AbilityDecl.no_rule)
        try gpa.dupe(u8, "")
    else
        try renderAbilityRuleAlloc(gpa, arena, decl.rule_idx);
    errdefer gpa.free(rule_text);
    const name = try gpa.dupe(u8, arena.strings.slice(decl.name));
    return .{ .name = name, .properties = try props.toOwnedSlice(gpa), .rule = rule_text };
}

/// Render an ability `cost:` struct_literal_body canonically:
/// `{ key: value, ... }` (spread entries as `..expr`). SHARED by both
/// backends (the proof-contract split).
pub fn renderAbilityCostAlloc(gpa: std.mem.Allocator, arena: *const AstArena, fields_start: u32, fields_len: u32) BuildError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{");
    var f: u32 = 0;
    while (f < fields_len) : (f += 1) {
        const field = arena.struct_lit_fields.items[fields_start + f];
        try out.appendSlice(gpa, if (f == 0) " " else ", ");
        if (field.name == 0) {
            try out.appendSlice(gpa, "..");
        } else {
            try out.appendSlice(gpa, arena.strings.slice(field.name));
            try out.appendSlice(gpa, ": ");
        }
        try renderExpr(gpa, arena, field.value, &out);
    }
    try out.appendSlice(gpa, if (fields_len == 0) "}" else " }");
    return try out.toOwnedSlice(gpa);
}

/// Render the ability-embedded rule canonically, single line:
/// `rule name(p: T, ...) [when <when>] { stmt; stmt }`. Param types are
/// bounded to NAMED type nodes (the E1 rule-param surface: scalar /
/// Entity) — anything else fails loud. SHARED by both backends.
pub fn renderAbilityRuleAlloc(gpa: std.mem.Allocator, arena: *const AstArena, rule_idx: u32) BuildError![]u8 {
    const rule = arena.rule_decls.items[rule_idx];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "rule ");
    try out.appendSlice(gpa, arena.strings.slice(rule.name));
    try out.appendSlice(gpa, "(");
    var p: u32 = 0;
    while (p < rule.params_len) : (p += 1) {
        const param = arena.rule_params.items[rule.params_start + p];
        if (p != 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, arena.strings.slice(param.name));
        try out.appendSlice(gpa, ": ");
        if (arena.typeNodeKind(param.type_node) != .named) return error.UnsupportedDescriptorExpr;
        try out.appendSlice(gpa, arena.strings.slice(arena.named_types.items[arena.typeNodeData(param.type_node)].name));
    }
    try out.appendSlice(gpa, ")");
    if (rule.when_root != ast_mod.RuleDecl.none_when) {
        const when_text = try renderWhenAlloc(gpa, arena, rule.when_root);
        defer gpa.free(when_text);
        try out.appendSlice(gpa, " when ");
        try out.appendSlice(gpa, when_text);
    }
    try out.appendSlice(gpa, " {");
    var st: u32 = 0;
    while (st < rule.body_len) : (st += 1) {
        const stmt: NodeId = @bitCast(arena.extra.items[rule.body_start + st]);
        const text = try renderStmtAlloc(gpa, arena, stmt);
        defer gpa.free(text);
        try out.appendSlice(gpa, if (st == 0) " " else "; ");
        try out.appendSlice(gpa, text);
    }
    try out.appendSlice(gpa, if (rule.body_len == 0) "}" else " }");
    return try out.toOwnedSlice(gpa);
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
        .int_lit, .float_lit, .duration_lit, .color_lit, .bool_lit => try out.appendSlice(gpa, arena.strings.slice(data)),
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
        .loc_expr => {
            // `@loc…` canonical text (§3.2, item 10 — structural form).
            const le = arena.loc_exprs.items[data];
            try out.appendSlice(gpa, "@loc");
            if (le.is_key_form) {
                try out.appendSlice(gpa, "(");
                try renderQuoted(gpa, arena.strings.slice(le.text), out);
                var a: u32 = 0;
                while (a < le.args_len) : (a += 1) {
                    const arg = arena.struct_lit_fields.items[le.args_start + a];
                    try out.appendSlice(gpa, ", ");
                    try out.appendSlice(gpa, arena.strings.slice(arg.name));
                    try out.appendSlice(gpa, ": ");
                    try renderExpr(gpa, arena, arg.value, out);
                }
                try out.appendSlice(gpa, ")");
                return;
            }
            if (le.meaning != 0) {
                try out.appendSlice(gpa, ":");
                try renderQuoted(gpa, arena.strings.slice(le.meaning), out);
            }
            if (le.description != 0) {
                try out.appendSlice(gpa, "|");
                try renderQuoted(gpa, arena.strings.slice(le.description), out);
            }
            if (le.custom_id != 0) {
                try out.appendSlice(gpa, "@@");
                try out.appendSlice(gpa, arena.strings.slice(le.custom_id));
            }
            try out.appendSlice(gpa, ":");
            try renderQuoted(gpa, arena.strings.slice(le.text), out);
        },
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
