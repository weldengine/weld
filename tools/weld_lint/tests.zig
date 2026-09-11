//! Test root for the linter's own unit tests.
//!
//! A `test` block runs only if the compiler ANALYSES the file holding it, and
//! Zig analyses declarations lazily. Only the third form below runs anything, and
//! the other two must NOT be restored — a green run over them means nothing ran:
//!
//!   - `addTest` rooted at `main.zig`, reaching the rules through plain `const`
//!     imports: runs NOTHING and reports success.
//!   - this file as the root with `pub const` re-exports: also runs nothing —
//!     `zig test` reports "All 0 tests passed" over every re-exported file. A
//!     `pub` declaration nobody references is still not analysed.
//!   - the `comptime` block below, which REFERENCES each import: runs them.
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
    _ = @import("rules/no_cimport.zig");
    _ = @import("rules/no_usingnamespace.zig");
    _ = @import("rules/doc_comments.zig");
    _ = @import("rules/c_module_isolation.zig");
    _ = @import("rules/no_device_dispatch_outside_gal.zig");
    _ = @import("rules/no_float_reduce.zig");
    _ = @import("rules/no_precision_crossing.zig");
    _ = @import("rules/conventional_commit.zig");
    _ = @import("rules/comment_identifiers.zig");
    _ = @import("rules/comment_tags.zig");
    // `main.zig` too: the lint subcommand's own logic lives there, and a helper
    // nobody elaborates is a helper nobody tests.
    _ = @import("main.zig");
    _ = @import("dead_tests.zig");
    _ = @import("scan.zig");
    _ = @import("diagnostic.zig");
    _ = @import("census.zig");
    _ = @import("comment_scan.zig");
}
