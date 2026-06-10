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
    }
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
        .fn_call => {
            const call = arena.call_exprs.items[data];
            try renderExpr(gpa, arena, call.callee, out);
            try out.appendSlice(gpa, "(");
            var i: u32 = 0;
            while (i < call.args_len) : (i += 1) {
                if (i != 0) try out.appendSlice(gpa, ", ");
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
