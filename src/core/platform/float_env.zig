//! `core/platform/float_env.zig` — the platform layer's INSTALLATION of the
//! engine's floating-point environment (`ARCH-031` rule 5, `engine-platform.md`
//! §4 — *Threading*).
//!
//! The mechanism — the register layouts and their decode — lives in
//! `foundation/float_env.zig` and is not duplicated here. What lives here is
//! the TIER RULE, at the only place where its callers can read it:
//!
//! > Round-to-nearest-even with denormals preserved is **installed by the
//! > platform layer**, at process init for the main thread and at every engine
//! > thread spawn. A module never installs it. A module whose output is
//! > compared **asserts** it at its own entry point.
//!
//! Both halves of that rule have a reason that is not stylistic. A module that
//! installed the state would leave divergent every thread it did not create —
//! and since the job system is work-stealing, that is most of them, including
//! the main thread, which is not born of a spawn. A module that re-installed
//! the state at its entry point instead of asserting would MASK the defect
//! rather than report it, and leave every other consumer of that thread running
//! on the state it just silently repaired.
//!
//! The layer has no single `init` entry point today: `threading.zig` propagates
//! `std.Thread` as-is (it is FROZEN at C0.5 and adds only `setAffinity` /
//! `setPriority`), so there is no `spawn_thread` of Weld's own to hook. The
//! call sites are therefore named individually and are exactly three:
//!
//! 1. `core/jobs/scheduler.zig`, at the head of `workerMain` — the engine's
//!    thread-spawn path, and the site `ARCH-031` rule 5 names by role;
//! 2. `runtime/main.zig`, first statement — the runtime process's main thread;
//! 3. `editor/main.zig`, first statement — the editor process's main thread.
//!
//! When a real `platform.init()` lands, those three calls move into it and
//! nothing else changes.

const std = @import("std");
const foundation = @import("foundation");

/// IEEE-754 rounding direction. Re-export — see `foundation/float_env.zig`.
pub const Rounding = foundation.float_env.Rounding;
/// The three properties of the float environment that change a result.
pub const State = foundation.float_env.State;
/// The state `ARCH-031` rule 5 requires on every engine thread.
pub const engine_default = foundation.float_env.engine_default;
/// Whether this target exposes a readable/writable float control register.
pub const controllable = foundation.float_env.controllable;
/// The float environment of the calling thread, or `null` on a target with no
/// control register this engine knows.
pub const read = foundation.float_env.read;
/// Whether the calling thread carries `engine_default`.
pub const isEngineDefault = foundation.float_env.isEngineDefault;

/// Install `engine_default` on the calling thread.
///
/// **Platform layer only.** The three call sites are listed in the file header;
/// a fourth one in a module is a defect, not an extension.
pub fn install() void {
    foundation.float_env.install();
}

test "platform.float_env: the facade forwards to the one owner" {
    // Not a tautology test. It pins that this file is a FACADE: if someone ever
    // gives it a second copy of the register layout — the drift shape this
    // repository has already paid for once — the two would have to be kept
    // equal, and the first thing to break would be this identity.
    try std.testing.expectEqual(foundation.float_env.controllable, controllable);
    try std.testing.expect(engine_default.eql(foundation.float_env.engine_default));

    install();
    try std.testing.expectEqual(foundation.float_env.isEngineDefault(), isEngineDefault());
}
