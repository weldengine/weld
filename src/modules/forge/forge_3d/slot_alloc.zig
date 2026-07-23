//! `forge_3d/slot_alloc.zig` — shared slot-lifecycle allocator.
//!
//! A deterministic generational slot allocator: LIFO intrusive free-list +
//! per-slot generation bumped on free, keyed by the `api.PackedId`
//! `index:24 | generation:8` packing. `ShapeStore` and `BodyManager` both
//! embed one so their "generation packing identical to `ShapeStore`" (brief
//! §E3) holds by construction — the payload lives in the caller's own columns,
//! indexed by the allocator's slot index.
//!
//! File split from the brief's listed set, justified: it is the single shared
//! mechanism both stores require; duplicating it would risk the two drifting.
//! Determinism (M1.1.14): no hash-map anywhere — the free-list is a plain
//! index stack, allocation appends sequentially, so an identical op sequence
//! yields identical ids.

const std = @import("std");
const api = @import("weld_forge");

/// Deterministic generational slot allocator (see file header).
pub const IdAllocator = struct {
    /// Per-slot metadata, parallel (by index) to the caller's payload columns.
    const SlotMeta = struct {
        generation: u8 = 0,
        alive: bool = false,
        /// Next free slot in the LIFO free-list (valid only while `!alive`).
        next_free: ?u32 = null,
    };

    slots: std.ArrayListUnmanaged(SlotMeta) = .empty,
    free_head: ?u32 = null,
    live_count: u32 = 0,

    /// Result of `allocateAssumeCapacity`: the slot index, the packed id, and
    /// whether the slot is brand-new (caller appends its payload) or reused
    /// (caller overwrites its payload at `index`).
    pub const Alloc = struct {
        index: u24,
        id: u32,
        is_new: bool,
    };

    /// Release the metadata storage.
    pub fn deinit(self: *IdAllocator, gpa: std.mem.Allocator) void {
        self.slots.deinit(gpa);
        self.* = undefined;
    }

    /// Reserve room for `n` more brand-new slots so the next `n`
    /// `allocateAssumeCapacity` calls cannot fail.
    pub fn ensureUnusedCapacity(self: *IdAllocator, gpa: std.mem.Allocator, n: usize) !void {
        try self.slots.ensureUnusedCapacity(gpa, n);
    }

    /// Allocate a slot (reusing a freed index LIFO, else a fresh one).
    /// Caller must have reserved capacity via `ensureUnusedCapacity`.
    pub fn allocateAssumeCapacity(self: *IdAllocator) Alloc {
        if (self.free_head) |idx| {
            const meta = &self.slots.items[idx];
            self.free_head = meta.next_free;
            meta.alive = true;
            meta.next_free = null;
            self.live_count += 1;
            return .{
                .index = @intCast(idx),
                .id = api.PackedId.pack(@intCast(idx), meta.generation),
                .is_new = false,
            };
        }
        const idx: u32 = @intCast(self.slots.items.len);
        self.slots.appendAssumeCapacity(.{ .generation = 0, .alive = true, .next_free = null });
        self.live_count += 1;
        return .{ .index = @intCast(idx), .id = api.PackedId.pack(@intCast(idx), 0), .is_new = true };
    }

    /// Free the slot behind `id`. Bumps its generation and pushes it onto the
    /// LIFO free-list. Returns false (no-op) if `id` is already stale/invalid.
    pub fn free(self: *IdAllocator, id: u32) bool {
        const idx = self.validate(id) orelse return false;
        const meta = &self.slots.items[idx];
        meta.alive = false;
        meta.generation +%= 1;
        meta.next_free = self.free_head;
        self.free_head = idx;
        self.live_count -= 1;
        return true;
    }

    /// Return the live slot index for `id`, or null if `id` is stale (freed,
    /// generation mismatch) or out of range.
    pub fn validate(self: *const IdAllocator, id: u32) ?u24 {
        const p = api.PackedId.unpack(id);
        if (p.index >= self.slots.items.len) return null;
        const meta = self.slots.items[p.index];
        if (!meta.alive or meta.generation != p.generation) return null;
        return p.index;
    }

    /// Whether the slot at bare column `index` is currently live. Distinct from
    /// `validate` (which takes a packed id and checks the generation): `free`
    /// does NOT compact, so `slots.items.len` is the high-water mark including
    /// dead slots. An index-ascending pass (the integrator) walks that range and
    /// must filter liveness per slot — a bare index carries no generation, so
    /// `validate` cannot serve here.
    pub fn isAliveIndex(self: *const IdAllocator, index: u32) bool {
        return index < self.slots.items.len and self.slots.items[index].alive;
    }
};
