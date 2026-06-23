//! Phase-1 persistent heap for the Etch runtime (`etch-memory-model.md` §4 /
//! §11). The keystone for non-POD resource fields: a refcounted, system-
//! allocator-backed heap whose blocks outlive a rule body. M1.0.3 uses it for
//! resource `string` fields; M1.0.4 reuses it unchanged for dynamic
//! collections (the `type_id` → drop dispatch and the open `TypeId` set are
//! exactly what `string[]` / `[K: V]` / `Set<T>` will register against).
//!
//! Layout (`etch-memory-model.md` §4.3 / §5.1). Each block is one system
//! allocation laid out as:
//!
//! ```
//!  offset 0        8          12         16 (= exposed payload pointer)
//!  ┌──────────────┬──────────┬──────────┬───────────────────────────┐
//!  │ size: usize  │ refcount │ type_id  │ payload (variable)         │
//!  │  (for free)  │ atomic u32│  u32     │ string bytes, …           │
//!  └──────────────┴──────────┴──────────┴───────────────────────────┘
//! ```
//!
//! The exposed pointer `p` is `block + 16`. The 8-byte `{ refcount, type_id }`
//! header sits **immediately before** `p` (`p-8` / `p-4`), matching the spec's
//! "invisible 8-byte header preceding the exposed payload pointer". The leading
//! `size` word (at `p-16`) is implementation bookkeeping — Zig's `Allocator`
//! requires the length at `free` time, which a literal 8-byte header cannot
//! carry — and is invisible to every consumer; nobody reads it but `free`.
//!
//! Refcount mechanics (`etch-memory-model.md` §4.4 / §8.3). `alloc` yields
//! refcount 1; `incref` is `fetchAdd(1, .monotonic)`; `decref` is
//! `fetchSub(1, .release)` and, on the last release, an acquire load (the
//! `@fence`-free idiom — `@fence` was removed in Zig 0.16, cf.
//! `src/core/jobs/deque.zig`) followed by the type's drop + the block free.
//! A block allocated immortal carries `refcount == sentinel` (`u32.max`):
//! `incref` / `decref` are no-ops on it — compile-time string literals (resource
//! field defaults) use this path so `addResource` allocates nothing.
//!
//! Tier-0-agnostic: imports only `std` (no `src/core` dependency). The Etch
//! runtime owns this heap; the Tier-0 `ResourceStore` stays string-agnostic.

const std = @import("std");

/// Coarse type tag stored in each block's header, used to dispatch the
/// drop that releases a type's owned sub-resources before the block is
/// freed. Open set: M1.0.4 dynamic collections add their own ids.
pub const TypeId = u32;

/// A block whose payload owns no sub-resources (the bytes/POD live inline
/// and are reclaimed by the block free). Drop is a no-op.
pub const type_plain: TypeId = 0;

/// A flat UTF-8 string: the bytes live inside the block (`p[0..len]`) and
/// are reclaimed by the block free, so its drop is a no-op. The distinct
/// id documents intent and lets `typeId` round-trip for debug/inspection.
pub const type_string: TypeId = 1;

/// Refcount value marking an immortal block. `incref` / `decref` are
/// no-ops on it; only `destroy` reclaims it (heap-owner teardown). Used
/// for compile-time interned string literals (`etch-memory-model.md` §4.4).
pub const sentinel: u32 = std.math.maxInt(u32);

/// On-storage layout of a resource `string` field slot (`etch-memory-model.md`
/// §5.1): `{ ptr, len }`, 16 bytes, 8-aligned. `ptr` is the address of the
/// persistent payload bytes (a `type_string` block's payload), or `0` for the
/// empty string (no backing block). The single source of truth for the slot
/// layout; `Registry.FieldKind.string_` reports `sizeBytes == 16` / `alignBytes
/// == 8` to match (cross-checked by a `comptime` assert in `ecs_bridge.zig`).
pub const StringSlot = extern struct {
    ptr: u64 = 0,
    len: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(StringSlot) == 16);
    std.debug.assert(@alignOf(StringSlot) == 8);
}

/// Allocation alignment of every block. ≥ `@alignOf(Header)` (8) and a
/// multiple of it, so the payload at `block + @sizeOf(Header)` is itself
/// 16-aligned — enough for any POD payload a future `TypeId` may carry.
const block_align: usize = 16;

/// Invisible per-block prefix. Field order is load-bearing: `refcount` and
/// `type_id` must be the 8 bytes immediately preceding the payload pointer
/// (`etch-memory-model.md` §4.3); `size` precedes them so `free` can
/// reconstruct the allocation length.
const Header = extern struct {
    size: usize,
    refcount: std.atomic.Value(u32),
    type_id: TypeId,
};

comptime {
    // Pin the layout invariant: a refactor that reorders the fields (and so
    // moves `{ refcount, type_id }` away from being the 8 bytes immediately
    // before the payload) breaks the spec contract — catch it at compile time.
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

/// Allocate a `size`-byte payload owned by `type_id`, refcount 1. Returns
/// the exposed payload pointer (`block + 16`); `p[0..size]` is the writable
/// payload. The `{ refcount, type_id }` header sits at `p-8`.
pub fn alloc(gpa: std.mem.Allocator, type_id: TypeId, size: usize) std.mem.Allocator.Error![*]u8 {
    return allocWithRefcount(gpa, type_id, size, 1);
}

/// Allocate an immortal `size`-byte payload (refcount = `sentinel`). Used
/// for compile-time string literals (resource field defaults): `incref` /
/// `decref` never touch it, and only `destroy` reclaims it at teardown.
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

/// Unconditionally release a block regardless of refcount (runs its drop,
/// then frees). For the heap owner's teardown of immortal / interned blocks,
/// which `decref` leaves alive by design.
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

/// Release a type's owned sub-resources before its block is freed
/// (`etch-memory-model.md` §4.3). Phase-1 ids (`type_plain` / `type_string`)
/// own nothing beyond their inline payload, so their drop is a no-op — the
/// block free reclaims the bytes. M1.0.4 collection ids free their element /
/// table buffers in the `else` arm before the block goes.
fn runDrop(gpa: std.mem.Allocator, type_id: TypeId, p: [*]u8, size: usize) void {
    switch (type_id) {
        type_plain, type_string => {},
        else => {},
    }
    _ = gpa;
    _ = p;
    _ = size;
}

fn freeBlock(gpa: std.mem.Allocator, p: [*]u8) void {
    gpa.free(blockSlice(p, headerOf(p).size));
}

// ─── tests ────────────────────────────────────────────────────────────────

test "alloc sets refcount 1 and decref to zero frees + drops" {
    const gpa = std.testing.allocator;
    const p = try alloc(gpa, type_string, 5);
    @memcpy(p[0..5], "intro");
    try std.testing.expectEqual(@as(u32, 1), refcount(p));
    try std.testing.expectEqual(type_string, typeId(p));
    try std.testing.expectEqual(@as(usize, 5), payloadSize(p));
    // refcount 1 → 0: runs the drop then frees the block (header + bytes).
    // `std.testing.allocator` fails the test on any leak — so a clean exit
    // proves the byte payload was reclaimed.
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
