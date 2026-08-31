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
    /// A gameplay-authoritative DYNAMIC body stays integrated and resolved — it
    /// keeps its mass, participates in manifolds and pushes other bodies — and
    /// its result is discarded, `syncIn` reposing it next tick. It behaves as an
    /// infinitely heavy externally driven body, which is the expected semantics
    /// of a scripted move on an object that must stay collidable. Removing it
    /// from integration would amount to changing its `BodyType` at runtime,
    /// which the solver does not support and which would destroy its island.
    gameplay = 1,
};
