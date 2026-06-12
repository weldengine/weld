//! Global tag table (M0.8 E3, `etch-validation-ecs.md` §5.2).
//!
//! A `tags { ... }` block declares a hierarchy of namespaces and leaves. The
//! whole compilation set is merged into ONE hierarchy, then each leaf is
//! assigned a globally-unique `bit_index` by a depth-first walk in declaration
//! order — stable cross-build (deterministic), which the saves and CRDT layers
//! rely on. This module is the single source of that algorithm: the resolver
//! (path validation + overflow), the interpreter (runtime bit lookup) and the
//! codegen (`TagSet` extern struct + bit constants) all build the table the
//! same way, so interpreter↔codegen parity is structural.
//!
//! Cross-block merge matters: two blocks may both extend `character.status`
//! with different leaves (`etch-validation-ecs.md` §5.6). Because of that, the
//! per-block flat leaf order in the AST is NOT directly the bit_index order —
//! the merged tree must be walked. For a single block the two coincide.
//!
//! The persistent structure is just `dotted-path -> Entry`; the build-time
//! tree (children lists + roots) is scratch, dropped once bit indices land in
//! the map. Namespace masks (`has_any_tag(.category)`) are computed by a prefix
//! scan over the map keys (the leaf set is small).

const std = @import("std");

const ast_mod = @import("ast.zig");
const diag_mod = @import("diagnostics.zig");
const token_mod = @import("token.zig");

const AstArena = ast_mod.AstArena;
const SourceSpan = token_mod.SourceSpan;
const Diagnostic = diag_mod.Diagnostic;

/// Default per-project bitfield bound (`etch-validation-ecs.md` §5.3): 256 tags
/// → 4 u64 words (32 bytes / entity). Overridable via
/// `RuntimeConfig.tag_bitfield_max` (Phase 2); exposed as a `build` parameter
/// so the bound is testable without 257 declared tags.
pub const default_max_tags: u32 = 256;

/// One resolved entry in the global table: a leaf carries its `bit_index`; a
/// namespace is a non-leaf grouping (no bit).
pub const Entry = struct {
    is_leaf: bool,
    bit_index: u32 = 0,
};

/// The merged, deterministically-numbered global tag table.
pub const TagTable = struct {
    /// Owns the dotted-path key strings referenced by `map`.
    arena: std.heap.ArenaAllocator,
    /// Canonical dotted path (`"character.status.alive"`) → entry.
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Number of leaves = number of assigned bits.
    leaf_count: u32 = 0,
    /// Configured upper bound; `leaf_count > max_tags` is `E0832`.
    max_tags: u32 = default_max_tags,

    /// Build-time tree node (scratch; not retained after `build`).
    const Node = struct {
        path: []const u8,
        is_leaf: bool,
        bit_index: u32 = 0,
        children: std.ArrayListUnmanaged(u32) = .empty,
        span: SourceSpan,
    };

    pub fn deinit(self: *TagTable, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// `TAG_BITFIELD_WORDS = (total + 63) / 64` (`etch-validation-ecs.md` §5.3).
    /// At least one word so a `tags`-free program with a stray `TagSet` is well
    /// formed (callers that emit `TagSet` only do so when leaves exist).
    pub fn words(self: *const TagTable) u32 {
        return (self.leaf_count + 63) / 64;
    }

    /// Look up a dotted path; `null` if it names neither a leaf nor a namespace.
    pub fn lookup(self: *const TagTable, path: []const u8) ?Entry {
        return self.map.get(path);
    }

    /// The bit_index of a leaf path, or `null` if the path is unknown or names
    /// a namespace (not a leaf).
    pub fn leafBit(self: *const TagTable, path: []const u8) ?u32 {
        if (self.map.get(path)) |e| {
            if (e.is_leaf) return e.bit_index;
        }
        return null;
    }

    /// Collect the bit indices of every leaf under `namespace_path` (a category
    /// passed to `has_any_tag`/`has_all_tags`/`has_no_tags`,
    /// `etch-validation-ecs.md` §5.4). A leaf is "under" the namespace iff its
    /// path has `namespace_path ++ "."` as a prefix. Appends to `out`.
    pub fn collectUnder(
        self: *const TagTable,
        gpa: std.mem.Allocator,
        namespace_path: []const u8,
        out: *std.ArrayListUnmanaged(u32),
    ) !void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (!e.is_leaf) continue;
            const p = kv.key_ptr.*;
            if (p.len > namespace_path.len and
                std.mem.startsWith(u8, p, namespace_path) and
                p[namespace_path.len] == '.')
            {
                try out.append(gpa, e.bit_index);
            }
        }
    }

    /// Build the merged global table from every `tags { ... }` block in `arena`
    /// (item order). Emits `E0831 TagPathConflict` (a path declared as both a
    /// leaf and a namespace, or a leaf declared twice) and `E0832
    /// TagBitfieldOverflow` (leaf count exceeds `max_tags`) into `diagnostics`.
    /// The table is returned partially-built on error so the resolver keeps
    /// going. The caller owns `deinit`.
    pub fn build(
        gpa: std.mem.Allocator,
        arena: *const AstArena,
        diagnostics: *std.ArrayListUnmanaged(Diagnostic),
        max_tags: u32,
    ) !TagTable {
        var table: TagTable = .{ .arena = std.heap.ArenaAllocator.init(gpa), .max_tags = max_tags };
        errdefer table.deinit(gpa);
        const aa = table.arena.allocator();

        // Build-time scratch lives in its own arena, dropped before return.
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        var nodes: std.ArrayListUnmanaged(Node) = .empty;
        var roots: std.ArrayListUnmanaged(u32) = .empty;
        var path_to_node: std.StringHashMapUnmanaged(u32) = .empty;

        // Find-or-create a tree node for `path`. A path string is duped into the
        // persistent arena (it doubles as the final map key). Returns the node
        // index; `created` is set when the node is new (so the caller links it
        // to its parent exactly once). A leaf/namespace kind mismatch on an
        // existing path is `E0831`.
        const Helper = struct {
            fn findOrCreate(
                a: std.mem.Allocator, // persistent arena (path strings)
                s: std.mem.Allocator, // scratch arena (node bookkeeping)
                ns: *std.ArrayListUnmanaged(Node),
                p2n: *std.StringHashMapUnmanaged(u32),
                diags: *std.ArrayListUnmanaged(Diagnostic),
                g: std.mem.Allocator,
                path: []const u8,
                is_leaf: bool,
                span: SourceSpan,
                created: *bool,
            ) !u32 {
                if (p2n.get(path)) |idx| {
                    created.* = false;
                    const existing = &ns.items[idx];
                    if (existing.is_leaf != is_leaf or (is_leaf and existing.is_leaf)) {
                        // leaf-vs-namespace conflict, or a leaf redeclared.
                        try emitDiag(diags, g, .tag_path_conflict, span, "tag path '{s}' is declared more than once with a conflicting kind (leaf vs namespace) or as a duplicate leaf", .{path});
                    }
                    return idx;
                }
                const owned = try a.dupe(u8, path);
                const idx: u32 = @intCast(ns.items.len);
                try ns.append(s, .{ .path = owned, .is_leaf = is_leaf, .span = span });
                try p2n.put(s, owned, idx);
                created.* = true;
                return idx;
            }
        };

        const item_kinds = arena.items.items(.kind);
        const item_datas = arena.items.items(.data);

        // Per-block map: AST namespace slab index → merged node index. Sized to
        // the whole slab and reused; a block's namespaces are a contiguous run
        // and parents always precede children (pre-order), so entries are filled
        // before they are read.
        const ns_to_node = try sa.alloc(u32, arena.tag_namespaces.items.len + 1);

        var item_i: usize = 0;
        while (item_i < arena.items.len) : (item_i += 1) {
            if (item_kinds[item_i] != .tags_decl) continue;
            const td = arena.tags_decls.items[item_datas[item_i]];

            // Namespaces (slab order = pre-order).
            var ns_i: u32 = td.ns_start;
            while (ns_i < td.ns_start + td.ns_len) : (ns_i += 1) {
                const node_ns = arena.tag_namespaces.items[ns_i];
                const name = arena.strings.slice(node_ns.name);
                const path = if (node_ns.parent == ast_mod.TagNamespace.no_parent)
                    try aa.dupe(u8, name)
                else
                    try std.fmt.allocPrint(aa, "{s}.{s}", .{ nodes.items[ns_to_node[node_ns.parent]].path, name });
                var created = false;
                const idx = try Helper.findOrCreate(aa, sa, &nodes, &path_to_node, diagnostics, gpa, path, false, node_ns.span, &created);
                ns_to_node[ns_i] = idx;
                if (created) {
                    if (node_ns.parent == ast_mod.TagNamespace.no_parent) {
                        try roots.append(sa, idx);
                    } else {
                        try nodes.items[ns_to_node[node_ns.parent]].children.append(sa, idx);
                    }
                }
            }

            // Leaves.
            var leaf_i: u32 = td.leaf_start;
            while (leaf_i < td.leaf_start + td.leaf_len) : (leaf_i += 1) {
                const leaf = arena.tag_leaves.items[leaf_i];
                const parent_idx = ns_to_node[leaf.parent];
                const name = arena.strings.slice(leaf.name);
                const path = try std.fmt.allocPrint(aa, "{s}.{s}", .{ nodes.items[parent_idx].path, name });
                var created = false;
                const idx = try Helper.findOrCreate(aa, sa, &nodes, &path_to_node, diagnostics, gpa, path, true, leaf.span, &created);
                if (created) try nodes.items[parent_idx].children.append(sa, idx);
            }
        }

        // Assign bit_index by depth-first walk in declaration order
        // (`etch-validation-ecs.md` §5.2). Leaves are numbered as visited.
        var next_bit: u32 = 0;
        for (roots.items) |r| assignBits(&nodes, r, &next_bit);
        table.leaf_count = next_bit;

        // E0832: the compilation set exceeds the configured bound.
        if (table.leaf_count > max_tags) {
            try emitDiag(diagnostics, gpa, .tag_bitfield_overflow, .{ .byte_start = 0, .byte_end = 0 }, "tag bitfield overflow: {d} tags declared, bound is {d} (raise RuntimeConfig.tag_bitfield_max or consolidate tags)", .{ table.leaf_count, max_tags });
        }

        // Materialise the persistent path → entry map from the numbered nodes.
        for (nodes.items) |n| {
            try table.map.put(gpa, n.path, .{ .is_leaf = n.is_leaf, .bit_index = n.bit_index });
        }
        return table;
    }

    fn assignBits(nodes: *std.ArrayListUnmanaged(Node), idx: u32, next_bit: *u32) void {
        const n = &nodes.items[idx];
        if (n.is_leaf) {
            n.bit_index = next_bit.*;
            next_bit.* += 1;
            return;
        }
        for (n.children.items) |c| assignBits(nodes, c, next_bit);
    }
};

/// Append a diagnostic, duplicating the formatted message via `gpa` (the
/// diagnostic owns its `primary_message`, freed at the list's `deinit`) —
/// mirrors `TypeChecker.emit`.
fn emitDiag(
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    gpa: std.mem.Allocator,
    code: diag_mod.DiagnosticCode,
    span: SourceSpan,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(gpa, fmt, args);
    try diagnostics.append(gpa, .{
        .code = code,
        .severity = .error_,
        .primary_span = span,
        .primary_message = message,
    });
}

// ─── inline tests ───────────────────────────────────────────────────────────

const parser_mod = @import("parser.zig");

const TestTable = struct {
    pr: parser_mod.ParseResult,
    diags: std.ArrayListUnmanaged(Diagnostic),
    table: TagTable,

    fn deinit(self: *TestTable, gpa: std.mem.Allocator) void {
        self.table.deinit(gpa);
        for (self.diags.items) |*d| d.deinit(gpa);
        self.diags.deinit(gpa);
        self.pr.deinit(gpa);
    }
};

fn buildFrom(gpa: std.mem.Allocator, source: []const u8, max_tags: u32) !TestTable {
    var pr = try parser_mod.parse(gpa, source);
    errdefer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    errdefer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    const table = try TagTable.build(gpa, &pr.ast, &diags, max_tags);
    return .{ .pr = pr, .diags = diags, .table = table };
}

test "tag table: single block, depth-first declaration-order bit indices" {
    const gpa = std.testing.allocator;
    var t = try buildFrom(gpa,
        \\tags {
        \\  character {
        \\    status { alive, dead, stunned }
        \\    team { red, blue }
        \\  }
        \\  item {
        \\    rarity { common, rare }
        \\  }
        \\}
    , default_max_tags);
    defer t.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), t.diags.items.len);
    try std.testing.expectEqual(@as(u32, 7), t.table.leaf_count);
    try std.testing.expectEqual(@as(u32, 1), t.table.words());

    // Depth-first declaration order: alive=0, dead=1, stunned=2, red=3, blue=4,
    // common=5, rare=6.
    try std.testing.expectEqual(@as(?u32, 0), t.table.leafBit("character.status.alive"));
    try std.testing.expectEqual(@as(?u32, 2), t.table.leafBit("character.status.stunned"));
    try std.testing.expectEqual(@as(?u32, 3), t.table.leafBit("character.team.red"));
    try std.testing.expectEqual(@as(?u32, 6), t.table.leafBit("item.rarity.rare"));

    // Namespaces resolve but carry no bit.
    try std.testing.expect(t.table.lookup("character.status") != null);
    try std.testing.expectEqual(@as(?u32, null), t.table.leafBit("character.status"));
    // Unknown path.
    try std.testing.expectEqual(@as(?u32, null), t.table.leafBit("character.status.frozen"));

    // Category mask: all leaves under `character.status`.
    var under: std.ArrayListUnmanaged(u32) = .empty;
    defer under.deinit(gpa);
    try t.table.collectUnder(gpa, "character.status", &under);
    try std.testing.expectEqual(@as(usize, 3), under.items.len); // alive, dead, stunned
}

test "tag table: cross-block merge numbers by merged tree, not flat order" {
    const gpa = std.testing.allocator;
    // Block A declares status.alive then combat.melee; block B extends
    // status with dead. Merged DFS order: alive=0, dead=1, melee=2 — NOT the
    // first-seen flat order (alive, melee, dead).
    var t = try buildFrom(gpa,
        \\tags { character { status { alive } combat { melee } } }
        \\tags { character { status { dead } } }
    , default_max_tags);
    defer t.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), t.diags.items.len);
    try std.testing.expectEqual(@as(u32, 3), t.table.leaf_count);
    try std.testing.expectEqual(@as(?u32, 0), t.table.leafBit("character.status.alive"));
    try std.testing.expectEqual(@as(?u32, 1), t.table.leafBit("character.status.dead"));
    try std.testing.expectEqual(@as(?u32, 2), t.table.leafBit("character.combat.melee"));
}

test "tag table: leaf-vs-namespace conflict is E0831" {
    const gpa = std.testing.allocator;
    // `character.status` is a namespace in block 1 and a leaf in block 2.
    var t = try buildFrom(gpa,
        \\tags { character { status { alive } } }
        \\tags { character { status } }
    , default_max_tags);
    defer t.deinit(gpa);
    try std.testing.expect(t.diags.items.len > 0);
    var found = false;
    for (t.diags.items) |d| {
        if (d.code == .tag_path_conflict) found = true;
    }
    try std.testing.expect(found);
}

test "tag table: overflow past the configured bound is E0832" {
    const gpa = std.testing.allocator;
    // 3 leaves, bound 2 → E0832.
    var t = try buildFrom(gpa,
        \\tags { n { a, b, c } }
    , 2);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), t.table.leaf_count);
    var found = false;
    for (t.diags.items) |d| {
        if (d.code == .tag_bitfield_overflow) found = true;
    }
    try std.testing.expect(found);
}
