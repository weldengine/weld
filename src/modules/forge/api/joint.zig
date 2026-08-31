//! Joint type family of the Tier 1 physics interface (M1.1.15.2 G5a).
//!
//! **Transcribed from `engine-tier-interfaces.md` §1, field for field, name for
//! name, default for default.** The contract was arbitrated there in full and
//! nothing here improves on it. Three consequences a reader should not have to
//! rediscover:
//!
//!   - `.off` is NOT a `JointMotorMode` variant. A motor that is off is
//!     `motor: null` on the descriptor, and `setJointMotor(id, null)` turns one
//!     off. Two ways to express the same absence are two things that can
//!     diverge — the same reason `PackedId.dead` is reused for "attached to the
//!     world" rather than a dedicated pattern.
//!   - `JointTarget` is TAGGED BY `joint_type`, on the same shape and the same
//!     correspondence table as `JointLimits`.
//!   - FOUR scalars per MOTOR, never per axis. `max_linear_force` (N) and
//!     `max_angular_torque` (N·m) are two ceilings by axis NATURE, which is not
//!     two ceilings per axis: `six_dof` carries two and not six, and no variant
//!     of `JointTarget` carries a ceiling or a gain. That absence is what puts
//!     "never per axis" in the TYPE rather than in prose.
//!
//! **The types are minted BEFORE the assert block, and that ordering is the
//! deliverable rather than a convenience.** A typed stub needs its parameter
//! type to exist: `createJoint`, `destroyJoint` and `setJointMotor` are not
//! PRESENTABLE without the seven types below, not merely bodyless.
//!
//! **Scalar.** Plain `Vec3` throughout, following `BodyDescriptor` — a
//! DESCRIPTOR is authoring input and stays at the f32 aliases. The three body
//! pose and velocity ENTRIES are what carry `WorldVec3`, on §1's statement about
//! the positions and poses of that section (`src/interfaces/PhysicsModule.zig`).

const math = @import("foundation").math;
const types = @import("types.zig");

const Vec3 = math.Vec3;
const BodyId = types.BodyId;

/// Opaque at the interface boundary; internally `index:24 | generation:8`
/// (`PackedId`) — stale-handle detection, 256-generation ABA window.
pub const JointId = u32;

/// The ten joint types: seven core, three extensions.
///
/// **Extensions** — optional, exposed through `Capability.advanced_joints`. If
/// the backend does not declare it, creating an extension joint returns a clear
/// error at load.
pub const JointType = enum {
    // Core
    fixed,
    hinge,
    ball_socket,
    prismatic,
    cone_twist,
    distance,
    six_dof,
    // Extensions (require Capability.advanced_joints)
    pulley,
    gear,
    rack_and_pinion,
};

/// A joint's limits, tagged by `joint_type`.
///
/// | JointType         | Variant used         | Meaning |
/// |-------------------|----------------------|---------|
/// | `fixed`           | `.none`              | no freedom, no limit |
/// | `hinge`           | `.angle1d`           | min/max angle about `axis_a` |
/// | `ball_socket`     | `.none` or `.cone1d` | unlimited, or a cone of opening |
/// | `prismatic`       | `.linear1d`          | min/max translation along `axis_a` |
/// | `cone_twist`      | `.cone_twist`        | swing (cone angle) + twist about the axis |
/// | `distance`        | `.distance`          | min/max distance |
/// | `six_dof`         | `.six_dof`           | 6 free axes with per-axis limits (3 trans + 3 rot) |
/// | `pulley`          | `.pulley`            | ratio between the two cables |
/// | `gear`            | `.gear`              | rotation ratio |
/// | `rack_and_pinion` | `.rack_and_pinion`   | translation/rotation ratio |
pub const JointLimits = union(enum) {
    none: void,

    /// Hinge: angle limit about `axis_a`.
    angle1d: struct {
        min_radians: f32,
        max_radians: f32,
    },

    /// Prismatic: translation limit along `axis_a`.
    linear1d: struct {
        min: f32,
        max: f32,
    },

    /// Ball socket with a cone: maximum opening angle.
    cone1d: struct {
        max_angle_radians: f32,
    },

    /// Cone twist: swing (cone angle) + twist (torsion about the axis).
    cone_twist: struct {
        /// Cone half-angle in `axis_a`'s XY plane.
        swing_y_radians: f32,
        /// Cone half-angle in the XZ plane — an elliptical cone when it differs
        /// from `swing_y_radians`.
        swing_z_radians: f32,
        /// Minimum torsion about `axis_a`.
        twist_min_radians: f32,
        /// Maximum torsion.
        twist_max_radians: f32,
    },

    /// Distance: a cord or spring with a min/max length.
    distance: struct {
        min: f32,
        max: f32,
    },

    /// Six DOF: independent limits on 3 translations (x/y/z) + 3 rotations
    /// (roll/pitch/yaw). To lock an axis, `min == max`; to free it,
    /// `min = -INF`, `max = +INF`.
    six_dof: struct {
        /// x, y, z — minimum translation.
        linear_min: Vec3,
        linear_max: Vec3,
        /// pitch, yaw, roll in radians — minimum rotation.
        angular_min: Vec3,
        angular_max: Vec3,
    },

    /// Pulley: ratio between the two cable lengths (body_a-pivot_a and
    /// body_b-pivot_b).
    pulley: struct {
        pivot_a_world: Vec3,
        pivot_b_world: Vec3,
        /// Ratio len_a / len_b.
        ratio: f32,
    },

    /// Gear: rotation ratio between two hinges.
    gear: struct {
        hinge_a: JointId,
        hinge_b: JointId,
        ratio: f32,
    },

    /// Rack and pinion: ratio between a rotation (hinge) and a translation
    /// (prismatic).
    rack_and_pinion: struct {
        hinge: JointId,
        prismatic: JointId,
        /// Radians per unit of translation.
        ratio: f32,
    },
};

/// A joint motor's mode.
///
/// **`.off` is NOT a variant.** A motor that is off is `motor: null` on the
/// descriptor, and `setJointMotor(id, null)` turns one off. Two ways to express
/// the same absence are two things that can diverge.
pub const JointMotorMode = enum { velocity, position };

/// A motor's target, **tagged by `joint_type`** — the same shape, the same
/// discipline and the same correspondence table as `JointLimits`. The descriptor
/// stays flat in the sense it already was: it CARRIES a tagged union, it does
/// not build one per branch.
///
/// | JointType         | Variant        | Target |
/// |-------------------|----------------|--------|
/// | `fixed`           | `.none`        | no motor — `motor` MUST be `null` |
/// | `hinge`           | `.scalar`      | rad (position) or rad/s (velocity) about `axis_a` |
/// | `ball_socket`     | `.none`        | no motor |
/// | `prismatic`       | `.scalar`      | m or m/s along `axis_a` |
/// | `cone_twist`      | `.swing_twist` | swing and twist, two independent axes |
/// | `distance`        | `.scalar`      | m or m/s on the cord |
/// | `six_dof`         | `.six_dof`     | three translations + three rotations |
/// | `pulley` / `gear` / `rack_and_pinion` | `.none` | no motor |
///
/// **One rule for the three levels of switching off, and one per fact:**
/// `motor = null` — no motor at all; an axis `mode` at `null` — that axis is
/// free; a single-axis joint has no second level, its axis being driven by
/// construction, else the motor does not exist.
pub const JointTarget = union(enum) {
    none: void,

    /// `hinge`, `prismatic`, `distance`.
    scalar: struct {
        mode: JointMotorMode,
        value: f32,
    },

    /// `cone_twist` — two independent axes, because the joint is. A scalar
    /// cannot name a swing.
    swing_twist: struct {
        swing_mode: ?JointMotorMode = null,
        swing_y_radians: f32 = 0,
        swing_z_radians: f32 = 0,
        twist_mode: ?JointMotorMode = null,
        twist_radians: f32 = 0,
    },

    /// `six_dof` — the same axes, the same order and the same convention as
    /// `JointLimits.six_dof`: linear x, y, z then pitch, yaw, roll.
    six_dof: struct {
        modes: [6]?JointMotorMode = .{ null, null, null, null, null, null },
        linear: Vec3 = Vec3.zero,
        angular: Vec3 = Vec3.zero,
    },
};

/// A joint's optional motor. Settings baked at creation by `createJoint`,
/// rewritten afterwards by `setJointMotor` — the descriptor carries the INITIAL
/// state, never the only state.
pub const JointMotor = struct {
    target: JointTarget,

    /// **Two ceilings and not one, because one could not be both.**
    /// `max_linear_force` is in newtons and governs the linear axes;
    /// `max_angular_torque` is in newton-metres and governs the angular ones.
    ///
    /// Revision 0.14 carried a single `max_force` justified by "the unit follows
    /// the driven axis". That "or" holds for a single-axis joint — `hinge`,
    /// `prismatic`, `distance` — and is FALSE for `six_dof`, which drives three
    /// linear and three angular axes SIMULTANEOUSLY: a scalar cannot be in
    /// newtons and in newton-metres at once. The variant the exclusion mattered
    /// for is precisely the one where it did not hold.
    ///
    /// A single-axis joint reads only the ceiling of its own nature and ignores
    /// the other. `swing_twist` reads `max_angular_torque` on both its axes.
    ///
    /// **`0` does NOT switch the motor off**: `null` does. Zero is a motor that
    /// is present and without authority, which the `.powered` ragdoll at
    /// `strength = 0` requires, the classic slack having to appear as a limit
    /// case of the same mechanism and not as a separate path.
    max_linear_force: f32 = 0,
    max_angular_torque: f32 = 0,

    /// `.position` mode only, ignored in `.velocity`. Soft servo, the same
    /// parametrisation as the solver's `contact_hertz` / `contact_damping_ratio`
    /// and as `JointLimits2D.wheel_spring`. Domain validated by `createJoint`
    /// and by `setJointMotor`: `frequency_hz > 0`, `damping_ratio >= 0`, both
    /// finite.
    ///
    /// **The four scalars are per MOTOR, never per axis**, and that property
    /// survives the correction above: naming two ceilings by axis NATURE is not
    /// naming them per axis. `six_dof` carries two ceilings and not six, and no
    /// variant of `JointTarget` carries a ceiling or a gain — which is what puts
    /// "never per axis" in the TYPE rather than in prose. Excluded on a
    /// structural motive and not deferred: the powered ragdoll's force profile is
    /// indexed by `BoneRole` (`ARCH-033`), not by axis.
    frequency_hz: f32 = 20,
    damping_ratio: f32 = 1,
};

/// Everything needed to create a joint.
///
/// **The descriptor is FLAT; the Etch `PhysicsJoint` component is not, and that
/// is not a divergence to reduce.** `engine-physics-forge.md` §5 declares the
/// authoring shape — a payload union the Etch grammar carries natively, which
/// puts under the author's eyes only the fields relevant to the type chosen. The
/// Tier 0 descriptor is the CALL shape: flat, copyable, branchless at
/// construction, and it is the one that is normative for the interface.
///
/// What was missing is neither shape but the PROJECTION between them, and the
/// Tier 1 service that translates the component into a descriptor carries it.
pub const JointDescriptor = struct {
    joint_type: JointType,
    body_a: BodyId,

    /// **`PackedId.dead` means ATTACHED TO THE WORLD**, and it is the
    /// translation of the component's `body_b: Entity = Entity.null`. The
    /// pattern is already reserved as "no handle", and "no second body" is
    /// exactly an instance of it: a joint attached to the world does not have a
    /// second body, it does not have a special second body. Written down because
    /// otherwise two readers draw two conclusions — and because `0` is a LIVE
    /// handle to slot 0 generation 0, the mistake already made once on
    /// `CharacterMoveResult.ground_body`.
    body_b: BodyId,

    anchor_a: Vec3 = Vec3.zero,
    anchor_b: Vec3 = Vec3.zero,

    /// Local axis in `body_a` (hinge, prismatic, cone_twist).
    axis_a: Vec3 = Vec3.unit_y,
    /// Local axis in `body_b`.
    axis_b: Vec3 = Vec3.unit_y,

    /// Limits specific to the joint type.
    limits: JointLimits = .none,

    /// Optional motor — INITIAL state. `setJointMotor` replaces it afterwards;
    /// the descriptor is not the motor's only state. `null` = no motor.
    motor: ?JointMotor = null,

    /// PRE-FREEZE EXTENSION (M1.1.15.2). The component has carried it all along
    /// and the descriptor did not: two jointed bodies passed through each other
    /// or collided depending on the solver, with no way for the author to
    /// decide.
    collide_connected: bool = false,

    /// Breakage: 0 = unbreakable, else the minimum force to break.
    break_force: f32 = 0,

    /// PRE-FREEZE EXTENSION (M1.1.15.2). Same motive as `collide_connected`: the
    /// component carries `break_force` AND `break_torque`, the descriptor had
    /// only the first — so a hinge could break in traction and never in torsion,
    /// and the authoring field was silently ignored.
    break_torque: f32 = 0,
};
