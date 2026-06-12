const driver = @import("diff_runner");

/// Diff-runner fixture: 1 tick. Exercises the M0.8 E3-C tranche-3bis Set
/// vertical — the `Set.new`/`Set.from` builtin associated calls plus the
/// §15.2 method subset, as an insertion-ordered element list in BOTH
/// backends (the codegen mirrors the interpreter's set store), so element
/// order is byte-exact by construction:
///
/// - `let e: Set<int> = Set.new()` types the empty set from the annotation.
/// - `Set.from([1, 2, 2, 3])` seeds through scan-skip-or-append — the
///   duplicate 2 collapses, leaving {1, 2, 3}.
/// - `s.insert(4)` appends; `s.insert(2)` is a no-op (already present —
///   the `bool` return is out of subset, statement use only).
/// - `contains(2)` hits, `contains(9)` misses; `len` counts elements.
pub const config: driver.Config = .{ .ticks = 1 };

/// One entity carrying `SetAcc` (all fields start at 0).
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "SetAcc" },
        } },
    },
};

/// After 1 tick: s == {1, 2, 3, 4} and e == {} in both backends, so
/// `count == 4`, `empty_len == 0`, `hit == 1`, `miss == 0`.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "SetAcc", .fields = &[_]driver.FieldSpec{
                .{ .name = "count", .value = .{ .int_ = 4 } },
                .{ .name = "empty_len", .value = .{ .int_ = 0 } },
                .{ .name = "hit", .value = .{ .int_ = 1 } },
                .{ .name = "miss", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
