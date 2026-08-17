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
//! Eight elements, each present for a named reason and none decorative:
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
//! 7. **A riser and three ramps, one walkable and two not, forming a closed bowl.**
//!    They exist so that `cos_max_slope` DECIDES something: their surface cosines
//!    bracket `cos(0.785) = 0.70738` at `0.894` and `0.6247`, and the bracket is
//!    proven to bite in BOTH directions by a counter-factual at the bottom of this
//!    file — metres of trajectory, not centimetres. Mesh ramps with literal
//!    vertices, so the scenario contains no trigonometry of its own.
//! 8. **A kinematic character on a scripted path across that terrain.** The
//!    controller — its slope test, its step-up arm and its slide — and the site
//!    where a wrong `max_slope` conversion surfaces first, which is the whole
//!    reason the deterministic cosine exists.
//!
//! **Elements 7 and 8 were BOTH defective until M1.1.14's own review, and the two
//! halves are one defect.** This header claimed "a step and a slope" while the
//! scene held neither — nothing stood near the character but the flat half-space,
//! so `max_slope` was never approached; and the character entered NO artifact,
//! because `mobile` holds rigid bodies and a virtual character owns none, so the
//! controller ran for a thousand frames and every bit of its output was discarded.
//! A text asserting more than its code, and a computation with no observer: the
//! milestone's two dominant families, in the file that defines what it measures.
//!
//! The elements are laid out in separate regions of X so that only the
//! interactions listed above occur. The half-space is the exception: it is
//! infinite and underlies all of them, which is intended. **That separation was
//! itself false at x = 100** and is now true: see the note at element 7 for the
//! arithmetic that put two other elements through the character's old region.

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
    /// The character's terrain: a riser it climbs, a ramp it walks up, and two it
    /// cannot — the far one and the near one, which together close the excursion
    /// into a bowl. All static, so none enters `mobile`.
    ///
    /// The ramps exist to make `cos_max_slope` LOAD-BEARING, which is the whole
    /// reason the deterministic cosine was written: their surface cosines are
    /// `0.894` and `0.6247`, bracketing `cos(0.785) = 0.70738` by `0.187` and
    /// `0.083`. Before M1.1.14's review this scenario had no relief at all — its
    /// header claimed "a step and a slope" while nothing stood near the character
    /// but the flat half-space, so `max_slope` was never approached and the cosine
    /// the milestone added was exercised by no witness.
    ///
    /// **The slope test is the character's ONLY reason for stopping where it does,
    /// and that is measured rather than assumed** (see the counter-factual test).
    /// The steep ramps are not surfaces it stands on — it butts into them and the
    /// verdict holds it there — so what carries the cosine into the witness is the
    /// POSITION, not the `GroundState`, which stays `.grounded` for all 1000 frames.
    step_block: BodyId = undefined,
    walk_slope: BodyId = undefined,
    steep_slope: BodyId = undefined,
    back_slope: BodyId = undefined,
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

        // --- (7) the character's terrain, x = −70 … −59 ----------------------
        //
        // WHY NEGATIVE X, and it is a correction rather than a preference. The
        // character sat at x = 100 and the header promised that elements occupy
        // separate X regions so only the listed interactions occur. That promise
        // was already false there, by arithmetic on this file's own constants: the
        // frictionless mesh sphere leaves the mesh at x = 65 carrying 3 m/s and
        // reaches x ≈ 106 by frame 1000, and the trigger visitor starts at x = 72
        // with 4 m/s and no gravity, reaching x ≈ 138. Both cross x = 100. Putting
        // terrain there would couple three elements that the design keeps apart,
        // so the character moves to the one region nothing else visits — the
        // slider starts at x = −30 and travels toward +x, in the z = 20 lane.
        //
        // THE SLOPES ARE MESHES AND NOT ROTATED BOXES, and that is a MEASURED
        // decision. Rotated boxes were tried first and abandoned after three
        // rounds: a box rotated about +Z has a footprint wider than its
        // half-extent by `|sin| · h`, so its leading edge is a corner at a height
        // the reader must derive rather than read, its Z faces stay VERTICAL — and
        // a vertical face is never ground whatever `max_slope` says
        // (`character.zig`), so a character arriving along Z is blocked without the
        // slope test ever running — and one placement floated the wedge 0.25 m
        // above the plane and wedged the character in the crevice underneath for
        // 775 of 1000 frames. A mesh ramp has literal vertices: the surface is
        // exactly where the numbers say, the walkable ramp and the steep one meet
        // at a vertex they SHARE to the bit, and there is no hidden extent to get
        // wrong.
        //
        // NO TRIGONOMETRY, which matters in this file above all others: an `@sin`
        // in the scenario would put back into the instrument exactly what
        // `ARCH-031` rule 4 took out of the engine. A ramp's normal is the cross
        // product of two exact integer-ish edges, so its cosine is exact algebra:
        //   rise 1 over run 2 → n · up = 2/√5 = 0.894 → WALKABLE (≥ 0.70738)
        //   rise 2.5 over run 2 → n · up = 0.6247 → TOO STEEP (< 0.70738)
        // The margins are 0.187 and 0.083 — the tighter one is 700 000 f32
        // epsilons, so no float noise can flip a verdict, while a cosine wrong in
        // its first decimal flips one and a cosine wrong in both directions flips
        // both. Both cosines checked against an independent computation, not read
        // off the vertex table.
        // THAT BRACKET IS THE POINT: an erroneously LARGE `cos_max_slope` makes the
        // walkable ramp unclimbable and an erroneously SMALL one makes the steep
        // ramp climbable, and each shows up as metres of difference in a position
        // the continuous state carries.

        // The riser, and its height is MEASURED rather than chosen. `tryStepUp`
        // lifts by `step_height` and then advances by the motion REMAINING in that
        // tick, so whether a riser is climbed depends on the caller's per-tick step
        // and not on the riser height alone. Swept here: at 0.03 m/tick — the walk
        // this scenario used before M1.1.14's review — NO riser is ever climbed,
        // 0.15 m and 0.25 m alike; 0.15 m needs 0.06 m/tick and 0.25 m needs 0.10.
        // So the scenario walked below the threshold of its own step arm, and the
        // walk is now 0.06 with a 0.15 m riser: the cheapest pair that exercises
        // `tryStepUp` at all. Not a defect in the controller — a sweep-based step
        // arm cannot lift a character that never commits enough forward motion to
        // land on the tread — but it is invisible without the sweep.
        const riser_box = try w.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 1, 4) } });
        var riser = api.BodyDescriptor{
            .entity = .{ .index = 61, .generation = 0 },
            .body_type = .static,
            .shape = riser_box,
        };
        // Top face at y = 0.15, the body sunk well below the half-space rather than
        // resting flush on it: static × static is `false` in the layer matrix so
        // there is no pair either way, but a face exactly coplanar with the
        // boundary is the configuration M1.1.13 measured a spurious second contact
        // from, and it costs nothing to not reproduce it.
        riser.position = av3(-65.5, -0.85, 0);
        riser.friction = 0.5;
        riser.restitution = 0;
        self.step_block = try w.addBody(gpa, riser);

        // The walkable ramp: from the plane at x = −62 up to y = 1 at x = −60.
        // WINDING IS LOAD-BEARING — a `MeshShape` is single-sided (§1.11.17), so a
        // reversed triangle is a surface the character falls through. It is not
        // asserted from the vertex order but OBSERVED: the coverage test below
        // requires the character to reach a height only this ramp can give it.
        const walk_verts = [_]Vec3{
            av3(-62, 0, -4), av3(-60, 1, -4),
            av3(-62, 0, 4),  av3(-60, 1, 4),
        };
        const ramp_idx = [_]u32{ 0, 2, 1, 1, 2, 3 };
        const walk_mesh = try w.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &walk_verts,
            .indices = &ramp_idx,
        } });
        var walkable = api.BodyDescriptor{
            .entity = .{ .index = 62, .generation = 0 },
            .body_type = .static,
            .shape = walk_mesh,
        };
        walkable.friction = 0.5;
        walkable.restitution = 0;
        self.walk_slope = try w.addBody(gpa, walkable);

        // The steep ramp, continuing from the walkable one's crest at exactly
        // (−60, 1) — shared to the bit, which is what leaves no crevice between
        // them for the character to fall into.
        const steep_verts = [_]Vec3{
            av3(-60, 1, -4), av3(-58, 3.5, -4),
            av3(-60, 1, 4),  av3(-58, 3.5, 4),
        };
        const steep_mesh = try w.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &steep_verts,
            .indices = &ramp_idx,
        } });
        var steep = api.BodyDescriptor{
            .entity = .{ .index = 63, .generation = 0 },
            .body_type = .static,
            .shape = steep_mesh,
        };
        steep.friction = 0.5;
        steep.restitution = 0;
        self.steep_slope = try w.addBody(gpa, steep);

        // THE TERRAIN IS A BOWL, and the fourth ramp is what makes it one. A
        // measured problem forced it: climbing costs forward progress, so a `+x`
        // leg that ends 2.2 m short of its commanded 9 m is followed by a `−x` leg
        // that spends all 9, and the character drifts 2.2 m per cycle for ever. Over
        // 1000 frames that is cosmetic — it still meets the ramps every cycle — but
        // this scenario is an INSTRUMENT that M1.1.25 and M1.A replay, possibly at
        // other frame counts, and at ten times the length the character is 55 m away
        // and the terrain is never touched again. An unbounded drift in a replayed
        // instrument is a latent vacuity, so the excursion is closed by geometry
        // rather than by tuning the leg lengths against the climb — a number that
        // would silently stop matching the moment a ramp angle changed.
        //
        // Mirrored winding, and it is NOT the same index list: reflecting the
        // profile reverses the triangles' orientation, so reusing `ramp_idx` here
        // would point both normals DOWN and the character would fall through a
        // surface that looks right in the vertex table.
        const back_verts = [_]Vec3{
            av3(-68, 0, -4), av3(-70, 2.5, -4),
            av3(-68, 0, 4),  av3(-70, 2.5, 4),
        };
        const back_idx = [_]u32{ 0, 1, 2, 1, 3, 2 };
        const back_mesh = try w.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &back_verts,
            .indices = &back_idx,
        } });
        var back = api.BodyDescriptor{
            .entity = .{ .index = 64, .generation = 0 },
            .body_type = .static,
            .shape = back_mesh,
        };
        back.friction = 0.5;
        back.restitution = 0;
        self.back_slope = try w.addBody(gpa, back);

        // --- (8) the kinematic character, x = −66 ----------------------------
        var cd = api.CharacterDescriptor{ .entity = .{ .index = 60, .generation = 0 } };
        cd.position = av3(-63.5, 0, 0);
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
    /// Four phases — `+x`, `+z`, `−x`, `−z` — over a period of 700 frames. **A
    /// COMMANDED LOOP IS NOT A CLOSED LOOP**, and that was measured, not foreseen:
    /// climbing costs forward progress, so a `+x` leg that ends 2.2 m short of the
    /// metres it asked for is followed by a `−x` leg that spends all of them, and
    /// the character walks away from its terrain at 2.2 m per cycle for ever. What
    /// closes the excursion is GEOMETRY — the bowl of element 7 — and not the
    /// symmetry of this function. The `+z`/`−z` pair does cancel, nothing blocking
    /// motion along Z.
    ///
    /// **The `+x` leg is 300 frames and that length is load-bearing.** At 0.06 m per
    /// frame it commands 18 m across a bowl 8 m wide, so the character spends most
    /// of the leg PRESSED against the steep ramp — which is the only regime where
    /// the slope verdict dominates the outcome. Measured: with a 150-frame leg it
    /// arrived at the ramp's base with its budget spent, and a `cos_max_slope`
    /// loosened enough to make that ramp walkable moved the trajectory by 0.23 m
    /// instead of 1.72 m. The counter-factual test at the bottom of this file is
    /// what would catch that weakening again.
    ///
    /// The walk is 0.06 and not 0.03 because `tryStepUp` is a per-tick sweep: at
    /// 0.03 m/frame NO riser is ever climbed, at any height — swept and measured at
    /// M1.1.14's review, where the scenario was found walking below the threshold of
    /// its own step arm.
    ///
    /// The gravity term runs throughout so the character is always resolving a
    /// ground contact rather than floating. A pure function of the frame index by
    /// construction — no RNG, no state.
    fn scriptedDisplacement(frame: u32) Vec3r {
        const fall: Real = -0.02;
        const walk: Real = 0.06;
        return switch (frame % 700) {
            0...299 => vr(walk, fall, 0),
            300...349 => vr(0, fall, walk),
            350...649 => vr(-walk, fall, 0),
            else => vr(0, fall, -walk),
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
    // can check it against the constructor rather than trust the total.
    //
    // **THIS ASSERTION DID NOT DO WHAT ITS COMMENT CLAIMED, and M1.1.14's review
    // proved it by finding the case it was written for.** It used to say it "fails
    // when an element is added without being appended to `mobile`, which would
    // silently shrink the continuous metric's coverage". The character was added
    // and not appended — deliberately, since a virtual character has no rigid body
    // to append — and this test stayed green because whoever added it updated the
    // TOTAL below in step. A count pinned in the same commit as the change it is
    // meant to catch catches nothing; what it really guards is arithmetic drift
    // between the two numbers, which is a smaller claim and is now the one written.
    // What covers the real case is the coverage test at the bottom of this file,
    // which asserts on the STREAM rather than on a count.
    try testing.expectEqual(@as(usize, 12), s.mobile.items.len);
    // ALL BODIES = the 12 above + the half-space ground + the static mesh + the
    // trigger + the riser + the THREE ramps + the character's kinematic presence
    // = 20. The presence is a body like any other in the store (§1.12.2) and is
    // counted here for that reason.
    try testing.expectEqual(@as(u32, 20), s.world.bm.count());
    try testing.expectEqual(@as(u32, 1), s.chars.count());
    try testing.expect(s.world.sensors_on);
}

test "scenario: steps without error, and the character resolves its ground" {
    const gpa = testing.allocator;
    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    var f: u32 = 0;
    while (f < 120) : (f += 1) try s.step(gpa, f);

    // The controller resolved a ground contact rather than sinking: a scripted
    // fall of 2 cm per tick over 120 ticks would put an unresolved character
    // 2.4 m under the plane, and the terrain's lowest surface is the plane itself.
    //
    // The BAND is what changed at M1.1.14's review, and the reason is the whole
    // point of the fix: this used to assert `|y| < 0.05`, which is only true of a
    // character on FLAT GROUND. It passed for a thousand frames because the scene
    // had no relief at all — the assertion was a witness to the defect rather than
    // a guard against it. By frame 120 the character is partway up the walkable
    // ramp, so the band is now the terrain's own vertical extent.
    const pos = s.chars.get(s.character).?.position.toArray();
    try testing.expect(pos[1] > -0.05);
    try testing.expect(pos[1] < 1.05);
    try testing.expectEqual(api.GroundState.grounded, s.chars.get(s.character).?.reported_ground);
}

test "scenario: every one of the eight elements actually fires" {
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
    var char_max_y: Real = -1e9;
    var char_max_x: Real = -1e9;
    var char_on_riser = false;

    // ONE FULL SCRIPT CYCLE AND MORE, and the bound is not free to choose: the
    // script's period is 700 frames, so a 400-frame window — what this loop used
    // to run — is STRUCTURALLY unable to observe the second half of the script.
    // Measured when the riser clause was added and failed: the character crosses it
    // on the `−x` leg, around frame 750. A coverage test shorter than the period of
    // the thing it covers is a coverage test with a blind half.
    var f: u32 = 0;
    while (f < 750) : (f += 1) {
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

        // (7) + (8) the terrain, accumulated over the RUN and not read at its end:
        // the claim is that the character climbed, which is a property of the
        // trajectory. A final-value assertion would depend on where this loop
        // happens to stop — measured, it stops on the descent leg, so the first
        // version of this check failed on a character that had climbed perfectly.
        const cp = s.chars.get(s.character).?.position.toArray();
        if (cp[1] > char_max_y) char_max_y = cp[1];
        if (cp[0] > char_max_x) char_max_x = cp[0];
        // Standing on the riser's tread: its top is at y = 0.15 and the capsule
        // stands `padding` above it, so the band is tight around that and excludes
        // both the plane below and the ramp above.
        if (cp[0] > -66 and cp[0] < -65 and cp[1] > 0.14 and cp[1] < 0.18) char_on_riser = true;
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

    // (7) + (8) THE TERRAIN, three clauses, each naming the arm it observes.
    //
    // It CLIMBED the walkable ramp: the ramp crests at y = 1 and the plane is at
    // y = 0, so a character that never left the plane cannot reach here.
    try testing.expect(char_max_y > 0.85);
    // It was HELD by the steep one: the steep ramp's base is at x = −60, and a
    // capsule of radius 0.3 pressed against it stands near −60.2. Passing this
    // line would mean the slope test admitted a 51.3° surface — which is exactly
    // what the counter-factual below makes it do, and it then reaches −58.8.
    try testing.expect(char_max_x < -60.0);
    // And `tryStepUp` fired: it stood on the riser's 0.15 m tread. This is the arm
    // the scenario's former 0.03 m/tick walk could not exercise at any riser
    // height — swept and measured at M1.1.14's review.
    try testing.expect(char_on_riser);
}

test "scenario: the slope test DECIDES the character's trajectory, both ways" {
    // THE NON-VACUITY OF ELEMENT 7, and it is the reason the two slopes exist at
    // all. Element 7's clauses above prove the character climbed one ramp and was
    // held by another; they do NOT prove that `cos_max_slope` is what decided it —
    // a controller that climbed everything under 40° by some other rule would pass
    // them identically. What discriminates is a COUNTER-FACTUAL ON THE OBJECT:
    // change the cosine and nothing else, and watch the trajectory move.
    //
    // The bracket is `0.894` (walkable ramp) and `0.6247` (both steep ramps) around
    // the default `cos(0.785) = 0.7074`. Measured, at f32, over 1000 frames:
    //
    //   max_slope 0.400 → cos 0.9211 → max_y 0.0063   x span 2.7 m
    //   max_slope 0.785 → cos 0.7074 → max_y 0.9463   x span 7.7 m   (the default)
    //   max_slope 1.200 → cos 0.3624 → max_y 2.6707   escapes the bowl
    //
    // Both directions, in METRES. Too large a cosine and the walkable ramp becomes
    // unclimbable — the character never leaves the plane. Too small and the steep
    // ramps become climbable — it crests both and leaves the terrain entirely. A
    // cosine wrong in its first decimal is therefore not a rounding difference in
    // this witness, it is a different scene.
    const gpa = testing.allocator;

    const Outcome = struct { max_y: Real, min_x: Real, max_x: Real };
    const measure = struct {
        fn run(a: std.mem.Allocator, max_slope: f32) !Outcome {
            var s = try Scenario.init(a);
            defer s.deinit(a);
            // A SECOND character, built from the same descriptor but for its slope,
            // and driven by the same script. Replacing the scenario's own would mean
            // rebuilding the body order, which is part of the contract (see header).
            var cd = api.CharacterDescriptor{ .entity = .{ .index = 70, .generation = 0 } };
            cd.position = av3(-63.5, 0, 0);
            cd.max_slope = max_slope;
            const alt = try s.chars.createCharacter(a, &s.world.store, &s.world.bm, cd);

            var out = Outcome{ .max_y = -1e9, .min_x = 1e9, .max_x = -1e9 };
            var f: u32 = 0;
            while (f < 1000) : (f += 1) {
                _ = s.chars.moveCharacter(
                    a,
                    &s.world.bp,
                    &s.world.bm,
                    &s.world.store,
                    alt,
                    Scenario.scriptedDisplacement(f),
                    fixed_dt,
                ) catch unreachable;
                try s.step(a, f);
                const p = s.chars.get(alt).?.position.toArray();
                if (p[1] > out.max_y) out.max_y = p[1];
                if (p[0] < out.min_x) out.min_x = p[0];
                if (p[0] > out.max_x) out.max_x = p[0];
            }
            return out;
        }
    }.run;

    const strict = try measure(gpa, 0.40);
    const actual = try measure(gpa, 0.785);
    const loose = try measure(gpa, 1.20);

    // A cosine STRICTER than the walkable ramp: the ramp is refused and the
    // character stays on the plane. Bounds are loose by a wide margin on purpose —
    // what is asserted is the SEPARATION between the three regimes, not a
    // measurement, which is what keeps this test from re-pinning a value the
    // solver is free to move.
    try testing.expect(strict.max_y < 0.1);
    try testing.expect(actual.max_y - strict.max_y > 0.5);

    // A cosine LOOSER than the steep ramps: they become walkable and the character
    // crests them, which the default run never does.
    try testing.expect(loose.max_y - actual.max_y > 0.5);
    try testing.expect(loose.max_x > actual.max_x);

    // And the DEFAULT run stays inside the bowl the terrain forms — the property
    // that keeps the instrument from drifting off its own scene when replayed at a
    // longer frame count (M1.1.25, M1.A).
    try testing.expect(actual.min_x > -68.5);
    try testing.expect(actual.max_x < -60.0);
}

test "scenario: the retained pair set really SHRINKS — the fourth trace is an oracle" {
    // P1-5, THE NON-VACUITY OF THE FOURTH DISCRETE TRACE. The retained pair set is
    // one of the four invariants every CI cell compares, and `trace.zig` states the
    // hazard on itself: over a set that can only GROW, a trace agrees with itself by
    // accumulation and proves nothing. The harness was pruned at M1.1.14 precisely
    // so that stops being true — but the pruning being IMPLEMENTED and the canonical
    // scenario EXERCISING it are two different claims, and `solver_test.zig`'s
    // generic departure test establishes only the first. This establishes the second.
    //
    // ASSERTED ON THE SET, NEVER ON ITS CARDINALITY, and that distinction is
    // measured rather than stylistic: the removal at frame 196 is followed by an
    // ADDITION as the same sphere reaches the ground plane, so the size returns to
    // what it was. A size-based probe sees the dip here only because the two events
    // land on different ticks — had they coincided it would have reported nothing at
    // all while the removal happened. What is required is that a key present once be
    // absent later.
    //
    // WHAT LEAVES, and why it is structural rather than incidental: the pair is the
    // static `MeshShape` and the frictionless sphere crossing it. The sphere carries
    // a fixed 3 m/s, leaves the mesh at x = 65 around frame 180, and its fat AABB
    // separates from the mesh's around frame 196 — permanently, there being nothing
    // to bring it back. The event is a consequence of element 5's design, so it
    // cannot quietly stop happening while that element still does what it is for.
    const gpa = testing.allocator;
    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    var seen: std.ArrayListUnmanaged(u64) = .empty;
    defer seen.deinit(gpa);
    var removed: std.ArrayListUnmanaged(u64) = .empty;
    defer removed.deinit(gpa);

    var max_live: usize = 0;
    var f: u32 = 0;
    while (f < 400) : (f += 1) {
        try s.step(gpa, f);
        const live = s.world.active.items;
        if (live.len > max_live) max_live = live.len;

        // Anything seen before and not live now has been pruned. Recorded once.
        for (seen.items) |k| {
            var still = false;
            for (live) |k2| {
                if (k == k2) {
                    still = true;
                    break;
                }
            }
            if (still) continue;
            var already = false;
            for (removed.items) |k2| {
                if (k == k2) {
                    already = true;
                    break;
                }
            }
            if (!already) try removed.append(gpa, k);
        }
        for (live) |k| {
            var known = false;
            for (seen.items) |k2| {
                if (k == k2) {
                    known = true;
                    break;
                }
            }
            if (!known) try seen.append(gpa, k);
        }
    }

    // POSITIVE WITNESS FIRST. "A key disappeared" is satisfied by a set that was
    // empty throughout, which is the vacuity this whole test exists against.
    try testing.expect(max_live >= 2);
    try testing.expect(seen.items.len >= 2);

    // THE REMOVAL. At least one pair the harness held was pruned.
    try testing.expect(removed.items.len >= 1);

    // AND IT IS THE PAIR THE ANALYSIS NAMES, not merely some pair. Without this the
    // test would pass on a removal caused by anything at all — a body recycled, a
    // key mis-sorted — and would stop being evidence about pruning. The key is
    // `min << 32 | max` over `BodyId`s, built here from the handles rather than
    // hard-coded, since a `BodyId` is generational and not a slot number.
    const lo = @min(s.mesh_body, s.mesh_sphere);
    const hi = @max(s.mesh_body, s.mesh_sphere);
    const want = (@as(u64, lo) << 32) | hi;
    var found = false;
    for (removed.items) |k| {
        if (k == want) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
