//! The Tier 0 context handed to every Tier 1 module at `init`.
//!
//! THE `*World` BELOW IS NOT AN `ARCH-030` EXCEPTION — it is outside that
//! invariant's object, the SYSTEM ENTRY POINT: a module `init` registers, and the
//! restriction starts in the bodies of what it registered.

const std = @import("std");

const ecs = @import("ecs/root.zig");
const jobs_scheduler = @import("jobs/scheduler.zig");

/// What the Tier 0 gives a Tier 1 module at initialisation.
pub const ModuleContext = struct {
    world: *ecs.World,

    persistent_allocator: std.mem.Allocator,

    system_scheduler: *ecs.SystemScheduler,

    job_scheduler: *jobs_scheduler.Scheduler,
};

const testing = std.testing;

test "ModuleContext carries exactly four fields, by name and by type" {
    // A field added here must fail at COMPILE time, not only under `zig build test`.
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
