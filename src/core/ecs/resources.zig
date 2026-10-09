//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! Tier 0 resource store — singleton byte buffers indexed by `ComponentId`,
//! each with a `dirty` flag set by `getMutResource`, cleared by `tickBoundary`
//! and read by the `when resource T changed` filter. Sizes come from the
//! registry; the Etch bridge reaches fields through its `FieldDesc` offsets.
//!
//! Every buffer is over-aligned to `ChunkAlignment` so generated code can form
//! a typed `*R` over the bytes. UNCONDITIONALLY so, whatever the access path —
//! two regimes would reopen an interpreter/codegen divergence.

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

/// Per-world store of singleton resources, keyed by `ComponentId`. Owns every
/// byte buffer it holds.
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

    /// Add a new resource, copying `init_bytes` into an over-aligned buffer —
    /// its length must match the registry's `componentSize(id)`. Initial `dirty`
    /// is `false`; an already-present id returns `error.DuplicateResource`.
    pub fn addResource(self: *ResourceStore, gpa: std.mem.Allocator, id: ComponentId, init_bytes: []const u8) ResourceError!void {
        if (self.entries.contains(id)) return ResourceError.DuplicateResource;
        const buf = try allocBuffer(gpa, init_bytes);
        errdefer gpa.free(buf);
        try self.reserve(gpa, 1);
        self.adoptAssumeCapacity(id, buf);
    }

    /// The buffer type the store holds a resource in.
    pub const Buffer = []align(BufferAlignment) u8;

    /// A buffer `adoptAssumeCapacity` accepts, filled with `init_bytes`. The
    /// caller owns it until adopted.
    pub fn allocBuffer(gpa: std.mem.Allocator, init_bytes: []const u8) error{OutOfMemory}!Buffer {
        const buf = try gpa.alignedAlloc(u8, comptime .fromByteUnits(BufferAlignment), init_bytes.len);
        @memcpy(buf, init_bytes);
        return buf;
    }

    /// Make room for `n` more resources, so that many `adoptAssumeCapacity`
    /// calls cannot fail. Changes nothing a reader of the store can observe.
    pub fn reserve(self: *ResourceStore, gpa: std.mem.Allocator, n: usize) error{OutOfMemory}!void {
        try self.entries.ensureUnusedCapacity(gpa, @intCast(n));
    }

    /// Store `buf` as resource `id`, not dirty, taking ownership of it. Cannot
    /// fail: requires room from `reserve` and an `id` the store does not hold.
    pub fn adoptAssumeCapacity(self: *ResourceStore, id: ComponentId, buf: Buffer) void {
        self.entries.putAssumeCapacityNoClobber(id, .{ .bytes = buf, .dirty = false });
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

    /// Set a resource's dirty bit explicitly; no-op if absent. Tier-0-internal
    /// seam, NOT a runtime / Etch / plugin API — `pub` only so the scene loader's
    /// rollback can undo the `dirty = true` that `getMutResource` forced.
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

    /// Remove a resource, freeing its buffer. `error.UnknownResource` if absent.
    pub fn removeResource(self: *ResourceStore, gpa: std.mem.Allocator, id: ComponentId) ResourceError!void {
        const kv = self.entries.fetchRemove(id) orelse return ResourceError.UnknownResource;
        gpa.free(kv.value.bytes);
    }
};

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

test "resource buffers are chunk-aligned (Option A)" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

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

test "setDirty restores an explicit dirty state" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{1};
    try store.addResource(gpa, 5, &bytes);
    _ = store.getMutResource(5).?;
    try std.testing.expect(store.isDirty(5));

    store.setDirty(5, false);
    try std.testing.expect(!store.isDirty(5));
    store.setDirty(5, true);
    try std.testing.expect(store.isDirty(5));

    store.setDirty(999, false);
}
