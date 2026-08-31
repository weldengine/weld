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
    /// **A gameplay-authoritative DYNAMIC body resolves with an inverse mass of
    /// ZERO, and the formulation this replaces was self-contradictory.** The
    /// text carried at G5b said the body *"keeps its mass, participates in
    /// manifolds"* AND that it *"behaves as an infinitely heavy body"*. The two
    /// cannot both be true, and the solver followed the first: it kept the
    /// body's inverse mass in the contact's effective mass and applied it a
    /// share of the impulse — a share `syncIn` then discarded by reposing the
    /// body. The other body therefore received LESS impulse than it would
    /// against an infinite mass, and momentum vanished at every contact.
    ///
    /// The normative regime is the inverse mass set to zero DURING RESOLUTION.
    /// The body stays dynamic in every other respect — same `BodyId`, same
    /// island, same shapes, no runtime `BodyType` change, which the solver does
    /// not support and which would destroy its island — and it is still
    /// integrated, its result discarded. It pushes other bodies exactly as an
    /// infinite mass would, and nothing is lost.
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
