//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Byte-level singleton store keyed by `ComponentId`, each entry a heap `[]u8`
//! plus a dirty flag. Every buffer is over-aligned to `ChunkAlignment`
//! UNCONDITIONALLY, so generated code can form a typed `*R` over the bytes and one
//! alignment regime covers every access path — two would reopen an
//! interpreter/codegen divergence.

const std = @import("std");
const registry_mod = @import("registry.zig");
const chunk_mod = @import("chunk.zig");

const ComponentId = registry_mod.ComponentId;

/// At least the largest POD field alignment; pinned at comptime below.
pub const BufferAlignment: usize = chunk_mod.ChunkAlignment;

comptime {
    std.debug.assert(BufferAlignment >= 8);
}

/// The READ paths return `?[]u8` instead of failing through this set.
pub const ResourceError = error{
    DuplicateResource,
    UnknownResource,
    OutOfMemory,
};

const Entry = struct {
    bytes: []align(BufferAlignment) u8,
    /// Set by `getMutResource`, cleared by `tickBoundary`.
    dirty: bool,
};

/// Owns each resource's byte buffer and its dirty flag.
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

    /// `init_bytes` is COPIED, and its length must equal `componentSize(id)`.
    /// A resource already present is `error.DuplicateResource`.
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

    /// Mutable view; sets `dirty = true` unconditionally, even for an equal write.
    pub fn getMutResource(self: *ResourceStore, id: ComponentId) ?[]u8 {
        const e = self.entries.getPtr(id) orelse return null;
        e.dirty = true;
        return e.bytes;
    }

    pub fn isDirty(self: *const ResourceStore, id: ComponentId) bool {
        const e = self.entries.getPtr(id) orelse return false;
        return e.dirty;
    }

    /// Tier-0-internal seam, `pub` only because the scene loader lives elsewhere:
    /// its rollback restores the pre-load dirty state, which `getMutResource` has
    /// already clobbered on both the failed load and the undo.
    pub fn setDirty(self: *ResourceStore, id: ComponentId, value: bool) void {
        const e = self.entries.getPtr(id) orelse return;
        e.dirty = value;
    }

    pub fn contains(self: *const ResourceStore, id: ComponentId) bool {
        return self.entries.contains(id);
    }

    /// Called once per tick, after every rule has run.
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

    // An odd-sized slice from a 1-byte-aligned source must still come back aligned.
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
