//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Asset registry — owns the slot table that `AssetHandle`s index into,
//! plus per-slot refcount and generation.
//!
//! M0.6 scope (brief §Scope): handle allocation, refcount, and a generation
//! bump on unload so a stale handle is detectable. Mirrors the ECS
//! `EntityIdentityStore` (slot table + free-index stack + generation),
//! adding the refcount and the `type_tag` carried by `AssetHandle`. Payload
//! binding (the loaded bytes) is deliberately out of scope here — it lands
//! with the async loader (E5).
//!
//! Unmanaged: the registry stores no allocator (Asset Pipeline is not on the
//! `engine-zig-conventions.md` §3 allocator-storing whitelist); the
//! allocator is passed to every mutating call.

const std = @import("std");
const AssetHandle = @import("asset_handle.zig").AssetHandle;
const AssetType = @import("../format/asset_type.zig").AssetType;

const Registry = @This();

/// Per-slot table, indexed by `AssetHandle.index`.
slots: std.ArrayListUnmanaged(Slot) = .empty,
/// Stack of freed slot indices available for recycling.
free_indices: std.ArrayListUnmanaged(u32) = .empty,

/// One row of the slot table. Private — consumers go through the verbs.
const Slot = struct {
    /// Current generation; bumped on unload so outstanding handles to the
    /// previous occupant fail `liveIndex`.
    generation: u16,
    /// `AssetType` value of the current occupant.
    type_tag: u16,
    /// Strong reference count; the slot unloads when it reaches 0.
    refcount: u32,
    /// `true` while the slot points at a live asset.
    alive: bool,
    /// Stable asset identity (UUIDv7 as u128). Stored only in M0.6 —
    /// references resolve by path; uuid-based resolution is Phase 1+. 0 when
    /// unknown (the runtime `.bin` carries no uuid in M0.6).
    uuid: u128,
};

/// Errors surfaced by the mutating verbs.
pub const Error = error{
    /// The handle no longer resolves (freed slot, generation mismatch,
    /// type-tag mismatch, or out-of-range index).
    StaleHandle,
    /// The slot table or free list could not grow.
    OutOfMemory,
    /// R9 (M1.1.1-HF3): `retain` would overflow the `u32` refcount (it is already
    /// at `maxInt(u32)`). Widens the pinned `Registry.Error` — a change tracked by
    /// `WELD_ASSET_PIPELINE_PROTOCOL_VERSION`.
    ReferenceCountOverflow,
};

/// A resolved view of a live slot returned by `resolve`.
pub const Resolved = struct {
    /// Raw `type_tag` stored at allocation.
    type_tag: u16,
    /// Current strong reference count.
    refcount: u32,
    /// Decoded `AssetType`, or `null` if the tag is not a known variant.
    asset_type: ?AssetType,
    /// Stable asset identity (0 if unknown).
    uuid: u128,
};

/// Create an empty registry. No allocation happens until the first `alloc`.
pub fn init() Registry {
    return .{};
}

/// Release the slot table + free list and poison `self`.
pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
    self.slots.deinit(gpa);
    self.free_indices.deinit(gpa);
    self.* = undefined;
}

/// Reserve a fresh handle for an asset of `asset_type`, with refcount 1.
/// Recycles a freed slot (carrying the bumped generation) when one is
/// available, otherwise appends a new slot at generation 0.
///
/// Errors: `error.OutOfMemory` if the slot table needs to grow.
pub fn alloc(self: *Registry, gpa: std.mem.Allocator, asset_type: AssetType) Error!AssetHandle {
    return self.allocWithUuid(gpa, asset_type, 0);
}

/// Like `alloc`, but records the asset's stable `uuid` in the slot. The uuid
/// is stored only (M0.6 resolves by path); use `alloc` when no uuid is known.
pub fn allocWithUuid(self: *Registry, gpa: std.mem.Allocator, asset_type: AssetType, uuid: u128) Error!AssetHandle {
    const tag = asset_type.toU16();
    if (self.free_indices.pop()) |idx| {
        const slot = &self.slots.items[idx];
        std.debug.assert(!slot.alive);
        slot.alive = true;
        slot.type_tag = tag;
        slot.refcount = 1;
        slot.uuid = uuid;
        return .{ .index = idx, .generation = slot.generation, .type_tag = tag };
    }
    const idx: u32 = @intCast(self.slots.items.len);
    try self.slots.append(gpa, .{ .generation = 0, .type_tag = tag, .refcount = 1, .alive = true, .uuid = uuid });
    return .{ .index = idx, .generation = 0, .type_tag = tag };
}

/// Resolve a handle to a live-slot view, or `null` if it is stale (freed,
/// generation mismatch, type-tag mismatch, or out-of-range index).
pub fn resolve(self: *const Registry, handle: AssetHandle) ?Resolved {
    const idx = self.liveIndex(handle) orelse return null;
    const slot = self.slots.items[idx];
    return .{
        .type_tag = slot.type_tag,
        .refcount = slot.refcount,
        .asset_type = AssetType.fromU16(slot.type_tag),
        .uuid = slot.uuid,
    };
}

/// `true` if `handle` currently resolves to a live asset.
pub fn isAlive(self: *const Registry, handle: AssetHandle) bool {
    return self.liveIndex(handle) != null;
}

/// Current strong reference count, or `null` if the handle is stale.
pub fn refCount(self: *const Registry, handle: AssetHandle) ?u32 {
    const idx = self.liveIndex(handle) orelse return null;
    return self.slots.items[idx].refcount;
}

/// Add a strong reference. Errors `error.StaleHandle` if the handle no
/// longer resolves, or `error.ReferenceCountOverflow` if the `u32` refcount is
/// saturated (R9 — guarded before the increment so the count is never wrapped).
pub fn retain(self: *Registry, handle: AssetHandle) Error!void {
    const idx = self.liveIndex(handle) orelse return error.StaleHandle;
    const slot = &self.slots.items[idx];
    if (slot.refcount == std.math.maxInt(u32)) return error.ReferenceCountOverflow;
    slot.refcount += 1;
}

/// Drop a strong reference; unloads the slot (bumping its generation) when
/// the count reaches 0. Errors `error.StaleHandle` if the handle no longer
/// resolves.
///
/// Reserve-then-mutate: when this release unloads the slot (refcount was 1),
/// the free-list slot is reserved *before* any mutation (via `freeSlot`), so
/// an `OutOfMemory` leaves the slot alive at refcount 1 and the call
/// retryable. The plain decrement path (refcount > 1) allocates nothing.
pub fn release(self: *Registry, gpa: std.mem.Allocator, handle: AssetHandle) Error!void {
    const idx = self.liveIndex(handle) orelse return error.StaleHandle;
    const slot = &self.slots.items[idx];
    std.debug.assert(slot.refcount > 0);
    if (slot.refcount == 1) {
        try self.freeSlot(gpa, idx);
    } else {
        slot.refcount -= 1;
    }
}

/// Force-unload the slot regardless of refcount, bumping its generation so
/// every outstanding handle becomes stale. Errors `error.StaleHandle` if
/// the handle is already stale.
pub fn unload(self: *Registry, gpa: std.mem.Allocator, handle: AssetHandle) Error!void {
    const idx = self.liveIndex(handle) orelse return error.StaleHandle;
    try self.freeSlot(gpa, idx);
}

/// Number of currently live slots. O(n) — for tests / diagnostics.
pub fn liveCount(self: *const Registry) usize {
    var n: usize = 0;
    for (self.slots.items) |slot| {
        if (slot.alive) n += 1;
    }
    return n;
}

/// Return the slot index `handle` refers to, or `null` if it is stale.
fn liveIndex(self: *const Registry, handle: AssetHandle) ?u32 {
    if (handle.index >= self.slots.items.len) return null;
    const slot = self.slots.items[handle.index];
    if (!slot.alive or slot.generation != handle.generation or slot.type_tag != handle.type_tag) {
        return null;
    }
    return handle.index;
}

/// Mark a slot dead, bump its generation, and push it onto the free list.
///
/// R9 (M1.1.1-HF3): a slot whose generation would WRAP is PERMANENTLY retired —
/// marked dead but never returned to the free list. Recycling it would reset the
/// generation to 0 and let a stale handle (generation 0) resolve against a fresh
/// asset (the ABA hazard). This is a deliberate, bounded, documented leak: one
/// slot index per 65 535 reuses of that same slot. Generation stays `u16` —
/// `AssetHandle` is a FROZEN `packed struct(u64)` (C0.5) with no spare bits, so
/// widening it is impossible without breaking the frozen layout; a wider
/// generation would ride a future (protocol-bumped) `AssetHandle` change.
///
/// Reserve-then-mutate: the non-retiring path grows the free-list capacity
/// *before* the slot is touched, so an `OutOfMemory` leaves the slot untouched
/// (alive, refcount preserved) and the caller (`release`/`unload`) retryable. The
/// retiring path allocates nothing (it never pushes to the free list).
fn freeSlot(self: *Registry, gpa: std.mem.Allocator, idx: u32) Error!void {
    const slot = &self.slots.items[idx];
    if (slot.generation == std.math.maxInt(u16)) {
        // Retire permanently: dead, generation left saturated, never recycled.
        slot.alive = false;
        slot.refcount = 0;
        return;
    }
    try self.free_indices.ensureUnusedCapacity(gpa, 1);
    slot.alive = false;
    slot.refcount = 0;
    slot.generation +%= 1;
    self.free_indices.appendAssumeCapacity(idx);
}

test "alloc returns a live, type-tagged handle with refcount 1" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .texture);
    try std.testing.expect(reg.isAlive(h));
    try std.testing.expectEqual(@as(u32, 1), reg.refCount(h).?);
    try std.testing.expectEqual(AssetType.texture, reg.resolve(h).?.asset_type.?);
    try std.testing.expectEqual(AssetType.texture, h.assetType().?);
    try std.testing.expectEqual(@as(usize, 1), reg.liveCount());
}

test "retain and release adjust the refcount without unloading" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .mesh);
    try reg.retain(h);
    try std.testing.expectEqual(@as(u32, 2), reg.refCount(h).?);
    try reg.release(gpa, h);
    try std.testing.expectEqual(@as(u32, 1), reg.refCount(h).?);
    try std.testing.expect(reg.isAlive(h));
}

test "release to zero unloads and invalidates the handle" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .audio);
    try reg.release(gpa, h);
    try std.testing.expect(!reg.isAlive(h));
    try std.testing.expectEqual(@as(?Resolved, null), reg.resolve(h));
    try std.testing.expectError(error.StaleHandle, reg.retain(h));
    try std.testing.expectEqual(@as(usize, 0), reg.liveCount());
}

test "explicit unload invalidates outstanding handles regardless of refcount" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .texture);
    try reg.retain(h); // refcount 2
    try reg.unload(gpa, h);
    try std.testing.expect(!reg.isAlive(h));
    try std.testing.expectError(error.StaleHandle, reg.unload(gpa, h));
}

test "freed slot is reused with a strictly bumped generation" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const a = try reg.alloc(gpa, .texture);
    try std.testing.expectEqual(@as(u16, 0), a.generation);
    try reg.unload(gpa, a);

    const b = try reg.alloc(gpa, .mesh);
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(b.generation > a.generation);
    try std.testing.expect(reg.isAlive(b));
    try std.testing.expect(!reg.isAlive(a));
}

test "a handle with a mismatched type_tag does not resolve" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .texture);
    var wrong = h;
    wrong.type_tag = AssetType.mesh.toU16();
    try std.testing.expect(!reg.isAlive(wrong));
    try std.testing.expect(reg.isAlive(h));
}

test "out-of-range handle is treated as stale" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const bogus = AssetHandle{ .index = 999, .generation = 0, .type_tag = AssetType.texture.toU16() };
    try std.testing.expect(!reg.isAlive(bogus));
    try std.testing.expectError(error.StaleHandle, reg.retain(bogus));
}

test "allocWithUuid stores the stable identity; alloc leaves it zero" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const id: u128 = 0x0190b3f0_1c2d_7e4a_8b6c_0123456789ab;
    const h = try reg.allocWithUuid(gpa, .mesh, id);
    try std.testing.expectEqual(id, reg.resolve(h).?.uuid);

    const h2 = try reg.alloc(gpa, .texture);
    try std.testing.expectEqual(@as(u128, 0), reg.resolve(h2).?.uuid);
}

test "release at refcount 1 under OOM leaves the slot alive and retryable" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .texture);
    try std.testing.expectEqual(@as(u32, 1), reg.refCount(h).?);

    // The free list starts empty, so the reserve inside freeSlot is the first
    // allocation the failing allocator sees.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, reg.release(failing.allocator(), h));

    // No observable mutation on OOM: still alive at refcount 1.
    try std.testing.expect(reg.isAlive(h));
    try std.testing.expectEqual(@as(u32, 1), reg.refCount(h).?);
    try std.testing.expectEqual(@as(usize, 1), reg.liveCount());

    // Retrying with a working allocator unloads and recycles the slot.
    try reg.release(gpa, h);
    try std.testing.expect(!reg.isAlive(h));
    try std.testing.expectEqual(@as(usize, 0), reg.liveCount());

    const h2 = try reg.alloc(gpa, .mesh);
    try std.testing.expectEqual(h.index, h2.index); // slot recycled
}

test "retain at maxInt refcount returns ReferenceCountOverflow" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .texture);
    // Saturate the refcount directly (no public API reaches maxInt in a test).
    reg.slots.items[h.index].refcount = std.math.maxInt(u32);

    try std.testing.expectError(error.ReferenceCountOverflow, reg.retain(h));
    // The count is unchanged — the guard runs before the increment.
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), reg.refCount(h).?);
}

test "a slot at generation maxInt is retired, not recycled" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const h = try reg.alloc(gpa, .texture); // slot index 0, generation 0
    // Force the generation to the wrap boundary, then free it: the slot must be
    // permanently retired (dead, not returned to the free list).
    reg.slots.items[h.index].generation = std.math.maxInt(u16);
    try reg.freeSlot(gpa, h.index);

    try std.testing.expect(!reg.isAlive(h)); // old handle is stale
    try std.testing.expectEqual(@as(usize, 0), reg.free_indices.items.len); // not recycled

    // A fresh alloc must NOT reuse the retired slot — it appends a new one.
    const h2 = try reg.alloc(gpa, .mesh);
    try std.testing.expect(h2.index != h.index);
    // The retired index stays dead forever; a stale handle to it never resolves.
    try std.testing.expect(!reg.isAlive(h));
}
