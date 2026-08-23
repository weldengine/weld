//! Test root for the linter's own unit tests.
//!
//! A `test` block runs only if the compiler ANALYSES the file holding it, and
//! Zig analyses declarations lazily. Two forms were tried at M1.1.14 and only
//! one works — measured, by appending a deliberately failing test to a rule and
//! watching for red:
//!
//!   - `addTest` rooted at `main.zig`, which reaches the rules through plain
//!     `const` imports: ran NOTHING and reported success.
//!   - This file as the root with `pub const` re-exports: also ran nothing —
//!     `zig test` reported "All 0 tests passed" over nine re-exported files, one
//!     of them holding eight test blocks. A `pub` declaration nobody references
//!     is still not analysed.
//!   - The `comptime` block below, which REFERENCES each import: runs them.
//!
//! `usingnamespace` is forbidden (`engine-zig-conventions.md`), and it would not
//! have helped either — the question is analysis, not namespacing.
//!
//! WHAT THIS LAYER PROVES, and what it does not. It proves each rule's LOGIC:
//! how many diagnostics a source yields, where an escape hatch reaches, whether
//! prose naming a construct is mistaken for a use of it. It cannot prove a rule
//! is WIRED into `runLint` — a rule deleted from `main.zig` passes every test
//! here. That is what the fixture corpus under `tests/lint/` is for: it runs the
//! real binary and reads its exit code. Neither layer substitutes for the other,
//! and a rule wants both.

comptime {
    // Rules.
    _ = @import("rules/no_cimport.zig");
    _ = @import("rules/no_usingnamespace.zig");
    _ = @import("rules/doc_comments.zig");
    _ = @import("rules/c_module_isolation.zig");
    _ = @import("rules/no_device_dispatch_outside_gal.zig");
    _ = @import("rules/no_float_reduce.zig");
    _ = @import("rules/no_precision_crossing.zig");
    _ = @import("rules/conventional_commit.zig");
    // Shared machinery.
    // `main.zig` too: the lint subcommand's own path-coverage logic lives there, and a
    // helper nobody elaborates is a helper nobody tests.
    _ = @import("main.zig");
    _ = @import("dead_tests.zig");
    _ = @import("scan.zig");
    _ = @import("diagnostic.zig");
}
