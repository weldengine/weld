const driver = @import("diff_runner");

/// Diff-runner fixture: 3 ticks. `damage` writes `Health` each tick ONLY for
/// entities carrying `Marked`, so their `Health` changes every tick; `react`
/// (`has Health changed`) fires for an entity iff its `Health` changed since
/// react's last run. This is the byte-exact interpreter↔codegen check that the
/// tick-based change-detection path (markChanged on write + per-rule
/// last_run_tick + `changedTick > last_run_tick` guard) agrees across backends.
pub const config: driver.Config = .{ .ticks = 3 };

/// Two entities sharing {Health, Counter}: entity 0 also has `Marked` (so
/// `damage` mutates its Health), entity 1 does not (its Health is never
/// written). Both match `react`'s `has Counter and has Health` archetype
/// predicate — the difference is solely whether Health *changed*, which is what
/// the filter gates on.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health" },
            .{ .name = "Counter" },
            .{ .name = "Marked" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health" },
            .{ .name = "Counter" },
        } },
    },
};

/// After 3 ticks: entity 0's Health fell 10→7 (written each tick) and its
/// Counter reached 3 (`react` fired each tick — Health changed). Entity 1's
/// Health stayed 10 (never written) so `react`'s `changed` guard skipped it
/// every tick → Counter stayed 0. Entity 1's Counter == 0 is the gating proof:
/// a `changed` filter that merely "always passed" would leave it at 3.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 7 } },
            } },
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 3 } },
            } },
            .{ .name = "Marked" },
        } },
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Health", .fields = &[_]driver.FieldSpec{
                .{ .name = "current", .value = .{ .int_ = 10 } },
            } },
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 0 } },
            } },
        } },
    },
};
