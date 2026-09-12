//! Counter-proof 3 — a system registered without a declared access set.
//!
//! MUST NOT COMPILE. The descriptor literal omits `.accesses`, which used to
//! yield an empty set by default — the value that declares zero conflict with
//! everything and lands the system at topological level 0.
//!
//! The diagnostic this case matches is the COMPILER's own missing-field
//! message and not the view's refusal marker, because the refusal here is
//! structural rather than semantic: there is no access to test, only a field
//! that is no longer optional.

const ecs = @import("weld_core").ecs;

fn body(_: ecs.SystemContext) anyerror!void {}

const descriptor = ecs.SystemDescriptor{
    .phase = .update,
    .name = "missing_accesses",
    .run = body,
};

comptime {
    _ = descriptor;
}
