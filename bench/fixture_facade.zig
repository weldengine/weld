//! Shared fixture facade — `@embedFile` cannot escape the package root of
//! the module that invokes it, so both the bench (`bench/etch_interp.zig`)
//! and the demo binary (`src/demo_etch_interp.zig`) reach the fixed
//! 5-rule program via this small module declared in `build.zig`.

/// Embedded source of the S4 demo Etch program (5 rules × 1 000 entities).
pub const demo_5_rules_etch: []const u8 = @embedFile("fixtures/demo_5_rules.etch");
