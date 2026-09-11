//! Foundation — transversal sibling submodules consumed across the engine.
//!
//! Per `engine-simd.md` § "Relation avec `foundation/math/`", `math` and `simd`
//! are sibling submodules with no mutual dependency.

/// General-purpose math types (Vec/Quat/Mat3/Aabb, generic over the scalar;
/// f32 aliases + generics). Operates one value at a time; imports no `simd`.
pub const math = @import("math/math.zig");

/// Batched-SIMD kernels.
pub const simd = @import("simd/simd.zig");

/// Types a dispatched job body must never receive, declared by the type and
/// tested by a tier-agnostic comptime predicate. Consumed by BOTH `src/core/ecs`
/// and `src/core/jobs`, which is what puts it here rather than beside the type
/// it refuses; the module header carries the reason.
pub const job_bound = @import("job_bound.zig");

comptime {
    _ = math;
    _ = simd;
    _ = job_bound;
}
