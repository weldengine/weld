//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Tier 0 resource store — singleton storage indexed by `ComponentId`.
//! Each resource carries a `dirty` flag set by `getMutResource` and cleared
//! by `tickBoundary`. Used by the `when resource T changed` filter (see
//! `engine-ecs-internals.md` §5 — change detection; S4 implements a
//! degenerate per-resource dirty bit, full tick-based detection is Phase
//! 0.5).
//!
//! Resource storage is byte-level: each entry holds a heap-allocated
//! `[]u8` (size from the registry) plus a dirty flag. The Etch bridge
//! reads or writes fields through the registry's `FieldDesc` offsets.
//!
//! Every buffer is over-aligned to `ChunkAlignment` (M0.8 E3-C, Option A)
//! so generated code can form a typed `*R` over the bytes — `@alignCast`
//! sound in ReleaseSafe, ABI pointer identity (`etch-abi-zig.md` §3.1).
//! UNCONDITIONAL: one alignment regime for every resource buffer regardless
//! of access path (two regimes by access path would reopen an
//! interpreter/codegen divergence); byte-offset access works unchanged.

const std = @import("std");
const registry_mod = @import("registry.zig");
const chunk_mod = @import("chunk.zig");

const ComponentId = registry_mod.ComponentId;

/// Alignment of every resource byte buffer. ≥ the largest POD field
/// alignment (8, `etch-abi-zig.md` §3.1), pinned at comptime.
pub const BufferAlignment: usize = chunk_mod.ChunkAlignment;

comptime {
    std.debug.assert(BufferAlignment >= 8);
}

/// Surfaced by `ResourceStore.addResource` and `removeResource`;
/// the read paths (`getResource` / `getMutResource`) return `?[]u8`
/// rather than failing through this set.
pub const ResourceError = error{
    DuplicateResource,
    UnknownResource,
    OutOfMemory,
};

const Entry = struct {
    bytes: []align(BufferAlignment) u8,
    /// Set by `getMutResource`; cleared by `tickBoundary`. Read by the
    /// `when resource T changed` filter (interpreter).
    dirty: bool,
};

/// Per-world store of singleton resources, keyed by `ComponentId`.
/// Owns the raw byte buffer for each resource plus a per-entry dirty
/// flag flipped on `getMutResource` and cleared on `tickBoundary`.
pub const ResourceStore = struct {
    entries: std.AutoHashMapUnmanaged(ComponentId, Entry) = .empty,

    pub fn init() ResourceStore {
        return .{};
    }

    pub fn deinit(self: *ResourceStore, gpa: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| gpa.free(e.bytes);
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// Add a new resource. `init_bytes` is copied into a freshly allocated
    /// buffer (length must match the registry's `componentSize(id)`),
    /// over-aligned to `BufferAlignment`. Initial `dirty` is `false`.
    /// Adding an already-present resource returns `error.DuplicateResource`.
    pub fn addResource(self: *ResourceStore, gpa: std.mem.Allocator, id: ComponentId, init_bytes: []const u8) ResourceError!void {
        if (self.entries.contains(id)) return ResourceError.DuplicateResource;
        const buf = try gpa.alignedAlloc(u8, comptime .fromByteUnits(BufferAlignment), init_bytes.len);
        errdefer gpa.free(buf);
        @memcpy(buf, init_bytes);
        try self.entries.put(gpa, id, .{ .bytes = buf, .dirty = false });
    }

    /// Immutable view of the resource bytes. Returns `null` if absent.
    pub fn getResource(self: *const ResourceStore, id: ComponentId) ?[]const u8 {
        const e = self.entries.getPtr(id) orelse return null;
        return e.bytes;
    }

    /// Mutable view of the resource bytes. Sets `dirty = true`. Returns
    /// `null` if absent.
    pub fn getMutResource(self: *ResourceStore, id: ComponentId) ?[]u8 {
        const e = self.entries.getPtr(id) orelse return null;
        e.dirty = true;
        return e.bytes;
    }

    pub fn isDirty(self: *const ResourceStore, id: ComponentId) bool {
        const e = self.entries.getPtr(id) orelse return false;
        return e.dirty;
    }

    /// Set a resource's dirty bit to an explicit value. **Tier-0-internal seam**,
    /// not a public runtime / Etch / plugin API: the scene loader's rollback path
    /// (a different Zig file — hence `pub`) restores the pre-load dirty state
    /// after a rejected transaction, because `getMutResource` (called during both
    /// the failed load and the rollback) unconditionally sets `dirty = true`
    /// (M1.1.1-HF2 C6). No-op if the resource is absent.
    pub fn setDirty(self: *ResourceStore, id: ComponentId, value: bool) void {
        const e = self.entries.getPtr(id) orelse return;
        e.dirty = value;
    }

    pub fn contains(self: *const ResourceStore, id: ComponentId) bool {
        return self.entries.contains(id);
    }

    /// Clear the dirty bit on every resource. Called once per tick by the
    /// interpreter after all rules have run.
    pub fn tickBoundary(self: *ResourceStore) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| e.dirty = false;
    }

    /// Remove a resource. Clears its dirty bit as a side effect of
    /// removal. Returns `error.UnknownResource` if absent.
    pub fn removeResource(self: *ResourceStore, gpa: std.mem.Allocator, id: ComponentId) ResourceError!void {
        const kv = self.entries.fetchRemove(id) orelse return ResourceError.UnknownResource;
        gpa.free(kv.value.bytes);
    }
};

// ─── tests ────────────────────────────────────────────────────────────────

test "addResource then getResource roundtrip" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{ 1, 2, 3, 4 };
    try store.addResource(gpa, 7, &bytes);
    const got = store.getResource(7).?;
    try std.testing.expectEqualSlices(u8, &bytes, got);
    try std.testing.expect(!store.isDirty(7));
}

test "getMutResource sets dirty, tickBoundary resets it" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{ 1, 2, 3, 4 };
    try store.addResource(gpa, 7, &bytes);
    _ = store.getMutResource(7).?;
    try std.testing.expect(store.isDirty(7));
    store.tickBoundary();
    try std.testing.expect(!store.isDirty(7));
}

test "removing a resource clears its dirty bit" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{1};
    try store.addResource(gpa, 3, &bytes);
    _ = store.getMutResource(3).?;
    try std.testing.expect(store.isDirty(3));
    try store.removeResource(gpa, 3);
    try std.testing.expect(!store.contains(3));
    try std.testing.expect(!store.isDirty(3));
}

test "resource buffers are chunk-aligned (M0.8 Option A)" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    // An odd-sized init slice from an arbitrary (1-byte-aligned) source —
    // the stored buffer must still come back over-aligned.
    const bytes = [_]u8{ 1, 2, 3, 4, 5 };
    try store.addResource(gpa, 9, bytes[0..]);
    const got = store.getResource(9).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(got.ptr) % BufferAlignment);
}

test "addResource rejects duplicate id" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{1};
    try store.addResource(gpa, 0, &bytes);
    try std.testing.expectError(error.DuplicateResource, store.addResource(gpa, 0, &bytes));
}

test "setDirty restores an explicit dirty state (M1.1.1-HF2 C6)" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{1};
    try store.addResource(gpa, 5, &bytes);
    _ = store.getMutResource(5).?; // forces dirty = true
    try std.testing.expect(store.isDirty(5));

    store.setDirty(5, false);
    try std.testing.expect(!store.isDirty(5));
    store.setDirty(5, true);
    try std.testing.expect(store.isDirty(5));

    // Absent resource → no-op, no crash.
    store.setDirty(999, false);
}
