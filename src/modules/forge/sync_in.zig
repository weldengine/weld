//! The INWARD half of the ECS seam — gameplay's pose and velocity into the
//! solver (M1.1.15.2 G5b). `sync.zig` is the outward half and this file mirrors
//! its discipline rather than inventing one.
//!
//! **Authority is DECLARED, never detected**, and the model's motive is on
//! `api/authority.zig`: three earlier attempts asked who wrote a `Transform`,
//! and the ECS stores values, not authorship.
//!
//! **The matrix this file implements** (`body_type × authority`):
//!
//! | `body_type` | `authority` | `syncIn`                   | `syncOut`       | during `step` |
//! |-------------|-------------|----------------------------|-----------------|---------------|
//! | `dynamic`   | `.solver`   | nothing                    | pose + velocity | integrated normally |
//! | `dynamic`   | `.gameplay` | pose + velocity, on change | NOTHING         | **piloted, never simulated** (see below) |
//! | `kinematic` | `.solver`   | nothing                    | velocity only   | pose imposed |
//! | `kinematic` | `.gameplay` | pose + velocity, on change | NOTHING         | pose imposed |
//! | `static`    | either      | pose only, on change       | nothing         | not integrated |
//!
//! **The "during `step`" column REFERS and does not summarise**, which is the correction
//! the owner document made to its own copy of this table and which this one had to make
//! too. It read "integrated, inverse mass set to zero" — the superseded formulation,
//! left standing after its replacement. A table cell that paraphrases a rule is a second
//! declarant of it, and two declarants diverge. What a piloted body does is stated once,
//! by `weld_forge`'s `PhysicsAuthority`: it does not integrate, it presents an infinite
//! mass to every impulse path, and it keeps its identity while leaving its island.
//!
//! **The zeroed inverse mass is this pass's doing**, and the flag it writes is the
//! only way the declaration reaches the solver: `RigidBody.authority` is a Tier 1
//! component and `forge_3d` imports no ECS. The regime and what it repairs are on
//! `api/authority.zig` and on `forge_3d/body.zig`'s `BodyFlags`.
//!
//! **The two transitions are not symmetric.** `gameplay → solver` pushes the ECS
//! state into the solver; `solver → gameplay` PUBLISHES the solver's state into the
//! ECS and consumes nothing that tick. Reversing the second one teleports a body whose
//! ECS pose `syncOut` had not been keeping current — a sleeper, or a body previously
//! withheld — backward to that stale pose, permanently.
//!
//! **TWO CONJOINT PREDICATES, and the conjunction is the point.** `changed_tick`
//! filters the bulk without reading any value — the question the tick answers
//! correctly. Value comparison then runs BEFORE the setter, because `getMut`
//! marks `changed_tick` unconditionally: a system that took a `getMut` and
//! changed nothing would mark, and the tick alone would wake a body for nothing.
//! Neither predicate alone is sufficient, and `sync.zig` already carries the
//! second half with its motive written out — this file mirrors it.
//!
//! **Why the wake matters so much here.** `setBodyTransform` composes the wake
//! UNCONDITIONALLY — itself, W4 on retained partners, `refreshProxy` — and the
//! velocity setters wake before writing. Without the change-driven guard every
//! `.gameplay` entity would stay awake forever and feed the broadphase for
//! nothing, which is the defect the load-bearing test of this gate pins.
//!
//! **Normative tick order**, on which the whole model depends:
//!
//! ```
//! gameplay rules and systems   (write Transform, Velocity)
//!   → syncIn                   (consume changes, mark the journal)
//!   → PhysicsModule.step
//!   → syncOut                  (publish per body_type × authority)
//! ```
//!
//! The SENSOR FOLLOWS from that order and from nothing else: `syncIn` precedes
//! `step`, so a gameplay-authored trigger is already at its new pose when the
//! sensor pass runs at step 10 bis. MEASURED rather than assumed — the test
//! moves a gameplay-authoritative trigger through the ECS and reads the overlap
//! set of the same tick.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const sync = @import("sync.zig");

const World = core.ecs.World;
const EntityId = core.ecs.EntityId;
const Tick = core.ecs.Tick;
const Transform = core.ecs.components.Transform;
const Velocity = api.Velocity;
const RigidBody = api.RigidBody;
const PhysicsAuthority = api.PhysicsAuthority;
const PhysicsWorld = forge_3d.PhysicsWorld;
const cross = forge_3d.cross;
const WorldReal = api.precision.WorldReal;
const WorldVec3 = api.precision.WorldVec3;
const WorldQuat = api.precision.WorldQuat;

/// What `syncIn` remembers between ticks, one entry per body registration.
///
/// **A journal and not a cache**: it records what was CONSUMED, so a change
/// already applied is not applied twice. That is what keeps an explicit wrapper
/// call — `physics_move_kinematic`, which mirrors its own effect into the ECS —
/// from being replayed by `syncIn` in the same tick as a second, derived-free
/// application.
pub const Journal = struct {
    /// Keyed by the COMPLETE `BodyId` — index AND generation — and never by a
    /// position (M1.1.15.2 G9).
    ///
    /// **It was keyed by registration position, and `removeBody` shifts.**
    /// `PhysicsWorld.removeBody` uses `orderedRemove` deliberately — its own
    /// comment says "ordered: the sweep order stays stable" — so every body after
    /// the removed one moves down one slot and INHERITS the removed body's
    /// `consumed_tick`, `last_authority` and `seen`. Two observable corruptions
    /// follow: a FABRICATED authority transition, when the neighbour inherits a
    /// `.gameplay` that was never its own and `syncIn` reads a change of field
    /// that never happened; and a LEGITIMATE CHANGE IGNORED, when it inherits a
    /// baseline later than its own write. Silent in both directions — no assertion
    /// in the tree could see it, and none did.
    ///
    /// The generation is part of the key and not decoration: a slot is recycled
    /// LIFO, so a reissued index names a different body, and keying on the index
    /// alone would reintroduce the same inheritance through the recycling path
    /// rather than through the shift.
    ///
    /// A HASH MAP, and the determinism rule is untouched: it is only ever LOOKED
    /// UP, never iterated, so no observable order is derived from it. The iteration
    /// stays `pw.bodies.items` in registration order, which is where the order the
    /// tick depends on lives.
    entries: std.AutoHashMapUnmanaged(api.BodyId, Entry) = .empty,

    /// **THE DIAGNOSTIC'S DURABLE RECORD, and it is here because the production path
    /// DISCARDS the pass's result** (M1.1.15.2 G15, P1-a). `stepAndPublishSystem` writes
    /// `_ = try in.syncIn(...)`: the registered system has nowhere to return a
    /// `SyncInResult` to, so until this gate the only reader of `forbidden_mutations`
    /// was a test calling `syncIn` by hand. A diagnostic no production path can observe
    /// is not a diagnostic — it is a counter with a doc comment.
    ///
    /// The journal is the one object that survives the tick AND is reachable from the
    /// system: it is attached by `attachSyncInJournal` and resolved through
    /// `PhysicsWorldRef.journalPtr`. So the record lives here, and any owner of the
    /// journal — the application, a debug overlay, a test driving the SYSTEM — reads it
    /// without a channel being invented for it.
    diagnostics: Diagnostics = .{},

    pub const Entry = struct {
        /// Tick at which an inbound change for this body was last consumed —
        /// by `syncIn` or by a wrapper that applied it itself.
        ///
        /// `null` means NEVER CONSUMED, and it is a sentinel rather than a zero
        /// for a reason a test found: `Tick` starts at 0, so a write made before
        /// the world's first `beginFrame` is stamped 0, and a `changed_tick > 0`
        /// predicate filters it out. A body that has never been consumed has no
        /// baseline to compare against, so the TICK predicate must not filter it —
        /// the VALUE predicate still does, which is why admitting it costs
        /// nothing.
        consumed_tick: ?Tick = null,
        /// The authority seen at the previous pass. A difference IS the
        /// transition, which is how the model works without the wrapper being
        /// the guardian: `authority` is a public field a rule can write
        /// directly, so the transition is detected here and performed here.
        last_authority: PhysicsAuthority = .solver,
        /// Whether `last_authority` has ever been written. Without it the first
        /// pass over a body already authored `.gameplay` would read a default
        /// `.solver` and manufacture a transition that never happened.
        seen: bool = false,
        /// Tick at which an EXPLICIT WRAPPER applied an operation to this body.
        ///
        /// **DISTINCT FROM `consumed_tick`, and conflating them was a defect**
        /// (M1.1.15.2 G16). The restore branch asks "does a wrapper own this tick",
        /// and it read `consumed_tick == now` — a value `syncIn` ALSO writes, at the
        /// end of its own pass. So a second `syncIn` call within one tick took the
        /// first call's own bookkeeping for a wrapper's mark and restored the mirror:
        /// on a KINEMATIC `.solver` body that publishes a pose `syncOut` deliberately
        /// withholds, gameplay owning a kinematic pose.
        ///
        /// One field, one question. `consumed_tick` is the BASELINE the tick predicate
        /// compares against; this is the OWNERSHIP of the tick. `markApplied` writes
        /// both — the wrapper both applied and consumed — and the pass writes only the
        /// first.
        applied_tick: ?Tick = null,
    };

    /// What the pass has caught since the journal was created. Cumulative and never
    /// reset by the pass: a per-tick number would be gone by the time anyone looked,
    /// which is the defect this record exists to close.
    pub const Diagnostics = struct {
        /// Total « mutation ECS interdite sous autorité `.solver` » caught.
        forbidden_mutations: u64 = 0,
        /// The most recent offender and the tick it was caught on — a count says
        /// something is wrong and not where, and a list would allocate on a path that
        /// does not.
        last_body: ?api.BodyId = null,
        last_tick: ?Tick = null,
    };

    pub fn deinit(self: *Journal, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    fn slot(self: *Journal, gpa: std.mem.Allocator, body: api.BodyId) !*Entry {
        const gop = try self.entries.getOrPut(gpa, body);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// The entry for `body`, or null when the journal has never seen it. Exposed
    /// for the guard that proves a neighbour inherits nothing.
    pub fn entryOf(self: *const Journal, body: api.BodyId) ?Entry {
        return self.entries.get(body);
    }

    /// Record that an inbound change for `body` was applied OUTSIDE `syncIn`, so
    /// the same tick's pass does not apply it again. The explicit call path —
    /// `physics_move_kinematic` and its siblings — calls this after mirroring
    /// into the ECS.
    pub fn markApplied(self: *Journal, gpa: std.mem.Allocator, body: api.BodyId, tick: Tick) !void {
        const e = try self.slot(gpa, body);
        // BOTH: the wrapper applied (ownership) and it consumed (baseline). They are
        // two questions and this is the one caller that answers yes to each.
        e.applied_tick = tick;
        e.consumed_tick = tick;
    }
};

/// What one pass consumed. Telemetry, and the load-bearing half of the guard:
/// `woke` is what a test asserts is ZERO on an unchanged gameplay body.
pub const SyncInResult = struct {
    poses_applied: u32 = 0,
    velocities_applied: u32 = 0,
    transitions: u32 = 0,
    /// Bodies whose ECS state was SEEDED FROM THE SOLVER at a `.solver → .gameplay`
    /// transition. Counted apart from `poses_applied`, which counts the opposite
    /// direction — merging them would make the guard blind to which way the tick went.
    seeded: u32 = 0,
    /// Bodies whose ECS state was RESTORED from the solver because an explicit
    /// wrapper had already applied this tick. Counted apart from `seeded` for the
    /// same reason: same direction, different cause, and a test that could not tell
    /// them apart would pass on either.
    restored: u32 = 0,
    /// Bodies this pass touched with a waking setter. The number that must stay
    /// at zero when nothing changed.
    woke: u32 = 0,
    /// Bodies woken to RESTORE the invariant "gameplay and sleeping are incompatible",
    /// as opposed to `woke`, which counts the wakes a value push composed. Counted apart
    /// because they answer different questions: one says gameplay moved something, the
    /// other says a body was found in a state its regime forbids.
    woke_for_invariant: u32 = 0,
    /// **« Mutation ECS interdite sous autorité `.solver` »** — how many bodies this
    /// pass caught in that state (M1.1.15.2 G12).
    ///
    /// **The wording is the owner's and the wording is the contract.** § *Autorité
    /// d'écriture* formulates it as a property of the STATE and never as "a rule
    /// wrote": the tick establishes that a component mutated since the last `syncIn`,
    /// and a Zig system can have done it as readily as a rule. A diagnostic that named
    /// an author would be naming something the ECS does not store.
    forbidden_mutations: u32 = 0,
    /// One offender, so the count is actionable. Registration order, so it is the same
    /// body on every run of the same scene — a counter alone tells a developer that
    /// something is wrong and not where, and a list would allocate on a path that does
    /// not.
    first_forbidden: ?api.BodyId = null,
};

/// Was `T`'s slot for `entity` stamped AT `tick` exactly?
///
/// **The question the diagnostic needs, and the one a baseline cannot answer on a
/// body's first pass** (M1.1.15.2 G17). `changedSince` takes `?Tick` and returns TRUE
/// unconditionally when it is null, because "never consumed" gives it nothing to filter
/// by — so the diagnostic had to suppress its first observation, and the FIRST forbidden
/// mutation of every body was lost: the baseline advanced, `syncOut` repaired the
/// divergence, and nothing was ever reported.
///
/// This asks the decidable question instead. The normative tick order puts gameplay
/// writes before `syncIn` in the SAME tick, so a forbidden mutation is stamped at
/// exactly `now` — no baseline required, and the third instance of the G5b sentinel
/// (`null` conflating "never consumed" with "no change") stops mattering here.
///
/// It is not weaker than `changedSince` for this use: for a `.solver` body the pass
/// advances the baseline every tick, so `changedTick > now - 1` and `changedTick == now`
/// are the same predicate everywhere except on the first pass, which is the case that
/// was wrong.
fn changedAt(ecs: *World, comptime T: type, entity: EntityId, tick: Tick) bool {
    const loc = ecs.dynamicLocation(entity) orelse return false;
    const arch = ecs.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = ecs.componentId(@typeName(T)) orelse return false;
    const col = arch.componentIndex(cid) orelse return false;
    return arch.changedTick(chunk, col, loc.slot) == tick;
}

/// Was `T`'s slot for `entity` stamped after `since`?
///
/// Reads the SIGNAL `Changed<T>` is built on (`world.getMut` → `markChanged`)
/// and deliberately not the value — the two predicates answer different
/// questions and the second one runs later, on the value.
fn changedSince(ecs: *World, comptime T: type, entity: EntityId, since: ?Tick) bool {
    const baseline = since orelse return true; // never consumed: no baseline to filter by
    const loc = ecs.dynamicLocation(entity) orelse return false;
    const arch = ecs.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = ecs.componentId(@typeName(T)) orelse return false;
    const col = arch.componentIndex(cid) orelse return false;
    return arch.changedTick(chunk, col, loc.slot) > baseline;
}

/// Consume gameplay's writes into the solver. Runs BEFORE `step`.
///
/// `cmd` is absent on purpose: nothing here is structural. The pass writes body
/// poses and velocities and touches no archetype.
pub fn syncIn(
    gpa: std.mem.Allocator,
    pw: *PhysicsWorld,
    ecs: *World,
    journal: *Journal,
) !SyncInResult {
    // THE SAME ELECTION AS `syncOut`, and it must be: if the two directions
    // elected different bodies, `syncOut` would publish from a body `syncIn`
    // does not drive, and one entity's pose would be read from one collider and
    // written to another. Two sources answering differently about the same
    // geometric fact are a defect, never an envelope.
    const table = try sync.electPublishers(gpa, pw);
    defer table.deinit(gpa);

    var result: SyncInResult = .{};
    const now = ecs.current_tick;

    for (pw.bodies.items, 0..) |entry, reg| {
        const body = entry.id;
        const entity = pw.bm.entity(body) orelse continue;
        const auth = sync.authorityOf(ecs, entity);

        // MIRROR THE DECLARATION INTO THE SOLVER, for EVERY registration and not only
        // for the elected one. The election governs which body is POSE-DRIVEN — one
        // entity, one collider answering for it — and it says nothing about mass: every
        // collider of a gameplay-driven entity must push as an infinite mass, or the
        // same entity would answer with two different regimes depending on which of its
        // bodies a contact touched. That is the "two sources answering differently
        // about the same fact" this seam refuses elsewhere.
        //
        // Written UNCONDITIONALLY rather than on a transition: the flag is a mirror,
        // and a mirror that is only refreshed on an event is a mirror that drifts. It
        // composes no wake, which is why writing it every tick costs nothing.
        pw.setBodyAuthorityIsGameplay(body, auth == .gameplay);

        // **AN INVARIANT IS MAINTAINED, IT IS NOT TRIGGERED** (M1.1.15.2 G20,
        // `engine-physics-forge.md` § *Autorite d'ecriture*). `gameplay` and `sleeping`
        // are incompatible: that is a PROPERTY of the regime, and it must not be carried
        // by the code that detects the TRANSITION to `.gameplay`. The two are distinct —
        // a transition is an event, an invariant holds whether or not one occurred — and
        // making one piece of code carry both makes them inseparable, so the invariant is
        // lost exactly where the transition does not happen.
        //
        // **Three paths, all named by the owner and all reachable**: a NEW journal entry,
        // whose `seen` is false so no transition is ever detected on it; a journal
        // REPLACED on a running world, since `attachSyncInJournal` has no precondition on
        // the state of its bodies; and a body ALREADY ASLEEP at the moment the authority
        // is declared. The G18 form — `if (to_gameplay) wakeBody` — covered the third and
        // only when a previous pass had recorded the authority.
        //
        // It costs one flag read per registration and wakes nothing in steady state: a
        // piloted body cannot fall asleep at all, being excluded from the island
        // collection and refused by `putToSleep`. What this restores is the state left by
        // a path that ran BEFORE the authority was known.
        if (auth == .gameplay and (pw.bm.isSleeping(body) orelse false)) {
            pw.bm.wakeBody(body);
            result.woke_for_invariant += 1;
        }

        // TRANSITION, detected here because `authority` is a PUBLIC field: a rule
        // writes it directly, so no wrapper can be the guardian of the invariant.
        //
        // **REALISED PER REGISTRATION AND NOT PER ELECTION** (M1.1.15.2 G18). Same
        // reasoning as the authority mirror above, applied to the other thing the flip
        // must do: the election governs which body carries the POSE, and sleep governs
        // the pose and not the regime. A multi-body entity flipped to `.gameplay` while
        // asleep had only its ELECTED body woken; the others kept `flags.sleeping` under
        // gameplay authority, where `isAwake` rejects them before it ever consults the
        // authority — a body left in a state its own regime forbids.
        const e = try journal.slot(gpa, body);
        const transitioned = e.seen and e.last_authority != auth;
        if (transitioned) result.transitions += 1;
        const to_solver = transitioned and auth == .solver;
        const to_gameplay = transitioned and auth == .gameplay;
        e.last_authority = auth;
        e.seen = true;

        if (!table.publishes[reg]) continue;
        const body_type = pw.bm.bodyType(body) orelse continue;

        // **`.solver → .gameplay` PUBLISHES FIRST, then flips**, and the direction of
        // information flow on this one tick is the OPPOSITE of every other `.gameplay`
        // tick. G5b instead SEEDED FROM THE ECS on the reasoning that `syncOut` had
        // already published, which is a claim about `syncOut` having run for this body
        // — and `syncOut` skips a SLEEPING body and withholds from a `.gameplay` one.
        // Where it has not run, the ECS `Transform` is the pose of the last published
        // tick, and consuming it teleports the body BACKWARD to it, permanently: the
        // push makes solver and ECS agree at the stale value and nothing ever corrects
        // it afterwards, since a `.gameplay` body is never published again.
        //
        // What is published is the SOLVER's current state, which is the control base
        // gameplay is entitled to start from.
        if (to_gameplay) {
            result.seeded += 1;
            _ = sync.mirrorSolverState(ecs, entity, pw, body, body_type != .static);
            // The baseline advances, and it must: the values now in the ECS ARE the
            // solver's, so the marks this publication just left are not gameplay's
            // writes and consuming them next tick would be `syncIn` answering its own
            // publication.
            e.consumed_tick = now;
            continue;
        }

        // **AN EXPLICIT WRAPPER ALREADY APPLIED THIS TICK — the pass restores the
        // mirror and consumes nothing** (M1.1.15.2 G11). `applied_tick` has exactly ONE
        // writer, `Journal.markApplied`, called by a Tier 1 mutation wrapper during the
        // gameplay phase.
        //
        // **It read `consumed_tick` until G16, and that was a second declarant of a
        // different fact.** The pass writes `consumed_tick` itself, at its own end, so a
        // second `syncIn` call within one tick read its own bookkeeping as a wrapper's
        // mark and restored the mirror — publishing, on a KINEMATIC `.solver` body, a
        // pose `syncOut` deliberately withholds because gameplay owns a kinematic pose.
        // One field per question is what makes the predicate precise; a shared field
        // made it merely plausible.
        //
        // **The restore is what keeps the mark from creating the very defect it
        // prevents.** Skipping alone would be wrong: a rule that calls
        // `physics.move_kinematic` and then writes `Transform` in the same tick leaves
        // a value the tick predicate can never see again — `changedTick > baseline` is
        // false when both are `now`, and it stays false forever after — so the ECS
        // would hold one pose and the solver another, permanently and silently. Two
        // sources answering differently about the same geometric fact are a defect,
        // never an envelope.
        //
        // And PUSHING it instead is what the mark exists to prevent: the wrapper
        // DERIVED both velocities from a target pose, while `setBodyTransform` is a
        // teleportation that derives nothing — so the replay would leave the body at
        // the raw pose carrying a velocity that describes a motion toward a target it
        // is no longer heading to. The explicit operation wins the tick, and the ECS is
        // brought back to what it did.
        if (e.applied_tick) |at| {
            if (at == now) {
                if (sync.mirrorSolverState(ecs, entity, pw, body, body_type != .static))
                    result.restored += 1;
                continue;
            }
        }

        // **THE DIAGNOSTIC, and it is detected BEFORE the pass decides to consume
        // anything** (M1.1.15.2 G12). § *Autorité d'écriture* declares it word for word
        // — "mutation ECS interdite sous autorité `.solver`" — and nothing produced it:
        // the `continue` below left before any tick was ever consulted for a `.solver`
        // body, so the one authority under which an ECS write is a defect was the one
        // authority the pass never looked at.
        //
        // **THE TICK IS THE SIGNAL, and the value comparison only removes a certain
        // false positive.** `changed_tick` is stamped by `World.getMut` and by nothing
        // else, so it answers exactly "was this ECS component written" — an API call
        // moving the same body never touches it. What the tick cannot tell is a
        // `getMut` that changed nothing, which is why the value is consulted wherever
        // the solver's own value is authoritative.
        //
        // **THE VALUE COMPARISON IS SIGNIFICANT FOR EVERY BODY TYPE, and the exception
        // that stood here was derived from the wrong fact** (M1.1.15.2 G19,
        // `engine-physics-forge.md` § *Autorite d'ecriture*). G12 short-circuited it on a
        // kinematic body, reasoning — correctly — that `syncOut` publishes a kinematic's
        // velocity and never its pose, so the two sides may legitimately differ and
        // comparing them says nothing.
        //
        // **The relevant fact was a different one: a kinematic `.solver` body is piloted
        // by NOBODY.** A kinematic moved through the API is `.gameplay`, and it is the
        // wrapper that writes both sides in the same breath. Under `.solver` its pose
        // moves on neither side, so the two agree permanently and the comparison is as
        // meaningful there as anywhere else.
        //
        // **The residual therefore turns into COVERAGE.** A kinematic `.solver` whose ECS
        // and solver diverge is ALREADY a defect: something moved it through the
        // interface without going through the wrapper, bypassing the authority model —
        // a Tier 1 module included, which is inside the service's house but not above its
        // rule. Reporting it is what the mechanism is for.
        //
        // **What the short-circuit cost, measured**: `World.spawn` stamps `changed_tick`
        // AND `added_tick` at the current tick (`archetype.zig`), so every kinematic
        // `.solver` created during a frame produced a diagnostic, identical poses or not
        // — a channel that drowns at the first scene creating one in flight. And
        // `added_tick` cannot rescue it: both columns hold `now` at spawn and a later
        // `getMut` rewrites `changed` to `now`, so they distinguish nothing.

        // **A STATIC IS NEVER REPORTED**, and that is F2's correction seen from here
        // rather than a second rule: the matrix consumes a static's pose under EITHER
        // authority, so an ECS write to one is the authored path and not a defect.
        if (auth == .solver and body_type != .static) {
            var forbidden = false;
            if (ecs.get(Transform, entity)) |t| {
                if (changedAt(ecs, Transform, entity, now)) {
                    const pose = sync.solverPose(pw, body).?;
                    const differs = !std.mem.eql(WorldReal, &t.pos, &pose.pos) or
                        !std.mem.eql(WorldReal, &t.rot, &pose.rot);
                    if (differs) forbidden = true;
                }
            }
            if (ecs.get(Velocity, entity)) |v| {
                if (changedAt(ecs, Velocity, entity, now)) {
                    const out = sync.solverVelocity(pw, body);
                    if (!std.mem.eql(WorldReal, &v.linear, &out.linear) or
                        !std.mem.eql(WorldReal, &v.angular, &out.angular)) forbidden = true;
                }
            }
            // **THE FIRST OBSERVATION IS REPORTED, and suppressing it lost every
            // body's FIRST forbidden mutation** (M1.1.15.2 G17). The trap was real —
            // with a null baseline `changedSince` returns true unconditionally — but the
            // treatment was wrong twice: it suppressed the report, and then the baseline
            // advanced and `syncOut` repaired the divergence, so that first mutation was
            // lost DEFINITIVELY. Nothing would ever report it again.
            //
            // The repair is not to establish the baseline earlier but to stop needing
            // one: `changedAt(..., now)` asks whether the component was stamped in THIS
            // tick, which is decidable with no history at all. "Never consumed" and "not
            // changed" are two different facts and the `?Tick` conflated them — the G5b
            // sentinel, third instance.
            //
            // **The residual is named**: an entity spawned and its body created in the
            // SAME tick as this pass, at disagreeing poses, is reported. That is not a
            // mutation, but the seam cannot tell it from one — something wrote the ECS
            // this tick and it disagrees with the solver, which is the whole of what the
            // diagnostic claims to observe.
            if (forbidden) {
                result.forbidden_mutations += 1;
                if (result.first_forbidden == null) result.first_forbidden = body;
                // AND ON THE JOURNAL, which is what makes it observable from the
                // registered system — see `Journal.Diagnostics`. The pass's own result
                // is discarded there.
                journal.diagnostics.forbidden_mutations += 1;
                journal.diagnostics.last_body = body;
                journal.diagnostics.last_tick = now;
            }
            // And the baseline advances whether or not anything was reported, which is
            // what turns the tick predicate into a ONE-TICK window: the next pass asks
            // "was it written since the previous `syncIn`", which is the question the
            // diagnostic is about.
            e.consumed_tick = now;
        }

        // **A STATIC TAKES ITS POSE UNDER EITHER AUTHORITY** (M1.1.15.2 G12, F2). The
        // matrix row is `static | l'un ou l'autre | pose seule, sur changement`, and the
        // predicate excluded a static `.solver` — **the default case**, since `.solver`
        // is the default for every body type. A static is skipped by `syncOut` too
        // (`body_type == .static` → continue), so it left BOTH directions: a rule moving
        // a static updated neither its body nor its broadphase proxy, and every query
        // kept answering at the old pose.
        //
        // `.gameplay → .solver` DOES push once, so the solver resumes from where
        // gameplay left the body rather than from the state it last computed for
        // itself and had discarded ever since.
        const consume = auth == .gameplay or to_solver or body_type == .static;
        if (!consume) continue;

        // A STATIC body takes its pose and nothing else — it has no velocity
        // columns the solver would read.
        const takes_velocity = body_type != .static;

        var applied_here = false;
        // **F8 — THE BASELINE ADVANCES ON A COMPARISON WITHOUT DIFFERENCE.** It used
        // to advance only when a value was APPLIED, so a body whose ECS and solver
        // agree — which is every `.gameplay` body from its creation until gameplay
        // first moves it — kept `consumed_tick` at `null` forever and was RE-COMPARED
        // on every tick. The tick predicate then filtered nothing at all, and the
        // guard the two-predicate design exists for was carried entirely by the value
        // comparison it was supposed to spare.
        //
        // What is recorded is that the change was CONSUMED, which examining it and
        // finding no difference is: the write that stamped `changed_tick` has been
        // looked at and answered.
        var examined = false;

        if (ecs.get(Transform, entity)) |t| {
            // PREDICATE 1 — the tick, which filters the bulk without reading a
            // value. A transition forces the read regardless: the authority
            // changed, not the pose, so nothing stamped the component.
            if (to_solver or changedSince(ecs, Transform, entity, e.consumed_tick)) {
                examined = true;
                const pose = sync.solverPose(pw, body).?;
                // PREDICATE 2 — the value, because `getMut` marks unconditionally
                // and a system that took one and changed nothing would otherwise
                // wake this body every tick forever.
                if (!std.mem.eql(WorldReal, &t.pos, &pose.pos) or
                    !std.mem.eql(WorldReal, &t.rot, &pose.rot))
                {
                    pw.setBodyTransform(
                        body,
                        cross.vec3ToSolver(WorldVec3.fromArray(t.pos)),
                        cross.quatToSolver(WorldQuat.fromArray(t.rot)),
                    );
                    result.poses_applied += 1;
                    applied_here = true;
                }
            }
        }

        if (takes_velocity) {
            if (ecs.get(Velocity, entity)) |v| {
                if (to_solver or changedSince(ecs, Velocity, entity, e.consumed_tick)) {
                    examined = true;
                    const out = sync.solverVelocity(pw, body);
                    if (!std.mem.eql(WorldReal, &v.linear, &out.linear)) {
                        pw.setLinearVelocity(body, cross.vec3ToSolver(WorldVec3.fromArray(v.linear)));
                        result.velocities_applied += 1;
                        applied_here = true;
                    }
                    if (!std.mem.eql(WorldReal, &v.angular, &out.angular)) {
                        pw.setAngularVelocity(body, cross.vec3ToSolver(WorldVec3.fromArray(v.angular)));
                        result.velocities_applied += 1;
                        applied_here = true;
                    }
                }
            }
        }

        if (applied_here) {
            // Every setter above composes a wake — `setBodyTransform`
            // unconditionally, the velocity setters before writing — so ONE
            // count covers them and it is the number the guard watches.
            result.woke += 1;
        }
        // The baseline moves on EXAMINATION, not on application. `woke` stays on
        // application, which is what the no-wake guard reads — the two counters
        // answer different questions and are deliberately not merged.
        if (examined) e.consumed_tick = now;
    }

    // **ONE LINE PER TICK AT MOST, and it is the human-observable half.** The record
    // above serves a reader that holds the journal; a log line serves the developer who
    // does not know to look. Bounded on purpose: per PASS and never per body, so a scene
    // with a hundred offenders logs once and names the count.
    //
    // The wording is the owner's — `engine-physics-forge.md` § *Autorité d'écriture*
    // formulates it as a property of the STATE and never as "a rule wrote", since a Zig
    // system can have done it as readily as a rule.
    if (result.forbidden_mutations > 0) {
        std.log.warn(
            "forge/syncIn: forbidden ECS mutation under `.solver` authority — {d} body(ies) this tick, first BodyId {d}",
            .{ result.forbidden_mutations, result.first_forbidden.? },
        );
    }

    return result;
}
