//! Explicit manifest of the Tier 1 modules exposing services to Etch
//! (M1.1.15.2 G3, `engine-c-bindings.md` §8.4.2).
//!
//! Explicit and not auto-discovered, for the reason §8.4.2 gives: Zig cannot
//! scan a source directory at comptime, and "explicit > magic" means a module
//! must be ADDED here for its services to reach Etch — no service silently
//! inactive because a manifest went unupdated. The emitter walks each entry's
//! declarations with `@typeInfo` and takes every `pub const` whose type is
//! `services.ServiceSpec`.
//!
//! `entries` is a comptime tuple and not a slice because each entry carries a
//! `type`, which no runtime array can hold.

const std = @import("std");
const services = @import("weld_etch").services;

/// One manifest row: a module, where it lives, and where its artifacts go.
pub const Entry = struct {
    /// The module holding one or more `pub const … : services.ServiceSpec`.
    module: type,
    /// Repo-relative path of that module, written into the artifact's header so
    /// a reader reaches the Zig source from the `.d.etch`.
    source_path: []const u8,
    /// Repo-relative directory the `.d.etch` files land in.
    output_dir: []const u8,
};

/// The toy service is a PERMANENT entry, not a placeholder. `etch-abi-zig.md`
/// §8.7 requires the interop gates to prove themselves on a toy and never on the
/// physics, which is only the first consumer — so the toy is what keeps the
/// emitter exercised end to end, and `bindgen-check` guards its artifact exactly
/// as it will guard the physics one. It is also why this manifest reaches into
/// `tests/`: the alternative, a second test-only manifest, would leave the toy
/// unguarded by the production check.
pub const entries = .{
    Entry{
        .module = @import("toy_service"),
        .source_path = "tests/etch_services/toy_service.zig",
        .output_dir = "tests/etch_services",
    },
};

/// Every `ServiceSpec` an entry's module declares, in declaration order.
/// Comptime because the answer is a property of the source.
pub fn specsOf(comptime entry: Entry) []const services.ServiceSpec {
    comptime {
        var found: []const services.ServiceSpec = &.{};
        for (@typeInfo(entry.module).@"struct".decls) |d| {
            const T = @TypeOf(@field(entry.module, d.name));
            if (T != services.ServiceSpec) continue;
            found = found ++ [_]services.ServiceSpec{@field(entry.module, d.name)};
        }
        return found;
    }
}

/// Repo-relative path of the artifact for one spec (§8.4.2:
/// `<output_dir>/<spec.name>.d.etch`).
pub fn artifactPath(gpa: std.mem.Allocator, entry: Entry, spec: services.ServiceSpec) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}.d.etch", .{ entry.output_dir, spec.name });
}
