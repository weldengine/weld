//! Single-module facade for out-of-tree wayland-protocol bindings tests
//! in `tests/bindings/`. Zig 0.16 forbids one file from belonging to
//! two modules, so we can't expose `core.zig`, `xdg_shell.zig` and
//! `xdg_decoration.zig` as three separate modules (the latter two
//! `@import("core.zig")` would clash with a module rooted at the same
//! file). This facade owns the wayland_protocols subdir and re-exports
//! the three pieces tests need.

/// `tests/bindings/wayland_abi_test.zig` consumes this module via
/// `@import("wl_protocols").core` to drive ABI tests that import
/// `core.zig`'s siblings indirectly. Cannot inline because Zig 0.16
/// rejects a file that belongs to two module roots simultaneously.
pub const core = @import("core.zig");
/// Same rationale as `core` — exposed for `wayland_abi_test.zig`.
pub const xdg_shell = @import("xdg_shell.zig");
/// Same rationale as `core` — exposed for `wayland_abi_test.zig`.
pub const xdg_decoration = @import("xdg_decoration.zig");
