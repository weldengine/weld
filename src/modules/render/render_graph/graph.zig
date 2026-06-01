//! Render Graph — Phase 0 / M0.4.
//!
//! Declarative DAG (Directed Acyclic Graph). Each pass declares its
//! reads/writes; the graph computes the topological execution order and
//! inserts the barriers automatically via the `BarrierTracker`.
//!
//! Phase 0:
//! - 3 passes max expected (depth prepass / forward / conditional
//!   capture), compact structure without optimization.
//! - Topological sort in `O(V + E)` (Kahn's algorithm).
//! - Cycle detection → `error.RenderGraphCycle`.
//! - Pass merging and resource aliasing deferred to Phase 1+ (cf. brief
//!   §Notes decision 2).

const std = @import("std");
const gal = @import("../gal/main.zig");
const pass_mod = @import("pass.zig");

/// Error set of the render graph.
pub const Error = error{
    RenderGraphCycle,
    PassNotFound,
    OutOfMemory,
    BackendError,
};

/// Typed index of a pass in `Graph.passes`.
pub const PassIndex = u32;

/// DAG container.
pub const Graph = struct {
    allocator: std.mem.Allocator,
    passes: std.ArrayListUnmanaged(pass_mod.Pass) = .empty,
    /// Topological order computed by `compile`. Indices into `passes`.
    execution_order: std.ArrayListUnmanaged(PassIndex) = .empty,
    /// Barrier tracker for the current frame (auto-tracking).
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

    /// Adds a pass to the graph. The insertion order is not the
    /// execution order — the topological sort recomputes the order from
    /// the `reads`/`writes` dependencies.
    pub fn addPass(self: *Graph, pass: pass_mod.Pass) Error!PassIndex {
        const idx: PassIndex = @intCast(self.passes.items.len);
        self.passes.append(self.allocator, pass) catch return error.OutOfMemory;
        return idx;
    }

    /// Computes the topological execution order. Must be called after
    /// all `addPass` and before `execute`. Detects cycles and returns
    /// `error.RenderGraphCycle` in that case.
    pub fn compile(self: *Graph) Error!void {
        self.execution_order.clearRetainingCapacity();
        try self.execution_order.ensureTotalCapacity(self.allocator, self.passes.items.len);

        const n = self.passes.items.len;
        if (n == 0) return;

        // Builds the adjacency list: edge (a → b) if pass a writes
        // a resource read by pass b, or if pass a and b write the
        // same resource (WAW dependency — pass a precedes pass b by
        // insertion order).
        var in_degree = try self.allocator.alloc(u32, n);
        defer self.allocator.free(in_degree);
        @memset(in_degree, 0);

        // adj[i] = list of passes that depend on pass i.
        var adj = try self.allocator.alloc(std.ArrayListUnmanaged(PassIndex), n);
        defer {
            for (adj) |*a| a.deinit(self.allocator);
            self.allocator.free(adj);
        }
        for (adj) |*a| a.* = .empty;

        // For each pair (i, j) with i != j, check the dependency.
        // The order in `passes` does not dictate the topological order — it is the
        // result. So we check both directions; a cycle appears
        // if pass A depends on pass B *and* pass B depends on pass A.
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

        // Kahn's algorithm: enqueue the nodes without dependency, then
        // visit + decrement the degrees of the neighbors.
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

    /// Computes the barriers required between passes (for a `compile`-d graph).
    /// To be called before `execute`. The result is consumable via
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

    /// Executes the compiled graph. Calls the body of each pass in
    /// topological order. The caller provides an optional opaque context
    /// passed to each pass.body.
    ///
    /// Phase 0: does not yet wire the barriers between passes (left
    /// to the Vulkan backend via the native render pass dependencies —
    /// PR follow-up wires `trackBarriers` to the emitted barriers).
    pub fn execute(self: *Graph, encoder: ?*anyopaque) Error!void {
        for (self.execution_order.items) |idx| {
            const p = &self.passes.items[idx];
            p.body(encoder, p.ctx) catch return error.BackendError;
        }
    }
};

/// Determines whether `b` topologically depends on `a` (i.e. whether `a`
/// must execute before `b` in the DAG).
///
/// Phase 0: only RAW and WAW create a topological dependency for
/// the execution order.
/// - **RAW** (Read-After-Write): `a` produces a resource that `b` consumes
///   → producer/consumer, `b` must wait for `a`.
/// - **WAW** (Write-After-Write): both write the same resource →
///   serialization required for coherence.
///
/// **WAR is NOT a topological dependency**: it is a pure memory
/// hazard (the writer must not clobber while the reader reads),
/// handled by the `BarrierTracker` (cf. `gal/barriers.zig`) which inserts the
/// barrier without imposing a topological order. Consistent with WebGPU and
/// the Frostbite/Bevy/Mach render graphs.
///
/// Cycle = two passes that mutually produce each other's inputs
/// (a RAW in both directions, or a circular WAW).
fn passDependsOn(b: *const pass_mod.Pass, a: *const pass_mod.Pass) bool {
    // RAW: a.writes ∩ b.reads
    for (a.writes) |aw| {
        for (b.reads) |br| if (sameResource(aw.resource, br.resource)) return true;
    }
    // WAW: a.writes ∩ b.writes
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
    // Three passes: A writes T, B reads T (→ A precedes B), C indep
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

    // The order must have A before B (RAW dep). C can be anywhere.
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
    // Build a cycle: pass A writes T1, reads T2. Pass B writes T2, reads T1.
    // → A depends on B (RAW on T2), and B depends on A (RAW on T1).
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
