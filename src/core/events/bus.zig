//! M0.2 / E4 — heterogeneous event bus.
//!
//! `EventBus` indexes typed `EventQueue(T)` instances by
//! `rtti.TypeId`. The bus stores each queue as an opaque pointer
//! plus a per-type `VTable` so the bus-level operations (deinit,
//! drain, drops accounting) can run without monomorphising on
//! every visit. Typed operations (`emit`, `subscribe`, `poll`)
//! resolve the queue pointer at the call site, then cast back to
//! `*EventQueue(T)` with a comptime-safe `@ptrCast(@alignCast)`.
//!
//! The bus is registered once per event type via `register`. The
//! brief makes `register` mandatory before `emit` — emitting an
//! unknown type returns `error.EventTypeNotRegistered`.
//!
//! Lifetime drains use `drainAtBoundary(lt)`: every queue whose
//! lifetime matches `lt` is reset (its epoch bumped). The bus
//! also reads the per-queue `drops_since_last_drain` counter
//! before the reset and emits a `std.log.scoped(.events).warn`
//! when it exceeds the per-drain threshold of 10.

const std = @import("std");
const rtti = @import("../rtti/root.zig");
const lifetime_mod = @import("lifetime.zig");
const cursor_mod = @import("cursor.zig");
const queue_mod = @import("queue.zig");

const log = std.log.scoped(.events);

/// Re-export of `Lifetime` for bus-local convenience.
pub const Lifetime = lifetime_mod.Lifetime;
/// Re-export of `EventCursor` for bus-local convenience.
pub const EventCursor = cursor_mod.EventCursor;
/// Re-export of the typed `EventQueue` factory for bus-local
/// convenience.
pub const EventQueue = queue_mod.EventQueue;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Errors surfaced by the bus's user-facing entry points.
pub const BusError = error{
    /// `emit` / `subscribe` / `poll` called on a type that was
    /// never `register`ed.
    EventTypeNotRegistered,
    /// `register` called on a type that was already registered.
    AlreadyRegistered,
    /// `poll`'s cursor `type_id` does not match the registered
    /// queue's `type_id` — usually a programming error (a cursor
    /// was reused across types).
    CursorTypeMismatch,
    /// Forwarded from the underlying allocator.
    OutOfMemory,
} || queue_mod.PollError;

/// Per-queue dispatch table — type-erased operations the bus
/// needs without monomorphising on every visit.
const QueueVTable = struct {
    deinit: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) void,
    drain: *const fn (ptr: *anyopaque) void,
    dropsSinceLastDrain: *const fn (ptr: *anyopaque) u64,
    resetDropsSinceLastDrain: *const fn (ptr: *anyopaque) void,
    currentEpoch: *const fn (ptr: *anyopaque) u64,
    currentHead: *const fn (ptr: *anyopaque) usize,
};

/// Build the static vtable for `EventQueue(T)`. Returns a pointer
/// to a comptime-monomorphised constant — same pointer for all
/// callers requesting the same `T`.
fn vtableFor(comptime T: type) *const QueueVTable {
    const gen = struct {
        const Q = EventQueue(T);
        fn deinit_(ptr: *anyopaque, gpa: std.mem.Allocator) void {
            const q: *Q = @ptrCast(@alignCast(ptr));
            q.deinit(gpa);
        }
        fn drain_(ptr: *anyopaque) void {
            const q: *Q = @ptrCast(@alignCast(ptr));
            q.drain();
        }
        fn dropsSinceLastDrain_(ptr: *anyopaque) u64 {
            const q: *Q = @ptrCast(@alignCast(ptr));
            return q.dropsSinceLastDrain();
        }
        fn resetDropsSinceLastDrain_(ptr: *anyopaque) void {
            const q: *Q = @ptrCast(@alignCast(ptr));
            q.resetDropsSinceLastDrain();
        }
        fn currentEpoch_(ptr: *anyopaque) u64 {
            const q: *Q = @ptrCast(@alignCast(ptr));
            return q.currentEpoch();
        }
        fn currentHead_(ptr: *anyopaque) usize {
            const q: *Q = @ptrCast(@alignCast(ptr));
            return q.currentHead();
        }
        const vt = QueueVTable{
            .deinit = deinit_,
            .drain = drain_,
            .dropsSinceLastDrain = dropsSinceLastDrain_,
            .resetDropsSinceLastDrain = resetDropsSinceLastDrain_,
            .currentEpoch = currentEpoch_,
            .currentHead = currentHead_,
        };
    };
    return &gen.vt;
}

const QueueEntry = struct {
    ptr: *anyopaque,
    type_id: rtti.TypeId,
    lifetime: Lifetime,
    vtable: *const QueueVTable,
};

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Drain-warning threshold — `drains_since_last_drain` above this
/// value at drain time emits a `log.warn`. Set per the brief
/// (`drops/sec > 10`); the threshold is evaluated per drain rather
/// than per second, but on a typical 60 Hz tick this is a strict
/// upper bound on the per-second rate.
pub const DROPS_WARN_THRESHOLD: u64 = 10;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Per-world heterogeneous event bus.
pub const EventBus = struct {
    queues: std.AutoHashMapUnmanaged(rtti.TypeId, QueueEntry) = .empty,

    pub fn init() EventBus {
        return .{};
    }

    pub fn deinit(self: *EventBus, gpa: std.mem.Allocator) void {
        var it = self.queues.valueIterator();
        while (it.next()) |entry| {
            entry.vtable.deinit(entry.ptr, gpa);
        }
        self.queues.deinit(gpa);
        self.* = undefined;
    }

    /// Register an event type. Must be called once before any
    /// `emit` / `subscribe` / `poll` for `T`. `cap` is the queue's
    /// ring buffer size; must be a power of two `>= 2`.
    pub fn register(
        self: *EventBus,
        gpa: std.mem.Allocator,
        comptime T: type,
        cap: usize,
        lifetime: Lifetime,
    ) BusError!void {
        // Validate POD via RTTI as a comptime gate.
        _ = comptime rtti.buildTypeInfo(T, .event);
        const tid: rtti.TypeId = comptime rtti.computeTypeId(T);
        if (self.queues.contains(tid)) return error.AlreadyRegistered;

        const q = try EventQueue(T).init(gpa, cap, lifetime);
        errdefer q.deinit(gpa);

        try self.queues.put(gpa, tid, .{
            .ptr = q,
            .type_id = tid,
            .lifetime = lifetime,
            .vtable = vtableFor(T),
        });
    }

    /// Enqueue an event of type `T`. Lock-free, never blocks,
    /// drops the oldest entry on saturation (and bumps the
    /// queue's `drops_since_last_drain`).
    pub fn emit(self: *EventBus, comptime T: type, event: T) BusError!void {
        const tid: rtti.TypeId = comptime rtti.computeTypeId(T);
        const entry = self.queues.get(tid) orelse return error.EventTypeNotRegistered;
        const q: *EventQueue(T) = @ptrCast(@alignCast(entry.ptr));
        q.enqueue(event);
    }

    /// Open a fresh cursor on the queue for `T`. The cursor reads
    /// from the queue's current head — events emitted before this
    /// call are not visible.
    pub fn subscribe(self: *const EventBus, comptime T: type) BusError!EventCursor {
        const tid: rtti.TypeId = comptime rtti.computeTypeId(T);
        const entry = self.queues.get(tid) orelse return error.EventTypeNotRegistered;
        const q: *EventQueue(T) = @ptrCast(@alignCast(entry.ptr));
        return EventCursor{
            .type_id = tid,
            .last_read = q.currentHead(),
            .epoch = q.currentEpoch(),
        };
    }

    /// Poll one event for `cursor`. Returns `null` when empty,
    /// `error.CursorInvalidated` when the cursor's epoch is
    /// stale, `error.CursorTypeMismatch` when the cursor is
    /// bound to a different type, `error.EventTypeNotRegistered`
    /// when `T` is not registered.
    pub fn poll(
        self: *const EventBus,
        comptime T: type,
        cursor: *EventCursor,
    ) BusError!?T {
        const tid: rtti.TypeId = comptime rtti.computeTypeId(T);
        if (cursor.type_id != tid) return error.CursorTypeMismatch;
        const entry = self.queues.get(tid) orelse return error.EventTypeNotRegistered;
        const q: *EventQueue(T) = @ptrCast(@alignCast(entry.ptr));
        return q.poll(cursor);
    }

    /// Drain every queue whose lifetime matches `lt`. For each
    /// matching queue: log a warning when
    /// `drops_since_last_drain > DROPS_WARN_THRESHOLD`, reset the
    /// drops counter, reset head + slot sequences, bump epoch.
    pub fn drainAtBoundary(self: *EventBus, lt: Lifetime) void {
        var it = self.queues.valueIterator();
        while (it.next()) |entry| {
            if (entry.lifetime != lt) continue;
            const drops = entry.vtable.dropsSinceLastDrain(entry.ptr);
            if (drops > DROPS_WARN_THRESHOLD) {
                log.warn(
                    "drop saturation: {d} drops on queue (lifetime={s}) since last drain",
                    .{ drops, @tagName(lt) },
                );
            }
            entry.vtable.drain(entry.ptr);
            entry.vtable.resetDropsSinceLastDrain(entry.ptr);
        }
    }

    /// Number of registered event types. Useful for sanity tests.
    pub fn queueCount(self: *const EventBus) u32 {
        return @intCast(self.queues.count());
    }
};
