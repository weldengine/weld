//! Single-module facade for out-of-tree wayland-protocol bindings tests
//! in `tests/bindings/`. Zig 0.16 forbids one file from belonging to
//! two modules, so we can't expose `core.zig`, `xdg_shell.zig` and
//! `xdg_decoration.zig` as three separate modules (the latter two
//! `@import("core.zig")` would clash with a module rooted at the same
//! file). This facade owns the wayland_protocols subdir and re-exports
//! the three pieces tests need.

/// Re-exports the generated core `wayland.xml` bindings.
pub const core = @import("core.zig");
/// Re-exports the generated `xdg-shell.xml` bindings.
pub const xdg_shell = @import("xdg_shell.zig");
/// Re-exports the generated `xdg-decoration-unstable-v1.xml` bindings.
pub const xdg_decoration = @import("xdg_decoration.zig");
