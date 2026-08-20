//! Fixture — `@reduce(.Add, …)` on a float path. Rule `no_float_reduce` must fire:
//! the summation order is the backend's, not the source's.

/// Sum of a 3-lane float vector, the way `ARCH-031` rule 3 forbids.
pub fn sum(v: @Vector(3, f32)) f32 {
    return @reduce(.Add, v);
}
