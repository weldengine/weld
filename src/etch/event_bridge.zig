//! Typed bridge from a Tier 0 `EventQueue(T)` into the interpreter's per-tick
//! event store.
//!
//! **The deliverable is the ORDER, not the adapter.** The interpreter's store
//! has a `Lifetime.tick` and is cleared at the head of every tick, so a bridge
//! pushing on the wrong side of that clear would emit an event nothing ever
//! observes. **THAT FAILURE IS RED**, and deliberately so: the ordering oracle
//! in `tests/etch_events/event_bridge_test.zig` drives three events across three
//! consecutive ticks and asserts the rule saw each one, which a
//! drain-before-clear leaves at zero.
//!
//! The DRAIN is not something a caller performs before `runFor`: it runs
//! inside `stepOnce`,
//! after the clear and before rule dispatch, so the ordering is a property of
//! the engine. What the caller owes is the REGISTRATION: `drainInto` is public,
//! so a caller holding both can drain by hand — and land on the wrong side of
//! the clear, which is the failure this header is about. Only
//! `Interpreter.addEventSource` puts it on the right side.
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
/// `T` must be an `extern struct` — the same bound `services.event` enforces on
/// the payload it derives a declaration from, and for the same reason: what
/// crosses a module boundary must have a layout. The SCALAR set is narrower
/// here: `valueOf` below has no `void` arm where `services.typeRefOf` does, and
/// Zig 0.16 admits a `void` field in an `extern struct` (measured), so a payload
/// carrying one declares through `services.event` and fails to compile here.
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
        /// that never observes the type is otherwise SILENT, and a silent drop
        /// is the one failure this counter exists to make visible.
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
                        // spinning. **THIS SKIPS MORE THAN THE DRAIN REMOVED**:
                        // `drain` resets head to 0, so anything enqueued AFTER
                        // it and before this poll sits in `[0, head)` and is
                        // dropped here too. Re-anchoring on 0 instead would
                        // recover what is still inside the window — past
                        // saturation `poll` snaps to `head - cap` anyway and the
                        // overflow is already counted as a drop by the queue.
                        // The counter is what makes THIS loss visible; it is a
                        // policy, not an inevitability.
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
            "' has no Etch mapping; the scalar set is {i64, f64, bool, []const u8, u64}"),
    };
}
