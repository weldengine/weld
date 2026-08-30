//! The Tier 0 → Etch event bridge, and the ORDER that is its deliverable
//! (M1.1.15.2 G4).
//!
//! The store carries a `Lifetime.tick` and is cleared at the head of every tick.
//! A bridge that pushed on the WRONG SIDE of that clear would produce an event
//! emitted, never observed, and no red anywhere — so the tests below are written
//! to fail in exactly that case, and the multi-tick shape is what does it: a
//! before-clear drain loses every event, and a missing clear leaks tick N's
//! event into tick N+1. One outcome assertion could not tell those apart.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");
const toy = @import("toy_service");

const World = weld_core.ecs.world.World;
const EventQueue = weld_core.events.EventQueue;
const EventCursor = weld_core.events.EventCursor;
const Lifetime = weld_core.events.Lifetime;
const types = weld_etch.types;
const AstArena = weld_etch.Ast;
const Diagnostic = weld_etch.diagnostics.Diagnostic;
const Bridge = weld_etch.event_bridge.Bridge;

/// A rule that counts what it observes AND records the last payload, so a test
/// can tell "observed nothing" from "observed the wrong one".
const observer_source =
    \\resource Tally { seen: int = 0, last: int = 0, loud_seen: int = 0 }
    \\@on_event(ToyPing)
    \\rule absorb()
    \\  when resource Tally
    \\{
    \\  let t = get_mut(Tally)
    \\  t.seen += 1
    \\  t.last = event.value
    \\  if event.loud { t.loud_seen += 1 }
    \\}
;

const Harness = struct {
    arenas: [2]AstArena,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    exports: [2]types.TypeChecker.ExportTable = .{ .empty, .empty },
    prefabs: std.StringHashMapUnmanaged(void) = .empty,
    uuids: std.StringHashMapUnmanaged(void) = .empty,
    module_index: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *Harness, gpa: std.mem.Allocator) void {
        for (self.diagnostics.items) |*d| d.deinit(gpa);
        self.diagnostics.deinit(gpa);
        for (&self.arenas) |*a| a.deinit(gpa);
        for (&self.exports) |*e| e.deinit(gpa);
        self.prefabs.deinit(gpa);
        self.uuids.deinit(gpa);
        self.module_index.deinit(gpa);
    }
};

/// Parse the EMITTED `ToyPing.d.etch` plus a caller, and type-check the caller
/// against it. The declaration is the generated artifact — the one
/// `bindgen-check` guards — never a literal written here.
fn check(gpa: std.mem.Allocator, caller_src: []const u8) !Harness {
    var decl_pr = try weld_etch.parser.parseWithMode(gpa, toy.ping_declaration_source, .declaration_file);
    errdefer decl_pr.deinit(gpa);
    var caller_pr = try weld_etch.parser.parse(gpa, caller_src);
    errdefer caller_pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), decl_pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), caller_pr.diagnostics.len);
    gpa.free(decl_pr.diagnostics);
    gpa.free(caller_pr.diagnostics);

    var h: Harness = .{ .arenas = .{ decl_pr.ast, caller_pr.ast }, .diagnostics = .empty };
    errdefer h.deinit(gpa);
    const ctx: types.TypeChecker.ProjectContext = .{
        .prefabs = &h.prefabs,
        .uuids = &h.uuids,
        .module_index = &h.module_index,
        .exports = &h.exports,
        .arenas = &h.arenas,
    };
    try types.TypeChecker.checkProject(gpa, &h.arenas[1], &h.diagnostics, &ctx);
    return h;
}

fn tally(world: *World, field: usize) i64 {
    const rid = world.registry.idOf("Tally").?;
    const bytes = world.resources.getResource(rid).?;
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), bytes[field * 8 ..][0..8]);
    return out;
}

test "a .d.etch-declared event type resolves in a rule that observes it" {
    const gpa = std.testing.allocator;
    // The G1 amendment's payoff, and the precondition of everything below: with
    // `event_decl` outside §20.1's allow-list this file could not exist.
    var h = try check(gpa, observer_source);
    defer h.deinit(gpa);
    for (h.diagnostics.items) |d| std.debug.print("check {s}: {s}\n", .{ d.code.code(), d.primary_message });
    try std.testing.expectEqual(@as(usize, 0), h.diagnostics.items.len);

    // COUNTERFACTUAL ON THE OBJECT: the same rule against an event type nothing
    // declares is still rejected, so the resolution above came from the
    // declaration file and not from a check that stopped checking.
    var undeclared = try check(gpa,
        \\resource Tally { seen: int = 0, last: int = 0, loud_seen: int = 0 }
        \\@on_event(NotDeclaredAnywhere)
        \\rule absorb()
        \\  when resource Tally
        \\{
        \\  get_mut(Tally).seen += 1
        \\}
    );
    defer undeclared.deinit(gpa);
    try std.testing.expect(undeclared.diagnostics.items.len > 0);

    // And a FIELD that the declaration does not carry is still rejected, which
    // is what shows the cross-arena field lookup reads the real declaration
    // rather than admitting anything.
    var bad_field = try check(gpa,
        \\resource Tally { seen: int = 0, last: int = 0, loud_seen: int = 0 }
        \\@on_event(ToyPing)
        \\rule absorb()
        \\  when resource Tally
        \\{
        \\  get_mut(Tally).last = event.nonexistent
        \\}
    );
    defer bad_field.deinit(gpa);
    try std.testing.expect(bad_field.diagnostics.items.len > 0);
}

test "toy event emitted from Zig is observed in a rule at the expected tick" {
    const gpa = std.testing.allocator;
    var h = try check(gpa, observer_source);
    defer h.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), h.diagnostics.items.len);

    var world = World.init();
    defer world.deinit(gpa);

    const queue = try EventQueue(toy.Ping).init(gpa, 8, Lifetime.tick);
    defer queue.deinit(gpa);

    var interp = try weld_etch.Interpreter.compile(gpa, &h.arenas[1], &world);
    defer interp.deinit();

    var bridge = Bridge(toy.Ping).init(queue, .{
        .type_id = weld_core.rtti.computeTypeId(toy.Ping),
        .last_read = queue.currentHead(),
        .epoch = queue.currentEpoch(),
    }, "ToyPing");
    try interp.addEventSource(bridge.source());

    // ── TICK 1: Zig enqueues, the rule must observe it THIS tick ──
    queue.enqueue(.{ .value = 41, .loud = true });
    var report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expectEqual(@as(i64, 1), tally(&world, 0));
    try std.testing.expectEqual(@as(i64, 41), tally(&world, 1));
    // Every field crossed, not only the first.
    try std.testing.expectEqual(@as(i64, 1), tally(&world, 2));
    try std.testing.expectEqual(@as(usize, 1), bridge.pushed);
    try std.testing.expectEqual(@as(usize, 0), bridge.dropped);

    // ── TICK 2: Zig enqueues NOTHING. The rule must observe nothing ──
    // This is the half a single-tick test cannot carry: it pins that the store
    // was CLEARED between the ticks, so tick 1's event is not still sitting
    // there. A drain that re-pushed, or a missing clear, both fail here.
    report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(i64, 1), tally(&world, 0));
    try std.testing.expectEqual(@as(i64, 41), tally(&world, 1));

    // ── TICK 3: a second event, distinguishable from the first ──
    queue.enqueue(.{ .value = 7, .loud = false });
    report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expectEqual(@as(i64, 2), tally(&world, 0));
    try std.testing.expectEqual(@as(i64, 7), tally(&world, 1));
    // `loud` was false this time, so the count did NOT move — the payload is
    // read per event and not carried over.
    try std.testing.expectEqual(@as(i64, 1), tally(&world, 2));
    try std.testing.expectEqual(@as(usize, 2), bridge.pushed);
}

test "the drain runs after the per-tick clear, not before it" {
    const gpa = std.testing.allocator;
    var h = try check(gpa, observer_source);
    defer h.deinit(gpa);

    var world = World.init();
    defer world.deinit(gpa);
    const queue = try EventQueue(toy.Ping).init(gpa, 8, Lifetime.tick);
    defer queue.deinit(gpa);
    var interp = try weld_etch.Interpreter.compile(gpa, &h.arenas[1], &world);
    defer interp.deinit();
    var bridge = Bridge(toy.Ping).init(queue, .{
        .type_id = weld_core.rtti.computeTypeId(toy.Ping),
        .last_read = queue.currentHead(),
        .epoch = queue.currentEpoch(),
    }, "ToyPing");
    try interp.addEventSource(bridge.source());

    // THE ORDERING ORACLE. Three events across three consecutive ticks, each
    // with a distinct value, and the rule records the last one it saw. If the
    // drain ran BEFORE the clear, every tick would observe nothing and `seen`
    // would stay 0 — which is precisely the "emitted, never observed, no red
    // anywhere" failure, and it is red HERE.
    var expected_last: i64 = 0;
    for ([_]i64{ 11, 22, 33 }, 1..) |v, n| {
        queue.enqueue(.{ .value = v, .loud = false });
        _ = try interp.runFor(&world, 1);
        expected_last = v;
        try std.testing.expectEqual(@as(i64, @intCast(n)), tally(&world, 0));
        try std.testing.expectEqual(expected_last, tally(&world, 1));
    }
    try std.testing.expectEqual(@as(usize, 3), bridge.pushed);
    try std.testing.expectEqual(@as(usize, 0), bridge.dropped);
    try std.testing.expectEqual(@as(usize, 0), bridge.invalidations);
}

test "an event no rule of the program mentions is dropped and counted" {
    const gpa = std.testing.allocator;
    // A program with no `ToyPing` anywhere: the type name is not interned in its
    // pool, so no observer can exist and the push has nowhere to land. The
    // COUNT is what makes that visible — a silent drop is the failure mode this
    // gate is written against.
    var h = try check(gpa,
        \\resource Tally { seen: int = 0, last: int = 0, loud_seen: int = 0 }
        \\rule idle()
        \\  when resource Tally
        \\{
        \\  get_mut(Tally).seen += 0
        \\}
    );
    defer h.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), h.diagnostics.items.len);

    var world = World.init();
    defer world.deinit(gpa);
    const queue = try EventQueue(toy.Ping).init(gpa, 8, Lifetime.tick);
    defer queue.deinit(gpa);
    var interp = try weld_etch.Interpreter.compile(gpa, &h.arenas[1], &world);
    defer interp.deinit();
    var bridge = Bridge(toy.Ping).init(queue, .{
        .type_id = weld_core.rtti.computeTypeId(toy.Ping),
        .last_read = queue.currentHead(),
        .epoch = queue.currentEpoch(),
    }, "ToyPing");
    try interp.addEventSource(bridge.source());

    queue.enqueue(.{ .value = 5, .loud = false });
    const report = try interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 0), report.runtime_errors);
    try std.testing.expectEqual(@as(usize, 1), bridge.pushed);
    try std.testing.expectEqual(@as(usize, 1), bridge.dropped);
}
