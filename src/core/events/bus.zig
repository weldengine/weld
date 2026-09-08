//! FROZEN — see engine-phase-0-criteria.md C0.5. Every public entry below is.
//!
//! Heterogeneous event bus: typed `EventQueue(T)` instances indexed by `rtti.TypeId`,
//! stored type-erased and cast back with `@ptrCast(@alignCast)` at the call site.
//! `register` is mandatory before `emit` — an unregistered type is an error, not a
//! silent no-op.

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
/// Re-export of the typed `EventQueue` factory.
pub const EventQueue = queue_mod.EventQueue;

/// Errors surfaced by the bus's user-facing entry points.
pub const BusError = error{
    /// `emit` / `subscribe` / `poll` on a type that was never registered.
    EventTypeNotRegistered,
    /// `register` called on a type that was already registered.
    AlreadyRegistered,
    /// The cursor's `type_id` does not match the queue's — a cursor reused across types.
    CursorTypeMismatch,
    /// Forwarded from the underlying allocator.
    OutOfMemory,
} || queue_mod.PollError;

/// Per-queue dispatch table: the operations the bus needs without monomorphising.
const QueueVTable = struct {
    deinit: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) void,
    drain: *const fn (ptr: *anyopaque) void,
    dropsSinceLastDrain: *const fn (ptr: *anyopaque) u64,
    resetDropsSinceLastDrain: *const fn (ptr: *anyopaque) void,
    currentEpoch: *const fn (ptr: *anyopaque) u64,
    currentHead: *const fn (ptr: *anyopaque) usize,
};

/// Static vtable for `EventQueue(T)` — the same pointer for every caller of one `T`.
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

/// Drops above this count at drain time emit a warning.
///
/// Evaluated PER DRAIN, not per second — at 60 Hz that is a strict upper bound on the rate.
pub const DROPS_WARN_THRESHOLD: u64 = 10;

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

    /// Register an event type once, before any `emit`. `cap` must be a power of two >= 2.
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

    /// Enqueue an event of `T`. Never blocks; DROPS THE OLDEST entry on saturation.
    pub fn emit(self: *EventBus, comptime T: type, event: T) BusError!void {
        const tid: rtti.TypeId = comptime rtti.computeTypeId(T);
        const entry = self.queues.get(tid) orelse return error.EventTypeNotRegistered;
        const q: *EventQueue(T) = @ptrCast(@alignCast(entry.ptr));
        q.enqueue(event);
    }

    /// Open a cursor at the queue's current head — events emitted earlier are not visible.
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

    /// Poll one event, or null when empty.
    ///
    /// Fails with `CursorInvalidated` on a stale epoch, `CursorTypeMismatch` on a
    /// foreign cursor, `EventTypeNotRegistered` when `T` was never registered.
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

    /// Drain every queue of lifetime `lt`: warn on excess drops, reset, bump epoch.
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
