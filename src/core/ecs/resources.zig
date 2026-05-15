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

const std = @import("std");
const registry_mod = @import("registry.zig");

pub const ComponentId = registry_mod.ComponentId;

pub const ResourceError = error{
    DuplicateResource,
    UnknownResource,
    OutOfMemory,
};

const Entry = struct {
    bytes: []u8,
    /// Set by `getMutResource`; cleared by `tickBoundary`. Read by the
    /// `when resource T changed` filter (interpreter).
    dirty: bool,
};

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
    /// buffer (length must match the registry's `componentSize(id)`).
    /// Initial `dirty` is `false`. Adding an already-present resource
    /// returns `error.DuplicateResource`.
    pub fn addResource(self: *ResourceStore, gpa: std.mem.Allocator, id: ComponentId, init_bytes: []const u8) ResourceError!void {
        if (self.entries.contains(id)) return ResourceError.DuplicateResource;
        const buf = try gpa.dupe(u8, init_bytes);
        errdefer gpa.free(buf);
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

test "addResource rejects duplicate id" {
    const gpa = std.testing.allocator;
    var store = ResourceStore.init();
    defer store.deinit(gpa);

    const bytes = [_]u8{1};
    try store.addResource(gpa, 0, &bytes);
    try std.testing.expectError(error.DuplicateResource, store.addResource(gpa, 0, &bytes));
}
