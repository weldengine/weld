//! Test root for `ci_verdict`. The `comptime` block references each file, which
//! is what makes the compiler analyse, and therefore run, its tests.

comptime {
    _ = @import("verdict.zig");
    _ = @import("guard.zig");
    _ = @import("main.zig");
}
