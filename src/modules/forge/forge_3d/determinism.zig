//! `forge_3d/determinism.zig` — the module's entry-point check on the floating-
//! point execution state (`ARCH-031` rule 5).
//!
//! `forge_3d` is a module whose output is compared between two machines, so the
//! invariant places an obligation on it that is one word long and easy to get
//! backwards: **assert, never install**. A module that re-installed the state at
//! its entry point would repair its own thread and leave every other consumer
//! of that thread — the renderer, the animation sampler, a plugin — running on
//! the state it just silently fixed, with no diagnostic anywhere. Installing is
//! Tier 0's job and happens once per thread, at creation
//! (`foundation/math/float_env.zig`, which names its three call sites).
//!
//! **Where the entry point is, today and tomorrow.** There is no
//! `PhysicsWorld.step()` yet — the orchestration lands at M1.1.15. What exists
//! is a per-tick driver in the acceptance harness, and the determinism harness
//! of this milestone. Both call `assertFloatEnvironment` when they open a
//! world; `step()` inherits the same call and nothing else moves. Naming the
//! seam before its production consumer exists is the pattern this repository
//! already used for the `on_attach` dispatch seam at M1.0.6.
//!
//! Note that the check is not decorative even inside a single process: the job
//! system installs the environment on the threads it creates, and a `forge_3d`
//! world opened on a thread nobody installed — a test runner's main thread, a
//! tool, a future plugin host — is exactly the case this reports.

const std = @import("std");
const float_env = @import("foundation").math.float_env;

/// The float-environment state of the calling thread, when it is NOT the state
/// the engine requires; `null` when the caller may proceed.
///
/// Returning the offending state rather than a `bool` is deliberate: the point
/// of the check is to be able to SAY what is wrong, and "the float environment
/// is not the engine's" is not an actionable message. On a target with no
/// readable control register the answer is `null` — the question is not
/// answerable there and a module entry point must not refuse to run because a
/// port has no `MXCSR` (`foundation/math/float_env.zig`, `controllable`).
pub fn checkFloatEnvironment() ?float_env.State {
    const state = float_env.read() orelse return null;
    if (state.eql(float_env.engine_default)) return null;
    return state;
}

/// Assert that the calling thread carries the engine float environment.
///
/// Compiled out in ReleaseFast like every other domain assert in this module
/// (`engine-physics-queries.md` §1.11.4 — *Domaine*). That is the established
/// arbitration here and not a weakening: the state is a property of the
/// PROCESS, established once at thread creation, so a Debug or ReleaseSafe run
/// of the same binary lineage catches it — unlike a per-call domain value,
/// which varies with the caller.
pub fn assertFloatEnvironment() void {
    std.debug.assert(checkFloatEnvironment() == null);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "determinism: the entry-point check passes on an engine thread" {
    try testing.expectEqual(@as(?float_env.State, null), checkFloatEnvironment());
    assertFloatEnvironment();
}

test "determinism: a perturbed float state is DETECTED" {
    if (!float_env.controllable) return error.SkipZigTest;

    // Perturbed through the OWNER's own writer, never by reaching for the
    // control register here: this test is about `forge_3d`'s reaction, and a
    // second copy of the register layout in a third file is exactly the drift
    // `foundation/math/float_env.zig` is written to prevent.
    const saved = float_env.save();
    defer float_env.restore(saved);
    float_env.installState(.{
        .rounding = .toward_zero,
        .flush_to_zero = false,
        .denormals_are_zero = false,
    });

    const observed = checkFloatEnvironment();
    try testing.expect(observed != null);
    try testing.expectEqual(float_env.Rounding.toward_zero, observed.?.rounding);
}

test "determinism: a perturbed float state is NOT repaired by the check" {
    // Separate block, and the separation is the point: detection and
    // non-repair are two claims, and a check that quietly re-installed would
    // satisfy the first while destroying the reason the second exists. Folded
    // together, the verdict would not say which half broke.
    if (!float_env.controllable) return error.SkipZigTest;

    const saved = float_env.save();
    defer float_env.restore(saved);
    float_env.installState(.{
        .rounding = .toward_zero,
        .flush_to_zero = false,
        .denormals_are_zero = false,
    });

    // Read it three times. A self-healing check would repair on the first and
    // report clean on the second.
    try testing.expect(checkFloatEnvironment() != null);
    try testing.expect(checkFloatEnvironment() != null);
    try testing.expectEqual(float_env.Rounding.toward_zero, checkFloatEnvironment().?.rounding);

    // And Tier 0's installer is what puts it back — the division of labour
    // stated in the file header, exercised rather than described.
    float_env.install();
    try testing.expectEqual(@as(?float_env.State, null), checkFloatEnvironment());
}

test "determinism: flushed denormals are detected too, not only a rounding mode" {
    // The check reads three fields; a test that only ever perturbs the rounding
    // mode would pass against an implementation that compares one of them. This
    // is that assertion's completeness half.
    if (!float_env.controllable) return error.SkipZigTest;

    const saved = float_env.save();
    defer float_env.restore(saved);
    float_env.installState(.{
        .rounding = .nearest_even,
        .flush_to_zero = true,
        .denormals_are_zero = true,
    });

    const observed = checkFloatEnvironment();
    try testing.expect(observed != null);
    try testing.expectEqual(float_env.Rounding.nearest_even, observed.?.rounding);
    try testing.expect(observed.?.flush_to_zero);
}
