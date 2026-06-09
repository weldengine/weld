const driver = @import("diff_runner");

/// Diff-runner fixture: 3 ticks. Tick 1 `mark` queues the deferred `add_tag`
/// (applied at the tick boundary → the entity gains `TagSet`); `count` sees no
/// tag yet that tick, so it does not increment. Ticks 2 + 3 the tag bit is
/// set, `count`'s `has_tag` filter matches → `value` reaches 2.
pub const config: driver.Config = .{ .ticks = 3 };

/// Diff-runner fixture: one entity with `Counter` only — no `TagSet`. Both
/// backends add it through the deferred tag mutation (`applyTagMutation`),
/// exercising the archetype transition that the deferral exists for.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter" },
        } },
    },
};

/// Diff-runner fixture: after 3 ticks the entity has migrated to
/// {Counter, TagSet}. `Counter.value == 2` is the byte-exact behavioural
/// outcome; asserting `TagSet` presence confirms the deferred mutation
/// migrated the entity in both backends (its raw bitfield has no named field
/// to diff, so only presence is checked here).
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Counter", .fields = &[_]driver.FieldSpec{
                .{ .name = "value", .value = .{ .int_ = 2 } },
            } },
            .{ .name = "TagSet" },
        } },
    },
};
