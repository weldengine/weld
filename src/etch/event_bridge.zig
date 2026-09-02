//! Typed bridge from a Tier 0 `EventQueue(T)` into the interpreter's per-tick
//! event store (M1.1.15.2 G4).
//!
//! **The deliverable is the ORDER, not the adapter.** The interpreter's store
//! has a `Lifetime.tick` and is cleared at the head of every tick; a bridge that
//! pushed on the wrong side of that clear would produce an event emitted, never
//! observed, and no red anywhere. So the drain is not something a caller does
//! before `runFor` — it is registered here and run BY `stepOnce`, after the
//! clear and before rule dispatch, which makes the ordering a property of the
//! engine instead of a discipline the caller has to remember.
//!
//! What crosses the boundary is a type NAME and a flat field list
//! (`Interpreter.pushExternalEvent`). `EventStore` stays private to
//! `interp.zig`: this file never names it, never sees its shape, and could not
//! reach it if it tried.

const std = @import("std");
const weld_core = @import("weld_core");
const interp_mod = @import("interp.zig");

const EventCursor = weld_core.events.EventCursor;
const Interpreter = interp_mod.Interpreter;
const ExternalField = interp_mod.ExternalField;
const ExternalValue = interp_mod.ExternalValue;

/// Bridge one Tier 0 `EventQueue(T)` to one Etch event type.
///
/// `T` must be an `extern struct` of scalars — the same bound
/// `services.event` enforces on the payload it derives a declaration from, and
/// for the same reason: what crosses a module boundary must have a layout.
/// `etch_type_name` is the Etch type the `.d.etch` declares, and it is passed
/// rather than derived because `@typeName` carries a Zig path, not an Etch name.
pub fn Bridge(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    if (info.layout != .@"extern") {
        @compileError("event bridge payload '" ++ @typeName(T) ++ "' must be an extern struct");
    }
    return struct {
        const Self = @This();

        queue: *weld_core.events.EventQueue(T),
        cursor: EventCursor,
        etch_type_name: []const u8,
        /// Events polled off the queue and handed over. Counts the ATTEMPT.
        pushed: usize = 0,
        /// Events the interpreter DROPPED because this program mentions no such
        /// type. Separated from `pushed` on purpose: a bridge wired to a program
        /// that never observes the type is silent otherwise, and silence is the
        /// failure mode this whole gate is written against.
        dropped: usize = 0,
        /// Polls that failed because the queue was drained under the cursor.
        /// A Tier 0 drain between two ticks invalidates it; recorded rather than
        /// swallowed, and rather than crashing a frame.
        invalidations: usize = 0,

        pub fn init(queue: *weld_core.events.EventQueue(T), cursor: EventCursor, etch_type_name: []const u8) Self {
            return .{ .queue = queue, .cursor = cursor, .etch_type_name = etch_type_name };
        }

        /// The erased source the interpreter drains. Registering it is what puts
        /// the drain on the right side of the clear.
        pub fn source(self: *Self) interp_mod.ExternalEventSource {
            return .{ .ctx = @ptrCast(self), .drain = drainErased };
        }

        fn drainErased(ctx: *anyopaque, vm: *Interpreter) anyerror!usize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.drainInto(vm);
        }

        /// Move every queued payload into this tick's store. Returns how many
        /// the interpreter accepted.
        pub fn drainInto(self: *Self, vm: *Interpreter) !usize {
            var accepted: usize = 0;
            while (true) {
                const maybe = self.queue.poll(&self.cursor) catch |e| switch (e) {
                    error.CursorInvalidated => {
                        self.invalidations += 1;
                        // Re-anchor on the current epoch and head rather than
                        // spinning: the events the drain missed are gone, and
                        // reporting the invalidation is what makes that visible.
                        self.cursor = .{
                            .type_id = self.cursor.type_id,
                            .last_read = self.queue.currentHead(),
                            .epoch = self.queue.currentEpoch(),
                        };
                        return accepted;
                    },
                };
                const payload = maybe orelse return accepted;
                self.pushed += 1;
                var fields: [info.fields.len]ExternalField = undefined;
                inline for (info.fields, 0..) |f, i| {
                    fields[i] = .{ .name = f.name, .value = valueOf(f.type, @field(payload, f.name)) };
                }
                if (try vm.pushExternalEvent(self.etch_type_name, &fields)) {
                    accepted += 1;
                } else {
                    self.dropped += 1;
                }
            }
        }
    };
}

fn valueOf(comptime F: type, v: F) ExternalValue {
    return switch (F) {
        i64 => .{ .int_ = v },
        f64 => .{ .float_ = v },
        bool => .{ .bool_ = v },
        []const u8 => .{ .string_ = v },
        u64 => .{ .entity_ = v },
        else => @compileError("event field type '" ++ @typeName(F) ++
            "' has no Etch mapping; the Phase 1 scalar set is {i64, f64, bool, []const u8, u64}"),
    };
}
