//! Render Graph — Phase 0 / M0.4.
//!
//! DAG (Directed Acyclic Graph) déclaratif. Chaque pass déclare ses
//! reads/writes ; le graph calcule l'ordre topologique d'exécution et
//! insère les barriers automatiquement via le `BarrierTracker`.
//!
//! Phase 0 :
//! - 3 passes max attendues (depth prepass / forward / capture
//!   conditionnelle), structure compacte sans optimisation.
//! - Tri topologique en `O(V + E)` (Kahn's algorithm).
//! - Détection de cycle → `error.RenderGraphCycle`.
//! - Pass merging et resource aliasing reportés Phase 1+ (cf. brief
//!   §Notes décision 2).

const std = @import("std");
const gal = @import("../gal/main.zig");
const pass_mod = @import("pass.zig");

/// Set d'erreurs du render graph.
pub const Error = error{
    RenderGraphCycle,
    PassNotFound,
    OutOfMemory,
    BackendError,
};

/// Index typé d'une pass dans `Graph.passes`.
pub const PassIndex = u32;

/// Container du DAG.
pub const Graph = struct {
    allocator: std.mem.Allocator,
    passes: std.ArrayListUnmanaged(pass_mod.Pass) = .empty,
    /// Ordre topologique calculé par `compile`. Indices vers `passes`.
    execution_order: std.ArrayListUnmanaged(PassIndex) = .empty,
    /// Tracker des barriers pour la frame courante (auto-tracking).
    barriers: gal.barriers.BarrierTracker,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .barriers = gal.barriers.BarrierTracker.init(allocator),
        };
    }

    pub fn deinit(self: *Graph) void {
        self.passes.deinit(self.allocator);
        self.execution_order.deinit(self.allocator);
        self.barriers.deinit();
        self.* = undefined;
    }

    /// Ajoute une pass au graph. L'ordre d'ajout n'est pas l'ordre
    /// d'exécution — le tri topologique recalcule l'ordre selon les
    /// dépendances `reads`/`writes`.
    pub fn addPass(self: *Graph, pass: pass_mod.Pass) Error!PassIndex {
        const idx: PassIndex = @intCast(self.passes.items.len);
        self.passes.append(self.allocator, pass) catch return error.OutOfMemory;
        return idx;
    }

    /// Calcule l'ordre topologique d'exécution. Doit être appelé après
    /// tous les `addPass` et avant `execute`. Détecte les cycles et
    /// retourne `error.RenderGraphCycle` dans ce cas.
    pub fn compile(self: *Graph) Error!void {
        self.execution_order.clearRetainingCapacity();
        try self.execution_order.ensureTotalCapacity(self.allocator, self.passes.items.len);

        const n = self.passes.items.len;
        if (n == 0) return;

        // Construit la liste d'adjacence : edge (a → b) si pass a écrit
        // une resource lue par pass b, ou si pass a et b écrivent la
        // même resource (WAW dépendance — pass a précède pass b par
        // ordre d'ajout).
        var in_degree = try self.allocator.alloc(u32, n);
        defer self.allocator.free(in_degree);
        @memset(in_degree, 0);

        // adj[i] = liste des passes qui dépendent de la pass i.
        var adj = try self.allocator.alloc(std.ArrayListUnmanaged(PassIndex), n);
        defer {
            for (adj) |*a| a.deinit(self.allocator);
            self.allocator.free(adj);
        }
        for (adj) |*a| a.* = .empty;

        // Pour chaque pair (i, j) avec i != j, vérifier la dépendance.
        // L'ordre dans `passes` ne dicte pas l'ordre topologique — c'est le
        // résultat. On checke donc les deux directions ; un cycle apparaît
        // si pass A dépend de pass B *et* pass B dépend de pass A.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                if (i == j) continue;
                if (passDependsOn(&self.passes.items[j], &self.passes.items[i])) {
                    try adj[i].append(self.allocator, @intCast(j));
                    in_degree[j] += 1;
                }
            }
        }

        // Kahn's algorithm : enqueue les noeuds sans dépendance, puis
        // visite + décrémente les degrés des voisins.
        var queue: std.ArrayListUnmanaged(PassIndex) = .empty;
        defer queue.deinit(self.allocator);
        for (in_degree, 0..) |d, k| {
            if (d == 0) try queue.append(self.allocator, @intCast(k));
        }
        var visited: u32 = 0;
        while (queue.items.len > 0) {
            const node = queue.orderedRemove(0);
            try self.execution_order.append(self.allocator, node);
            visited += 1;
            for (adj[node].items) |succ| {
                in_degree[succ] -= 1;
                if (in_degree[succ] == 0) try queue.append(self.allocator, succ);
            }
        }
        if (visited != n) return error.RenderGraphCycle;
    }

    /// Calcule les barriers requises entre passes (pour `compile`-d graph).
    /// À appeler avant `execute`. Le résultat est consommable via
    /// `Graph.barriers.consumeRecorded()`.
    pub fn trackBarriers(self: *Graph) Error!void {
        self.barriers.reset();
        for (self.execution_order.items) |pass_idx| {
            const p = &self.passes.items[pass_idx];
            if (p.barrier_mode == .explicit) continue; // skip auto-tracking
            for (p.reads) |r| {
                try self.trackResourceUsage(r);
            }
            for (p.writes) |w| {
                try self.trackResourceUsage(w);
            }
        }
    }

    fn trackResourceUsage(self: *Graph, usage: pass_mod.ResourceUsage) Error!void {
        switch (usage.resource) {
            .buffer => |b| self.barriers.trackBuffer(b, .{
                .stage = usage.stage,
                .access = usage.access,
                .layout = null,
            }) catch return error.OutOfMemory,
            .texture => |t| self.barriers.trackTexture(t, .{
                .stage = usage.stage,
                .access = usage.access,
                .layout = usage.layout,
            }, .undefined) catch return error.OutOfMemory,
        }
    }

    /// Exécute le graph compilé. Appelle le body de chaque pass dans
    /// l'ordre topologique. Le caller fournit un context opaque
    /// optionnel passé à chaque pass.body.
    ///
    /// Phase 0 : ne câble pas encore les barriers entre passes (laissé
    /// au backend Vulkan via les render pass dependencies natives —
    /// PR follow-up câble `trackBarriers` aux barriers émises).
    pub fn execute(self: *Graph, encoder: ?*anyopaque) Error!void {
        for (self.execution_order.items) |idx| {
            const p = &self.passes.items[idx];
            p.body(encoder, p.ctx) catch return error.BackendError;
        }
    }
};

/// Détermine si `b` dépend topologiquement de `a` (i.e. si `a` doit
/// s'exécuter avant `b` dans le DAG).
///
/// Phase 0 : seuls RAW et WAW créent une dépendance topologique pour
/// l'ordre d'exécution.
/// - **RAW** (Read-After-Write) : `a` produit une resource que `b` consomme
///   → producer/consumer, `b` doit attendre `a`.
/// - **WAW** (Write-After-Write) : les deux écrivent la même resource →
///   sérialisation requise pour cohérence.
///
/// **WAR n'est PAS une dépendance topologique** : c'est une hazard
/// mémoire pure (le writer doit pas clobber pendant que le reader lit),
/// gérée par le `BarrierTracker` (cf. `gal/barriers.zig`) qui insère la
/// barrière sans imposer d'ordre topologique. Cohérent avec WebGPU et
/// les render graphs Frostbite/Bevy/Mach.
///
/// Cycle = deux passes qui produisent mutuellement les inputs l'une de
/// l'autre (un RAW dans les deux sens, ou un WAW circulaire).
fn passDependsOn(b: *const pass_mod.Pass, a: *const pass_mod.Pass) bool {
    // RAW : a.writes ∩ b.reads
    for (a.writes) |aw| {
        for (b.reads) |br| if (sameResource(aw.resource, br.resource)) return true;
    }
    // WAW : a.writes ∩ b.writes
    for (a.writes) |aw| {
        for (b.writes) |bw| if (sameResource(aw.resource, bw.resource)) return true;
    }
    return false;
}

fn sameResource(a: pass_mod.ResourceRef, b: pass_mod.ResourceRef) bool {
    return switch (a) {
        .buffer => |ab| switch (b) {
            .buffer => |bb| ab.inner == bb.inner,
            else => false,
        },
        .texture => |at| switch (b) {
            .texture => |bt| at.inner == bt.inner,
            else => false,
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

fn noopBody(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
}

test "graph: empty graph compile + execute" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    try g.compile();
    try g.execute(null);
    try std.testing.expectEqual(@as(usize, 0), g.execution_order.items.len);
}

test "graph: single pass" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    _ = try g.addPass(.{ .name = "lonely", .body = noopBody });
    try g.compile();
    try std.testing.expectEqual(@as(usize, 1), g.execution_order.items.len);
}

test "graph: produces correct topological order on known DAG" {
    // Trois passes : A writes T, B reads T (→ A precedes B), C indep
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const t = gal.types.TextureHandle{ .inner = 1 };
    const idx_a = try g.addPass(.{
        .name = "A",
        .body = noopBody,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });
    const idx_b = try g.addPass(.{
        .name = "B",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
    });
    const idx_c = try g.addPass(.{ .name = "C", .body = noopBody });
    try g.compile();

    // L'ordre doit avoir A avant B (RAW dep). C peut être n'importe où.
    var pos_a: ?usize = null;
    var pos_b: ?usize = null;
    var pos_c: ?usize = null;
    for (g.execution_order.items, 0..) |idx, i| {
        if (idx == idx_a) pos_a = i;
        if (idx == idx_b) pos_b = i;
        if (idx == idx_c) pos_c = i;
    }
    try std.testing.expect(pos_a != null and pos_b != null and pos_c != null);
    try std.testing.expect(pos_a.? < pos_b.?);
}

test "graph: detects cycle and returns error" {
    // Construire un cycle : pass A écrit T1, lit T2. Pass B écrit T2, lit T1.
    // → A dépend de B (RAW sur T2), et B dépend de A (RAW sur T1).
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const t1 = gal.types.TextureHandle{ .inner = 1 };
    const t2 = gal.types.TextureHandle{ .inner = 2 };
    _ = try g.addPass(.{
        .name = "A",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t2 },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
        }},
        .writes = &.{.{
            .resource = .{ .texture = t1 },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
        }},
    });
    _ = try g.addPass(.{
        .name = "B",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t1 },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
        }},
        .writes = &.{.{
            .resource = .{ .texture = t2 },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
        }},
    });
    try std.testing.expectError(error.RenderGraphCycle, g.compile());
}

test "graph: trackBarriers inserts read-after-write barrier between passes" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const t = gal.types.TextureHandle{ .inner = 5 };
    _ = try g.addPass(.{
        .name = "depth_prepass",
        .body = noopBody,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .depth_attachment = true },
            .layout = .depth_stencil_attachment,
        }},
    });
    _ = try g.addPass(.{
        .name = "forward",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
    });
    try g.compile();
    try g.trackBarriers();
    const barriers = g.barriers.consumeRecorded();
    try std.testing.expect(barriers.len >= 1);
}

test "graph: explicit mode skips auto-tracking" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const t = gal.types.TextureHandle{ .inner = 7 };
    _ = try g.addPass(.{
        .name = "writer",
        .body = noopBody,
        .barrier_mode = .explicit,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });
    _ = try g.addPass(.{
        .name = "reader",
        .body = noopBody,
        .barrier_mode = .explicit,
        .reads = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
    });
    try g.compile();
    try g.trackBarriers();
    const barriers = g.barriers.consumeRecorded();
    try std.testing.expectEqual(@as(usize, 0), barriers.len);
}
