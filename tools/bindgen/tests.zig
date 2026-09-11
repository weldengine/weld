//! Test root for the bindgen tool's own unit tests.
//!
//! `main.zig` reaches its adapters through plain `const` imports, which a test
//! build does not analyse, so rooting a test target there collects NOTHING: the
//! target builds and the suite total does not move. Only a `comptime` block that
//! REFERENCES each import collects their tests.
//! Same trap as `tools/weld_lint/tests.zig` and `src/etch/root.zig`; see
//! `engine-zig-conventions.md` §13.

comptime {
    _ = @import("adapters/vk_xml/parser.zig");
    _ = @import("core/api_description.zig");
    _ = @import("core/emitter.zig");
    _ = @import("core/resolver.zig");
    _ = @import("core/validator.zig");
}
