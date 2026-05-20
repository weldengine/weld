//! Single-module facade for out-of-tree spike tests in `tests/spike/`.
//!
//! Zig 0.16 forbids the same file from belonging to two different module
//! trees, so we can't expose `cli.zig` and `scoring.zig` as two separate
//! modules (the scorer's `@import("cli.zig")` would then conflict with a
//! `spike_cli` module rooted at the same file). This facade owns the
//! spike subdir as one module and re-exports the pieces tests reach for.
//!
//! Lives next to the rest of `src/spike/` so it is automatically scoped
//! to the same throwaway-code blast radius as the other spike files.

/// `tests/spike/cli_test.zig` consumes this via `@import("spike").cli`
/// because Zig 0.16 rejects a file that belongs to two module roots
/// at once — the spike subdir lives behind this facade module.
pub const cli = @import("cli.zig");
/// Same rationale as `cli` — consumed by `tests/spike/scoring_test.zig`.
pub const scoring = @import("scoring.zig");
