//! Fixture — `@reduce(.Max, …)`. Flagged for order AND for leaving NaN
//! propagation to the backend.

/// Largest lane of a float vector.
pub fn largest(v: @Vector(4, f64)) f64 {
    return @reduce(.Max, v);
}
