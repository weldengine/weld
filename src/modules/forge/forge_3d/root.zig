//! `forge_3d` — the native Zig 3D physics solver (Tier 1, in-tree per
//! `engine-spec.md` §3.5). M1.1.0 lays the foundations: the `Real` scalar,
//! the `ShapeStore`, per-body `MotionProperties` with analytic inertia, and the
//! SoA `BodyManager`. No stepping, no scheduler, no broadphase yet — those are
//! later M1.1 sub-milestones. Depends only on `foundation/math` and
//! `src/modules/forge/api/` (core entity/component types reach here through
//! `api/`).

const config = @import("config.zig");
const shape = @import("shape.zig");
const body = @import("body.zig");
const body_manager = @import("body_manager.zig");

// --- Solver scalar + math aliases ---

/// Solver scalar (`f32`, or `f64` under `-Dphysics_f64=true`).
pub const Real = config.Real;
/// 3-vector at solver precision.
pub const Vec3r = config.Vec3r;
/// Quaternion at solver precision.
pub const Quatr = config.Quatr;
/// 3×3 matrix at solver precision.
pub const Mat3r = config.Mat3r;
/// Axis-aligned bounding box at solver precision.
pub const Aabbr = config.Aabbr;

// --- Shapes ---

/// Immutable per-shape data (geometry + local AABB + unit-mass inertia).
pub const Shape = shape.Shape;
/// Generational store of collision shapes.
pub const ShapeStore = shape.ShapeStore;

// --- Bodies ---

/// Derived inverse mass/inertia + damping/gravity for a body.
pub const MotionProperties = body.MotionProperties;
/// Per-body simulation flags.
pub const BodyFlags = body.BodyFlags;
/// One SoA body row.
pub const Body = body.Body;
/// SoA store of rigid bodies with generational handles.
pub const BodyManager = body_manager.BodyManager;

// Pins so the inline tests + the acceptance suite are analysed when this module
// is built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = config;
    _ = shape;
    _ = body;
    _ = body_manager;
    _ = @import("pipeline/broadphase.zig");
    _ = @import("tests/body_manager_test.zig");
    _ = @import("tests/broadphase_test.zig");
}
