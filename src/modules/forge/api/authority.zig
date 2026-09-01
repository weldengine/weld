//! Who owns a body's pose and velocity (M1.1.15.2 G5b).
//!
//! **Three previous attempts failed, and all three asked the same wrong
//! question: WHO wrote this `Transform`.** The ECS stores values, not
//! authorship — the change tick records WHEN, never WHO — and solver-side
//! provenance does not close it either, since the publication deliberately does
//! not write a kinematic body's pose. Authority derived from `BodyType` is too
//! coarse in the other direction: a dynamic body under scripted control has no
//! way to exist under it.
//!
//! So the model stops detecting and DECLARES. The default is `.solver` for
//! EVERY `body_type`, with no type-dependent default: `.gameplay` is explicit
//! and visible in the component, which is the whole point of not inferring it.

/// Who owns a body's pose and velocity.
pub const PhysicsAuthority = enum(u8) {
    /// The solver owns them. `syncIn` reads nothing; `syncOut` publishes.
    solver = 0,
    /// Gameplay owns them. `syncIn` pushes the ECS values on change; `syncOut`
    /// publishes NOTHING, or it would overwrite the authority it just read.
    ///
    /// **THE REGIME: PILOTED, NEVER SIMULATED** — `engine-physics-forge.md`
    /// § *Autorite d'ecriture*, three clauses, transcribed here because this type is
    /// the one place in the tree that may state them. Every other site REFERS to this
    /// declaration and never paraphrases it.
    ///
    ///   1. **It does not integrate** — no gravity, no velocity integration, no
    ///      damping. Its pose and velocity are what `syncIn` posed, and nothing else
    ///      makes them evolve.
    ///   2. **It presents an infinite mass to EVERY impulse path** — rigid contact
    ///      resolution, character-controller pushes, and `addImpulse`. "Every path" is
    ///      NORMATIVE: a path added later that does not consult this flag is a defect
    ///      of that path.
    ///   3. **It keeps its identity** — same `BodyId`, same shapes, same contacts, no
    ///      runtime `BodyType` change, reversible without reconstruction. **It leaves
    ///      its island**, as a kinematic body has none, and follows the kinematic
    ///      regime on every predicate that asks what kind of body this is: it is not a
    ///      sleep candidate, and it counts as a motion source only when it is MOVING.
    ///
    /// **Two superseded formulations are recorded because each cost a defect.** The
    /// text carried at G5b said the body *"keeps its mass, participates in manifolds"*
    /// AND that it *"behaves as an infinitely heavy body"* — the two cannot both be
    /// true, the solver followed the first, and momentum vanished at every contact.
    /// The text that replaced it said the inverse mass is zero *"during resolution"*,
    /// which was exact and named ONE path of three: measured, the flag had a single
    /// reader in the whole repository, so the body fell under gravity while nothing
    /// published its pose and the character controller pushed it with its stored
    /// inverse mass. *A contradiction is visible on a re-read; an incompleteness only
    /// on wiring.*
    ///
    /// **The TRANSITIONS are `syncIn`'s and not a wrapper's**, because
    /// `authority` is a PUBLIC field: a rule writes
    /// `entity.get_mut(RigidBody).authority = .gameplay` directly, so no wrapper
    /// can be the guardian of the invariant and a convenience wrapper writes the
    /// field and nothing else.
    ///
    /// - `solver` -> `gameplay`: the solver's pose and velocity are PUBLISHED
    ///   into the ECS first, then the authority flips. Without that publication
    ///   the control base would be the `Transform` of the last published tick,
    ///   and the object would jump backward at the first `syncIn`.
    /// - `gameplay` -> `solver`: the CURRENT ECS pose and `Velocity` are pushed
    ///   as they stand. No derived velocity — it would turn a teleport into an
    ///   arbitrarily large speed and would ignore that `Velocity` exists exactly
    ///   as authorable state. Derivation stays `moveKinematic`'s explicit job.
    gameplay = 1,
};
