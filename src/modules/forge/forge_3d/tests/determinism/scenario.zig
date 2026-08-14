//! The CANONICAL determinism scenario of M1.1.14 — frozen by the brief.
//!
//! Fixed step 60 Hz, `substep_count` at its M1.1.13.1 default, ONE worker, and
//! **no RNG anywhere**: every initial value below is a literal. What the scenario
//! is for is not to be a plausible game scene — it is to make every mechanism
//! whose determinism the milestone claims actually RUN, so that a witness taken
//! over it can fail when one of them moves.
//!
//! **Body creation order is part of the contract.** `BodyId` is a slot index, so
//! creation order fixes the island rank (`engine-physics-solver.md` §1.8.1, rank
//! = smallest member `BodyId`) and therefore the order constraints are resolved
//! in. Reordering the `init` below is not a refactor; it is a different scenario,
//! and every committed witness becomes wrong. The order is numbered in the code.
//!
//! Seven elements, each present for a named reason and none decorative:
//!
//! 1. **A static half-space ground.** The surface everything rests on, and the
//!    one shape with no AABB at all — it exercises the unbounded proxy list
//!    (`engine-physics-shapes.md` §1.11.15) rather than the BVH.
//! 2. **The five-box stack of M1.1.13.1.** Manifold cardinality 4, sleep
//!    transitions, and the deepest chain of contacts in the scene.
//! 3. **Two groups starting apart and colliding partway through.** The island
//!    partition changes in BOTH directions — two islands become one on contact,
//!    and the trace would not see a merge-only scene.
//! 4. **The frictionless slider of M1.1.13.1.** Carries that milestone's named
//!    ULP residual into the instrument, which is what Gate E re-measures.
//! 5. **A sphere crossing the internal edge of a static `MeshShape`.** Several
//!    constraints per body pair, hence the THIRD term of the ordering key
//!    (`subshape_id`, M1.1.11.1) — without a mesh the key's totality is never
//!    exercised and a two-term key would pass every trace.
//! 6. **One sensor and one body entering then leaving it.** Sensor state and both
//!    deltas (`engine-physics-solver.md` §1.13.11).
//! 7. **A kinematic character on a scripted path over a step and a slope.** The
//!    controller, and the site where a wrong `max_slope` conversion surfaces
//!    first — which is the whole reason the deterministic cosine exists.
//!
//! The elements are laid out in separate regions of X so that only the
//! interactions listed above occur. The half-space is the exception: it is
//! infinite and underlies all of them, which is intended.

const std = @import("std");
const config = @import("../../config.zig");
const api = @import("weld_forge");
const harness = @import("../solver_test.zig");
const character_mod = @import("../../character.zig");
const shape_mod = @import("../../shape.zig");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyId = api.BodyId;
const Vec3 = foundation.math.Vec3;

const vr = harness.vr;
const av3 = harness.av3;

/// Fixed timestep — 60 Hz, the tick the whole contract is expressed in.
pub const fixed_dt: Real = 1.0 / 60.0;
/// Gravity, a literal like everything else here.
pub const gravity: Vec3r = .{ .data = .{ 0, -9.81, 0 } };

/// The scenario, its bodies, and the one character.
///
/// Owns a `harness.World` — the published per-tick cycle, the same one every
/// acceptance test drives, so the instrument measures the engine and not a
/// second copy of the cycle written for it.
pub const Scenario = struct {
    world: harness.World,
    chars: character_mod.CharacterStore = .{},
    character: api.CharacterId = undefined,

    /// The five-box stack, bottom to top.
    stack: [5]BodyId = undefined,
    /// The two groups that start apart and collide.
    group_a: [2]BodyId = undefined,
    group_b: [2]BodyId = undefined,
    /// The frictionless slider of M1.1.13.1.
    slider: BodyId = undefined,
    /// The sphere that crosses the mesh's internal edge.
    mesh_sphere: BodyId = undefined,
    /// The trigger, and the body that enters and leaves it.
    trigger: BodyId = undefined,
    trigger_visitor: BodyId = undefined,
    /// The two static bodies, kept because a `BodyId` is a GENERATIONAL handle
    /// (`index:24 | generation:8`) and not a slot number: a probe that assumed
    /// "the ground is body 0" would silently observe nothing. Measured — that is
    /// exactly how the scope test below failed on its first run.
    ground: BodyId = undefined,
    mesh_body: BodyId = undefined,

    /// Every MOBILE body, in creation order — the set the continuous deviation
    /// metric covers.
    ///
    /// The half-space ground and the static mesh are deliberately EXCLUDED. A
    /// static shape with an unbounded local AABB has no meaningful scale, and the
    /// metric weights by body radius; forcing one into it would mean inventing a
    /// radius, which is the fabricated-constant class this module refuses
    /// elsewhere.
    mobile: std.ArrayListUnmanaged(BodyId) = .empty,

    /// Build the scenario. **The order of the numbered blocks IS the contract.**
    pub fn init(gpa: std.mem.Allocator) !Scenario {
        // Sleeping is ON: the scenario is an instrument for determinism, not a
        // convergence measurement, and the sleep transitions are one of the four
        // discrete traces. `initNoSleep` is the world every CONVERGENCE
        // measurement uses (§1.8.3) and would silence that trace entirely.
        var self = Scenario{ .world = harness.World.init(gravity, fixed_dt) };
        errdefer self.deinit(gpa);
        const w = &self.world;

        // --- (1) the static half-space ground ---------------------------------
        const plane = try w.store.createShape(gpa, .{ .plane = .{} });
        var ground = api.BodyDescriptor{
            .entity = .{ .index = 0, .generation = 0 },
            .body_type = .static,
            .shape = plane,
        };
        ground.friction = 0.5;
        ground.restitution = 0;
        self.ground = try w.addBody(gpa, ground);

        // --- (2) the five-box stack, x = 0 -----------------------------------
        const unit_box = try w.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        for (&self.stack, 0..) |*id, i| {
            var d = api.BodyDescriptor{
                .entity = .{ .index = @intCast(1 + i), .generation = 0 },
                .body_type = .dynamic,
                .shape = unit_box,
            };
            // Analytic rest heights: box i sits flush on the one below, so the
            // stack starts with zero penetration everywhere and the transient is
            // the solver's own rather than the scene's.
            d.position = av3(0, @floatCast(0.5 + @as(Real, @floatFromInt(i))), 0);
            d.mass = 1;
            d.restitution = 0;
            id.* = try w.addBody(gpa, d);
            try self.mobile.append(gpa, id.*);
        }

        // --- (3) two groups, apart at t = 0, colliding partway ---------------
        // Closing speed 4 m/s over a 12 m gap: contact around frame 180, well
        // inside the 1000-frame chain and well after the stack has settled, so
        // the island partition changes in a tick where nothing else does.
        for (&self.group_a, 0..) |*id, i| {
            var d = api.BodyDescriptor{
                .entity = .{ .index = @intCast(10 + i), .generation = 0 },
                .body_type = .dynamic,
                .shape = unit_box,
            };
            d.position = av3(30, @floatCast(0.5 + @as(Real, @floatFromInt(i))), 0);
            d.mass = 1;
            d.restitution = 0;
            id.* = try w.addBody(gpa, d);
            try self.mobile.append(gpa, id.*);
        }
        for (&self.group_b, 0..) |*id, i| {
            var d = api.BodyDescriptor{
                .entity = .{ .index = @intCast(20 + i), .generation = 0 },
                .body_type = .dynamic,
                .shape = unit_box,
            };
            d.position = av3(42, @floatCast(0.5 + @as(Real, @floatFromInt(i))), 0);
            d.mass = 1;
            d.restitution = 0;
            id.* = try w.addBody(gpa, d);
            try self.mobile.append(gpa, id.*);
        }
        for (self.group_a) |id| w.bm.setLinearVelocity(id, vr(2, 0, 0));
        for (self.group_b) |id| w.bm.setLinearVelocity(id, vr(-2, 0, 0));

        // --- (4) the frictionless slider, z = 20 ------------------------------
        var slider = api.BodyDescriptor{
            .entity = .{ .index = 30, .generation = 0 },
            .body_type = .dynamic,
            .shape = unit_box,
        };
        slider.position = av3(-30, 0.5, 20);
        slider.mass = 1;
        slider.friction = 0;
        slider.restitution = 0;
        // Damping OFF, both channels. At the default 0.05 a 5 m/s slider loses
        // 4.756 m/s over sixty ticks — measured at M1.1.11.1 — which would swamp
        // the ULP-scale residual this element exists to carry.
        slider.linear_damping = 0;
        slider.angular_damping = 0;
        self.slider = try w.addBody(gpa, slider);
        try self.mobile.append(gpa, self.slider);
        w.bm.setLinearVelocity(self.slider, vr(5, 0, 0));

        // --- (5) static mesh + the sphere that crosses its internal edge ------
        // Two coplanar triangles sharing the diagonal (v1, v2). That shared edge
        // is the INTERNAL one: paired, therefore inactive, therefore corrected —
        // and a sphere crossing it produces several constraints for ONE body
        // pair, which is what exercises the third term of the ordering key.
        const mesh_verts = [_]Vec3{
            av3(55, 2, -3),
            av3(65, 2, -3),
            av3(55, 2, 3),
            av3(65, 2, 3),
        };
        const mesh_idx = [_]u32{ 0, 2, 1, 1, 2, 3 };
        const mesh = try w.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &mesh_verts,
            .indices = &mesh_idx,
        } });
        var mesh_body = api.BodyDescriptor{
            .entity = .{ .index = 40, .generation = 0 },
            .body_type = .static,
            .shape = mesh,
        };
        mesh_body.friction = 0.5;
        mesh_body.restitution = 0;
        self.mesh_body = try w.addBody(gpa, mesh_body);

        const sphere = try w.store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
        var ms = api.BodyDescriptor{
            .entity = .{ .index = 41, .generation = 0 },
            .body_type = .dynamic,
            .shape = sphere,
        };
        ms.position = av3(56, 2.5, 0);
        ms.mass = 1;
        ms.friction = 0;
        ms.restitution = 0;
        ms.linear_damping = 0;
        ms.angular_damping = 0;
        self.mesh_sphere = try w.addBody(gpa, ms);
        try self.mobile.append(gpa, self.mesh_sphere);
        w.bm.setLinearVelocity(self.mesh_sphere, vr(3, 0, 0));

        // --- (6) the trigger and its visitor, x = 80 -------------------------
        const trigger_box = try w.store.createShape(gpa, .{ .box = .{ .half_extents = av3(2, 2, 2) } });
        var trig = api.BodyDescriptor{
            .entity = .{ .index = 50, .generation = 0 },
            .body_type = .static,
            .shape = trigger_box,
        };
        // y = 3, not 2. MEASURED: at y = 2 the box spans y ∈ [0, 4] and its lowest
        // face touches the half-space boundary exactly, so the trigger detects the
        // GROUND as well — a second, permanent pair, and the scope test below
        // reported two `entered` instead of one. Lifting it clear leaves the
        // element as the brief describes it: one sensor, one body crossing.
        trig.position = av3(80, 3, 0);
        trig.is_trigger = true;
        // The visitor is on the default object layer, so the trigger's mask must
        // admit it. A mask of zero detects nothing and the two deltas would never
        // fire — the shape of a trace that passes by producing nothing.
        trig.trigger_layer_mask = 0xFFFF_FFFF;
        self.trigger = try w.addBody(gpa, trig);

        var visitor = api.BodyDescriptor{
            .entity = .{ .index = 51, .generation = 0 },
            .body_type = .dynamic,
            .shape = unit_box,
        };
        visitor.position = av3(72, 2, 0);
        visitor.mass = 1;
        visitor.restitution = 0;
        visitor.friction = 0;
        visitor.linear_damping = 0;
        visitor.angular_damping = 0;
        // No gravity on the visitor: it must fly THROUGH the trigger and out the
        // far side, producing one `entered` and one `exited`. Under gravity it
        // would land on the ground plane and the exit would come from falling,
        // which is a different observable.
        visitor.gravity_factor = 0;
        self.trigger_visitor = try w.addBody(gpa, visitor);
        try self.mobile.append(gpa, self.trigger_visitor);
        w.bm.setLinearVelocity(self.trigger_visitor, vr(4, 0, 0));
        self.world.sensors_on = true;

        // --- (7) the kinematic character, x = 100 ----------------------------
        var cd = api.CharacterDescriptor{ .entity = .{ .index = 60, .generation = 0 } };
        cd.position = av3(100, 0, 0);
        self.character = try self.chars.createCharacter(gpa, &w.store, &w.bm, cd);

        return self;
    }

    pub fn deinit(self: *Scenario, gpa: std.mem.Allocator) void {
        self.mobile.deinit(gpa);
        self.chars.deinit(gpa);
        self.world.deinit(gpa);
    }

    /// Advance one tick: the character's scripted displacement, then the world.
    ///
    /// The character moves FIRST and by a scripted displacement rather than a
    /// velocity, because `moveCharacter` takes metres and the caller owns the
    /// kinematics (`engine-physics-queries.md` §1.12.1). The script is a pure
    /// function of the frame index — no RNG, no state — so replaying frame `n`
    /// always asks for the same metres.
    pub fn step(self: *Scenario, gpa: std.mem.Allocator, frame: u32) !void {
        const d = scriptedDisplacement(frame);
        _ = self.chars.moveCharacter(
            gpa,
            &self.world.bp,
            &self.world.bm,
            &self.world.store,
            self.character,
            d,
            fixed_dt,
        ) catch |err| switch (err) {
            // A stale handle would be a defect in this file, not a condition to
            // absorb; anything else is the controller reporting on the scene.
            error.StaleCharacter => unreachable,
            else => return err,
        };
        try self.world.step(gpa);
    }

    /// The character's displacement at `frame`, in metres.
    ///
    /// Three phases, each exercising a different arm of the controller, and the
    /// gravity term is applied throughout so the character is always resolving a
    /// ground contact rather than floating: walk forward, walk into the slope,
    /// then back. A pure function of the frame index by construction.
    fn scriptedDisplacement(frame: u32) Vec3r {
        const fall: Real = -0.02;
        const walk: Real = 0.03;
        return switch (frame % 300) {
            0...99 => vr(walk, fall, 0),
            100...199 => vr(0, fall, walk),
            else => vr(-walk, fall, 0),
        };
    }
};

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "scenario: builds, and every element is present" {
    const gpa = testing.allocator;
    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    // MOBILE = 5 stack + 2 group_a + 2 group_b + 1 slider + 1 mesh sphere
    //        + 1 trigger visitor = 12. The arithmetic is written out so a reader
    // can check it against the constructor rather than trust the total, and the
    // assertion is what fails when an element is added without being appended to
    // `mobile` — which would silently shrink the continuous metric's coverage
    // while every other test stayed green.
    try testing.expectEqual(@as(usize, 12), s.mobile.items.len);
    // ALL BODIES = the 12 above + the half-space ground + the static mesh + the
    // trigger + the character's kinematic presence = 16. The presence is a body
    // like any other in the store (§1.12.2) and is counted here for that reason.
    try testing.expectEqual(@as(u32, 16), s.world.bm.count());
    try testing.expectEqual(@as(u32, 1), s.chars.count());
    try testing.expect(s.world.sensors_on);
}

test "scenario: steps without error, and the character stays on the ground" {
    const gpa = testing.allocator;
    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    var f: u32 = 0;
    while (f < 120) : (f += 1) try s.step(gpa, f);

    // The controller resolved a ground contact rather than sinking through the
    // half-space: a scripted fall of 2 cm per tick over 120 ticks would put an
    // unresolved character 2.4 m under the plane.
    const pos = s.chars.get(s.character).?.position.toArray();
    try testing.expect(pos[1] > -0.05);
    try testing.expect(pos[1] < 0.05);
}

test "scenario: every one of the seven elements actually fires" {
    // THE SCOPE MEASUREMENT, and it is due BEFORE any witness is committed. A
    // witness taken over a scene where the groups never meet, the sensor never
    // triggers or the mesh never produces a second constraint would be perfectly
    // stable and would prove nothing: the trace would agree with itself because
    // nothing happened. Each assertion below names the mechanism it observes.
    const gpa = testing.allocator;
    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    var saw_ground_contact = false;
    var saw_sleep = false;
    var saw_multi_constraint_pair = false;
    var min_islands: usize = std.math.maxInt(usize);
    var max_islands: usize = 0;
    var entered: usize = 0;
    var exited: usize = 0;

    var f: u32 = 0;
    while (f < 400) : (f += 1) {
        try s.step(gpa, f);

        // (1) the half-space: a constraint EITHER of whose halves is the ground's
        // handle. Both halves are tested because `pair_key` is `min << 32 | max`
        // over `BodyId`s and which side the ground lands on is not ours to assume.
        // (5) the mesh: two constraints sharing one pair key is the third term of
        // the ordering key being needed, which only a multi-triangle contact
        // produces.
        var prev_key: ?u64 = null;
        for (s.world.constraints.items) |c| {
            const hi: BodyId = @intCast(c.pair_key >> 32);
            const lo: BodyId = @intCast(c.pair_key & 0xFFFF_FFFF);
            if (hi == s.ground or lo == s.ground) saw_ground_contact = true;
            if (prev_key) |k| {
                if (k == c.pair_key) saw_multi_constraint_pair = true;
            }
            prev_key = c.pair_key;
        }

        // (2) sleep transitions.
        if (s.world.slept_last_tick > 0) saw_sleep = true;

        // (3) the island partition, in BOTH directions: the count must both rise
        // and fall over the run, which a merge-only scene would not give.
        const n = s.world.islands.islandsSlice().len;
        if (n < min_islands) min_islands = n;
        if (n > max_islands) max_islands = n;

        // (6) the two sensor deltas.
        entered += s.world.sensors.entered.items.len;
        exited += s.world.sensors.exited.items.len;
    }

    try testing.expect(saw_ground_contact); // (1)
    try testing.expect(saw_sleep); // (2)
    try testing.expect(max_islands > min_islands); // (3)
    try testing.expect(saw_multi_constraint_pair); // (5)
    try testing.expectEqual(@as(usize, 1), entered); // (6) exactly one crossing in
    try testing.expectEqual(@as(usize, 1), exited); // (6) and exactly one out

    // (4) the slider still carries speed: it is frictionless and undamped, so a
    // value far from 5 m/s would mean it hit something and stopped being the
    // residual carrier this element exists to be.
    const v = s.world.bm.linearVelocity(s.slider).?.toArray()[0];
    try testing.expect(v > 4.9);

    // (7) the character resolved a ground contact rather than sinking.
    const y = s.chars.get(s.character).?.position.toArray()[1];
    try testing.expect(y > -0.05 and y < 0.05);
}
