const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-4 Optional
/// vertical — the ops `??` / `!` / `?.`, the `some(v)` / `none` match
/// patterns, and the tranche-3 lift points `pop() -> T?` and `m[k] -> V?`:
///
/// - `xs.pop() ?? -1` → 20 (some), `xs.pop()!` → 10, a third pop on the
///   emptied array → none → `?? -1` = -1 ⇒ popped = 29.
/// - `m[1] ?? 0` hits (100); `m[9] ?? 7` misses (7) — presence/absence
///   through the same insertion-ordered scan in both backends.
/// - `s?.len() ?? 0` chains on `some("hello")` → 5.
/// - `match m[2] { some(x) => x + 1, none => 0 }` → 201 (exhaustive
///   optional match, no wildcard).
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `OptAcc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "OptAcc" },
        } },
    },
};

/// After 1 tick: popped == 20 + 10 - 1, map hit/miss == 100/7, the chain
/// yields the byte length of "hello", and the optional match adds 1 to the
/// present value.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "OptAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "popped", .value = .{ .int_ = 29 } },
                .{ .name = "map_hit", .value = .{ .int_ = 100 } },
                .{ .name = "map_miss", .value = .{ .int_ = 7 } },
                .{ .name = "chained", .value = .{ .int_ = 5 } },
                .{ .name = "matched", .value = .{ .int_ = 201 } },
            } },
        } },
    },
};
