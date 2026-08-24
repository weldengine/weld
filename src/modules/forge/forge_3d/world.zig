//! `forge_3d/world.zig` — `PhysicsWorld`, the SOLE OWNER of the per-tick cycle
//! (`engine-physics-solver.md` §1.7).
//!
//! Until M1.1.15 the cycle existed only as a set of callable halves plus one
//! composition of them written inside an acceptance suite
//! (`tests/solver_test.zig`), and nine call sites across the module named a
//! `PhysicsWorld` that did not exist. This file is that owner. The composition is
//! MOVED here, not rewritten: the call sequence, the arguments and the arithmetic
//! are the ones the eight committed determinism witnesses were taken over, and the
//! reparenting changes who calls, never what is computed.
//!
//! **The normative cycle, in order.** Step numbers are STABLE ANCHORS — §1.8 and
//! §1.13 refer to them by number — and two of them carry no code:
//!
//!   (1)  `Broadphase.computePairs` on the current poses (moved-driven deltas)
//!   (2)  candidate-pair retention: merge the deltas into a PERSISTENT set, and
//!        prune only on fat-AABB separation
//!   (3)  external forces — READ-ONLY, and it owns NO CODE. The force/torque
//!        accumulators are constant for the whole of `step()` (nothing writes them
//!        in-tick), so they ARE the tick's accelerations and every substep reads
//!        them directly. The uniform §2 reset is not here: it runs once at the END
//!        of step 6, because clearing an accumulator before anything consumes it
//!        delivers `F/m·0` (deviation B1, M1.1.13.1).
//!   (4)  `cache.beginTick` → `build` (narrowphase `collidePair` per candidate,
//!        `prepare` capturing `v_n⁻` PRE-GRAVITY, the local anchors, the softness
//!        selection and the warm-start SEEDING, plus the wake fixpoint of §1.8.5)
//!   (5)  island partition + activation (W2, W3) — never puts anything to sleep
//!   (5 bis) the composite pre-solve seam (§1.7.3) — EMPTY in Phase 1, by design:
//!        no consumer, no call, no line executed. Its first occupant is the
//!        powered ragdoll. It is an anchor, not a step this file runs.
//!   (6)  the SUBSTEP LOOP and (7) the restitution pass, both inside
//!        `rigid.solveTick`: per substep `integrateVelocitiesNoReset(h)` →
//!        warm-start APPLICATION → biased solve (normal points only) →
//!        `integratePositions(h)` → relax (normals unbiased, then friction); after
//!        the loop the uniform accumulator reset, then restitution per island.
//!   (8)  retired at a FROZEN NUMBER, never reassigned. There is no position pass:
//!        position error is corrected by the bias inside step 6, and penetration
//!        recovery is PACED by `contact_push_max_speed`.
//!   (9)  `storeContacts` (harvest) → `cache.endTick` (sort + swap)
//!   (10) broadphase proxy updates on the final poses — skips sleeping bodies
//!   (10 bis) the sensor pass (§1.13.4)
//!   (11) sleep window sweep on the POST-SOLVE state, then the sleep transition:
//!        the only point in the cycle where a body falls asleep.
//!
//! **Step 10 bis is UNCONDITIONAL, and that is a change from the harness it comes
//! from.** The harness gated it on a `sensors_on` flag defaulting to `false`, which
//! for a production world would mean sensors silently do not work until someone
//! remembers to switch them on — the silent-limitation class this module refuses
//! everywhere else. A world with no trigger proxy enumerates nothing and the pass
//! costs what enumerating nothing costs; a world with one gets its state whether or
//! not it asked. `sensor.SensorState.update` takes `*const BodyManager`, so the
//! pass cannot alter one bit of body state either way, which is why making it
//! unconditional leaves every committed witness byte-identical.
//!
//! **What this file does NOT own.** ECS synchronisation lives one tier up
//! (`../sync.zig`): sync-in runs before step 1, sync-out after step 11, so step
//! 10 bis sees the poses the tick publishes, which is its stated premise. The
//! resolution is SINGLE-WORKER: per-island parallel solving is M1.1.25, and the
//! scratch buffers below are therefore unique rather than per-island (§1.8.8).

const std = @import("std");
const config = @import("config.zig");
const shape_mod = @import("shape.zig");
const bm_mod = @import("body_manager.zig");
const broadphase = @import("pipeline/broadphase.zig");
const sleep = @import("pipeline/sleep.zig");
const sensor = @import("pipeline/sensor.zig");
const rigid = @import("rigid/root.zig");
const character_mod = @import("character.zig");
const determinism = @import("determinism.zig");
const api = @import("weld_forge");

const Real = config.Real;
const Vec3r = config.Vec3r;
const ShapeStore = shape_mod.ShapeStore;
const BodyManager = bm_mod.BodyManager;
const BodyId = api.BodyId;
const Bp = broadphase.Broadphase(Real);
const ContactConstraint = rigid.ContactConstraint;
const ContactCache = rigid.ContactCache;
const SolverConfig = rigid.SolverConfig;
const CharacterStore = character_mod.CharacterStore;
const BroadphaseLayer = broadphase.BroadphaseLayer;

/// One executed stage of the cycle, in the order `step()` runs them.
///
/// The enum carries exactly the anchors that EXECUTE. Three do not, and their
/// absence here is the contract rather than an omission: step 3 is read-only and
/// owns no code, step 5 bis is the empty composite seam of §1.7.3, and step 8 is
/// retired at a frozen number. Anchors 6 and 7 are one `rigid.solveTick` call —
/// their internal order (substep loop first, restitution after) is pinned by
/// `rigid/solver.zig`'s own suite, not observable from out here.
pub const Step = enum(u8) {
    /// (1) `computePairs` on the current poses.
    broadphase_pairs,
    /// (2) merge the deltas into the persistent candidate set, prune the separated.
    pair_retention,
    /// (4) `beginTick` → `build` (narrowphase + `prepare` + warm-start seeding).
    build_constraints,
    /// (5) island partition and activation.
    island_partition,
    /// (6) + (7) the substep loop, the accumulator reset, and restitution.
    solve_tick,
    /// (9) harvest into the cache, then `endTick`.
    harvest_contacts,
    /// (10) broadphase proxy updates on the final poses.
    proxy_update,
    /// (10 bis) the sensor pass.
    sensor_pass,
    /// (11) sleep windows, then the per-island transition.
    sleep_transition,
};

/// The number of anchors that execute — pinned so a stage added or removed has to
/// be a deliberate edit of this file and of the order test together.
pub const executed_step_count: usize = @typeInfo(Step).@"enum".fields.len;

comptime {
    // The two claims the header makes about `Step`, checked rather than asserted in
    // prose: the count, and that `solve_tick` sits between the partition and the
    // harvest — the one adjacency the retired step 8 could silently reopen.
    std.debug.assert(executed_step_count == 9);
    std.debug.assert(@intFromEnum(Step.island_partition) + 1 == @intFromEnum(Step.solve_tick));
    std.debug.assert(@intFromEnum(Step.solve_tick) + 1 == @intFromEnum(Step.harvest_contacts));
}

/// A recorder for the ORDER in which `step()` entered its stages.
///
/// It exists because the frozen sequence of §1.7 is a contract, and a test that
/// checks each stage RAN reads a set where the contract is an order. Attached
/// through `PhysicsWorld.trace`, `null` by default: one null check per stage, nine
/// per tick, no float, no allocation on the physics path.
pub const StepTrace = struct {
    /// Entered stages, in order. Sized for one tick; `record` saturates rather
    /// than wrapping, so an overrun shows up as a short trace and never as a
    /// plausible one.
    entries: [executed_step_count]Step = undefined,
    len: usize = 0,
    /// Stages a full buffer refused. Non-zero means the reader is looking at a
    /// truncated order and must not read it as the whole one.
    dropped: u32 = 0,

    /// Forget the previous tick.
    pub fn reset(self: *StepTrace) void {
        self.len = 0;
        self.dropped = 0;
    }

    fn record(self: *StepTrace, step_id: Step) void {
        if (self.len == self.entries.len) {
            self.dropped += 1;
            return;
        }
        self.entries[self.len] = step_id;
        self.len += 1;
    }

    /// The order as a slice.
    pub fn order(self: *const StepTrace) []const Step {
        return self.entries[0..self.len];
    }
};

/// What a registered proxy belongs to.
///
/// **A character presence carries the SAME `entity` as its character** (`character.zig`
/// creates it with `.entity = desc.entity`), so nothing in the body store distinguishes the
/// two: they are one entity with two bodies. Anything walking this list and keying on the
/// entity — the ECS sync seam does exactly that, in both directions — needs the distinction
/// spelled out here, because it cannot be recovered downstream.
pub const BodyKind = enum {
    /// A body created through `addBody`: the ECS entity's own rigid body.
    rigid_body,
    /// The virtual controller's inner body, created by the character store. It is driven
    /// ONLY by `moveCharacter` and its siblings; it is not the entity's rigid body and does
    /// not answer for it.
    character_presence,
};

/// A body registered in this world, with the broadphase proxy that represents it.
pub const BodyProxy = struct { id: BodyId, proxy: Bp.Proxy, kind: BodyKind };

/// The physics world: the shape store, the body store, the broadphase, the warm-start
/// cache, the island partition, the per-tick scratches, and `step()`.
pub const PhysicsWorld = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    bp: Bp,
    cache: ContactCache = .{},
    cfg: SolverConfig = .{},
    /// Sleep tuning. Enabled by default; convergence measurements switch it off.
    sleep_cfg: sleep.SleepConfig = .{},
    gravity: Vec3r,
    dt: Real,
    bodies: std.ArrayListUnmanaged(BodyProxy) = .empty,
    active: std.ArrayListUnmanaged(u64) = .empty,
    constraints: std.ArrayListUnmanaged(ContactConstraint) = .empty,
    scratch: std.ArrayListUnmanaged(Bp.Pair) = .empty,
    /// The island partition of the last tick (step 5).
    islands: rigid.IslandManager = .{},
    /// Last tick's solver telemetry (steps 6 and 7) — substeps executed, solve and
    /// relax sweeps, and the minimum separation any biased sweep observed, plus the
    /// `not_reported` counters §1.8.2 excludes from the telemetry surface.
    solver_stats: rigid.SolverStats = .{},
    /// Islands put to sleep at step 11 of the last tick.
    slept_last_tick: u32 = 0,
    /// The character controllers. The orchestrator holds them because a controller's
    /// broadphase PRESENCE has to be inserted, and the store that creates it cannot
    /// choose a layer — the `BodyType` → `BroadphaseLayer` derivation lives here.
    chars: CharacterStore = .{},
    /// The sensor state, rebuilt in full at STEP 10 BIS of every tick (M1.1.13).
    sensors: sensor.SensorState = .{},
    /// Where `step()` records the order it entered its stages, when a caller wants
    /// to read that order. `null` on a production world.
    trace: ?*StepTrace = null,

    /// A world with the given gravity and fixed timestep. Default `SolverConfig`,
    /// sleeping ENABLED.
    pub fn init(gravity: Vec3r, dt: Real) PhysicsWorld {
        // `ARCH-031` rule 5 — THE physics entry point. Opening a world on a thread
        // whose float environment is not the engine's makes every number this world
        // produces incomparable with the same world opened elsewhere, so the state is
        // checked once, here, where a world begins — and ASSERTED, not installed (the
        // reason the two verbs differ is in `determinism.zig`).
        determinism.assertFloatEnvironment();
        return .{ .bp = Bp.init(.{}), .gravity = gravity, .dt = dt };
    }

    /// `init` with sleeping switched off — the world every MEASUREMENT of the solver
    /// uses: settling, penetration recovery, drift, friction decay, determinism.
    ///
    /// Normative, not a convenience (§1.8.3). The sleep criterion is a displacement
    /// bound over a window, so a body creeping at 5 mm/s moves 2.5 mm per 0.5 s window
    /// against a 15 mm bound and falls asleep while still creeping. Ask "does this
    /// settle?" with sleeping on and the answer you measure is "it fell asleep", which
    /// is not the same question.
    pub fn initNoSleep(gravity: Vec3r, dt: Real) PhysicsWorld {
        var world = init(gravity, dt);
        world.sleep_cfg.allow_sleeping = false;
        return world;
    }

    /// Release every owned buffer.
    pub fn deinit(self: *PhysicsWorld, gpa: std.mem.Allocator) void {
        self.chars.deinit(gpa);
        self.sensors.deinit(gpa);
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
        self.bp.deinit(gpa);
        self.cache.deinit(gpa);
        self.bodies.deinit(gpa);
        self.active.deinit(gpa);
        self.constraints.deinit(gpa);
        self.scratch.deinit(gpa);
        self.islands.deinit(gpa);
        self.* = undefined;
    }

    /// Create a body and insert its broadphase proxy on the matching layer.
    /// Dispatches on the shape CLASS: an unbounded half-space has no world AABB and
    /// goes into the layer's flat list (`engine-physics-shapes.md` §1.11.15); a MESH
    /// is a finite surface, so it takes the bounded arm. Exhaustive on the class, no
    /// `else`.
    pub fn addBody(self: *PhysicsWorld, gpa: std.mem.Allocator, desc: api.BodyDescriptor) !BodyId {
        const id = try self.bm.addBody(gpa, &self.store, desc);
        // TRANSACTIONAL, in the shape `createCharacter` already had: three fallible steps in
        // sequence, so each one undoes what precedes it on the way out. Without these, a
        // failing `bp.insert` left a body no proxy represents — invisible to every query and
        // to pair generation — and a failing `bodies.append` left a body AND a leaked proxy
        // that step 10 would go on updating for a registration that does not exist.
        errdefer self.bm.removeBody(id);

        const layer = BodyManager.broadLayerFor(desc.is_trigger, desc.body_type);
        const shape = self.store.get(desc.shape).?;
        const proxy = switch (shape.class()) {
            .convex, .triangle_soup => try self.bp.insert(gpa, layer, self.bm.bodyAabb(&self.store, id).?, id),
            .half_space => blk: {
                const world = shape_mod.halfSpace(shape).transformed(
                    self.bm.rotation(id).?,
                    self.bm.position(id).?,
                );
                break :blk try self.bp.insertUnbounded(gpa, layer, .{
                    .normal = world.normal,
                    .distance = world.distance,
                }, id);
            },
        };
        errdefer self.bp.remove(proxy);

        try self.bodies.append(gpa, .{ .id = id, .proxy = proxy, .kind = .rigid_body });
        return id;
    }

    /// Remove a body, applying wake cause W4 (§1.8.5) first: every sleeper retained
    /// in a candidate pair with it is woken, because removing it changes what
    /// supports them and a sleeper emits nothing in broadphase that could notice.
    pub fn removeBody(self: *PhysicsWorld, id: BodyId) void {
        // A CHARACTER PRESENCE IS NOT REMOVABLE HERE, and the sequence is reachable without
        // doing anything illegal: `getCharacterInnerBody` is a public entry, and its `BodyId`
        // handed to this one released the proxy, the registration and the body — after which
        // `destroyCharacter` released a proxy the broadphase had already freed and tripped
        // `Broadphase.remove`'s assertion. A presence's lifetime runs through
        // `destroyCharacter` and through nothing else.
        //
        // A NO-OP rather than an error: the frozen signature returns `void`, and the repository
        // already answers an unhandleable handle this way (`setPresenceProxy`). The filter sits
        // BEFORE every mutation, `wakeRetainedPartners` included — a refused call that had
        // still woken the scene would be a side effect with no operation behind it.
        for (self.bodies.items) |entry| {
            if (entry.id == id and entry.kind == .character_presence) return;
        }

        self.wakeRetainedPartners(id);
        for (self.bodies.items, 0..) |entry, i| {
            if (entry.id != id) continue;
            self.bp.remove(entry.proxy);
            _ = self.bodies.orderedRemove(i); // ordered: the sweep order stays stable
            break;
        }
        self.bm.removeBody(id);
    }

    /// Create a character controller AND insert its broadphase presence.
    ///
    /// **This is the half the store cannot do.** `CharacterStore.createCharacter` builds
    /// the presence — a `.kinematic` body carrying the controller's own capsule
    /// (`engine-physics-queries.md` §1.12.2) — but a proxy needs a LAYER, and the layer
    /// comes from the `BodyType` → `BroadphaseLayer` derivation this file owns. Without
    /// the insertion the presence exists in the body store and is invisible to every
    /// query, which C1.8 refuses twice over: the player's attack goes through
    /// raycast/overlap, and the follow camera's anti-wall sweep starts from the player.
    ///
    /// The layer is derived from the presence's OWN stored flags rather than from a
    /// literal, so a presence follows the same fixed priority as any other body —
    /// `is_trigger` first, then body type (`engine-physics-solver.md` §1.13.3). A
    /// hard-coded `.dynamic` would agree with the rule today and stop agreeing the day
    /// the rule moves.
    ///
    /// TRANSACTIONAL: if the insertion fails, the character is destroyed rather than left
    /// half-built with a presence no tree holds.
    pub fn createCharacter(
        self: *PhysicsWorld,
        gpa: std.mem.Allocator,
        desc: api.CharacterDescriptor,
    ) !api.CharacterId {
        const id = try self.chars.createCharacter(gpa, &self.store, &self.bm, desc);
        errdefer self.chars.destroyCharacter(gpa, &self.bp, &self.store, &self.bm, id);

        const presence = (try self.chars.getCharacterInnerBody(id)) orelse return id;
        const layer = BodyManager.broadLayerFor(
            self.bm.isTrigger(presence).?,
            self.bm.bodyType(presence).?,
        );
        const proxy = try self.bp.insert(gpa, layer, self.bm.bodyAabb(&self.store, presence).?, presence);
        self.chars.setPresenceProxy(id, proxy);

        // AND REGISTERED IN THIS WORLD'S OWN BODY LIST, which is a SECOND fact and not a
        // restatement of the insertion — the defect found by the W4 test at gate C lived
        // exactly in the gap between the two. `pairStillOverlaps` resolves a retained
        // pair's endpoints through `proxyOf`, which searches this list; an unregistered
        // presence resolves to `null`, so step 2 pruned EVERY pair involving it on EVERY
        // tick, and the retained set — which IS the wake graph (§1.8.7) — could never
        // hold a character. W4 was structurally unable to fire for the one producer the
        // engine has. The proxy handle survives a `resizeCharacter`, which updates it in
        // place, so this registration stays valid for the character's whole life.
        try self.bodies.append(gpa, .{ .id = presence, .proxy = proxy, .kind = .character_presence });
        return id;
    }

    /// Destroy a character, releasing its presence body and the proxy inserted above.
    /// The store owns that release — it holds the proxy handle — so this is a delegation
    /// and not a second removal path.
    pub fn destroyCharacter(self: *PhysicsWorld, gpa: std.mem.Allocator, id: api.CharacterId) void {
        // Deregister BEFORE delegating: the store removes the proxy and the presence
        // body, so an entry left here would hand step 10 a proxy the broadphase has
        // freed. Ordered removal, for the same reason `removeBody` uses one — the sweep
        // order of this list stays stable.
        if (self.chars.getCharacterInnerBody(id) catch null) |presence| {
            // W4 FIRST, which is what `removeBody` does in its own first instruction and
            // what this path did not. The cause does not care which entry removes the body:
            // a sleeper retained in a pair with the presence loses what it was resting
            // against, and a sleeper emits nothing in broadphase that could notice.
            self.wakeRetainedPartners(presence);
            for (self.bodies.items, 0..) |entry, i| {
                if (entry.id != presence) continue;
                _ = self.bodies.orderedRemove(i);
                break;
            }
        }
        self.chars.destroyCharacter(gpa, &self.bp, &self.store, &self.bm, id);
    }

    /// Move a character, then apply W4 for it.
    ///
    /// **W3 is structurally blind to a controller, and W4 is the only cause that covers
    /// it** (`engine-physics-solver.md` §1.8.5). A presence is a kinematic body moved by
    /// POSE WRITE, so its velocity columns stay exactly zero while it crosses the scene
    /// and W3's true-zero test never sees it move. A character walking into a sleeping
    /// stack would sink into it with no diagnostic. The controller is the engine's first
    /// real producer of W4, and this is where that producer lives.
    pub fn moveCharacter(
        self: *PhysicsWorld,
        gpa: std.mem.Allocator,
        id: api.CharacterId,
        displacement: Vec3r,
        dt: Real,
    ) !character_mod.MoveResult {
        const result = try self.chars.moveCharacter(gpa, &self.bp, &self.bm, &self.store, id, displacement, dt);
        self.wakePresencePartners(id);
        return result;
    }

    /// Teleport a character, then apply W4 for it — same cause, same reason as
    /// `moveCharacter`: the presence's pose changed and its velocity columns did not.
    pub fn setCharacterPosition(
        self: *PhysicsWorld,
        gpa: std.mem.Allocator,
        id: api.CharacterId,
        position: Vec3r,
    ) !void {
        try self.chars.setCharacterPosition(gpa, &self.bp, &self.bm, &self.store, id, position);
        self.wakePresencePartners(id);
    }

    /// Resize a character, and apply W4 only on SUCCESS.
    ///
    /// `false` means the target volume was occupied and NOTHING moved — a legitimate
    /// gameplay answer and not an error (`engine-physics-queries.md` §1.12.7). Waking on
    /// a refused resize would wake for a mutation that did not happen, which is the
    /// always-wake rule wearing the shape of a correct one.
    pub fn resizeCharacter(
        self: *PhysicsWorld,
        gpa: std.mem.Allocator,
        id: api.CharacterId,
        radius: f32,
        height: f32,
    ) !bool {
        const ok = try self.chars.resizeCharacter(gpa, &self.bp, &self.bm, &self.store, id, radius, height);
        if (ok) self.wakePresencePartners(id);
        return ok;
    }

    /// W4 for a character: wake the sleepers retained in a pair with its PRESENCE. A
    /// character without a presence has no pair to be retained in, so there is nothing
    /// to wake and the absence is the correct answer rather than a skipped case.
    fn wakePresencePartners(self: *PhysicsWorld, id: api.CharacterId) void {
        const presence = (self.chars.getCharacterInnerBody(id) catch return) orelse return;
        self.wakeRetainedPartners(presence);
    }

    /// How many proxies the broadphase holds in `layer` — tree leaves plus the layer's
    /// live unbounded slots.
    ///
    /// PER CLASS, and never a total, because that is the only form that discriminates: a
    /// body inserted into the wrong class satisfies a total and fails a per-class count.
    pub fn proxyCountIn(self: *const PhysicsWorld, layer: BroadphaseLayer) u32 {
        var counter: struct {
            n: u32 = 0,
            pub fn add(c: *@This(), user_data: u32) void {
                _ = user_data;
                c.n += 1;
            }
        } = .{};
        self.bp.forEachInLayer(layer, &counter);
        return counter.n;
    }

    // --- wake composition (§1.8.4, §1.8.5) ------------------------------------
    //
    // The store keeps the two INTENTIONS apart and this tier composes them. A
    // solver-internal write — what the substep loop and the restitution pass do every
    // tick to every body in contact — must NOT rearm a sleep window, or nothing in
    // contact would ever sleep; an EXTERNAL mutation must wake and rearm. So
    // `setLinearVelocity`, `setAngularVelocity`, `setPosition` and `setRotation` are
    // non-activating in the store BY CONTRACT, and the entries below are the ones that
    // add the wake. `addForce`, `addTorque` and `addImpulse` are external by
    // construction — the solver has zero call sites on them — and activate in the store
    // itself, so this tier delegates them unchanged rather than waking twice.

    /// Wake every sleeper RETAINED IN A PAIR with `id` — wake cause W4 (§1.8.5).
    ///
    /// The retained candidate set IS the wake graph (§1.8.7): a sleeper emits nothing in
    /// broadphase, so nothing else could notice that what supported it has moved or gone.
    /// One helper and not a copy per producer, because the five producers of W4 —
    /// body removal, static/kinematic teleportation, and the controller's three — differ
    /// in what they do to their own body and not at all in what they owe their partners.
    fn wakeRetainedPartners(self: *PhysicsWorld, id: BodyId) void {
        for (self.active.items) |key| {
            const a: BodyId = @intCast(key >> 32);
            const b: BodyId = @intCast(key & 0xFFFF_FFFF);
            if (a != id and b != id) continue;
            self.bm.wakeBody(if (a == id) b else a);
        }
    }

    /// Refresh `id`'s broadphase proxy from its current pose, so a query issued between
    /// two ticks finds the body where it now is and not where step 10 last left it. An
    /// UNBOUNDED proxy has no box to refresh.
    fn refreshProxy(self: *PhysicsWorld, gpa: std.mem.Allocator, id: BodyId) !void {
        const proxy = self.proxyOf(id) orelse return;
        if (proxy.kind == .unbounded) return;
        if (self.bm.bodyAabb(&self.store, id)) |aabb| try self.bp.update(gpa, proxy, aabb);
    }

    /// TELEPORT `id` to a pose. Writes the pose and derives NO velocity — the split
    /// against `moveKinematic` is contractual and not an oversight
    /// (`engine-physics-queries.md` §1.12.5): a platform moved by this entry keeps
    /// velocity columns at zero, which is exactly why a character standing on one needs
    /// the other entry to report a truthful `ground_velocity`.
    ///
    /// Composes the wake: the body itself, because a teleport is an external mutation
    /// (§1.8.4), and W4 on its retained partners, because a body that moves changes what
    /// supports the sleepers around it and they cannot see it happen. No-op on a stale
    /// handle.
    ///
    /// **W4 IS APPLIED TO A DYNAMIC BODY TOO, and §1.8.5 now says so.** The reasoning that
    /// carried the decision, kept because it is what the amended text rests on: a sleeper
    /// emits nothing in broadphase that could notice a change, and that holds identically for
    /// a teleported DYNAMIC body — its own island wakes through W1 then W2, but the sleepers
    /// of ANOTHER island retained in a pair with it wake through nothing at all. An earlier
    /// wording named only removal and static/kinematic teleportation, which would have
    /// manufactured a silent false negative on a legal configuration — the thing §1.13.6
    /// refuses in as many words.
    ///
    /// **TRANSACTIONAL ON THE POSE.** The proxy refresh reserves and can fail. Before this
    /// was written the pose had already been committed when it did, leaving the broadphase
    /// describing a body that had moved — and a caller who retried would be retrying against
    /// a store that already held the target. The pose is restored on failure, so the
    /// broadphase and the store agree again and a retry is a retry. The WAKES are not rolled
    /// back and that is a decision, not an omission: a spurious wake costs simulation time
    /// and never an answer, while a stale proxy is a wrong answer.
    pub fn setBodyTransform(
        self: *PhysicsWorld,
        gpa: std.mem.Allocator,
        id: BodyId,
        position: Vec3r,
        rotation: config.Quatr,
    ) !void {
        const prev_position = self.bm.position(id) orelse return; // stale handle
        const prev_rotation = self.bm.rotation(id).?;
        errdefer {
            self.bm.setPosition(id, prev_position);
            self.bm.setRotation(id, prev_rotation);
        }

        self.wakeRetainedPartners(id);
        self.bm.wakeBody(id);
        self.bm.setPosition(id, position);
        self.bm.setRotation(id, rotation);
        try self.refreshProxy(gpa, id);
    }

    /// Move a KINEMATIC body to a target pose over `dt`, deriving both velocities from
    /// the move — the entry `setBodyTransform` is deliberately not.
    ///
    /// **It writes the pose AND publishes the velocities**, and that pairing is the whole
    /// point (`engine-physics-queries.md` §1.12.5). The problem the two entries exist to
    /// separate is a platform the gameplay drives tick after tick: moved by
    /// `setBodyTransform` its velocity columns stay at zero and `ground_velocity` reports
    /// 0 for something visibly in motion; moved by this entry the columns carry the motion
    /// that actually happened. An entry that published a velocity WITHOUT moving the body
    /// would only mirror the same lie the other way round, and one that moved the body
    /// without publishing would be `setBodyTransform` under a second name — either way the
    /// caller would have to compose the two, which is a missing operation and not a
    /// documented recipe.
    ///
    /// **Kinematic bodies are never integrated, and that is load-bearing rather than a
    /// gap.** `integratePositions` skips every non-dynamic body, so a presence crosses the
    /// scene with velocity columns at exactly zero and W3's true-zero test never sees it —
    /// which is precisely why W4 exists at all (`engine-physics-solver.md` §1.8.5). Making
    /// the integrator advance kinematics would give a presence a non-zero velocity, W3
    /// would start firing, and the reasoning that justifies W4 would collapse. So the pose
    /// is written here, not integrated from `ω` later.
    ///
    /// **The angular derivation carries no trigonometry, and it needs none.** With no
    /// integrator consuming `ω`, its single consumer is `ground_velocity = v + ω × r`, so
    /// there is nothing an exact axis-angle extraction would be exact AGAINST — while
    /// `acos` is an external transcendental `ARCH-031` rule 4 forbids on a compared path.
    /// `ω = 2 · vec(q_target · conj(q_current)) / dt`, with the sign normalised so the
    /// SHORT path is taken: `q` and `−q` are the same rotation, and without the flip a
    /// small turn expressed by the negated quaternion would read as a near-full turn the
    /// other way.
    ///
    /// Composes the wake like any external pose write: the body, and W4 on its retained
    /// partners. No-op on a stale handle.
    ///
    /// **TRANSACTIONAL ON POSE AND VELOCITIES, and the second half is what makes a retry
    /// honest.** Both are derived FROM the current pose, so committing them before the
    /// fallible proxy refresh left a failed call with the target already stored — and a
    /// retry then computed `target − current` over a difference of zero, publishing a null
    /// velocity for a move that had happened. That is exactly the lie this entry exists to
    /// remove, arriving through the error path. Restoring pose and velocities makes the
    /// retry recompute the same non-zero derivation.
    pub fn moveKinematic(
        self: *PhysicsWorld,
        gpa: std.mem.Allocator,
        id: BodyId,
        target_position: Vec3r,
        target_rotation: config.Quatr,
        dt: Real,
    ) !void {
        std.debug.assert(std.math.isFinite(dt) and dt > 0);
        const current_position = self.bm.position(id) orelse return; // stale handle
        const current_rotation = self.bm.rotation(id).?;

        const inv_dt = 1.0 / dt;
        const linear = target_position.sub(current_position).scale(inv_dt);

        var dq = target_rotation.mul(current_rotation.conjugate());
        if (dq.w < 0) dq = dq.scale(-1); // short path: q and −q are one rotation
        const angular = Vec3r.fromArray(.{ dq.x, dq.y, dq.z }).scale(2 * inv_dt);

        const prev_linear = self.bm.linearVelocity(id).?;
        const prev_angular = self.bm.angularVelocity(id).?;
        errdefer {
            self.bm.setPosition(id, current_position);
            self.bm.setRotation(id, current_rotation);
            self.bm.setLinearVelocity(id, prev_linear);
            self.bm.setAngularVelocity(id, prev_angular);
        }

        self.wakeRetainedPartners(id);
        self.bm.wakeBody(id);
        self.bm.setLinearVelocity(id, linear);
        self.bm.setAngularVelocity(id, angular);
        self.bm.setPosition(id, target_position);
        self.bm.setRotation(id, target_rotation);
        try self.refreshProxy(gpa, id);
    }

    /// Set the linear velocity from gameplay: wake, then write. The store's setter is
    /// non-activating because the solver drives it every substep; this entry is the one
    /// an external caller reaches, and it is where the wake belongs.
    pub fn setLinearVelocity(self: *PhysicsWorld, id: BodyId, velocity: Vec3r) void {
        self.bm.wakeBody(id);
        self.bm.setLinearVelocity(id, velocity);
    }

    /// Set the angular velocity from gameplay — same composition, same reason.
    pub fn setAngularVelocity(self: *PhysicsWorld, id: BodyId, velocity: Vec3r) void {
        self.bm.wakeBody(id);
        self.bm.setAngularVelocity(id, velocity);
    }

    /// Accumulate a world-space force. ALREADY activating in the store, which is where
    /// it belongs: a force is external by construction and the solver has no call site
    /// on it. Delegated rather than re-woken here, so the wake happens once.
    pub fn addForce(self: *PhysicsWorld, id: BodyId, force: Vec3r) void {
        self.bm.addForce(id, force);
    }

    /// Accumulate a world-space torque — same reasoning as `addForce`.
    pub fn addTorque(self: *PhysicsWorld, id: BodyId, torque: Vec3r) void {
        self.bm.addTorque(id, torque);
    }

    /// Apply a world-space impulse — same reasoning as `addForce`.
    pub fn addImpulse(self: *PhysicsWorld, id: BodyId, impulse: Vec3r) void {
        self.bm.addImpulse(id, impulse);
    }

    /// The proxy of `id`, or `null` once the body has been removed.
    pub fn proxyOf(self: *const PhysicsWorld, id: BodyId) ?Bp.Proxy {
        for (self.bodies.items) |b| {
            if (b.id == id) return b.proxy;
        }
        return null;
    }

    /// Whether a retained pair still satisfies §1.7 step 2 — "removal on FAT-AABB
    /// separation only".
    ///
    /// Three cases, exhaustive on what a proxy can be, and the middle one is why
    /// this is not a two-box test. A half-space has no box at all
    /// (`engine-physics-shapes.md` §1.11.15), so a pair with one on either side is
    /// tested by the SAME exact predicate the traversal uses,
    /// `Aabb.overlapsHalfSpace` from `foundation/math` — never a second copy of that
    /// formula. Two half-spaces both force static bodies and can never separate, so
    /// such a pair is retained unconditionally.
    ///
    /// The FAT boxes are the ones compared, deliberately. Comparing the tight boxes
    /// would purge on a transient sub-margin separation and lose the contact until
    /// the body sank back past the margin — the defect `test "small hop within the
    /// fat margin keeps the contact pair alive"` was written for at M1.1.6. The
    /// margin exists precisely so that this test has hysteresis.
    fn pairStillOverlaps(self: *const PhysicsWorld, a: BodyId, b: BodyId) bool {
        // A removed body's pair serves nothing: W4 has already woken whoever was
        // retained with it, at `removeBody`, and there is no proxy left to test.
        const pa = self.proxyOf(a) orelse return false;
        const pb = self.proxyOf(b) orelse return false;

        const box_a = self.bp.proxyAabb(pa);
        const box_b = self.bp.proxyAabb(pb);
        if (box_a) |ba| {
            if (box_b) |bb| return ba.overlaps(bb);
            const hs = self.bp.unboundedShape(pb) orelse return false;
            return ba.overlapsHalfSpace(hs.normal, hs.distance);
        }
        if (box_b) |bb| {
            const hs = self.bp.unboundedShape(pa) orelse return false;
            return bb.overlapsHalfSpace(hs.normal, hs.distance);
        }
        return true; // two half-spaces: both static, no separation is possible
    }

    /// Record entry into a stage. Called as the FIRST statement of each stage
    /// method below and nowhere else, which is what binds the record to the work:
    /// a stage cannot be moved in `step()` without its record moving with it. A
    /// recorder wired at the call site instead would be blind to exactly the
    /// mutation it exists to catch — the work reordered while the records stay put.
    ///
    /// **The bound is structural, and it is MEASURED — with the scope the measurement
    /// actually supports.** Swapping the BODIES of two stage methods while leaving each
    /// `enter()` in place is invisible to every test ONLY where inverting those two
    /// stages is physically harmless. Measured both ways: on `(proxy_update,
    /// sensor_pass)`, whose inversion cannot alter body state, the whole forge suite
    /// stays green; on `(build_constraints, island_partition)`, whose inversion
    /// partitions last tick's constraints, the same mutation gives `3 failed, 35
    /// crashed` — the same yield as swapping the CALLS, minus the order test. So the
    /// physical guards cover every consequential pair on their own, and this convention
    /// is what covers the harmless ones. The note lives here and not only in
    /// `tests/world_test.zig` because this is the file where it can be broken.
    fn enter(self: *PhysicsWorld, step_id: Step) void {
        if (self.trace) |t| t.record(step_id);
    }

    /// (1) Broadphase candidate deltas on the current poses — moved-driven, with
    /// fat-AABB hysteresis: a pair is emitted only when a proxy leaves its fat box.
    fn stepBroadphasePairs(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.broadphase_pairs);
        try self.bp.computePairs(gpa, &self.scratch);
    }

    /// (2) Merge the deltas into the PERSISTENT candidate set, then prune it on the
    /// one condition §1.7 step 2 allows: the two FAT AABBs have separated.
    ///
    /// The set's retention is a CORRECTNESS condition of sleep (§1.8.7), not merely
    /// warm-start persistence — a sleeper emits nothing in broadphase, so these
    /// retained pairs ARE the wake graph. The pruning is equally load-bearing in the
    /// other direction: a set that can only grow makes a determinism trace over it
    /// pass by ACCUMULATION and prove nothing.
    fn stepPairRetention(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.pair_retention);
        for (self.scratch.items) |p| try self.active.append(gpa, (@as(u64, p.a) << 32) | p.b);
        sortDedup(&self.active);
        var w: usize = 0;
        for (self.active.items) |key| {
            const a: BodyId = @intCast(key >> 32);
            const b: BodyId = @intCast(key & 0xFFFF_FFFF);
            if (!self.pairStillOverlaps(a, b)) continue;
            self.active.items[w] = key;
            w += 1;
        }
        self.active.shrinkRetainingCapacity(w);
    }

    /// (4) Build the constraint array: narrowphase per candidate, then `prepare` —
    /// which captures `v_n⁻` PRE-GRAVITY (the velocity integration lives in the
    /// substep loop), selects the softness, SEEDS the warm start from the cache, and
    /// runs the wake fixpoint of §1.8.5.
    fn stepBuildConstraints(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.build_constraints);
        self.cache.beginTick();
        try rigid.build(
            gpa,
            &self.constraints,
            &self.bm,
            &self.store,
            self.active.items,
            rigid.prepareContext(self.cfg, self.dt, &self.cache),
        );
    }

    /// (5) Partition into islands and arbitrate activation (W2, W3). Reorders the
    /// constraint array into one contiguous range per island. WAKES ONLY — nothing
    /// falls asleep here.
    fn stepIslandPartition(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.island_partition);
        try self.islands.partition(gpa, &self.bm, self.constraints.items);
    }

    /// (6) The substep loop and (7) the restitution pass. Islands advance in
    /// LOCKSTEP inside: every stage sweeps all intervals before the next begins.
    fn stepSolveTick(self: *PhysicsWorld) void {
        self.enter(.solve_tick);
        self.solver_stats = rigid.solveTick(
            &self.bm,
            self.constraints.items,
            self.islands.islandsSlice(),
            self.cfg,
            self.dt,
            self.gravity,
        );
    }

    /// (9) Harvest the solved impulses into the cache, then finalize it (sort + swap,
    /// which is also what evicts whatever this tick did not rewrite).
    fn stepHarvestContacts(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.harvest_contacts);
        try rigid.storeContacts(gpa, &self.cache, self.constraints.items);
        self.cache.endTick();
    }

    /// (10) Broadphase proxy updates on the final poses — skipping sleepers, whose
    /// AABB is unchanged by construction.
    fn stepProxyUpdate(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.proxy_update);
        for (self.bodies.items) |b| {
            const sleeping = self.bm.isSleeping(b.id) orelse continue; // stale handle
            if (sleeping) continue; // a sleeper's AABB is unchanged by construction
            // An UNBOUNDED proxy has no box to update and cannot move: a half-space
            // forces a STATIC body, so its pairs are established once at insertion
            // and then carried by the retention rule of step 2 (§1.11.15).
            if (b.proxy.kind == .unbounded) continue;
            if (self.bm.bodyAabb(&self.store, b.id)) |aabb| try self.bp.update(gpa, b.proxy, aabb);
        }
    }

    /// (10 bis) The sensor pass (§1.13.4).
    ///
    /// Placement rests on two claims of UNEQUAL rank: BEFORE step 11 is MEASURED
    /// (falling asleep inside a trigger never produces an exit, and a sleep filter on
    /// the traversal makes that test fail); AFTER step 10 is a DESIGN REASONING — the
    /// poses there are the ones the tick publishes, so an `enter` cannot announce a
    /// crossing the solver then undoes. Unconditional: see the file header.
    fn stepSensorPass(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        self.enter(.sensor_pass);
        try self.sensors.update(gpa, &self.bp, &self.bm, &self.store);
    }

    /// (11) Advance the sleep windows on the POST-SOLVE state, then put to sleep every
    /// island all of whose members are eligible. The ONLY point in the cycle where a
    /// body falls asleep, and the only one where velocities are zeroed exactly.
    fn stepSleepTransition(self: *PhysicsWorld) void {
        self.enter(.sleep_transition);
        sleep.updateWindows(&self.bm, self.dt, self.sleep_cfg);
        self.slept_last_tick = self.islands.sleepEligibleIslands(&self.bm, self.sleep_cfg);
    }

    /// Advance one fixed tick through the normative cycle (file header).
    ///
    /// The body IS the cycle: nine calls in the frozen order, and the two anchors
    /// that carry no code appear as comments where they would run. Step 3 is
    /// read-only — the force accumulators are constant for the whole tick and every
    /// substep reads them directly — and step 5 bis is the empty composite seam of
    /// §1.7.3, which costs nothing precisely because it has no call.
    pub fn step(self: *PhysicsWorld, gpa: std.mem.Allocator) !void {
        try self.stepBroadphasePairs(gpa); //   (1)
        try self.stepPairRetention(gpa); //     (2)
        //                                      (3) external forces — read-only, no code
        try self.stepBuildConstraints(gpa); //  (4)
        try self.stepIslandPartition(gpa); //   (5)
        //                                      (5 bis) composite pre-solve seam — empty
        self.stepSolveTick(); //                (6) + (7)
        //                                      (8) retired at a frozen number
        try self.stepHarvestContacts(gpa); //   (9)
        try self.stepProxyUpdate(gpa); //       (10)
        try self.stepSensorPass(gpa); //        (10 bis)
        self.stepSleepTransition(); //          (11)
    }

    /// Deepest penetration across the manifolds this world currently holds.
    pub fn deepestPenetration(self: *const PhysicsWorld) Real {
        var deepest: Real = 0;
        for (self.constraints.items) |c| {
            for (0..c.count) |i| deepest = @max(deepest, c.points[i].penetration);
        }
        return deepest;
    }
};

fn sortDedup(list: *std.ArrayListUnmanaged(u64)) void {
    std.mem.sort(u64, list.items, {}, std.sort.asc(u64));
    if (list.items.len == 0) return;
    var w: usize = 1;
    var i: usize = 1;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] != list.items[w - 1]) {
            list.items[w] = list.items[i];
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}
