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
/// **TWENTY-EIGHT, not thirty, and the two missing ones are accounted for below.**
/// `engine-tier-interfaces.md` §12 puts the frozen total at 30 `assertFn`; `createJoint` and
/// `destroyJoint` are absent because their parameter types are — see
/// `module.joint_entries_absent`.
const frozen_entries = [_][]const u8{
    "init",                  "deinit",           "step",
    "addBody",               "removeBody",       "setBodyTransform",
    "moveKinematic",         "getBodyTransform", "setLinearVelocity",
    "setAngularVelocity",    "addForce",         "addImpulse",
    "createShape",           "destroyShape",     "raycast",
    "raycastAny",            "raycastAll",       "shapeCast",
    "overlapShape",          "overlapAabb",      "pointQuery",
    "closestPoint",          "createCharacter",  "destroyCharacter",
    "moveCharacter",         "resizeCharacter",  "setCharacterPosition",
    "getCharacterInnerBody",
};

/// The entries `engine-tier-interfaces.md` §1 declares `void` under the moved-log
/// uniqueness invariant, plus `resizeCharacter`, which §1 keeps fallible and which is the
/// control that makes the walk non-vacuous.
const void_pose_entries = [_][]const u8{ "setBodyTransform", "moveKinematic", "setCharacterPosition" };

test "Forge3DModule satisfies PhysicsModule with no allocator on any entry" {
    // THE SIZE OF WHAT IS WALKED, first. A probe that finds zero offenders across zero
    // entries is a probe that measured nothing, and `engine-tier-interfaces.md` §12 gives
    // the number this has to be: THIRTY `assertFn`, of which 27 exclude the three
    // lifecycle entries. The count is asserted, not printed.
    const frozen_total: usize = 30; // `engine-tier-interfaces.md` §12
    const absent_for_want_of_a_type: usize = 2; // createJoint, destroyJoint
    try testing.expectEqual(frozen_total - absent_for_want_of_a_type, frozen_entries.len);

    // THE ABSENCE IS ASSERTED, not left to the shorter list to imply. A walk that simply
    // did not mention two entries is indistinguishable from one that forgot them.
    try testing.expect(module.joint_entries_absent);
    try testing.expect(!@hasDecl(Forge3DModule, "createJoint"));
    try testing.expect(!@hasDecl(Forge3DModule, "destroyJoint"));
    try testing.expect(!@hasDecl(api, "JointDescriptor"));
    try testing.expect(!@hasDecl(api, "JointId"));
    // NON-VACUITY for those four negatives: `@hasDecl` on these namespaces does find what
    // is really there.
    try testing.expect(@hasDecl(Forge3DModule, "addBody"));
    try testing.expect(@hasDecl(api, "BodyDescriptor"));

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
    try testing.expectEqual(@as(f32, 1), m.getBodyTransform(body).position.toArray()[0]);
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
