//! Test root for the bindgen tool's own unit tests.
//!
//! `main.zig` reaches its adapters through plain `const` imports, which a test
//! build does not analyse, so rooting a test target there collects NOTHING —
//! measured at M1.1.14: the target was added, the suite total moved by zero.
//! Only a `comptime` block that REFERENCES each import collects their tests.
//! Same trap as `tools/weld_lint/tests.zig` and `src/etch/root.zig`; see
//! `engine-zig-conventions.md` §13.

comptime {
    _ = @import("adapters/vk_xml/parser.zig");
    _ = @import("core/api_description.zig");
    _ = @import("core/emitter.zig");
    _ = @import("core/resolver.zig");
    _ = @import("core/validator.zig");
}
