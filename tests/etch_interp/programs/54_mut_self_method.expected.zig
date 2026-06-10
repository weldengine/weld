const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-5 mut-self
/// codegen closure (part1 §8.3, resolver-types §7.6):
///
/// - `c.bump(40)` / `c.bump(1)` mutate the receiver through a `mut self`
///   method — the interpreter shares the `struct_ref` store handle, the
///   codegen emits a pointer receiver (`self: *Cnt`) auto-referenced on the
///   caller's `var` binding. The mutation is visible to the caller in both
///   backends: `c.v` reads 42 after the calls.
/// - `c.peek()` (plain `self`) proves the by-value shape still dispatches
///   on the same mutated receiver.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `MutAcc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "MutAcc" },
        } },
    },
};

/// After 1 tick: out == 1 + 40 + 1 read directly, peeked == the same value
/// read through the by-value method.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "MutAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "out", .value = .{ .int_ = 42 } },
                .{ .name = "peeked", .value = .{ .int_ = 42 } },
            } },
        } },
    },
};
