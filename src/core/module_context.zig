//! The Tier 0 context handed to every Tier 1 module at `init`.
//! Normative shape, and the reason each absent field is absent:
//! `engine-tier-interfaces.md` §0.
//!
//! THE `*World` BELOW IS NOT AN `ARCH-030` EXCEPTION — it is outside that
//! invariant's object, which is the SYSTEM ENTRY POINT. A module `init` registers
//! components, resources, observers and systems; the restriction starts in the
//! bodies of the systems it just registered. Narrowing this field would refuse
//! correct code.

const std = @import("std");

const ecs = @import("ecs/root.zig");
const jobs_scheduler = @import("jobs/scheduler.zig");

/// What the Tier 0 gives a Tier 1 module at initialisation.
pub const ModuleContext = struct {
    /// ECS: components, resources, events, observers — the SINGLE path to each.
    world: *ecs.World,

    /// Engine-lifetime allocator; the module stores it.
    persistent_allocator: std.mem.Allocator,

    /// System registration in the scheduler phases.
    system_scheduler: *ecs.SystemScheduler,

    /// Submitting parallel jobs to the shared work-stealing pool (`ARCH-010`).
    job_scheduler: *jobs_scheduler.Scheduler,
};

const testing = std.testing;

test "ModuleContext carries exactly four fields, by name and by type" {
    // Pinned here as well as in the test: a field added to this struct must fail
    // at compile time, not only under `zig build test`.
    const fields = @typeInfo(ModuleContext).@"struct".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);

    try testing.expectEqualStrings("world", fields[0].name);
    try testing.expectEqual(*ecs.World, fields[0].type);

    try testing.expectEqualStrings("persistent_allocator", fields[1].name);
    try testing.expectEqual(std.mem.Allocator, fields[1].type);

    try testing.expectEqualStrings("system_scheduler", fields[2].name);
    try testing.expectEqual(*ecs.SystemScheduler, fields[2].type);

    try testing.expectEqualStrings("job_scheduler", fields[3].name);
    try testing.expectEqual(*jobs_scheduler.Scheduler, fields[3].type);
}
