//! Refcounted, system-allocator-backed persistent heap for non-POD resource fields —
//! blocks that outlive a rule body or a single scene load.
//! Normative model: `etch-memory-model.md` §4 / §11.
//!
//! THE EXPOSED POINTER IS `block + 16`, and every access here is arithmetic relative
//! to it: `size: usize` at `p-16`, `refcount: atomic u32` at `p-8`, `type_id: u32` at
//! `p-4`, payload from `p`. The leading `size` word is not redundant — Zig's
//! `Allocator` needs the length back at `free`, which the spec's 8-byte header
//! cannot carry.
//!
//! `decref` is `fetchSub(1, .release)` and, on the last release, an ACQUIRE LOAD
//! before the drop and the free — the `@fence`-free idiom, `@fence` having been
//! removed in Zig 0.16. A block allocated immortal carries `refcount == sentinel`,
//! on which `incref` and `decref` are no-ops.
//!
//! Imports only `std`: this sits at Tier 0 and must stay free of Etch coupling.

const std = @import("std");

/// Coarse type tag in each block's header; dispatches the drop before the free.
pub const TypeId = u32;

/// Payload owns no sub-resources — its drop is a no-op.
pub const type_plain: TypeId = 0;

/// A flat UTF-8 string living inside the block (`p[0..len]`) — its drop is a no-op.
pub const type_string: TypeId = 1;

/// A dynamic-array container block; its payload owns the elements, freed by its drop.
pub const type_array: TypeId = 2;

/// A map container block; same discipline as `type_array`.
pub const type_map: TypeId = 3;

/// A set container block (`Set<T>`, ). Same discipline as `type_array`.
pub const type_set: TypeId = 4;

/// Refcount marking an immortal block: `incref` and `decref` are no-ops on it.
pub const sentinel: u32 = std.math.maxInt(u32);

/// On-storage layout of a resource `string` field slot.
pub const StringSlot = extern struct {
    ptr: u64 = 0,
    len: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(StringSlot) == 16);
    std.debug.assert(@alignOf(StringSlot) == 8);
}

/// On-storage layout of a resource collection field slot.
pub const CollectionSlot = extern struct {
    ptr: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(CollectionSlot) == 8);
    std.debug.assert(@alignOf(CollectionSlot) == 8);
}

/// Per-`TypeId` drop callback, registered by the runtime that owns the payload type.
pub const DropFn = *const fn (gpa: std.mem.Allocator, p: [*]u8, size: usize) void;

/// Upper bound of the drop registry — a fixed table indexed by `TypeId`.
const drop_table_len = 16;

/// Per-`TypeId` drop registry — the open `TypeId` set, populated at runtime init.
var drop_table = [_]?DropFn{null} ** drop_table_len;

/// Register the drop for a `TypeId`. Idempotent when the same callback is re-registered.
pub fn registerDrop(type_id: TypeId, f: DropFn) void {
    std.debug.assert(type_id < drop_table_len);
    drop_table[type_id] = f;
}

/// Allocation alignment of every block; at least `@alignOf(Header)`.
const block_align: usize = 16;

/// Invisible per-block prefix. FIELD ORDER IS LOAD-BEARING: `refcount` then `type_id`
/// must sit at `p-8` and `p-4`.
const Header = extern struct {
    size: usize,
    refcount: std.atomic.Value(u32),
    type_id: TypeId,
};

comptime {
    // A reorder here silently moves `refcount` and `type_id` off `p-8` and `p-4`.
    std.debug.assert(@sizeOf(Header) == 16);
    std.debug.assert(@offsetOf(Header, "refcount") == 8);
    std.debug.assert(@offsetOf(Header, "type_id") == 12);
    std.debug.assert(block_align >= @alignOf(Header));
    std.debug.assert(block_align % @alignOf(Header) == 0);
}

fn headerOf(p: [*]u8) *Header {
    const base: [*]u8 = @ptrFromInt(@intFromPtr(p) - @sizeOf(Header));
    return @ptrCast(@alignCast(base));
}

fn blockSlice(p: [*]u8, size: usize) []align(block_align) u8 {
    const base: [*]align(block_align) u8 = @alignCast(@as([*]u8, @ptrFromInt(@intFromPtr(p) - @sizeOf(Header))));
    return base[0 .. @sizeOf(Header) + size];
}

/// Allocate a `size`-byte payload owned by `type_id`, refcount 1.
pub fn alloc(gpa: std.mem.Allocator, type_id: TypeId, size: usize) std.mem.Allocator.Error![*]u8 {
    return allocWithRefcount(gpa, type_id, size, 1);
}

/// Allocate an immortal `size`-byte payload — refcount is `sentinel`, never freed.
pub fn allocImmortal(gpa: std.mem.Allocator, type_id: TypeId, size: usize) std.mem.Allocator.Error![*]u8 {
    return allocWithRefcount(gpa, type_id, size, sentinel);
}

fn allocWithRefcount(gpa: std.mem.Allocator, type_id: TypeId, size: usize, initial: u32) std.mem.Allocator.Error![*]u8 {
    const block = try gpa.alignedAlloc(u8, comptime .fromByteUnits(block_align), @sizeOf(Header) + size);
    const h: *Header = @ptrCast(block.ptr);
    h.* = .{ .size = size, .refcount = .init(initial), .type_id = type_id };
    return block.ptr + @sizeOf(Header);
}

/// Increment the refcount on a copied handle. No-op on an immortal block.
pub fn incref(p: [*]u8) void {
    const h = headerOf(p);
    if (h.refcount.load(.monotonic) == sentinel) return;
    _ = h.refcount.fetchAdd(1, .monotonic);
}

/// Drop a handle. On the last release the block's drop runs and the block
/// is freed. No-op on an immortal block (reclaim those via `destroy`).
pub fn decref(gpa: std.mem.Allocator, p: [*]u8) void {
    const h = headerOf(p);
    if (h.refcount.load(.monotonic) == sentinel) return;
    if (h.refcount.fetchSub(1, .release) == 1) {
        // Acquire load stands in for the dropped `@fence(.acquire)` (removed
        // in Zig 0.16): it synchronizes-with the prior `.release` decrements
        // so the drop observes every writer's stores. Cf. `deque.zig`.
        _ = h.refcount.load(.acquire);
        runDrop(gpa, h.type_id, p, h.size);
        freeBlock(gpa, p);
    }
}

/// Release a block regardless of refcount, running its drop first.
pub fn destroy(gpa: std.mem.Allocator, p: [*]u8) void {
    const h = headerOf(p);
    runDrop(gpa, h.type_id, p, h.size);
    freeBlock(gpa, p);
}

/// Current refcount (`sentinel` for immortal blocks). Debug / test helper.
pub fn refcount(p: [*]u8) u32 {
    return headerOf(p).refcount.load(.monotonic);
}

/// The block's owning `TypeId`.
pub fn typeId(p: [*]u8) TypeId {
    return headerOf(p).type_id;
}

/// The payload size in bytes recorded at `alloc` time.
pub fn payloadSize(p: [*]u8) usize {
    return headerOf(p).size;
}

/// Release a type's owned sub-resources before its block is freed.
fn runDrop(gpa: std.mem.Allocator, type_id: TypeId, p: [*]u8, size: usize) void {
    switch (type_id) {
        type_plain, type_string => {},
        else => {
            if (type_id < drop_table_len) {
                if (drop_table[type_id]) |f| f(gpa, p, size);
            }
        },
    }
}

fn freeBlock(gpa: std.mem.Allocator, p: [*]u8) void {
    gpa.free(blockSlice(p, headerOf(p).size));
}

test "alloc sets refcount 1 and decref to zero frees + drops" {
    const gpa = std.testing.allocator;
    const p = try alloc(gpa, type_string, 5);
    @memcpy(p[0..5], "intro");
    try std.testing.expectEqual(@as(u32, 1), refcount(p));
    try std.testing.expectEqual(type_string, typeId(p));
    try std.testing.expectEqual(@as(usize, 5), payloadSize(p));
    decref(gpa, p);
}

test "incref then decref keeps the block alive until the last release" {
    const gpa = std.testing.allocator;
    const p = try alloc(gpa, type_plain, 8);
    // 3 increfs → refcount 4 → needs 4 decrefs (N increfs require N+1).
    incref(p);
    incref(p);
    incref(p);
    try std.testing.expectEqual(@as(u32, 4), refcount(p));
    decref(gpa, p);
    decref(gpa, p);
    decref(gpa, p);
    try std.testing.expectEqual(@as(u32, 1), refcount(p)); // still alive
    decref(gpa, p); // last release → free
}

test "immortal-interned sentinel: incref/decref are no-ops" {
    const gpa = std.testing.allocator;
    const p = try allocImmortal(gpa, type_string, 5);
    @memcpy(p[0..5], "intro");
    try std.testing.expectEqual(sentinel, refcount(p));
    incref(p);
    try std.testing.expectEqual(sentinel, refcount(p)); // unchanged
    decref(gpa, p); // no-op: not freed, never double-frees
    try std.testing.expectEqual(sentinel, refcount(p)); // still alive
    // Immortal blocks are reclaimed only by the heap owner at teardown.
    destroy(gpa, p);
}

test "type_array drop frees container and decrefs string elements (no leak)" {
    const gpa = std.testing.allocator;
    const List = std.ArrayListUnmanaged([*]u8);
    const Drop = struct {
        fn run(g: std.mem.Allocator, p: [*]u8, size: usize) void {
            _ = size;
            const list: *List = @ptrCast(@alignCast(p));
            for (list.items) |elem| decref(g, elem);
            list.deinit(g);
        }
    };
    registerDrop(type_array, Drop.run);

    const blk = try alloc(gpa, type_array, @sizeOf(List));
    const list: *List = @ptrCast(@alignCast(blk));
    list.* = .empty;
    const s1 = try alloc(gpa, type_string, 5);
    @memcpy(s1[0..5], "intro");
    const s2 = try alloc(gpa, type_string, 5);
    @memcpy(s2[0..5], "outro");
    try list.append(gpa, s1);
    try list.append(gpa, s2);

    decref(gpa, blk);
}

test "type_map drop decrefs keys and values" {
    const gpa = std.testing.allocator;
    const Pair = struct { key: [*]u8, value: [*]u8 };
    const List = std.ArrayListUnmanaged(Pair);
    const Drop = struct {
        fn run(g: std.mem.Allocator, p: [*]u8, size: usize) void {
            _ = size;
            const list: *List = @ptrCast(@alignCast(p));
            for (list.items) |pair| {
                decref(g, pair.key);
                decref(g, pair.value);
            }
            list.deinit(g);
        }
    };
    registerDrop(type_map, Drop.run);

    const blk = try alloc(gpa, type_map, @sizeOf(List));
    const list: *List = @ptrCast(@alignCast(blk));
    list.* = .empty;
    const k = try alloc(gpa, type_string, 4);
    @memcpy(k[0..4], "name");
    const v = try alloc(gpa, type_string, 5);
    @memcpy(v[0..5], "alice");
    try list.append(gpa, .{ .key = k, .value = v });

    decref(gpa, blk);
}

test "type_set drop decrefs elements" {
    const gpa = std.testing.allocator;
    const List = std.ArrayListUnmanaged([*]u8);
    const Drop = struct {
        fn run(g: std.mem.Allocator, p: [*]u8, size: usize) void {
            _ = size;
            const list: *List = @ptrCast(@alignCast(p));
            for (list.items) |elem| decref(g, elem);
            list.deinit(g);
        }
    };
    registerDrop(type_set, Drop.run);

    const blk = try alloc(gpa, type_set, @sizeOf(List));
    const list: *List = @ptrCast(@alignCast(blk));
    list.* = .empty;
    const e = try alloc(gpa, type_string, 3);
    @memcpy(e[0..3], "tag");
    try list.append(gpa, e);

    decref(gpa, blk);
}

test "registerDrop dispatches; unregistered id is a no-op" {
    const gpa = std.testing.allocator;
    const dispatch_id: TypeId = 8;
    const unregistered_id: TypeId = 9;

    const Drop = struct {
        fn run(g: std.mem.Allocator, p: [*]u8, size: usize) void {
            _ = size;
            const owned: *[]u8 = @ptrCast(@alignCast(p));
            g.free(owned.*);
        }
    };
    registerDrop(dispatch_id, Drop.run);
    const blk = try alloc(gpa, dispatch_id, @sizeOf([]u8));
    const slot: *[]u8 = @ptrCast(@alignCast(blk));
    slot.* = try gpa.alloc(u8, 8);
    decref(gpa, blk); // → Drop.run frees the sub-allocation, then the block.

    const blk2 = try alloc(gpa, unregistered_id, 4);
    decref(gpa, blk2);
}
