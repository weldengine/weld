//! End-to-end proof of the Phase 1 tree-walker service path (M1.1.15.2 G2,
//! `etch-abi-zig.md` §8.7): a `.d.etch` declares, the type-checker resolves, the
//! interpreter dispatches into an ordinary Zig function, and a Zig error union
//! comes back as an Etch `throw` a `try` / `catch` consumes.
//!
//! The declaration and the call CANNOT share a file — a call needs a body,
//! bodies are refused in a `.d.etch`, and `service` is refused in a `.etch` — so
//! every case here runs the two-file project shape, which is also the deployed
//! one (§20.5).

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");
const toy = @import("toy_service.zig");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;
const parser = weld_etch.parser;
const types = weld_etch.types;
const services = weld_etch.services;
const Diagnostic = weld_etch.diagnostics.Diagnostic;
const DiagnosticCode = weld_etch.diagnostics.DiagnosticCode;
const AstArena = weld_etch.Ast;

/// Parse the toy's declaration file plus a caller source, type-check the caller
/// against it, then run the caller's rules for one tick with the toy service
/// registered. Returns the checker diagnostics and the accumulator component's
/// two fields, so a test can assert on either side.
const Outcome = struct {
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    arenas: [2]AstArena,
    exports: [2]types.TypeChecker.ExportTable = .{ .empty, .empty },
    prefabs: std.StringHashMapUnmanaged(void) = .empty,
    uuids: std.StringHashMapUnmanaged(void) = .empty,
    module_index: std.StringHashMapUnmanaged(usize) = .empty,
    out: i64 = 0,
    err_out: i64 = 0,
    msg_len: i64 = 0,
    calls: u32 = 0,
    runtime_errors: u64 = 0,

    fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        for (self.diagnostics.items) |*d| d.deinit(gpa);
        self.diagnostics.deinit(gpa);
        for (&self.arenas) |*a| a.deinit(gpa);
        for (&self.exports) |*e| e.deinit(gpa);
        self.prefabs.deinit(gpa);
        self.uuids.deinit(gpa);
        self.module_index.deinit(gpa);
    }
};

const accumulator =
    \\component Acc { out: int = 0, err_out: int = 0, msg_len: int = 0 }
;

/// `check_only` stops after the type-checker, for the cases whose subject IS a
/// diagnostic — running a program the checker rejected would prove nothing and
/// could fail for an unrelated reason.
fn run(gpa: std.mem.Allocator, caller_src: []const u8, check_only: bool) !Outcome {
    var decl_pr = try parser.parseWithMode(gpa, toy.declaration_source, .declaration_file);
    errdefer decl_pr.deinit(gpa);
    var caller_pr = try parser.parse(gpa, caller_src);
    errdefer caller_pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), decl_pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), caller_pr.diagnostics.len);
    gpa.free(decl_pr.diagnostics);
    gpa.free(caller_pr.diagnostics);

    var out: Outcome = .{ .diagnostics = .empty, .arenas = .{ decl_pr.ast, caller_pr.ast } };
    errdefer out.deinit(gpa);

    const ctx: types.TypeChecker.ProjectContext = .{
        .prefabs = &out.prefabs,
        .uuids = &out.uuids,
        .module_index = &out.module_index,
        .exports = &out.exports,
        .arenas = &out.arenas,
    };
    try types.TypeChecker.checkProject(gpa, &out.arenas[1], &out.diagnostics, &ctx);
    if (check_only) return out;

    var world = World.init();
    defer world.deinit(gpa);

    var svc_ctx: toy.Ctx = .{};
    var registry: services.Registry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, &toy.spec, &svc_ctx);

    var interp = try weld_etch.Interpreter.compile(gpa, &out.arenas[1], &world);
    defer interp.deinit();
    interp.setServiceRegistry(&registry);

    const cid = world.registry.idOf("Acc").?;
    const eid = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    const report = try interp.runFor(&world, 1);
    out.runtime_errors = report.runtime_errors;
    out.calls = svc_ctx.calls;

    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const slot = arch.componentSlot(arch.chunks.items[loc.chunk_idx], arch.componentIndex(cid).?, loc.slot);
    @memcpy(std.mem.asBytes(&out.out), slot[0..8]);
    @memcpy(std.mem.asBytes(&out.err_out), slot[8..16]);
    @memcpy(std.mem.asBytes(&out.msg_len), slot[16..24]);
    return out;
}

fn expectCode(diagnostics: []const Diagnostic, code: DiagnosticCode) !void {
    for (diagnostics) |d| if (d.code == code) return;
    return error.DiagnosticCodeNotEmitted;
}

test "toy service call returns its value to the rule" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).out = toy.echo(5)
        \\}
    , false);
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.items.len);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    // 100 (the service's own state) + 5 (the rule's argument). Neither operand
    // alone would produce this, so the value crossed in both directions.
    try std.testing.expectEqual(@as(i64, 105), r.out);
    // And the implementation really ran, rather than the value arriving from
    // somewhere on the way.
    try std.testing.expectEqual(@as(u32, 1), r.calls);
}

test "a service string argument and result cross in both directions" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let s = toy.label("abc")
        \\  entity.get_mut(Acc).msg_len = s.len()
        \\}
    , false);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.items.len);
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    // "abc" in, "abc!" out — the length changes, so the string was READ by the
    // service and not echoed by the dispatch.
    try std.testing.expectEqual(@as(i64, 4), r.msg_len);
    try std.testing.expectEqual(@as(u32, 1), r.calls);
}

test "failing toy method propagates to try/catch" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let acc = entity.get_mut(Acc)
        \\  try {
        \\    acc.out = toy.risky(2)
        \\    acc.out = toy.risky(5)
        \\    acc.out = 999
        \\  } catch err {
        \\    acc.err_out = 7
        \\    acc.msg_len = err.message.len()
        \\  }
        \\}
    , false);
    defer r.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.items.len);
    // A caught throw is NOT a runtime error: the rule handled it.
    try std.testing.expectEqual(@as(u64, 0), r.runtime_errors);
    // The FIRST call succeeded and its value landed, so the second one's failure
    // is the implementation's and not a dispatch that never worked.
    try std.testing.expectEqual(@as(i64, 20), r.out);
    try std.testing.expectEqual(@as(i64, 7), r.err_out);
    // `@errorName(error.TooBig)` is "TooBig" — six bytes. The message carries the
    // Zig error name verbatim, which is the whole of what survives the crossing.
    try std.testing.expectEqual(@as(i64, 6), r.msg_len);
    // Both calls ran; the statement AFTER the failing one did not (out stayed 20).
    try std.testing.expectEqual(@as(u32, 2), r.calls);
}

test "a throwing service call with no try is E0902" {
    const gpa = std.testing.allocator;
    var r = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).out = toy.risky(1)
        \\}
    , true);
    defer r.deinit(gpa);
    try expectCode(r.diagnostics.items, .unhandled_throws_call);
    try std.testing.expectEqualStrings("E0902", r.diagnostics.items[0].code.code());

    // COUNTERFACTUAL ON THE OBJECT: the same call inside a `try` is clean, and
    // the NON-throwing method is clean outside one. Without the second, E0902
    // would also pass against a checker that flagged every service call.
    var wrapped = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  try {
        \\    entity.get_mut(Acc).out = toy.risky(1)
        \\  } catch err {
        \\    entity.get_mut(Acc).err_out = 1
        \\  }
        \\}
    , true);
    defer wrapped.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), wrapped.diagnostics.items.len);

    var infallible = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).out = toy.echo(1)
        \\}
    , true);
    defer infallible.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), infallible.diagnostics.items.len);
}

test "a local shadows a service, in the checker and in the interpreter alike" {
    const gpa = std.testing.allocator;
    // The two layers agree on what a service call is, and the proof is that they
    // agree on what one is NOT. A local named `toy` takes the name back, so the
    // checker reports an ordinary receiver with no such method rather than
    // resolving the service.
    var r = try run(gpa, accumulator ++
        \\
        \\rule use_service(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let toy = 1
        \\  entity.get_mut(Acc).out = toy.echo(5)
        \\}
    , true);
    defer r.deinit(gpa);
    try std.testing.expect(r.diagnostics.items.len > 0);
    for (r.diagnostics.items) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.primary_message, "service") == null);
    }
}
