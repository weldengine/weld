const driver = @import("diff_runner");

/// Diff-runner fixture: tick budget for the full-grammar codegen integration.
pub const config: driver.Config = .{ .ticks = 7 };

/// Diff-runner fixture: world snapshot at tick 0. A single `RefProbe` entity
/// isolates the Level-A assertion — every other iterative rule's `when entity
/// has X` fails to match it, so only `rule ref_probe_tick` (+= 1 / tick) runs
/// against it. The full-grammar file's B/C constructs (data/routine/.../scene/
/// prefab) emit descriptors at cook time (codegen-compiles proof) and never tick.
pub const initial: driver.WorldSpec = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "RefProbe" },
        } },
    },
};

/// Diff-runner fixture: after 7 ticks `RefProbe.ticks == 7` — byte-exact in
/// both backends (interp + cooked codegen), the Level-A integration proof.
pub const expected: driver.ExpectedWorld = .{
    .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "RefProbe", .fields = &[_]driver.FieldSpec{
                .{ .name = "ticks", .value = .{ .int_ = 7 } },
            } },
        } },
    },
};
