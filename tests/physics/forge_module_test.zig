//! M1.1.15.1 / gate C — acceptance for `Forge3DModule` and for the `step` failure contract.
//!
//! Two subjects, and they are not the same claim. The FIRST is the SHAPE of the Tier 1
//! surface: no allocator on any entry, `void` where the frozen interface says `void`, an
//! error channel where it says one. That half is asserted on the signatures, which is the
//! strongest form available — a runtime probe can show an entry did not allocate on one
//! call, the type system shows it cannot.
//!
//! The SECOND is what `step`'s error channel means when it fires. The contract is that the
//! tick is NOT atomic: an `error.OutOfMemory` leaves the world UNSPECIFIED but NOT
//! CORRUPTED, and the only permitted recovery is to stop ticking and `deinit`. So the
//! injection sweep below asserts STRUCTURE and never simulation state, and it reports the
//! number of injection points it actually reached — a sweep that measured nothing answers
//! exactly like a sweep that found nothing wrong.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const sync = @import("forge_sync");
const module = @import("forge_module");
const foundation = @import("foundation");

const World = core.ecs.World;
const EntityId = core.ecs.EntityId;
const Transform = core.ecs.components.Transform;
const ModuleContext = core.ModuleContext;
const Forge3DModule = module.Forge3DModule;
const PhysicsWorld = forge_3d.PhysicsWorld;
const Vec3r = forge_3d.Vec3r;
const Real = forge_3d.Real;
const testing = std.testing;

const fixed_dt: f32 = 1.0 / 60.0;

fn av3(x: f32, y: f32, z: f32) foundation.math.Vec3 {
    return foundation.math.Vec3.fromArray(.{ x, y, z });
}

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// A context whose only filled field is the one this milestone consumes.
///
/// The other three are real Tier 0 objects rather than `undefined`: a context handed to a
/// module must be a context, and filling them with garbage would make any future `init` that
/// reads one fail in a way this test could not distinguish from a defect.
const Fixture = struct {
    world: World,
    scheduler: core.ecs.SystemScheduler,
    ctx: ModuleContext,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{
            .world = World.init(),
            .scheduler = core.ecs.SystemScheduler.init(),
            .ctx = undefined,
        };
        self.ctx = .{
            .world = &self.world,
            .persistent_allocator = gpa,
            .system_scheduler = &self.scheduler,
            // The job scheduler is the one field with no cheap real instance — starting a
            // worker pool for a test that never submits a job would buy nothing. It is
            // pointed at a zeroed placeholder that this milestone's `init` provably never
            // reads, which the field-set test of gate A is what makes checkable.
            .job_scheduler = @ptrFromInt(@alignOf(core.jobs.scheduler.Scheduler)),
        };
        return self;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.scheduler.deinit(gpa);
        self.world.deinit(gpa);
        gpa.destroy(self);
    }
};

// --- the surface's shape -----------------------------------------------------

/// The frozen `PhysicsModule` entries this adapter PRESENTS, by name. Written out rather
/// than derived from `@typeInfo`'s declaration list, so that an entry DISAPPEARING is a
/// failure here instead of a silently shorter walk.
///
/// **THIRTY-TWO, the whole frozen surface, since M1.1.15.2 G5a.**
/// `engine-tier-interfaces.md` §12 puts the total at 32 `assertFn`, of which 29 exclude
/// `init`, `deinit` and `step`. At M1.1.15.1 this list held twenty-eight and asserted the
/// ABSENCE of `createJoint` and `destroyJoint`, whose parameter types no file declared;
/// G5a mints those types, and `getTriggerOverlaps` and `setJointMotor` joined the frozen
/// surface at §12 versions 0.12 and 0.14. The absence assertions are gone with the absence
/// — see the milestone brief, where the removal is declared.
const frozen_entries = [_][]const u8{
    "init",                  "deinit",             "step",
    "addBody",               "removeBody",         "setBodyTransform",
    "moveKinematic",         "getBodyTransform",   "setLinearVelocity",
    "setAngularVelocity",    "addForce",           "addImpulse",
    "createShape",           "destroyShape",       "raycast",
    "raycastAny",            "raycastAll",         "shapeCast",
    "overlapShape",          "overlapAabb",        "pointQuery",
    "closestPoint",          "createCharacter",    "destroyCharacter",
    "moveCharacter",         "resizeCharacter",    "setCharacterPosition",
    "getCharacterInnerBody", "getTriggerOverlaps", "createJoint",
    "destroyJoint",          "setJointMotor",
};

/// The entries `engine-tier-interfaces.md` §1 declares `void` under the moved-log
/// uniqueness invariant, plus `resizeCharacter`, which §1 keeps fallible and which is the
/// control that makes the walk non-vacuous.
const void_pose_entries = [_][]const u8{ "setBodyTransform", "moveKinematic", "setCharacterPosition" };

/// The four entries that fill a caller slice, and that `engine-tier-interfaces.md` §1 types
/// `anyerror!u32` since M1.1.15.1. They share ONE staging path which allocates the moment the
/// caller's slice exceeds the stack buffer, so an entry among them without a channel returns,
/// under exhaustion, a truncated success indistinguishable from a complete answer.
const fallible_query_entries = [_][]const u8{ "raycastAll", "overlapShape", "overlapAabb", "pointQuery" };

test "Forge3DModule satisfies PhysicsModule with no allocator on any entry" {
    // THE SIZE OF WHAT IS WALKED, first. A probe that finds zero offenders across zero
    // entries is a probe that measured nothing, and `engine-tier-interfaces.md` §12 gives
    // the number this has to be: THIRTY `assertFn`, of which 27 exclude the three
    // lifecycle entries. The count is asserted, not printed.
    const frozen_total: usize = 32; // `engine-tier-interfaces.md` §12
    try testing.expectEqual(frozen_total, frozen_entries.len);

    // THE PRESENCE IS ASSERTED, and it replaces the absence M1.1.15.1 asserted here. The
    // seven types are what make the three joint entries presentable at all, so they are
    // checked alongside the entries rather than assumed by them.
    try testing.expect(module.joint_entries_present);
    inline for ([_][]const u8{
        "JointId",     "JointType",  "JointLimits",     "JointMotorMode",
        "JointTarget", "JointMotor", "JointDescriptor",
    }) |t| {
        try testing.expect(@hasDecl(api, t));
    }
    // NON-VACUITY: `@hasDecl` on this namespace does report a false for something that is
    // really absent, so the seven positives above are not the answer it always gives.
    try testing.expect(!@hasDecl(api, "JointNotAThing"));

    var walked: usize = 0;
    inline for (frozen_entries) |name| {
        // Present at all — the half a signature walk cannot state on its own.
        try testing.expect(@hasDecl(Forge3DModule, name));

        const info = @typeInfo(@TypeOf(@field(Forge3DModule, name))).@"fn";
        inline for (info.params) |param| {
            if (param.type) |T| try testing.expect(T != std.mem.Allocator);
        }
        walked += 1;
    }
    try testing.expectEqual(frozen_entries.len, walked);

    // NON-VACUITY, and it is the whole point of the rule. `PhysicsWorld` — the core this
    // adapter fronts — DOES take an allocator on entries of the same name, which is why it
    // is not the `Impl` and why this file exists. If the predicate above could not find an
    // allocator anywhere, this assertion would fail.
    var core_entries_taking_an_allocator: usize = 0;
    inline for (.{ "addBody", "createCharacter", "resizeCharacter", "step" }) |name| {
        const info = @typeInfo(@TypeOf(@field(PhysicsWorld, name))).@"fn";
        inline for (info.params) |param| {
            if (param.type) |T| {
                if (T == std.mem.Allocator) core_entries_taking_an_allocator += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), core_entries_taking_an_allocator);
}

test "the four multi-result query entries carry an error channel" {
    // THE STRONGEST FORM AVAILABLE, and it complements rather than repeats the runtime probe
    // below: a starved-allocator test shows that an entry DID report on one call; this shows
    // it CANNOT fail to. Three of these four were bare `u32` and survived two rounds of
    // external review under the circular argument that the signature did not permit
    // reporting — an argument the unfrozen interface refutes by existing.
    inline for (fallible_query_entries) |name| {
        const info = @typeInfo(@TypeOf(@field(Forge3DModule, name))).@"fn";
        try testing.expect(@typeInfo(info.return_type.?) == .error_union);
        try testing.expectEqual(u32, @typeInfo(info.return_type.?).error_union.payload);
    }

    // THE CONTROL, without which a walk that found four error unions among four entries could
    // also be a walk that cannot tell one from anything: `raycast` and `raycastAny` are
    // frozen NON-fallible, allocate on no path, and must stay that way.
    try testing.expect(@typeInfo(@typeInfo(@TypeOf(Forge3DModule.raycast)).@"fn".return_type.?) != .error_union);
    try testing.expect(@typeInfo(@typeInfo(@TypeOf(Forge3DModule.raycastAny)).@"fn".return_type.?) != .error_union);
}

test "the frozen void entries are void, and resizeCharacter is not" {
    inline for (void_pose_entries) |name| {
        const info = @typeInfo(@TypeOf(@field(Forge3DModule, name))).@"fn";
        try testing.expectEqual(void, info.return_type.?);
    }

    // The control, and it is named in the brief for this exact reason: `resizeCharacter`
    // CREATES a capsule, an allocation with nothing to do with the moved log, so it cannot
    // join the three however the broadphase is bounded.
    const rc = @typeInfo(@TypeOf(Forge3DModule.resizeCharacter)).@"fn";
    try testing.expect(@typeInfo(rc.return_type.?) == .error_union);

    // And `step` carries its channel, which is the subject of the second half of this file.
    const st = @typeInfo(@TypeOf(Forge3DModule.step)).@"fn";
    try testing.expect(@typeInfo(st.return_type.?) == .error_union);
    try testing.expectEqual(void, @typeInfo(st.return_type.?).error_union.payload);
}

test "the adapter owns the allocator across a body lifecycle" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit(gpa);

    // NOT ONE ALLOCATOR APPEARS BELOW THIS LINE. That is the property; the rest of the
    // test exists so it is exercised on a real lifecycle rather than asserted on types.
    var m = try Forge3DModule.init(&fx.ctx);
    defer m.deinit();

    const shape = try m.createShape(.{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const entity = try fx.world.spawn(gpa, .{ .pos = .{ 0, 5, 0 } }, .{});
    const body = try m.addBody(.{
        .entity = entity,
        .body_type = .dynamic,
        .shape = shape,
        .position = av3(0, 5, 0),
        .mass = 1,
    });

    // Move it through the two frozen `void` entries.
    m.setBodyTransform(body, av3(1, 5, 0), foundation.math.Quatf.identity);
    try testing.expectEqual(@as(f32, 1), (try m.getBodyTransform(body)).position.toArray()[0]);
    m.setLinearVelocity(body, av3(0, 0, 2));
    m.addForce(body, av3(0, 1, 0));
    m.addImpulse(body, av3(0, 0.1, 0));

    // A character, resized — the entry that KEEPS its channel and takes its allocator from
    // the adapter, which is the arrangement this whole file is about.
    const hero = try m.createCharacter(.{ .entity = entity, .position = av3(5, 0, 0) });
    try testing.expect(try m.resizeCharacter(hero, 0.25, 1.2));
    m.setCharacterPosition(hero, av3(6, 0, 0));
    try testing.expect((try m.getCharacterInnerBody(hero)) != null);

    // A tick, then teardown, both through the adapter alone.
    try m.step(fixed_dt);
    m.destroyCharacter(hero);
    m.removeBody(body);
    m.destroyShape(shape);
}

// --- the step failure contract (RD-3) ----------------------------------------

/// An allocator that fails the n-th allocation attempt **once** and then passes everything
/// through.
///
/// **`std.testing.FailingAllocator` CANNOT SERVE THIS TEST, and the reason is mechanical
/// rather than stylistic.** It does not advance its index on a failure, so from `fail_index`
/// onwards EVERY allocation fails. That makes it perfect for the sweep above — the first
/// failure is the one that propagates — and useless for asking whether a caller SWALLOWED a
/// failure: after the swallow the next allocation fails too, so the call reports an error
/// either way and a swallow is invisible. Measured: a counter-factual that made
/// `stepAndPublish` swallow `step`'s error passed against a differential built on
/// `FailingAllocator`, twice, under two different formulations.
///
/// One shot is what separates them. After the induced failure the allocator is healthy, so a
/// caller that swallowed carries on and its later work SUCCEEDS — which is observable.
const OneShotFailingAllocator = struct {
    child: std.mem.Allocator,
    /// Which attempt fails; `attempts` counts every attempt, successful or not.
    fail_at: usize,
    attempts: usize = 0,
    fired: bool = false,

    fn allocator(self: *OneShotFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn shouldFail(self: *OneShotFailingAllocator) bool {
        if (self.fired) return false;
        const hit = self.attempts == self.fail_at;
        self.attempts += 1;
        if (hit) self.fired = true;
        return hit;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return false;
        return self.child.rawResize(buf, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }
};

/// A scene with enough moving parts that a cold tick reaches several allocation sites:
/// a static ground, four dynamic boxes above it, and a character.
fn coldScene(gpa: std.mem.Allocator, pw: *PhysicsWorld) !void {
    const ground = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(20, 0.5, 20) } });
    _ = try pw.addBody(gpa, .{
        .entity = EntityId.dead,
        .body_type = .static,
        .shape = ground,
        .position = av3(0, -0.5, 0),
    });
    const box = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    for (0..4) |i| {
        const x: f32 = @floatFromInt(i);
        _ = try pw.addBody(gpa, .{
            .entity = EntityId.dead,
            .body_type = .dynamic,
            .shape = box,
            .position = av3(x * 2, 0.5, 0),
            .mass = 1,
        });
    }
    _ = try pw.createCharacter(gpa, .{ .entity = EntityId.dead, .position = av3(-4, 0, 0) });

    // A TRIGGER, and it is not decoration. Without one the sensor pass of step 10 bis
    // enumerates nothing and allocates nothing, so no injection index ever lands there and
    // the sweep silently covers ten of the eleven steps. MEASURED: a counter-factual that
    // made step 10 bis swallow its `error.OutOfMemory` did not move the sweep's numbers at
    // all on the scene without this body — the probe was vacuous and the scene was the
    // reason. The overlapping box gives the pass a pair to hold.
    const zone = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(3, 3, 3) } });
    _ = try pw.addBody(gpa, .{
        .entity = EntityId.dead,
        .body_type = .kinematic,
        .shape = zone,
        .position = av3(1, 0.5, 0),
        .is_trigger = true,
    });
}

/// The structural invariants the contract promises across a failed tick.
///
/// **STRUCTURE ONLY, and that is the contract and not a weakening.** The tick is not atomic:
/// some of the eleven steps ran and others did not, so no simulation quantity has a defined
/// value. What must hold is that nothing dangles.
fn assertStructure(pw: *PhysicsWorld, expected_registrations: usize) !void {
    // No registration lost or invented.
    try testing.expectEqual(expected_registrations, pw.bodies.items.len);

    for (pw.bodies.items) |entry| {
        // No dangling index: every registered body is still live in the store...
        try testing.expect(pw.bm.position(entry.id) != null);
        // ...and its proxy still resolves through the registration list.
        try testing.expect(pw.proxyOf(entry.id) != null);
    }

    // No orphan proxy: the broadphase holds exactly as many as the list registers.
    var proxies: u32 = 0;
    inline for (.{ .static, .dynamic, .debris, .trigger }) |layer| {
        proxies += pw.proxyCountIn(layer);
    }
    try testing.expectEqual(@as(u32, @intCast(pw.bodies.items.len)), proxies);

    // No retained pair naming a dead body.
    for (pw.constraints.items) |c| {
        try testing.expect(pw.bm.position(c.body_a) != null);
        try testing.expect(pw.bm.position(c.body_b) != null);
    }
}

test "a failed step leaves the world uncorrupted, and the sweep reports what it reached" {
    const gpa = testing.allocator;

    // THE SWEEP. `n` selects which allocation the injection fails; the loop stops when the
    // injection no longer fires, which is what says the tick has fewer than `n + 1`
    // allocations left to make.
    //
    // **A SITE NOT REACHED AND A SITE NOT FALLIBLE ANSWER IDENTICALLY — no error — and
    // conflating them would let a sweep that measured nothing pass.** `has_induced_failure`
    // is what separates them: it is set by the allocator itself when the injection fires,
    // independently of what `step` then does with the failure. So `fired` counts reach and
    // `errored` counts propagation, and asserting they are EQUAL is what rules out a
    // swallowed failure.
    var fired: usize = 0;
    var errored: usize = 0;
    var n: usize = 0;
    const sweep_cap: usize = 512;

    while (n < sweep_cap) : (n += 1) {
        var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
        defer pw.deinit(gpa);
        try coldScene(gpa, &pw);
        const registrations = pw.bodies.items.len;

        // Armed on the TICK only: the scene is built with the healthy allocator, so what
        // the sweep measures is the tick's own allocations and not the construction's.
        var fa = std.testing.FailingAllocator.init(gpa, .{ .fail_index = n, .resize_fail_index = n });
        const result = pw.step(fa.allocator());

        if (fa.has_induced_failure) fired += 1;
        if (result) |_| {} else |_| errored += 1;

        // The contract, asserted whether or not the injection fired — a tick that
        // succeeded must satisfy it too, or the assertion would only ever describe the
        // failure path.
        try assertStructure(&pw, registrations);

        if (!fa.has_induced_failure) break;
    }

    // THE SIZE OF WHAT WAS MEASURED. Reported as an assertion and not as a print: a cold
    // tick on this scene reaches allocation points, and if it ever reaches none this test
    // must fail rather than pass quietly having swept an empty range.
    try testing.expect(fired > 0);
    try testing.expect(n < sweep_cap); // the sweep terminated on its own signal
    std.debug.print(
        "\n[step failure sweep] injection points reached: {d}; steps that returned an error: {d}\n",
        .{ fired, errored },
    );

    // NOTHING SWALLOWED. Every injection that fired propagated out of `step`. An inequality
    // here means a site catches `error.OutOfMemory` and continues, which the contract
    // forbids in as many words.
    try testing.expectEqual(fired, errored);
}

test "the sweep's errors come from the injection: no failure armed, no error" {
    // THE COUNTER-FACTUAL for the sweep above, on a change of the OBJECT — the same scene,
    // the same number of ticks, a healthy allocator. Without it, a sweep whose scene simply
    // failed on its own would read as a successful measurement of the contract.
    const gpa = testing.allocator;
    var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer pw.deinit(gpa);
    try coldScene(gpa, &pw);
    const registrations = pw.bodies.items.len;

    var fa = std.testing.FailingAllocator.init(gpa, .{}); // nothing armed
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try pw.step(fa.allocator());
        try assertStructure(&pw, registrations);
    }
    try testing.expect(!fa.has_induced_failure);
}

test "a failed step propagates, and the ECS publication does not run after it" {
    // **THE INSTRUMENT IS THE POINT HERE.** Two earlier formulations of this test, both built
    // on `std.testing.FailingAllocator`, agreed with a defect: a counter-factual making
    // `stepAndPublish` SWALLOW `step`'s error passed both. The reason is on
    // `OneShotFailingAllocator` above — that allocator never recovers, so after a swallowed
    // failure the publication fails too and the call reports an error either way. With one
    // shot the allocator is healthy again after the induced failure, so a swallow lets the
    // publication RUN, and running is observable.
    const gpa = testing.allocator;

    var ecs = World.init();
    defer ecs.deinit(gpa);
    var pw = PhysicsWorld.init(vr(0, -9.81, 0), 1.0 / 60.0);
    defer pw.deinit(gpa);
    try coldScene(gpa, &pw);

    const shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const entity = try ecs.spawn(gpa, .{ .pos = .{ 0, 10, 0 } }, .{});
    _ = try pw.addBody(gpa, .{
        .entity = entity,
        .body_type = .dynamic,
        .shape = shape,
        .position = av3(0, 10, 0),
        .mass = 1,
    });

    var caught: usize = 0;
    var n: usize = 0;
    while (n < 96) : (n += 1) {
        var one = OneShotFailingAllocator{ .child = gpa, .fail_at = n };
        const before = ecs.get(Transform, entity).?.pos;
        ecs.beginFrame();
        const failed = if (sync.stepAndPublish(one.allocator(), &pw, &ecs)) |_| false else |_| true;

        if (!one.fired) break; // the tick has fewer than `n + 1` attempts left: sweep done
        if (!failed) continue; // the induced failure landed on a path that recovers on its own

        // THE TWO HALVES, and each needs the other. The call REPORTED the failure — a
        // swallow returns success here — and the ECS did NOT learn anything, which a swallow
        // breaks the other way by letting `syncOut` run on a now-healthy allocator.
        try testing.expectEqual(before, ecs.get(Transform, entity).?.pos);
        caught += 1;
    }

    // NON-VACUITY: without this the loop passes by never having injected anything.
    try testing.expect(caught > 0);

    // COUNTER-FACTUAL on the OBJECT: the same call with a healthy allocator DOES publish, so
    // "unchanged" above is a statement about the failure and not about a scene that never
    // moves.
    const before_healthy = ecs.get(Transform, entity).?.pos;
    ecs.beginFrame();
    try sync.stepAndPublish(gpa, &pw, &ecs);
    try testing.expect(!std.mem.eql(
        u8,
        std.mem.asBytes(&before_healthy),
        std.mem.asBytes(&ecs.get(Transform, entity).?.pos),
    ));
}

// --- the surface's BEHAVIOUR -------------------------------------------------
//
// **THE HALF THAT WAS MISSING, AND ITS ABSENCE IS THE CAUSE OF F1 AND F2.** Everything
// above asserts that the twenty-eight entries EXIST and have the declared shape. Not one of
// them asserts what an entry ANSWERS. Two defects lived in exactly that gap: `entitiesOf`
// projected bodies onto entities without deduplicating, which
// `engine-physics-queries.md` §1.11.14 makes MANDATORY at the projecting tier, and a
// private staging bound of 256 capped four public entries below the caller's own slice.
// Both are invisible to a signature walk, and both are visible to the first call that
// carries a duplicate or asks for more than 256.
//
// The scene below therefore carries TWO bodies on ONE entity and hands out slices WIDER
// than the staging.

/// A module with a scene, driven only through `Forge3DModule` — never through
/// `PhysicsWorld` underneath it. Reaching past the adapter would test the solver again,
/// which is already tested, and would leave the adapter's own projection unexercised, which
/// is the whole point.
const Scene = struct {
    fx: *Fixture,
    m: Forge3DModule,
    unit_box: api.ShapeId,

    fn init(gpa: std.mem.Allocator) !Scene {
        const fx = try Fixture.init(gpa);
        var m = try Forge3DModule.init(&fx.ctx);
        const unit_box = try m.createShape(.{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        return .{ .fx = fx, .m = m, .unit_box = unit_box };
    }

    fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        self.m.deinit();
        self.fx.deinit(gpa);
    }

    /// A static box at `x` owned by `entity`. Static so nothing moves and every query below
    /// answers about placement rather than about simulation.
    fn place(self: *Scene, entity: u32, x: f32) !api.BodyId {
        return self.m.addBody(.{
            .entity = .{ .index = entity, .generation = 0 },
            .body_type = .static,
            .shape = self.unit_box,
            .position = av3(x, 0, 0),
        });
    }
};

/// Wider than `Forge3DModule.max_hits`, so a staging bound below the caller's slice shows up as a
/// short answer instead of hiding behind it.
const wide: usize = 512;

test "the three entity-projecting entries deduplicate: one entity, two bodies, one answer" {
    // §1.11.14: "No deduplication in the solver. The solver's identity is the BODY; it
    // returns bodies. Deduplication belongs to the tier that PROJECTS BODIES ONTO ENTITIES
    // and is MANDATORY there: an entity returned twice by an overlap would translate into
    // damage applied twice." The frozen signatures return `[]EntityId`, so THIS is that
    // tier and the obligation is this file's to check.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // ONE entity, TWO bodies, both inside every probe below.
    _ = try s.place(7, -0.2);
    _ = try s.place(7, 0.2);

    var out: [wide]EntityId = undefined;

    // NON-VACUITY FIRST: the probe really reaches both bodies. Without this, a `1` below
    // would be indistinguishable from a probe that found a single body.
    const solver_bodies = s.m.world.bodies.items.len;
    try testing.expectEqual(@as(usize, 2), solver_bodies);

    const by_box = try s.m.overlapAabb(av3(-2, -2, -2), av3(2, 2, 2), .{}, &out);
    try testing.expectEqual(@as(u32, 1), by_box);
    try testing.expectEqual(@as(u32, 7), out[0].index);

    const by_point = try s.m.pointQuery(av3(-0.2, 0, 0), .{}, &out);
    try testing.expectEqual(@as(u32, 1), by_point);

    const by_shape = try s.m.overlapShape(.{ .shape = s.unit_box, .position = av3(0, 0, 0) }, &out);
    try testing.expectEqual(@as(u32, 1), by_shape);
}

test "retention is on the deduplicated entity set, not on the bodies" {
    // THE SECOND-ORDER DEFECT, and the one a naive fix reproduces. Deduplicating AFTER the
    // truncation cannot be right: collecting `out.len` BODIES and then collapsing them
    // under-fills the slice and evicts unique entities that were entitled to it. The
    // ordering key is entity-major, so entity 1's three bodies come first — a
    // four-body collection sees {1,1,1,2} and answers two entities where four exist.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    _ = try s.place(1, -0.30);
    _ = try s.place(1, -0.10);
    _ = try s.place(1, 0.10);
    _ = try s.place(2, 2.0);
    _ = try s.place(3, 4.0);
    _ = try s.place(4, 6.0);

    var out: [4]EntityId = undefined;
    const n = try s.m.overlapAabb(av3(-10, -2, -2), av3(10, 2, 2), .{}, &out);

    // Four distinct entities exist inside the box and four slots were offered.
    try testing.expectEqual(@as(u32, 4), n);
    for (out, [_]u32{ 1, 2, 3, 4 }) |got, want| try testing.expectEqual(want, got.index);
}

test "no entry caps its answer below the caller's slice" {
    // A private staging depth is an implementation detail; the caller sized `out` and the
    // frozen interface declares `out.len` as the only bound. 400 real hits into a slice of
    // 512 must answer 400 — a `256` here is indistinguishable, to the caller, from a scene
    // that really held 256.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const n_bodies: u32 = 400;
    try testing.expect(n_bodies > Forge3DModule.max_hits); // the probe must exceed the staging
    for (0..n_bodies) |i| _ = try s.place(@intCast(i + 1), @as(f32, @floatFromInt(i)) * 2.0);

    var out: [wide]EntityId = undefined;
    try testing.expect(out.len > n_bodies); // the slice must not be the limit either

    const by_box = try s.m.overlapAabb(av3(-2, -2, -2), av3(900, 2, 2), .{}, &out);
    try testing.expectEqual(n_bodies, by_box);

    // THE PROBE IS CUBIC ON PURPOSE, and the first version of this test was not.
    // A 1000 x 2 x 2 box is a 500:1 aspect ratio, which is past the ~30:1 the GJK path is
    // documented reliable to for radius-0 box cores. Measured, same 400 bodies and the same
    // query with only the probe's shape changed: 500:1 answers 265, 1:1 answers 400. That is
    // the known narrowphase limit and NOT the staging under test, so the probe is chosen to
    // stay inside it — a test that cannot tell its own subject from a neighbouring limit
    // measures neither.
    const by_shape = try s.m.overlapShape(
        .{ .shape = try s.m.createShape(.{ .box = .{ .half_extents = av3(500, 500, 500) } }), .position = av3(400, 0, 0) },
        &out,
    );
    try testing.expectEqual(n_bodies, by_shape);

    var hits: [wide]api.RaycastHit = undefined;
    const by_ray = try s.m.raycastAll(.{
        .origin = av3(-10, 0, 0),
        .direction = av3(1, 0, 0),
        .max_distance = 2000,
    }, &hits);
    try testing.expectEqual(n_bodies, by_ray);
}

// --- the class sweep ---------------------------------------------------------
//
// **F1 AND F2 ARE NOT TWO DEFECTS, THEY ARE THE FIRST TWO OF NINETEEN.** Classified by
// reading the file rather than by grepping it, the twenty-eight entries stood at 9
// behaviour-asserted, 8 called with their answer never asserted, and 11 never called at
// all. Fixing the two named instances and stopping would have left seventeen entries whose
// only guarantee is that they compile — which is how the two named ones got through in the
// first place. The tests below take the remaining surface to behaviour.
//
// What stays deliberately un-asserted is named at each site, so a reader can see the
// residual instead of inferring coverage from the absence of a gap.

test "the read-back mutators move what they claim to move" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const e = api.EntityId{ .index = 1, .generation = 0 };
    const body = try s.m.addBody(.{
        .entity = e,
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(0, 0, 0),
        .mass = 1,
        .gravity_factor = 0,
    });

    // setLinearVelocity — called by the lifecycle test and never read back. A body given
    // +X velocity and no gravity must be further along +X after a tick, and the SIGN is
    // what discriminates: an entry that dropped the write leaves it at the origin.
    s.m.setLinearVelocity(body, av3(3, 0, 0));
    try s.m.step(fixed_dt);
    const after_v = (try s.m.getBodyTransform(body)).position.toArray()[0];
    try testing.expect(after_v > 0.01);

    // addImpulse — an immediate velocity change, so the NEXT tick must travel further than
    // the previous one did. Asserted as a comparison and not against a constant, which
    // keeps the check independent of the timestep.
    s.m.addImpulse(body, av3(6, 0, 0));
    try s.m.step(fixed_dt);
    const after_i = (try s.m.getBodyTransform(body)).position.toArray()[0];
    try testing.expect(after_i - after_v > after_v);

    // setAngularVelocity — never called anywhere before this. There is no angular getter on
    // the frozen surface, so the observable is the ORIENTATION after a tick.
    const before_rot = (try s.m.getBodyTransform(body)).rotation;
    s.m.setAngularVelocity(body, av3(0, 8, 0));
    try s.m.step(fixed_dt);
    const after_rot = (try s.m.getBodyTransform(body)).rotation;
    try testing.expect(!std.meta.eql(before_rot, after_rot));

    // removeBody — called before and never observed. After it, no query finds the body.
    var out: [8]EntityId = undefined;
    try testing.expect(try s.m.overlapAabb(av3(-20, -20, -20), av3(20, 20, 20), .{}, &out) >= 1);
    s.m.removeBody(body);
    try testing.expectEqual(@as(u32, 0), try s.m.overlapAabb(av3(-20, -20, -20), av3(20, 20, 20), .{}, &out));
}

test "addForce is a force and not an impulse, and destroyShape really destroys" {
    // G2. Both entries were CALLED by the lifecycle test and neither effect was ever
    // observed. An oracle that only proves the call did not crash is a smoke test wearing a
    // behaviour test's name.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // addForce — DISCRIMINATED FROM addImpulse, its plausible neighbour, and not merely
    // shown to move something. A force gives `dv = F*h/m` per substep and an impulse gives
    // `dv = F/m` once, so on identical bodies with identical vectors the impulse travels far
    // further. A ratio near ONE would mean the entry is applying an impulse; a ratio near
    // zero would mean it is applying nothing.
    //
    // **THE BAND IS DELIBERATE AND THE EXACT VALUE IS NOT ASSERTED.** A first version of this
    // oracle predicted 1/dt = 60 from single-step Euler and MEASURED 95.99, because `step`
    // runs four TGS Soft substeps: over `h = dt/4` the force accumulates
    // `x = F*h^2/m * (1+2+3+4) = 0.625*F*dt^2/m` while the impulse gives `x = F*dt/m`, so the
    // ratio is `1.6/dt = 96`. The derivation matches the measurement exactly — and pinning 96
    // in an ADAPTER test would pin the solver's substep cadence, which is not this file's
    // subject and would break it for a reason unrelated to the adapter. The band is what
    // discriminates the two entries and nothing more, which is the right scope.
    const forced = try s.m.addBody(.{
        .entity = .{ .index = 10, .generation = 0 },
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(0, 0, 0),
        .mass = 1,
        .gravity_factor = 0,
    });
    const impulsed = try s.m.addBody(.{
        .entity = .{ .index = 11, .generation = 0 },
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(0, 10, 0),
        .mass = 1,
        .gravity_factor = 0,
    });
    s.m.addForce(forced, av3(6, 0, 0));
    s.m.addImpulse(impulsed, av3(6, 0, 0));
    try s.m.step(fixed_dt);

    const dx_force = (try s.m.getBodyTransform(forced)).position.toArray()[0];
    const dx_impulse = (try s.m.getBodyTransform(impulsed)).position.toArray()[0];
    try testing.expect(dx_force > 0); // it is not a no-op
    const ratio = dx_impulse / dx_force;
    try testing.expect(ratio > 10); // an impulse implementation would give ~1
    try testing.expect(ratio < 1000); // and a no-op would send this to infinity

    // destroyShape — DISCRIMINATED FROM A NO-OP. The handle is generational, so after the
    // destruction it is stale and the store refuses it by name.
    const doomed = try s.m.createShape(.{ .box = .{ .half_extents = av3(1, 1, 1) } });
    const before = try s.m.addBody(.{
        .entity = .{ .index = 12, .generation = 0 },
        .body_type = .static,
        .shape = doomed,
        .position = av3(50, 0, 0),
    });
    s.m.removeBody(before); // nothing may still reference it
    s.m.destroyShape(doomed);
    try testing.expectError(error.InvalidShape, s.m.addBody(.{
        .entity = .{ .index = 13, .generation = 0 },
        .body_type = .static,
        .shape = doomed,
        .position = av3(60, 0, 0),
    }));
}

test "the four single-result query entries answer about the scene" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    _ = try s.place(11, 5.0);

    const q = api.RaycastQuery{ .origin = av3(-5, 0, 0), .direction = av3(1, 0, 0), .max_distance = 100 };

    // raycast — never called before. Asserted on the ENTITY and on the DISTANCE, because a
    // projection defect of the F1 family would show up in the first and a scalar-crossing
    // defect in the second. The box spans [4.5, 5.5], so the near face is at 9.5 from -5.
    const hit = s.m.raycast(q) orelse return error.ExpectedHit;
    try testing.expectEqual(@as(u32, 11), hit.entity.index);
    try testing.expectApproxEqAbs(@as(f32, 9.5), hit.distance, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4.5), hit.position.toArray()[0], 1e-3);

    // raycastAny — both verdicts, because a stub returning `true` unconditionally passes a
    // one-sided check.
    try testing.expect(s.m.raycastAny(q));
    try testing.expect(!s.m.raycastAny(.{ .origin = av3(-5, 40, 0), .direction = av3(1, 0, 0), .max_distance = 100 }));

    // shapeCast — never called before. A unit box swept along +X meets the target's near
    // face half its own extent early, so the time of impact is 9.0 and not 9.5; that
    // difference is what distinguishes a real cast from a raycast wearing its name.
    const cast = (try s.m.shapeCast(.{
        .shape = s.unit_box,
        .origin = av3(-5, 0, 0),
        .direction = av3(1, 0, 0),
        .max_distance = 100,
    })) orelse return error.ExpectedHit;
    try testing.expectEqual(@as(u32, 11), cast.entity.index);
    try testing.expectApproxEqAbs(@as(f32, 9.0), cast.distance, 1e-3);

    // closestPoint — never called before. Distance to the SURFACE, so 3.5 from x = 1 and
    // not 4.0 to the centre.
    const near = s.m.closestPoint(av3(1, 0, 0), 100, .{}) orelse return error.ExpectedHit;
    try testing.expectEqual(@as(u32, 11), near.entity.index);
    try testing.expectApproxEqAbs(@as(f32, 3.5), near.distance, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4.5), near.position.toArray()[0], 1e-3);

    // And the negative: out of range answers nothing rather than answering the far thing.
    try testing.expect(s.m.closestPoint(av3(1, 0, 0), 1.0, .{}) == null);
}

test "the character entries move and report a ground" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // A floor to stand on, so `moveCharacter` has a ground to report and the result is not
    // vacuously `.in_air`.
    const floor = try s.m.createShape(.{ .box = .{ .half_extents = av3(20, 0.5, 20) } });
    _ = try s.m.addBody(.{
        .entity = .{ .index = 90, .generation = 0 },
        .body_type = .static,
        .shape = floor,
        .position = av3(0, -0.5, 0),
    });

    const hero = try s.m.createCharacter(.{
        .entity = .{ .index = 91, .generation = 0 },
        .position = av3(0, 0, 0),
        .radius = 0.3,
        .height = 1.6,
    });

    // setCharacterPosition — called by the lifecycle test and never observed. The presence
    // body is the observable the frozen surface offers.
    s.m.setCharacterPosition(hero, av3(2, 0, 0));
    const inner = (try s.m.getCharacterInnerBody(hero)) orelse return error.ExpectedPresence;
    try testing.expectApproxEqAbs(@as(f32, 2), (try s.m.getBodyTransform(inner)).position.toArray()[0], 1e-3);

    // moveCharacter — never called before. Asserted on BOTH halves of its result: the
    // position advanced, and the ground was found. A stub returning a zeroed result passes
    // neither.
    const r = try s.m.moveCharacter(hero, av3(0.5, 0, 0), fixed_dt);
    try testing.expect(r.position.toArray()[0] > 2.01);
    try testing.expectEqual(api.GroundState.grounded, r.ground_state);
    try testing.expectEqual(@as(u32, 90), r.ground_entity.index);
    try testing.expectApproxEqAbs(@as(f32, 1), r.ground_normal.toArray()[1], 1e-3);

    // destroyCharacter — called before and never observed. After it the handle is dead, and
    // the entry that reads it says so rather than answering about a stale presence.
    s.m.destroyCharacter(hero);
    try testing.expect(s.m.getCharacterInnerBody(hero) catch null == null);
}

test "pointQuery does not cap either, and deduplicates at the same time" {
    // The fourth entry of the capped family, and the one the line scene above cannot reach:
    // a point lies inside one body of a row. Four hundred CO-LOCATED boxes put it inside all
    // of them at once, which exercises the cap and the deduplication on the same call.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const distinct: u32 = 400;
    for (0..distinct) |i| _ = try s.place(@intCast(i + 1), 0);
    // ...plus a second body on an entity that already has one, so the answer is the number
    // of ENTITIES and not the number of bodies.
    _ = try s.place(1, 0);
    try testing.expectEqual(@as(usize, distinct + 1), s.m.world.bodies.items.len);

    var out: [wide]EntityId = undefined;
    try testing.expect(out.len > distinct);
    try testing.expectEqual(distinct, try s.m.pointQuery(av3(0, 0, 0), .{}, &out));
}

test "under an exhausted allocator all four multi-result entries REPORT" {
    // I2, and it replaces an oracle that pinned the wrong contract. Three of the four were
    // frozen bare `u32`, so this test used to assert that they DEGRADED to a correct prefix
    // while `overlapShape` alone reported — a difference of shape on one staging path, one
    // failure, four entries. `engine-tier-interfaces.md` §1 now types all four
    // `anyerror!u32`: §0's prohibition is the entry that ALLOCATES AND HAS NO CHANNEL, and a
    // `u32` truncating in silence is that entry under a different return type.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const distinct: u32 = 400;
    for (0..distinct) |i| _ = try s.place(@intCast(i + 1), 0);

    // NON-VACUITY, on a healthy allocator first: all four really answer here, so an error
    // below is exhaustion and not the scene's own limit.
    var out: [wide]EntityId = undefined;
    try testing.expect(out.len > Forge3DModule.stack_hits);
    try testing.expectEqual(distinct, try s.m.overlapAabb(av3(-2, -2, -2), av3(2, 2, 2), .{}, &out));
    try testing.expectEqual(distinct, try s.m.overlapShape(.{ .shape = s.unit_box, .position = av3(0, 0, 0) }, &out));

    // Now starve it. The scene is already built, so nothing but the staging can fail. A
    // FRESH module, because `scratch_bodies` retains capacity and a buffer that already grew
    // would never call the allocator again.
    var fx2 = try Fixture.init(gpa);
    defer fx2.deinit(gpa);
    var m2 = try Forge3DModule.init(&fx2.ctx);
    defer m2.deinit();
    const shape = try m2.createShape(.{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    for (0..distinct) |i| _ = try m2.addBody(.{
        .entity = .{ .index = @intCast(i + 1), .generation = 0 },
        .body_type = .static,
        .shape = shape,
        .position = av3(0, 0, 0),
    });

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const healthy = m2.gpa;
    m2.gpa = failing.allocator();

    // ALL FOUR REPORT. Asserted one by one rather than in a loop, so a failure names the
    // entry that swallowed instead of the position of a slot.
    try testing.expectError(error.OutOfMemory, m2.overlapShape(.{ .shape = shape, .position = av3(0, 0, 0) }, &out));
    try testing.expectError(error.OutOfMemory, m2.overlapAabb(av3(-2, -2, -2), av3(2, 2, 2), .{}, &out));
    try testing.expectError(error.OutOfMemory, m2.pointQuery(av3(0, 0, 0), .{}, &out));

    var hits: [wide]api.RaycastHit = undefined;
    try testing.expectError(error.OutOfMemory, m2.raycastAll(.{
        .origin = av3(-10, 0, 0),
        .direction = av3(1, 0, 0),
        .max_distance = 100,
    }, &hits));

    m2.gpa = healthy; // teardown must not run against a refusing allocator
}
test "moveKinematic derives a velocity where setBodyTransform teleports" {
    // G2, and the oracle it replaces did NOT discriminate. `moveKinematic` DERIVES both
    // velocities from a target pose over `dt` while `setBodyTransform` teleports and derives
    // nothing — that split is the contract — and an implementation that quietly teleported
    // reached the same pose and passed.
    //
    // MEASURED before this oracle was written: after one step both forms sit at 4.0000, and
    // after a SECOND step both are STILL at 4.0000. So the derived velocity is not readable
    // from the pose at all, and the overshoot oracle drafted for it discriminated nothing
    // either. The frozen surface has no velocity getter — but it has ONE place where a
    // kinematic body's velocity is observable: `moveCharacter` reports `ground_velocity` for
    // the body a character stands on. That is what this test reads.
    //
    // The counter-factual is inside the oracle: a twin plate driven by `setBodyTransform`
    // over the same displacement must report a ground velocity of zero.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const plate_shape = try s.m.createShape(.{ .box = .{ .half_extents = av3(4, 0.5, 4) } });

    const driven = try s.m.addBody(.{
        .entity = .{ .index = 20, .generation = 0 },
        .body_type = .kinematic,
        .shape = plate_shape,
        .position = av3(0, -0.5, 0),
    });
    const teleported = try s.m.addBody(.{
        .entity = .{ .index = 21, .generation = 0 },
        .body_type = .kinematic,
        .shape = plate_shape,
        .position = av3(50, -0.5, 0),
    });

    const rider = try s.m.createCharacter(.{
        .entity = .{ .index = 22, .generation = 0 },
        .position = av3(0, 0, 0),
        .radius = 0.3,
        .height = 1.6,
    });
    const passenger = try s.m.createCharacter(.{
        .entity = .{ .index = 23, .generation = 0 },
        .position = av3(50, 0, 0),
        .radius = 0.3,
        .height = 1.6,
    });

    // Same displacement, two entries.
    s.m.moveKinematic(driven, av3(0, -0.5, 0.05), foundation.math.Quatf.identity, fixed_dt);
    s.m.setBodyTransform(teleported, av3(50, -0.5, 0.05), foundation.math.Quatf.identity);

    const on_driven = try s.m.moveCharacter(rider, av3(0, 0, 0), fixed_dt);
    const on_teleported = try s.m.moveCharacter(passenger, av3(0, 0, 0), fixed_dt);

    // NON-VACUITY: both characters really are standing on their plate, so a zero below is a
    // zero velocity and not a missing ground.
    try testing.expectEqual(api.GroundState.grounded, on_driven.ground_state);
    try testing.expectEqual(api.GroundState.grounded, on_teleported.ground_state);
    try testing.expectEqual(@as(u32, 20), on_driven.ground_entity.index);
    try testing.expectEqual(@as(u32, 21), on_teleported.ground_entity.index);

    // THE ASSERTION THAT NAMES THE ENTRY: 0.05 m over one tick is 3 m/s derived, and a
    // teleport derives nothing.
    try testing.expectApproxEqAbs(@as(f32, 3), on_driven.ground_velocity.toArray()[2], 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 0), on_teleported.ground_velocity.toArray()[2], 1e-4);
}

test "three more oracles that discriminate rather than merely observe" {
    // Found by re-counting the class with the RIGHT predicate — not "is the entry called"
    // and not even "is its effect observed", but "does its oracle tell it apart from a
    // plausible NEIGHBOURING entry". Three entries failed that predicate while passing the
    // weaker one, which is the same shape as the F1/F2 family one level up.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // init — its allocator half is covered by the leak check, but nothing observed the WORLD
    // it opens. An `init` that stored a zero gravity passed every other test in this file,
    // because they either use static bodies or set `gravity_factor = 0`.
    const falling = try s.m.addBody(.{
        .entity = .{ .index = 30, .generation = 0 },
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(0, 100, 0),
        .mass = 1,
    });
    try s.m.step(fixed_dt);
    try testing.expect((try s.m.getBodyTransform(falling)).position.toArray()[1] < 100);

    // setLinearVelocity — SETS, where addImpulse ADDS, and with unit mass the two were
    // indistinguishable in the read-back test above: both leave the body at velocity v. The
    // discriminating sequence is to impulse FIRST and then set: an entry that added would
    // leave 11 m/s, one that sets leaves 1.
    const rider = try s.m.addBody(.{
        .entity = .{ .index = 31, .generation = 0 },
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(0, 50, 0),
        .mass = 1,
        .gravity_factor = 0,
    });
    s.m.addImpulse(rider, av3(10, 0, 0));
    s.m.setLinearVelocity(rider, av3(1, 0, 0));
    try s.m.step(fixed_dt);
    const travelled = (try s.m.getBodyTransform(rider)).position.toArray()[0];
    try testing.expect(travelled > 0); // not a no-op
    try testing.expect(travelled < 10 * fixed_dt); // and it REPLACED rather than added

    // resizeCharacter — its `true` was asserted and its EFFECT never was, so an entry that
    // answered `true` and resized nothing passed. The presence body's world box is the
    // observable: a probe at head height finds the tall character and must not find the
    // short one.
    const hero = try s.m.createCharacter(.{
        .entity = .{ .index = 32, .generation = 0 },
        .position = av3(20, 0, 0),
        .radius = 0.3,
        .height = 1.6,
    });
    var out: [8]EntityId = undefined;
    const head_low = av3(19.5, 1.0, -0.5);
    const head_high = av3(20.5, 1.4, 0.5);
    try testing.expectEqual(@as(u32, 1), try s.m.overlapAabb(head_low, head_high, .{}, &out));
    // 0.8 and not 0.5: a capsule's own domain requires `height >= 2 * radius`, and the
    // entry says so by typed error rather than by silently clamping. 0.8 still puts the top
    // well below the probe.
    try testing.expect(try s.m.resizeCharacter(hero, 0.3, 0.8));
    try testing.expectEqual(@as(u32, 0), try s.m.overlapAabb(head_low, head_high, .{}, &out));
}

test "pointQuery tests the SOLID where overlapAabb tests the box" {
    // The last entry that failed the discrimination predicate. On a scene of co-located
    // boxes, `pointQuery` and an `overlapAabb` of a degenerate box at the same point return
    // the same answer, so the oracle above told the two entries apart from nothing. A SPHERE
    // separates them: a point can sit inside the world AABB and outside the solid, and only
    // one of the two entries is allowed to say so.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const ball = try s.m.createShape(.{ .sphere = .{ .radius = 1 } });
    _ = try s.m.addBody(.{
        .entity = .{ .index = 40, .generation = 0 },
        .body_type = .static,
        .shape = ball,
        .position = av3(0, 0, 0),
    });

    // (0.9, 0.9, 0) is inside the box [-1,1]^3 and 1.273 from the centre, so outside a unit
    // sphere. NON-VACUITY first: the AABB query really does reach the body from there.
    var out: [8]EntityId = undefined;
    const corner_lo = av3(0.85, 0.85, -0.05);
    const corner_hi = av3(0.95, 0.95, 0.05);
    try testing.expectEqual(@as(u32, 1), try s.m.overlapAabb(corner_lo, corner_hi, .{}, &out));
    try testing.expectEqual(@as(u32, 0), try s.m.pointQuery(av3(0.9, 0.9, 0), .{}, &out));

    // And it is not blind: a point genuinely inside the solid is found.
    try testing.expectEqual(@as(u32, 1), try s.m.pointQuery(av3(0.2, 0.2, 0), .{}, &out));
}

test "the public path answers under truncation, and the guard stays silent" {
    // K1, and this test exists to attest a LIMIT rather than a guarantee.
    //
    // Five successive formulations promised something about the run — never wrong, then no
    // duplicate, then duplicate-free AND ordered, then true unless the premise broke during
    // the run. All were too wide for one structural reason: `dedupEntities` does not see the
    // run, it sees the window it is handed. With `out.len == 2` and an owner sequence
    // `[3, 5, 1]`, the first pass receives `[3, 5]`, finds it ordered — because it IS — fills
    // the slice and returns before `want` ever doubles. The `1` never enters an observed
    // buffer, and no wording turns a windowed observation into a statement about what it
    // never saw.
    //
    // So the public path is exercised WITH TRUNCATION and the assertion is what actually
    // holds: the premise being sound in reality, the answer is the canonical smallest
    // `out.len` entities and the guard never fires.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    _ = try s.place(5, 0);
    _ = try s.place(3, 2);
    _ = try s.place(1, 4);

    var two: [2]EntityId = undefined;
    const n = try s.m.overlapAabb(av3(-2, -2, -2), av3(10, 2, 2), .{}, &two);

    // The canonical smallest two under the §1.11.14 key — the solver's collector really does
    // deliver entity-major order, so 1 and 3 come back and 5 is the one truncated away.
    try testing.expectEqual(@as(u32, 2), n);
    try testing.expectEqual(@as(u32, 1), two[0].index);
    try testing.expectEqual(@as(u32, 3), two[1].index);
    try testing.expectEqual(@as(u32, 0), s.m.unordered_projections);

    // NON-VACUITY: three entities really are present, so the two above are a TRUNCATION and
    // not the whole scene answering.
    var wide_out: [8]EntityId = undefined;
    try testing.expectEqual(@as(u32, 3), try s.m.overlapAabb(av3(-2, -2, -2), av3(10, 2, 2), .{}, &wide_out));
}

test "the guard refuses what it OBSERVES broken, and that detection is windowed" {
    // The other half, and the two together are the whole contract: a refusal on an observed
    // breach, and NO claim about a breach the window does not contain.
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    const e5 = try s.place(5, 0);
    const e3 = try s.place(3, 2);
    const e1 = try s.place(1, 4);

    var out: [8]EntityId = undefined;

    // NON-VACUITY first: an ordered window answers normally and leaves the counter at zero.
    try testing.expectEqual(@as(u32, 3), try s.m.dedupEntities(&.{ e1, e3, e5 }, &out));
    try testing.expectEqual(@as(u32, 0), s.m.unordered_projections);

    // THE REFUSAL, on a breach the window contains.
    try testing.expectError(error.UnorderedProjection, s.m.dedupEntities(&.{ e5, e3 }, &out));
    try testing.expect(s.m.unordered_projections >= 1);

    // The counter survives the error and answers a different question — the error tells THIS
    // caller its answer is refused, the counter tells a later reader the premise broke at all.
    const after = s.m.unordered_projections;
    try testing.expectError(error.UnorderedProjection, s.m.dedupEntities(&.{ e5, e1 }, &out));
    try testing.expectEqual(after + 1, s.m.unordered_projections);

    // **THE LIMIT, ASSERTED RATHER THAN LEFT TO THE PROSE.** A window that is internally
    // ordered is accepted even when the owner's sequence had a smaller element after it:
    // `[3, 5]` is ordered, and the `1` that would have followed is invisible here. This is
    // the documented behaviour and not a defect — the proof of order over the WHOLE selection
    // belongs to `OverlapCollector`: `add` carries the replace-worst and decides what is
    // RETAINED, `finish` orders the prefix already kept, and neither alone sees both.
    const before = s.m.unordered_projections;
    var two: [2]EntityId = undefined;
    try testing.expectEqual(@as(u32, 2), try s.m.dedupEntities(&.{ e3, e5 }, &two));
    try testing.expectEqual(before, s.m.unordered_projections);
}

// --- M1.1.15.2 G5a — the entries this gate adds -------------------------------

test "getBodyTransform separates a stale handle from a body at the origin" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // THE DEFECT THE ERROR CHANNEL CLOSES, made visible by the pair. A body AT the
    // origin answers the identity pose; a body that was removed answers an error. Before
    // M1.1.15.2 both answered the identity pose and the two were indistinguishable — which
    // is why one body here sits exactly at the origin rather than somewhere convenient.
    const at_origin = try s.place(1, 0);
    const removed = try s.place(2, 5);

    const pose = try s.m.getBodyTransform(at_origin);
    try testing.expectEqual(@as(f32, 0), pose.position.toArray()[0]);

    s.m.removeBody(removed);
    try testing.expectError(error.StaleBodyHandle, s.m.getBodyTransform(removed));

    // And the live one still answers, so the error above is the handle's state and not a
    // world that stopped answering.
    _ = try s.m.getBodyTransform(at_origin);
}

test "getTriggerOverlaps refuses to truncate a state" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // A trigger over two bodies of two distinct entities: two oriented pairs.
    _ = try s.m.addBody(.{
        .entity = .{ .index = 10, .generation = 0 },
        .body_type = .static,
        .shape = s.unit_box,
        .position = av3(0, 0, 0),
        .is_trigger = true,
    });
    _ = try s.place(11, 0.1);
    _ = try s.place(12, -0.1);
    try s.m.step(1.0 / 60.0);

    var room: [8]api.TriggerOverlap = undefined;
    const n = try s.m.getTriggerOverlaps(&room);
    try testing.expectEqual(@as(u32, 2), n);
    // Sorted on `(trigger_entity, other_entity)` — §1.13.11's key, and the trigger is the
    // FIRST member of the pair, so the orientation is observable and not assumed.
    try testing.expectEqual(@as(u32, 10), room[0].trigger_entity.index);
    try testing.expectEqual(@as(u32, 11), room[0].other_entity.index);
    try testing.expectEqual(@as(u32, 12), room[1].other_entity.index);

    // THE ENTRY'S OWN CONTRACT, and where it parts from the query family: a slice too
    // small is `error.BufferTooSmall` and NOT a truncated answer. A subset of a selection
    // is still an answer; a subset of a STATE is a false state — a caller reading one
    // would conclude that an entity left a trigger it never left.
    var too_small: [1]api.TriggerOverlap = undefined;
    try testing.expectError(error.BufferTooSmall, s.m.getTriggerOverlaps(&too_small));

    // NON-VACUITY on that refusal: a slice of EXACTLY the right size is accepted, so the
    // error above is about capacity and not about any slice shorter than the buffer.
    var exact: [2]api.TriggerOverlap = undefined;
    try testing.expectEqual(@as(u32, 2), try s.m.getTriggerOverlaps(&exact));
}

test "the three joint entries are presentable and fail loud" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);
    const body = try s.place(1, 0);

    // PRESENTABLE is the deliverable: this call site could not be WRITTEN without the
    // seven types, so its mere compilation is half the proof. The other half is that the
    // stubs fail loud rather than returning a plausible value — a `JointId` no solver
    // knows would put a dead handle into a caller's state.
    try testing.expectError(error.JointsNotImplemented, s.m.createJoint(.{
        .joint_type = .hinge,
        .body_a = body,
        .body_b = api.PackedId.dead,
        .limits = .{ .angle1d = .{ .min_radians = -1, .max_radians = 1 } },
        .motor = .{
            .target = .{ .scalar = .{ .mode = .velocity, .value = 2 } },
            .max_force = 10,
        },
    }));
    try testing.expectError(error.JointsNotImplemented, s.m.setJointMotor(0, null));
    // `destroyJoint` is `void` by the frozen signature and cannot report; it is a no-op
    // because no id can exist for it to destroy, every path that could mint one having
    // failed first. Called so the entry is exercised rather than only declared.
    s.m.destroyJoint(0);

    // The descriptor's own defaults are the spec's, checked on the fields a caller is
    // most likely to leave alone.
    const d: api.JointDescriptor = .{ .joint_type = .fixed, .body_a = body, .body_b = body };
    try testing.expectEqual(api.JointLimits.none, d.limits);
    try testing.expect(d.motor == null);
    try testing.expect(!d.collide_connected);
    try testing.expectEqual(@as(f32, 0), d.break_force);
    try testing.expectEqual(@as(f32, 0), d.break_torque);
    try testing.expectEqual(@as(f32, 1), d.axis_a.toArray()[1]);

    // `.off` IS NOT A MOTOR MODE, and the absence is asserted rather than left to the
    // enum's shortness to imply. A motor that is off is `null`.
    try testing.expectEqual(@as(usize, 2), @typeInfo(api.JointMotorMode).@"enum".fields.len);
    inline for (@typeInfo(api.JointMotorMode).@"enum".fields) |f| {
        try testing.expect(!std.mem.eql(u8, f.name, "off"));
    }

    // ONE `(max_force, frequency_hz, damping_ratio)` triple per motor, never per axis —
    // pinned structurally, so a per-axis refactor is a failure here and not a silent
    // widening of a contract §1 excluded on a stated motive.
    inline for ([_][]const u8{ "max_force", "frequency_hz", "damping_ratio" }) |name| {
        try testing.expectEqual(f32, @FieldType(api.JointMotor, name));
    }
    // And the ceiling is on the MOTOR and not on the target: no variant of `JointTarget`
    // carries one, which is what "never per axis" means in the type rather than in prose.
    inline for (@typeInfo(api.JointTarget).@"union".fields) |variant| {
        if (@typeInfo(variant.type) != .@"struct") continue;
        inline for (@typeInfo(variant.type).@"struct".fields) |vf| {
            try testing.expect(!std.mem.eql(u8, vf.name, "max_force"));
            try testing.expect(!std.mem.eql(u8, vf.name, "frequency_hz"));
            try testing.expect(!std.mem.eql(u8, vf.name, "damping_ratio"));
        }
    }
}

// --- M1.1.15.2 G6b — the coverage proof ---------------------------------------

/// One row of the coverage map: an entry, the test that DISCRIMINATES it, and
/// the NEIGHBOUR it is told apart from.
///
/// **The predicate, stated before anything is counted.** For entry `E` there is a
/// test `T` and a neighbour `N` — another entry a plausible implementation could
/// be confused with, or a no-op, or a plausible constant — such that `T` FAILS
/// when `E`'s implementation is replaced by `N`'s. "Called by a test" is not the
/// predicate and never was: `addBody` is called by ten tests and none of that
/// tells it apart from anything.
///
/// The trap this table exists against is the one twenty-nine written oracles do
/// not close: two entries sharing one predicate are one entry covered and one
/// entry accompanied. So `neighbour` is written per row and the pairs are checked
/// for duplication below.
const Coverage = struct {
    entry: []const u8,
    /// The test whose name contains this, verbatim.
    test_name: []const u8,
    /// What the entry is discriminated FROM.
    neighbour: []const u8,
};

const coverage = [_]Coverage{
    .{ .entry = "addBody", .test_name = "getBodyTransform separates a stale handle from a body at the origin", .neighbour = "a no-op that returns a handle registering nothing" },
    .{ .entry = "removeBody", .test_name = "the read-back mutators move what they claim to move", .neighbour = "a no-op removal, after which a query still finds the body" },
    .{ .entry = "setBodyTransform", .test_name = "moveKinematic derives a velocity where setBodyTransform teleports", .neighbour = "moveKinematic, which derives both velocities" },
    .{ .entry = "moveKinematic", .test_name = "moveKinematic derives a velocity where setBodyTransform teleports", .neighbour = "setBodyTransform, which derives nothing" },
    .{ .entry = "getBodyTransform", .test_name = "addForce is a force and not an impulse, and destroyShape really destroys", .neighbour = "an entry answering the identity pose whatever the body did" },
    .{ .entry = "setLinearVelocity", .test_name = "three more oracles that discriminate rather than merely observe", .neighbour = "addImpulse, which at unit mass moves a body the same way" },
    .{ .entry = "setAngularVelocity", .test_name = "setAngularVelocity turns about the axis it was given", .neighbour = "an entry that spins about a fixed axis whatever it was asked" },
    .{ .entry = "addForce", .test_name = "addForce is a force and not an impulse, and destroyShape really destroys", .neighbour = "addImpulse, an immediate velocity change" },
    .{ .entry = "addImpulse", .test_name = "addForce is a force and not an impulse, and destroyShape really destroys", .neighbour = "addForce, an accumulated one" },
    .{ .entry = "createShape", .test_name = "pointQuery tests the SOLID where overlapAabb tests the box", .neighbour = "a handle allocator that ignores the descriptor's geometry" },
    .{ .entry = "destroyShape", .test_name = "addForce is a force and not an impulse, and destroyShape really destroys", .neighbour = "a no-op destruction" },
    .{ .entry = "raycast", .test_name = "the four single-result query entries answer about the scene", .neighbour = "raycastAny, which answers whether and not where" },
    .{ .entry = "raycastAny", .test_name = "the four single-result query entries answer about the scene", .neighbour = "a constant verdict — both are asserted" },
    .{ .entry = "raycastAll", .test_name = "no entry caps its answer below the caller's slice", .neighbour = "raycast, which answers one hit" },
    .{ .entry = "shapeCast", .test_name = "the four single-result query entries answer about the scene", .neighbour = "raycast wearing its name — the swept extent moves the impact by half a box" },
    .{ .entry = "overlapShape", .test_name = "overlapShape tests the SHAPE where overlapAabb tests its box", .neighbour = "overlapAabb over the probe's own bounding box" },
    .{ .entry = "overlapAabb", .test_name = "pointQuery tests the SOLID where overlapAabb tests the box", .neighbour = "pointQuery, which tests membership of the solid" },
    .{ .entry = "pointQuery", .test_name = "pointQuery tests the SOLID where overlapAabb tests the box", .neighbour = "overlapAabb, which tests a box" },
    .{ .entry = "closestPoint", .test_name = "the four single-result query entries answer about the scene", .neighbour = "an entry answering the distance to the CENTRE rather than to the surface" },
    .{ .entry = "createCharacter", .test_name = "the character entries move and report a ground", .neighbour = "a handle allocator creating no presence" },
    .{ .entry = "destroyCharacter", .test_name = "the character entries move and report a ground", .neighbour = "a no-op, after which the inner body still answers" },
    .{ .entry = "moveCharacter", .test_name = "the character entries move and report a ground", .neighbour = "a stub returning a zeroed result" },
    .{ .entry = "resizeCharacter", .test_name = "three more oracles that discriminate rather than merely observe", .neighbour = "an entry returning true and resizing nothing" },
    .{ .entry = "setCharacterPosition", .test_name = "the character entries move and report a ground", .neighbour = "a no-op, read through the presence body" },
    .{ .entry = "getCharacterInnerBody", .test_name = "the character entries move and report a ground", .neighbour = "an entry answering a stale presence after destruction" },
    .{ .entry = "getTriggerOverlaps", .test_name = "getTriggerOverlaps refuses to truncate a state", .neighbour = "a query-family entry, which truncates instead of refusing" },
    .{ .entry = "createJoint", .test_name = "the three joint entries are presentable and fail loud", .neighbour = "a stub returning a plausible handle no solver knows" },
    .{ .entry = "destroyJoint", .test_name = "the three joint entries are presentable and fail loud", .neighbour = "an entry that cannot be called at all — the type family is what makes it presentable" },
    .{ .entry = "setJointMotor", .test_name = "the three joint entries are presentable and fail loud", .neighbour = "a void stub reporting a write that never happened" },
};

/// This file, read at compile time, so the table's `test_name`s are confronted
/// with the tests that actually exist rather than with a reader's memory.
const this_file = @embedFile("forge_module_test.zig");

test "every non-lifecycle entry carries a discriminating oracle" {
    // (1) THE SET, both directions. Every non-lifecycle frozen entry appears in the
    // table, and the table names no entry the surface does not have. A one-sided
    // check would pass a table that covered twenty-nine of thirty, or one that
    // covered twenty-nine phantoms.
    const lifecycle = [_][]const u8{ "init", "deinit", "step" };
    var expected: usize = 0;
    for (frozen_entries) |name| {
        var is_lifecycle = false;
        for (lifecycle) |l| {
            if (std.mem.eql(u8, name, l)) is_lifecycle = true;
        }
        if (is_lifecycle) continue;
        expected += 1;
        var found = false;
        for (coverage) |c| {
            if (std.mem.eql(u8, c.entry, name)) found = true;
        }
        if (!found) std.debug.print("UNCOVERED ENTRY: {s}\n", .{name});
        try testing.expect(found);
    }
    try testing.expectEqual(expected, coverage.len);
    // §12's number, minus the three lifecycle entries. Written out so the table's
    // length is confronted with the SPEC and not only with `frozen_entries`.
    try testing.expectEqual(@as(usize, 32 - 3), coverage.len);

    for (coverage) |c| {
        var in_surface = false;
        for (frozen_entries) |name| {
            if (std.mem.eql(u8, c.entry, name)) in_surface = true;
        }
        try testing.expect(in_surface);
    }

    // (2) EVERY NAMED TEST EXISTS, confronted with this file's own bytes. A row
    // naming a test that was renamed or deleted is a row that guards nothing, and
    // nothing else in the build would say so.
    for (coverage) |c| {
        var needle_buf: [256]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "test \"{s}\" {{", .{c.test_name});
        if (std.mem.indexOf(u8, this_file, needle) == null) {
            std.debug.print("MISSING TEST for {s}: {s}\n", .{ c.entry, c.test_name });
        }
        try testing.expect(std.mem.indexOf(u8, this_file, needle) != null);
    }
    // NON-VACUITY on that search: a name that is NOT a test in this file is not
    // found, so the twenty-nine hits above are not what the search always answers.
    try testing.expect(std.mem.indexOf(u8, this_file, "test \"a test that does not exist\" {") == null);

    // (3) NO TWO ENTRIES SHARE ONE PREDICATE. Rows may share a TEST — several
    // entries are discriminated inside one scene — but never a `(test, neighbour)`
    // pair, which would mean one assertion doing duty for two entries and one of
    // them merely accompanied.
    for (coverage, 0..) |a, i| {
        for (coverage[i + 1 ..]) |b| {
            const same = std.mem.eql(u8, a.test_name, b.test_name) and
                std.mem.eql(u8, a.neighbour, b.neighbour);
            if (same) std.debug.print("SHARED PREDICATE: {s} and {s}\n", .{ a.entry, b.entry });
            try testing.expect(!same);
        }
    }
}

test "setAngularVelocity turns about the axis it was given" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // THE GAP M1.1.15.1 NAMED AND LEFT: its oracle asserted that the orientation
    // CHANGED, not which axis — so an entry spinning about a fixed axis whatever it
    // was asked passed it. Two bodies, same everything, different axis, is what
    // tells them apart.
    const about_y = try s.m.addBody(.{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(0, 0, 0),
        .mass = 1,
        .gravity_factor = 0,
    });
    const about_x = try s.m.addBody(.{
        .entity = .{ .index = 2, .generation = 0 },
        .body_type = .dynamic,
        .shape = s.unit_box,
        .position = av3(10, 0, 0),
        .mass = 1,
        .gravity_factor = 0,
    });

    s.m.setAngularVelocity(about_y, av3(0, 8, 0));
    s.m.setAngularVelocity(about_x, av3(8, 0, 0));
    try s.m.step(fixed_dt);

    const ry = (try s.m.getBodyTransform(about_y)).rotation.toArray();
    const rx = (try s.m.getBodyTransform(about_x)).rotation.toArray();

    // Each turned, which is what the old oracle asserted...
    try testing.expect(!std.mem.eql(f32, &ry, &[_]f32{ 0, 0, 0, 1 }));
    try testing.expect(!std.mem.eql(f32, &rx, &[_]f32{ 0, 0, 0, 1 }));
    // ...and they turned DIFFERENTLY, which is what it could not. An entry ignoring
    // the axis produces the same quaternion for both.
    try testing.expect(!std.mem.eql(f32, &ry, &rx));

    // And each about ITS OWN axis, componentwise: the vector part of a rotation about
    // +Y is `(0, sin(θ/2), 0)`. Asserting only "different" would pass an entry that
    // permuted the axes.
    try testing.expect(@abs(ry[1]) > 1e-4);
    try testing.expect(@abs(ry[0]) < 1e-6 and @abs(ry[2]) < 1e-6);
    try testing.expect(@abs(rx[0]) > 1e-4);
    try testing.expect(@abs(rx[1]) < 1e-6 and @abs(rx[2]) < 1e-6);
}

test "overlapShape tests the SHAPE where overlapAabb tests its box" {
    const gpa = testing.allocator;
    var s = try Scene.init(gpa);
    defer s.deinit(gpa);

    // THE SECOND GAP THE AUDIT FOUND. `overlapShape` was asserted for deduplication
    // and for the absence of a cap, and never for the probe's GEOMETRY mattering —
    // so an implementation testing the probe's bounding box would have passed every
    // assertion the file carried.
    //
    // A unit box at the origin spans [-0.5, 0.5]. A radius-0.5 sphere centred at
    // (0.9, 0.9, 0) has a bounding box of [0.4, 1.4] on both axes, which OVERLAPS
    // the box's — but the sphere's surface is 0.566 from the box's nearest corner,
    // which is beyond its radius. Box says yes, shape says no.
    _ = try s.place(1, 0);
    const probe = try s.m.createShape(.{ .sphere = .{ .radius = 0.5 } });

    var out: [8]EntityId = undefined;
    // The bounding boxes DO overlap — the non-vacuity of the whole test, and what
    // makes the zero below a geometric answer rather than a probe that missed.
    try testing.expectEqual(@as(u32, 1), try s.m.overlapAabb(av3(0.4, 0.4, -0.5), av3(1.4, 1.4, 0.5), .{}, &out));
    // The SHAPES do not.
    try testing.expectEqual(@as(u32, 0), try s.m.overlapShape(.{
        .shape = probe,
        .position = av3(0.9, 0.9, 0),
    }, &out));

    // And the same probe moved onto the box DOES answer, so the zero above is a
    // refusal and not an entry that never accepts.
    try testing.expectEqual(@as(u32, 1), try s.m.overlapShape(.{
        .shape = probe,
        .position = av3(0.2, 0, 0),
    }, &out));
}
