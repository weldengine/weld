//! A set of Etch source files parsed together and indexed for cross-file
//! resolution: every file's arena, its module path, its exports table, the
//! project-wide prefab index, and an order in which to check the files. Built
//! once and shared by `validateProject` and the project cook, so the two resolve
//! an import through the same tables.

const std = @import("std");

const ast = @import("ast.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Ast = ast.AstArena;
const NodeId = ast.NodeId;
const StringId = ast.StringId;
const SourceSpan = @import("token.zig").SourceSpan;
const TypeChecker = types.TypeChecker;
const Diagnostic = diagnostics_mod.Diagnostic;

/// One source file of a multi-file Etch project. `name` is its path: the module
/// path is derived from it (`deriveModulePath`) and so is the parse mode
/// (`parser.modeForPath`).
pub const ProjectFile = struct {
    name: []const u8,
    source: []const u8,
};

/// The parsed files and their indexes. Owns every arena; the maps' keys point
/// into those arenas' string pools.
pub const Project = struct {
    gpa: std.mem.Allocator,
    /// One arena per file, in input order.
    arenas: std.ArrayListUnmanaged(Ast) = .empty,
    /// Per file, whether its parse reported a diagnostic.
    parse_failed: []bool = &.{},
    module_paths: std.ArrayListUnmanaged([]u8) = .empty,
    module_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Every prefab name the project declares (E1786 / E1791).
    prefabs: std.StringHashMapUnmanaged(void) = .empty,
    /// The cross-scene UUID tracker (E1782), filled as the files are checked.
    uuids: std.StringHashMapUnmanaged(void) = .empty,
    exports: std.ArrayListUnmanaged(TypeChecker.ExportTable) = .empty,
    /// Dependencies first; input order when the imports form a cycle, which has
    /// no such order.
    order: []usize = &.{},
    has_cycle: bool = false,

    /// Parse every file and build the indexes. Parse diagnostics and the E0108
    /// of an import cycle go to `diags_out` (caller-owned).
    pub fn init(gpa: std.mem.Allocator, files: []const ProjectFile, diags_out: *std.ArrayListUnmanaged(Diagnostic)) !Project {
        var self: Project = .{ .gpa = gpa };
        errdefer self.deinit();
        const n = files.len;

        self.parse_failed = try gpa.alloc(bool, n);
        @memset(self.parse_failed, false);
        try self.arenas.ensureTotalCapacity(gpa, n);
        for (files, 0..) |f, idx| {
            var pr = try parser.parseWithMode(gpa, f.source, parser.modeForPath(f.name));
            pr.ast.typed_extension = parser.typedExtensionForPath(f.name);
            // Each parse diagnostic moves into `diags_out` (its message
            // transfers), then only the vacated slice is freed — never
            // `pr.deinit`, which would free the arena kept below.
            self.parse_failed[idx] = pr.diagnostics.len > 0;
            for (pr.diagnostics) |d| try diags_out.append(gpa, d);
            gpa.free(pr.diagnostics);
            self.arenas.appendAssumeCapacity(pr.ast);
        }

        for (self.arenas.items) |*a| {
            const kinds = a.items.items(.kind);
            const datas = a.items.items(.data);
            var i: usize = 0;
            while (i < a.items.len) : (i += 1) {
                if (kinds[i] != .prefab_decl) continue;
                try self.prefabs.put(gpa, a.strings.slice(a.prefab_decls.items[datas[i]].name), {});
            }
        }

        try self.module_paths.ensureTotalCapacity(gpa, n);
        for (files, 0..) |f, idx| {
            const mp = try deriveModulePath(gpa, f.name);
            self.module_paths.appendAssumeCapacity(mp);
            // A duplicate module path maps to the last file.
            try self.module_index.put(gpa, mp, idx);
        }

        try self.buildOrder(diags_out);

        try self.exports.ensureTotalCapacity(gpa, n);
        for (self.arenas.items, 0..) |*a, idx| {
            var table: TypeChecker.ExportTable = .empty;
            errdefer table.deinit(gpa);
            try buildExports(gpa, a, idx, &table);
            self.exports.appendAssumeCapacity(table);
        }
        return self;
    }

    pub fn deinit(self: *Project) void {
        const gpa = self.gpa;
        // The maps' keys point into the arenas' string pools: maps first.
        for (self.exports.items) |*t| t.deinit(gpa);
        self.exports.deinit(gpa);
        self.uuids.deinit(gpa);
        self.prefabs.deinit(gpa);
        self.module_index.deinit(gpa);
        for (self.module_paths.items) |p| gpa.free(p);
        self.module_paths.deinit(gpa);
        gpa.free(self.order);
        gpa.free(self.parse_failed);
        for (self.arenas.items) |*a| a.deinit(gpa);
        self.arenas.deinit(gpa);
        self.* = undefined;
    }

    /// The context a file's check resolves cross-file references through.
    pub fn context(self: *Project) TypeChecker.ProjectContext {
        return .{
            .prefabs = &self.prefabs,
            .uuids = &self.uuids,
            .module_index = &self.module_index,
            .exports = self.exports.items,
            .arenas = self.arenas.items,
        };
    }

    /// The import graph's dependency-first order, by iterative DFS: post-order
    /// lists dependencies first, and a back edge to a node still on the stack
    /// closes a cycle, reported as E0108 at the import that closes it.
    fn buildOrder(self: *Project, diags_out: *std.ArrayListUnmanaged(Diagnostic)) !void {
        const gpa = self.gpa;
        const n = self.arenas.items.len;

        // Edge importer → imported, for each import whose target is a file of
        // the set. A target that names no file is an import-resolution concern,
        // not a cycle edge.
        const Edge = struct { to: usize, span: SourceSpan };
        var adj: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Edge)) = .empty;
        defer {
            for (adj.items) |*lst| lst.deinit(gpa);
            adj.deinit(gpa);
        }
        try adj.ensureTotalCapacity(gpa, n);
        for (0..n) |_| adj.appendAssumeCapacity(.empty);
        for (self.arenas.items, 0..) |*a, u| {
            const kinds = a.items.items(.kind);
            const datas = a.items.items(.data);
            const spans = a.items.items(.span);
            var i: usize = 0;
            while (i < a.items.len) : (i += 1) {
                if (kinds[i] != .import_decl) continue;
                const target_path = try TypeChecker.importPath(gpa, a, a.import_decls.items[datas[i]]);
                defer gpa.free(target_path);
                if (self.module_index.get(target_path)) |v| {
                    try adj.items[u].append(gpa, .{ .to = v, .span = spans[i] });
                }
            }
        }

        // White = 0, gray = 1, black = 2.
        const colors = try gpa.alloc(u8, n);
        defer gpa.free(colors);
        @memset(colors, 0);
        var order: std.ArrayListUnmanaged(usize) = .empty;
        defer order.deinit(gpa);
        try order.ensureTotalCapacity(gpa, n);
        const Frame = struct { node: usize, ei: usize };
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        defer stack.deinit(gpa);
        for (0..n) |start| {
            if (colors[start] != 0) continue;
            colors[start] = 1;
            stack.clearRetainingCapacity();
            try stack.append(gpa, .{ .node = start, .ei = 0 });
            while (stack.items.len > 0) {
                const frame = &stack.items[stack.items.len - 1];
                const edges = adj.items[frame.node].items;
                if (frame.ei < edges.len) {
                    const edge = edges[frame.ei];
                    frame.ei += 1;
                    switch (colors[edge.to]) {
                        0 => {
                            colors[edge.to] = 1;
                            try stack.append(gpa, .{ .node = edge.to, .ei = 0 });
                        },
                        1 => {
                            self.has_cycle = true;
                            const msg = try std.fmt.allocPrint(
                                gpa,
                                "import cycle detected: module '{s}' imports '{s}', which closes a cycle back to '{s}'",
                                .{ self.module_paths.items[frame.node], self.module_paths.items[edge.to], self.module_paths.items[edge.to] },
                            );
                            errdefer gpa.free(msg);
                            try diags_out.append(gpa, .{
                                .code = .import_cycle,
                                .severity = .error_,
                                .primary_span = edge.span,
                                .primary_message = msg,
                            });
                        },
                        else => {},
                    }
                } else {
                    colors[frame.node] = 2;
                    order.appendAssumeCapacity(frame.node);
                    _ = stack.pop();
                }
            }
        }

        self.order = try gpa.alloc(usize, n);
        for (self.order, 0..) |*o, k| o.* = if (self.has_cycle) k else order.items[k];
    }
};

/// Module path of a project file from its `ProjectFile.name` (path under `src/`,
/// `etch-reference-part1.md` §1.1): strip an optional leading `src/`, strip the
/// file extension (a typed compound `.scene.etch`/`.prefab.etch`/`.layer.etch`/
/// `.manifest.etch`/`.d.etch` if present, else plain `.etch`), and map `/`→`.`.
/// The returned slice is `gpa`-owned. Typed-extension files take their basename
/// as the module label, and the reason they are not import *targets* differs by
/// extension:
///   - `.scene.etch` / `.prefab.etch` / `.layer.etch` / `.manifest.etch` declare
///     no top-level types (`etch-grammar.md` §21.2 bounds them to one scene or
///     prefab plus imports), so there is nothing to import FROM them.
///   - `.d.etch` declares nothing BUT top-level constructs (§20.4). It is not an
///     import target for the opposite reason: a `service` is resolved from the
///     compiler's global declaration table (`etch-abi-zig.md` §8.3), never
///     through the per-module export index, so it is never named in an `import`.
/// Either way the label only identifies the file as a node in the dependency
/// graph.
fn deriveModulePath(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var s = name;
    if (std.mem.startsWith(u8, s, "src/")) s = s["src/".len..];
    const typed_exts = [_][]const u8{ ".d.etch", ".scene.etch", ".prefab.etch", ".layer.etch", ".manifest.etch" };
    var stripped = false;
    for (typed_exts) |ext| {
        if (std.mem.endsWith(u8, s, ext)) {
            s = s[0 .. s.len - ext.len];
            stripped = true;
            break;
        }
    }
    if (!stripped and std.mem.endsWith(u8, s, ".etch")) s = s[0 .. s.len - ".etch".len];
    const out = try gpa.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return out;
}

/// Build module `a`'s exports table: every top-level symbol-bearing declaration
/// (component / resource / struct / enum / trait / event / fn / type-alias /
/// const) keyed by its interned name's bytes → `{ kind, visibility, arena_index,
/// item_id }`. Keys reference `a`'s string pool, kept alive by the caller.
fn buildExports(gpa: std.mem.Allocator, a: *const Ast, arena_index: usize, table: *TypeChecker.ExportTable) !void {
    const kinds = a.items.items(.kind);
    const datas = a.items.items(.data);
    var i: usize = 0;
    while (i < a.items.len) : (i += 1) {
        const item_id: NodeId = .{ .category = .item, .index = @intCast(i) };
        const nk: ?struct { name: StringId, kind: types.SymbolKind } = switch (kinds[i]) {
            .component_decl => .{ .name = a.component_decls.items[datas[i]].name, .kind = .component },
            .resource_decl => .{ .name = a.resource_decls.items[datas[i]].name, .kind = .resource },
            .struct_decl => .{ .name = a.struct_decls.items[datas[i]].name, .kind = .struct_ },
            .enum_decl => .{ .name = a.enum_decls.items[datas[i]].name, .kind = .enum_ },
            .trait_decl => .{ .name = a.trait_decls.items[datas[i]].name, .kind = .trait_ },
            .event_decl => .{ .name = a.event_decls.items[datas[i]].name, .kind = .event_ },
            .fn_decl => .{ .name = a.fn_decls.items[datas[i]].name, .kind = .fn_ },
            .type_alias => .{ .name = a.type_alias_decls.items[datas[i]].name, .kind = .type_alias },
            // Always public: a const cannot carry `private`. `test` blocks live
            // in their own name space (`TypeChecker.test_symbols`) and are never
            // exported.
            .const_decl => .{ .name = a.const_decls.items[datas[i]].name, .kind = .const_ },
            else => null,
        };
        if (nk) |e| {
            // Last decl wins on a same-name dup (an intra-file dup is E0101 in
            // pass 1); the table only needs a single resolvable entry.
            const vis: TypeChecker.Visibility = switch (a.itemVisibility(item_id)) {
                .public => .public,
                .private => .private,
            };
            try table.put(gpa, a.strings.slice(e.name), .{
                .kind = e.kind,
                .visibility = vis,
                .arena_index = arena_index,
                .item_id = item_id,
            });
        }
    }
}
