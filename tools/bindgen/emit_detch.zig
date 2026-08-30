//! `bindgen.ServiceSpec` → `.d.etch` emitter (M1.1.15.2 G3,
//! `engine-c-bindings.md` §8.4, format per `etch-abi-zig.md` §8.2).
//!
//! Emission direction Zig → Etch, the mirror of the `.api.zig` → Zig pipeline
//! the rest of `tools/bindgen/` carries. The SOURCE OF TRUTH is the Zig
//! `ServiceSpec`; a `.d.etch` is a DERIVED artifact, committed so the language
//! server and a reviewer can read a service's surface without reading Zig, and
//! never edited by hand (§8.4.1, §8.4.5).
//!
//! The emitter makes no policy: it renders what the spec carries. In particular
//! it never invents a version (§8.4.6), and the method order is the `.methods`
//! array's (§8.4.3) — so a reordering in Zig shows up as a diff rather than
//! being silently normalised away.

const std = @import("std");
const services = @import("weld_etch").services;

/// `@version` sits BEFORE `service`, in prefix position.
///
/// `engine-c-bindings.md` §8.4.3's example writes it INSIDE the braces, and
/// that placement is unrealisable: `etch-grammar.md` §20.4's `service_decl` has
/// no production for an annotation between the braces, and the parser attaches a
/// leading annotation run to the declaration that FOLLOWS it — so inside the
/// braces it would bind to the first method, not to the service. Settled in
/// prefix position at the G1 gate signal; the KB carries the correction.
/// Measured: the prefix form parses clean and the type-checker is silent on it.
///
/// Nothing reads it in Phase 1. The confrontation §8.5 describes happens at
/// `.etchc` load, which does not exist before Phase 2; the annotation is written
/// now because the artifact is committed now and a version added later would
/// diff every file.
pub const version_annotation = "@version";

/// The header every generated artifact carries (§8.4.1). `bindgen-lint`'s
/// "no hand-written `.d.etch`" rule keys on it; that rule is §9.2's and is not
/// part of this gate.
pub const header_line = "// AUTO-GENERATED — DO NOT EDIT";

/// Render one service's `.d.etch`. `source_path` and `emitter_path` are
/// repo-relative and land in the header, so a reader of the artifact can reach
/// both the Zig it came from and the code that wrote it.
pub fn emit(
    w: *std.Io.Writer,
    spec: services.ServiceSpec,
    source_path: []const u8,
    emitter_path: []const u8,
) !void {
    try w.print("{s}\n", .{header_line});
    try w.print("// Source: {s}\n", .{source_path});
    try w.print("// Emitter: {s}\n", .{emitter_path});
    try w.print("\n{s}({d})\n", .{ version_annotation, spec.version });
    try w.print("service {s} {{\n", .{spec.name});
    for (spec.methods, 0..) |m, i| {
        if (i != 0) try w.writeAll("\n");
        if (m.doc) |d| try w.print("  /// {s}\n", .{d});
        try w.print("  fn {s}(", .{m.name});
        for (m.params, 0..) |p, pi| {
            if (pi != 0) try w.writeAll(", ");
            try w.print("{s}: {s}", .{ p.name, p.type.etchName() });
        }
        try w.writeAll(")");
        // §20.1 `function_decl_no_body` orders these exactly so: `throws`
        // BEFORE the return arrow.
        if (m.throws) try w.writeAll(" throws");
        // A void return renders as NO arrow clause at all, which is what §20.1
        // means by the arrow being optional — `-> void` is not a form.
        if (m.returns != .void_) try w.print(" -> {s}", .{m.returns.etchName()});
        try w.writeAll("\n");
    }
    try w.writeAll("}\n");
}

/// Render one event's `.d.etch` (M1.1.15.2 G4). Its own artifact rather than a
/// section of the service's, because §8.4.2 emits one file per SPEC and a module
/// may publish events without publishing a service.
pub fn emitEvent(
    w: *std.Io.Writer,
    spec: services.EventSpec,
    source_path: []const u8,
    emitter_path: []const u8,
) !void {
    try w.print("{s}\n", .{header_line});
    try w.print("// Source: {s}\n", .{source_path});
    try w.print("// Emitter: {s}\n\n", .{emitter_path});
    if (spec.doc) |d| try w.print("/// {s}\n", .{d});
    try w.print("event {s} {{\n", .{spec.name});
    for (spec.fields) |f| {
        try w.print("  {s}: {s} = ", .{ f.name, f.type.etchName() });
        switch (f.default) {
            .int_ => |v| try w.print("{d}", .{v}),
            // Rendered through `{d}` so an integral float still carries a
            // decimal point — `0` would parse as an `int` literal and the field
            // would be typed against the wrong builtin.
            .float_ => |v| try w.print("{d:.1}", .{v}),
            .bool_ => |v| try w.print("{s}", .{if (v) "true" else "false"}),
            .string_ => |v| try w.print("\"{s}\"", .{v}),
        }
        try w.writeAll("\n");
    }
    try w.writeAll("}\n");
}

/// Render into an owned buffer. The caller frees.
pub fn emitAlloc(
    gpa: std.mem.Allocator,
    spec: services.ServiceSpec,
    source_path: []const u8,
    emitter_path: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try emit(&aw.writer, spec, source_path, emitter_path);
    return aw.toOwnedSlice();
}

/// `emitEvent` into an owned buffer. The caller frees.
pub fn emitEventAlloc(
    gpa: std.mem.Allocator,
    spec: services.EventSpec,
    source_path: []const u8,
    emitter_path: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try emitEvent(&aw.writer, spec, source_path, emitter_path);
    return aw.toOwnedSlice();
}

/// One line of a unified-style difference between an expected and an actual
/// rendering. Kept structural rather than pre-formatted so the caller decides
/// where it prints.
pub const DiffLine = struct {
    kind: enum { same, expected_only, actual_only },
    line_no: usize,
    text: []const u8,
};

/// Line-by-line comparison, as §8.4.4 requires of `bindgen-check`. Lines are
/// compared positionally, which is enough for a generated artifact: the
/// emitter's output is a pure function of the spec, so a divergence is always a
/// local edit or a spec change and never a re-flow.
pub fn diff(
    gpa: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
    out: *std.ArrayListUnmanaged(DiffLine),
) !bool {
    var e_it = std.mem.splitScalar(u8, expected, '\n');
    var a_it = std.mem.splitScalar(u8, actual, '\n');
    var n: usize = 0;
    var differs = false;
    while (true) {
        const e = e_it.next();
        const a = a_it.next();
        if (e == null and a == null) break;
        n += 1;
        if (e != null and a != null and std.mem.eql(u8, e.?, a.?)) {
            try out.append(gpa, .{ .kind = .same, .line_no = n, .text = e.? });
            continue;
        }
        differs = true;
        if (e) |t| try out.append(gpa, .{ .kind = .expected_only, .line_no = n, .text = t });
        if (a) |t| try out.append(gpa, .{ .kind = .actual_only, .line_no = n, .text = t });
    }
    return differs;
}
