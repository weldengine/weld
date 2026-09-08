//! Facade module for `tests/bindings/`: Zig 0.16 refuses a file in two module roots.

/// Re-export for `tests/bindings/wayland_abi_test.zig`.
pub const core = @import("core.zig");
/// Re-export for `tests/bindings/wayland_abi_test.zig`.
pub const xdg_shell = @import("xdg_shell.zig");
/// Re-export for `tests/bindings/wayland_abi_test.zig`.
pub const xdg_decoration = @import("xdg_decoration.zig");
