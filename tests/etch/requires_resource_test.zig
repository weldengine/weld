//! `@requires` naming a resource is refused (`engine-ecs-internals.md` §3): by
//! the checker, by the registry when a program is compiled unchecked, by the
//! scene cook, and by the codegen, which carries no `@requires` at all.

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const Interpreter = weld_etch.Interpreter;

/// Whether checking `src` reports a diagnostic whose message holds `needle`.
fn reports(src: []const u8, needle: []const u8) !bool {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.primary_message, needle) != null) return true;
    }
    return false;
}

test "a declared resource named by @requires is refused by the checker" {
    try std.testing.expect(try reports(
        \\resource R { x: int = 0 }
        \\@requires(R)
        \\component C { y: int = 0 }
    , "@requires names `R`, which is a resource"));
}

test "a builtin resource named by @requires is refused by the checker" {
    try std.testing.expect(try reports(
        \\@requires(GameTime)
        \\component C { y: int = 0 }
    , "@requires names `GameTime`, which is a resource"));
}

test "a host resource named by @requires is refused by an unchecked compile" {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa,
        \\@requires(HostRes)
        \\component C { y: int = 0 }
    );
    defer pr.deinit(gpa);
    var world = World.init();
    defer world.deinit(gpa);
    _ = try world.registry.registerComponentRaw(gpa, .{
        .name = "HostRes",
        .size = 8,
        .alignment = 8,
        .default_bytes = &[_]u8{0} ** 8,
        .fields = &.{},
        .kind = .resource,
    });
    try std.testing.expectError(error.RequisiteIsResource, Interpreter.compile(gpa, &pr.ast, &world));
}

test "a scene whose component requires a resource is refused by the cook" {
    var msg: []const u8 = "";
    try std.testing.expectError(error.RequisiteIsResource, weld_etch.scene_cook.cook(std.testing.allocator,
        \\resource R { x: int = 0 }
        \\@requires(R)
        \\component C { y: int = 0 }
        \\scene "S" {
        \\  entity "E" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" C { } }
        \\}
    , &msg));
    try std.testing.expect(msg.len > 0);
}

test "the codegen refuses a component carrying @requires" {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa,
        \\component B { x: int = 0 }
        \\@requires(B)
        \\component C { y: int = 0 }
    );
    defer pr.deinit(gpa);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try std.testing.expectError(error.RequiresUnsupported, weld_etch.codegen_zig.lower.generateFile(gpa, &pr.ast, "requires_resource_test.etch", &buf));
}
