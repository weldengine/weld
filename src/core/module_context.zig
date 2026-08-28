//! `src/core/module_context.zig` — the Tier 0 context handed to every Tier 1 module at
//! `init`. Normative shape: `engine-tier-interfaces.md` §0.
//!
//! **FOUR fields, and the count is the contract.** Each field a reader might expect and not
//! find is absent for a named reason, never by minimalism, and adding one back silently
//! re-opens the defect its absence closes:
//!
//!   - **`registrar` and `event_bus`** would be SECOND declarants of acts `World` already
//!     owns: it carries `registerComponent` as a declaration and `registry`, `resources`,
//!     `singleton_resources`, `event_bus` and `observer_registry` as fields. A context
//!     offering a second route to component registration and a second route to the bus gives
//!     two actors for one act — pattern D11 of `engine-audit-checklist.md` §3. Registration,
//!     resources, events and observers go through `world`, and through nothing else.
//!   - **`asset_loader`** would be a TIER INVERSION. The Asset Pipeline is a Tier 1 module
//!     (`ARCH-013`, `engine-tier-interfaces.md` §10), so a Tier 0 type cannot hold a pointer
//!     to it — and the absurdity needs no invariant to see: that module's own `init` takes a
//!     `*ModuleContext`, so it would receive a pointer to itself. A module that needs another
//!     module goes through the `ModuleRegistry` (§11), which exists for exactly that.
//!   - **`frame_allocator`** has no Tier 0 producer and no consumer. Purely additive,
//!     therefore deferrable without a later refactor; its owner is its first consumer. It
//!     does not travel through `SystemContext` either, which `ARCH-030` re-types wholesale.
//!
//! **The `*World` below is NOT an `ARCH-030` exception — it is outside that invariant's
//! object.** `ARCH-030` restricts the view a SYSTEM ENTRY POINT receives, because that is
//! where entity data is read and written. A module `init` registers components, resources,
//! observers and systems: acts that bear on the whole world by nature, that no restricted
//! view can express, and that touch no entity data. The restriction starts in the bodies of
//! the systems this `init` has just registered. Narrowing this field would produce a false
//! positive against correct code — the shape `ARCH-030` names as D18.

const std = @import("std");

const ecs = @import("ecs/root.zig");
const jobs_scheduler = @import("jobs/scheduler.zig");

/// What the Tier 0 gives a Tier 1 module at initialisation.
///
/// The module **stores** `persistent_allocator` and allocates from its own state
/// afterwards: no entry of a Tier 1 interface takes an allocator as a parameter
/// (`ARCH-013`, `engine-tier-interfaces.md` §0). An implementation whose core demands an
/// allocator per call is therefore fronted by an adapter that owns it — `Forge3DModule`
/// before `PhysicsWorld` is the first such case.
pub const ModuleContext = struct {
    /// ECS: components, resources, events, observers. The SINGLE path to all four — see
    /// the file header on why no second declarant is offered.
    world: *ecs.World,

    /// Engine-lifetime allocator. The module stores it; that is the only thing it is, and
    /// the no-allocator-on-an-entry rule depends on it being stored.
    persistent_allocator: std.mem.Allocator,

    /// Registering systems in the scheduler phases. Distinct from `job_scheduler`: this one
    /// orders ECS systems, the other one runs parallel jobs, and the two qualifiers exist
    /// because the bare word `scheduler` named both.
    system_scheduler: *ecs.SystemScheduler,

    /// Submitting parallel jobs to the shared work-stealing pool (`ARCH-010`).
    job_scheduler: *jobs_scheduler.Scheduler,
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "ModuleContext carries exactly four fields, by name and by type" {
    // The pin lives HERE as well as in `tests/core/module_context_test.zig` because this
    // file is what a future author edits: a count asserted only in a distant test file is a
    // count they will not see. What breaks if this test is removed: a fifth field lands as
    // an ordinary edit instead of as a scope change.
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
