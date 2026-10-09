//! Etch `test` runner (`etch-reference-part2.md` §32 normative block).
//!
//! Orchestration only: iterate the `test` blocks of a type-checked AST in
//! declaration order, run each in FULL ISOLATION (a fresh `World` + fresh
//! `Interpreter` compiled from the shared AST — isolation is possible only
//! because type registration lives in `Interpreter.compile`, so a fresh compile
//! re-registers every component / resource / event / rule), honour `@skip` /
//! `@only`, and
//! convert each body's outcome into a per-test result carrying the test name,
//! a message, the failure source span, and the wall-clock duration.
//!
//! The body execution + failure conversion live in `interp.runTestBody` (a
//! failed `assert*`, an uncaught `throw`, or any runtime failure becomes a
//! `.fail` outcome — NOT an aggregated `runtime_errors` count, §32). The
//! test-world surface (`test_world`/`spawn_with`/`emit`/`tick`) and the
//! assertion family (`assert_eq`, `measure`, `tick_until`) live in `interp.zig`,
//! NOT here, and this file is stable against them by construction: it drives
//! `runTestBody` and the builtins grow underneath it without reaching this
//! orchestration.
//!
//! `RunReport` OWNS its strings (an internal arena); the caller need only keep
//! `ast` alive for the duration of `run`. The `etch_test` shim is the driver:
//! it calls `test_runner.run` directly. A `weld test` CLI
//! (`engine-platform.md` § "Build System — CLI `weld`") would consume this same
//! library, and `tools/weld` does not exist.

const std = @import("std");
const weld_core = @import("weld_core");
const ast_mod = @import("ast.zig");
const interp_mod = @import("interp.zig");
const token = @import("token.zig");

const World = weld_core.ecs.world.World;
const Ast = ast_mod.AstArena;
const Interpreter = interp_mod.Interpreter;
const AnnotationKind = ast_mod.AnnotationKind;
const SourceSpan = token.SourceSpan;
const Io = std.Io;

/// Per-test outcome status.
pub const TestStatus = enum { passed, failed, skipped };

/// One test's result. All strings are owned by the enclosing `RunReport`'s
/// arena (copied out of interpreter/AST memory), so the report can outlive the
/// AST and the transient per-test interpreter.
pub const TestResult = struct {
    /// The test name (the `test "..."` label), report-arena-owned.
    name: []const u8,
    status: TestStatus,
    /// Wall-clock duration of the body run in nanoseconds (0 for a skipped test).
    duration_ns: u64 = 0,
    /// Failure message (`.failed`) or skip reason (`.skipped`); null for a pass.
    /// Report-arena-owned.
    message: ?[]const u8 = null,
    /// Source span of the failing statement (byte offsets into the test's file).
    /// Non-null only for `.failed`; the shim resolves it to `file:line`.
    span: ?SourceSpan = null,
};

/// Aggregate result of running a compilation set's tests. Holds its own arena;
/// `deinit` frees every owned string and the results slice at once.
pub const RunReport = struct {
    arena: std.heap.ArenaAllocator,
    results: []TestResult = &.{},
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn deinit(self: *RunReport) void {
        self.arena.deinit();
    }
};

/// Run every `test` block in a type-checked `ast` (§32). Declaration
/// order; a fresh World + Interpreter per test (full isolation, mono-world);
/// `@skip` reported skipped with its reason (body not run); `@only` focusing (if
/// any `@only` test exists in the set, only those run, the rest reported
/// skipped). `gpa` backs the transient per-test World/Interpreter; `io` provides
/// the monotonic clock for per-test wall-clock durations (Zig 0.16 clocks live
/// under `std.Io.Clock`); the returned report owns its strings.
pub fn run(gpa: std.mem.Allocator, io: Io, ast: *const Ast) !RunReport {
    var report = RunReport{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer report.deinit();
    const a = report.arena.allocator();

    var results: std.ArrayListUnmanaged(TestResult) = .empty;

    // `@only` is per compilation set: if ANY test is `@only`, only those run.
    var any_only = false;
    for (ast.test_decls.items) |decl| {
        if (annotationPresent(ast, decl, .only)) {
            any_only = true;
            break;
        }
    }

    for (ast.test_decls.items) |decl| {
        const name = try a.dupe(u8, ast.strings.slice(decl.name));

        // `@skip` wins over everything: reported skipped, body not run.
        if (skipReason(ast, decl)) |reason| {
            try results.append(a, .{ .name = name, .status = .skipped, .message = try a.dupe(u8, reason) });
            report.skipped += 1;
            continue;
        }
        // `@only` focusing: a non-`@only` test is skipped when any `@only` exists.
        if (any_only and !annotationPresent(ast, decl, .only)) {
            try results.append(a, .{ .name = name, .status = .skipped, .message = try a.dupe(u8, "not selected (@only in effect)") });
            report.skipped += 1;
            continue;
        }

        // Full isolation: a fresh World + Interpreter compiled from the shared
        // AST (re-registers every declaration), bound for observer dispatch.
        var world = World.init();
        defer world.deinit(gpa);
        var interp = try Interpreter.compile(gpa, ast, &world);
        defer interp.deinit();
        interp.io = io; // wall-clock provider for `measure { … }`
        try interp.bindToWorld(&world);

        const t0 = Io.Clock.now(.awake, io);
        const outcome = try interp.runTestBody(&world, decl);
        const t1 = Io.Clock.now(.awake, io);
        const dur: u64 = @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds));

        switch (outcome) {
            .pass => {
                try results.append(a, .{ .name = name, .status = .passed, .duration_ns = dur });
                report.passed += 1;
            },
            .fail => |f| {
                // Copy the borrowed message into report memory BEFORE THIS
                // iteration's `defer interp.deinit()`. The message has two
                // provenances (`interp.TestBodyOutcome`) and only one of them,
                // `test_msg_buf`, is freed there; an `assert` literal points at
                // AST-stable bytes the caller keeps alive. Copying covers both.
                // Not the next test's interpreter — there is none yet when this
                // runs — so moving the `dupe` after the `deinit` would be wrong
                // for a reason the ordering here already settles.
                try results.append(a, .{
                    .name = name,
                    .status = .failed,
                    .duration_ns = dur,
                    .message = try a.dupe(u8, f.message),
                    .span = f.span,
                });
                report.failed += 1;
            },
        }
    }

    report.results = try results.toOwnedSlice(a);
    return report;
}

/// True iff `decl` carries an annotation of the given `kind`.
fn annotationPresent(ast: *const Ast, decl: ast_mod.TestDecl, kind: AnnotationKind) bool {
    var i: u32 = 0;
    while (i < decl.annotations_len) : (i += 1) {
        if (ast.annot_pool.items[decl.annotations_extra + i].kind == kind) return true;
    }
    return false;
}

/// The `@skip(reason: "...")` reason if the test is skipped, else null. The
/// type-checker (`checkTestAnnotations`) validated the arg shape (exactly one
/// string literal), so this reads it directly; a malformed arg (already
/// diagnosed) yields an empty reason rather than a crash.
fn skipReason(ast: *const Ast, decl: ast_mod.TestDecl) ?[]const u8 {
    var i: u32 = 0;
    while (i < decl.annotations_len) : (i += 1) {
        const annot = ast.annot_pool.items[decl.annotations_extra + i];
        if (annot.kind != .skip) continue;
        if (annot.args_len == 0) return "";
        const arg = ast.annot_args.items[annot.args_start];
        if (ast.exprKind(arg.value) != .string_lit) return "";
        return ast.strings.slice(ast.exprData(arg.value));
    }
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────────

const parser_mod = @import("parser.zig");
const types_mod = @import("types.zig");
const Diagnostic = @import("diagnostics.zig").Diagnostic;

/// Parse + type-check `source` (asserting both clean) then run its tests. A
/// throwaway `std.Io.Threaded` supplies the clock (the shim passes the process
/// `io`).
fn runSource(gpa: std.mem.Allocator, source: []const u8) !RunReport {
    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return try run(gpa, threaded.io(), &pr.ast);
}

test "passing test reports pass" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "arithmetic holds" {
        \\  assert(1 + 1 == 2)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
    try std.testing.expectEqual(@as(usize, 1), report.results.len);
    try std.testing.expectEqual(TestStatus.passed, report.results[0].status);
    try std.testing.expectEqualStrings("arithmetic holds", report.results[0].name);
}

test "failing assert reports name, message, and span" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "two is not one" {
        \\  assert(2 == 1, "two must equal one")
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 0), report.passed);
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    const r = report.results[0];
    try std.testing.expectEqual(TestStatus.failed, r.status);
    try std.testing.expectEqualStrings("two is not one", r.name);
    try std.testing.expectEqualStrings("two must equal one", r.message.?);
    try std.testing.expect(r.span != null);
    try std.testing.expect(r.span.?.byte_end > r.span.?.byte_start);
}

test "skip reports skipped with reason, body not run" {
    const gpa = std.testing.allocator;
    // The body would fail if run — @skip must prevent that.
    var report = try runSource(gpa,
        \\@skip(reason: "WIP")
        \\test "unfinished" {
        \\  assert(false)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 0), report.failed);
    try std.testing.expectEqual(@as(u32, 1), report.skipped);
    try std.testing.expectEqual(TestStatus.skipped, report.results[0].status);
    try std.testing.expectEqualStrings("WIP", report.results[0].message.?);
}

test "only focuses execution to the annotated test" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\@only
        \\test "focused" {
        \\  assert(true)
        \\}
        \\test "ignored" {
        \\  assert(false)
        \\}
    );
    defer report.deinit();
    // Only the @only test runs (passes); the other is skipped, never failing.
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
    try std.testing.expectEqual(@as(u32, 1), report.skipped);
    try std.testing.expectEqual(TestStatus.passed, report.results[0].status);
    try std.testing.expectEqual(TestStatus.skipped, report.results[1].status);
}

test "aggregate counts across a mixed set" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "p" { assert(true) }
        \\test "f" { assert(false) }
        \\@skip(reason: "later")
        \\test "s" { assert(false) }
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    try std.testing.expectEqual(@as(u32, 1), report.skipped);
    try std.testing.expectEqual(@as(usize, 3), report.results.len);
}

// ─── test-world surface ─────────────────────────────────────────────────────

test "spawn_with returns a live handle usable with get(C) immediately" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\component Health { current: float = 100.0, max: float = 100.0 }
        \\test "live handle" {
        \\  let world = test_world()
        \\  let e = world.spawn_with([Health { current: 42.0 }])
        \\  assert(e.get(Health).current == 42.0)
        \\  assert(e.get(Health).max == 100.0)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "spawn_with fires observers (on_added emits, event tallied after tick)" {
    const gpa = std.testing.allocator;
    // spawn_with fires the on_added(Marker) observer, which emits Spawned; the
    // pre-tick event survives into tick(1), where @on_event(Spawned) tallies it.
    var report = try runSource(gpa,
        \\component Marker { x: int = 0 }
        \\event Spawned { by: int }
        \\resource Count { n: int = 0 }
        \\@on_added(Marker)
        \\rule note(entity: Entity, value: Marker) {
        \\  emit Spawned { by: value.x }
        \\}
        \\@on_event(Spawned)
        \\rule tally()
        \\  when resource Count
        \\{
        \\  get_mut(Count).n += 1
        \\}
        \\test "observer effect visible" {
        \\  let world = test_world()
        \\  world.spawn_with([Marker { x: 7 }])
        \\  world.tick(1)
        \\  assert(get(Count).n == 1)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "tick drives an iterative rule" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\component Health { current: float = 0.0, max: float = 100.0 }
        \\rule regen(entity: Entity)
        \\  when entity has Health
        \\{
        \\  entity.get_mut(Health).current += 10.0
        \\}
        \\test "regen over ticks" {
        \\  let world = test_world()
        \\  let e = world.spawn_with([Health { current: 0.0 }])
        \\  world.tick(1)
        \\  assert(e.get(Health).current == 10.0)
        \\  world.tick(2)
        \\  assert(e.get(Health).current == 30.0)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "a tick count is evaluated once" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\resource Count { n: int = 0 }
        \\rule bump()
        \\  when resource Count
        \\{
        \\  get_mut(Count).n += 1
        \\}
        \\test "one count, one tick" {
        \\  let world = test_world()
        \\  let mut k = 0
        \\  world.tick({
        \\    k += 1
        \\    k
        \\  })
        \\  assert(k == 1)
        \\  assert(get(Count).n == 1)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "world.emit + tick drives an event-handling rule" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\event Damage { amount: int }
        \\resource Tally { total: int = 0 }
        \\@on_event(Damage)
        \\rule absorb()
        \\  when resource Tally
        \\{
        \\  get_mut(Tally).total += event.amount
        \\}
        \\test "damage tallied" {
        \\  let world = test_world()
        \\  world.emit(Damage { amount: 30 })
        \\  world.tick(1)
        \\  assert(get(Tally).total == 30)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "fresh world per test — no cross-test state leak" {
    const gpa = std.testing.allocator;
    // A rule counts Marker entities into a resource each tick; a fresh World per
    // test means test 2 sees only its own spawn, not test 1's two.
    var report = try runSource(gpa,
        \\resource Count { n: int = 0 }
        \\component Marker { x: int = 0 }
        \\rule count(entity: Entity)
        \\  when entity has Marker and resource Count
        \\{
        \\  get_mut(Count).n += 1
        \\}
        \\test "first spawns two" {
        \\  let world = test_world()
        \\  world.spawn_with([Marker { x: 1 }])
        \\  world.spawn_with([Marker { x: 2 }])
        \\  world.tick(1)
        \\  assert(get(Count).n == 2)
        \\}
        \\test "second spawns one — isolated" {
        \\  let world = test_world()
        \\  world.spawn_with([Marker { x: 9 }])
        \\  world.tick(1)
        \\  assert(get(Count).n == 1)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 2), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "test-body collection handle survives tick (no reset-from-under)" {
    const gpa = std.testing.allocator;
    // The driven rule body allocates + resets its own collection each tick; the
    // test body's `xs` (a shared-store handle) must survive that tick unmangled.
    // Without the suppression fix, the rule's per-body reset truncates the store
    // and `xs`'s index is stale/reused → wrong values or OOB.
    var report = try runSource(gpa,
        \\component Marker { x: int = 0 }
        \\rule churn(entity: Entity)
        \\  when entity has Marker
        \\{
        \\  let mut tmp: int[] = [7, 8, 9]
        \\  tmp.push(tmp.len())
        \\}
        \\test "xs survives tick" {
        \\  let world = test_world()
        \\  world.spawn_with([Marker { x: 1 }])
        \\  let mut xs: int[] = [10, 20]
        \\  world.tick(1)
        \\  xs.push(30)
        \\  assert(xs.len() == 3)
        \\  assert(xs[0] == 10)
        \\  assert(xs[2] == 30)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "test-body runtime string survives tick (no use-after-free)" {
    const gpa = std.testing.allocator;
    // `greeting` is a `.string_run` (concat) held across tick(1); the driven rule
    // body's `resetRunStrings` would free it — a use-after-free on a value the
    // test's own locals still hold — without the
    // suppression fix. Under testing.allocator a freed/reused slot yields a wrong
    // length (or OOB), so `len() == 10` is a genuine regression guard.
    var report = try runSource(gpa,
        \\component Marker { x: int = 0 }
        \\rule churn(entity: Entity)
        \\  when entity has Marker
        \\{
        \\  let s = "ab" + "cd"
        \\  s.len()
        \\}
        \\test "greeting survives tick" {
        \\  let world = test_world()
        \\  world.spawn_with([Marker { x: 1 }])
        \\  let name = "hero"
        \\  let greeting = "hello " + name
        \\  world.tick(1)
        \\  assert(greeting.len() == 10)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

// ─── assertion family, measure, tick_until ──────────────────────────────────

test "assert_eq passes; a failure carries both values" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "eq ok" { assert_eq(2 + 2, 4) }
        \\test "eq bad" { assert_eq(2 + 2, 5) }
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    // The failing test's message names both compared values (4 and 5).
    var msg: []const u8 = "";
    for (report.results) |r| {
        if (r.status == .failed) msg = r.message.?;
    }
    try std.testing.expect(std.mem.indexOf(u8, msg, "4") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "5") != null);
}

test "assert_neq / assert_approx / assert_some / assert_none" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "neq ok" { assert_neq(1, 2) }
        \\test "neq bad" { assert_neq(3, 3) }
        \\test "approx ok" { assert_approx(1.0, 1.0000001) }
        \\test "approx bad" { assert_approx(1.0, 2.0) }
        \\test "some ok" { let s: int? = some(5) assert_some(s) }
        \\test "some bad" { let n: int? = none assert_some(n) }
        \\test "none ok" { let n: int? = none assert_none(n) }
        \\test "none bad" { let s: int? = some(5) assert_none(s) }
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 4), report.passed);
    try std.testing.expectEqual(@as(u32, 4), report.failed);
}

test "panic / todo / unreachable fail the test with a message" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "boom" { panic("kaboom") }
        \\test "wip" { todo() }
        \\test "never" { unreachable() }
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 0), report.passed);
    try std.testing.expectEqual(@as(u32, 3), report.failed);
    for (report.results) |r| {
        try std.testing.expect(r.message != null);
        try std.testing.expect(r.message.?.len > 0);
    }
    // The custom panic message is preserved.
    try std.testing.expectEqualStrings("kaboom", report.results[0].message.?);
}

test "measure returns a positive duration" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "measured" {
        \\  let elapsed = measure {
        \\    let mut i: int = 0
        \\    while i < 5000 { i += 1 }
        \\  }
        \\  assert(elapsed > 0.0s)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "tick_until stops on the predicate and on timeout" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\resource Counter { n: int = 0 }
        \\rule inc()
        \\  when resource Counter
        \\{
        \\  get_mut(Counter).n += 1
        \\}
        \\test "reaches predicate" {
        \\  let world = test_world()
        \\  let hit = tick_until(|| get(Counter).n >= 3, 1.0s)
        \\  assert(hit)
        \\  assert_eq(get(Counter).n, 3)
        \\}
        \\test "hits timeout" {
        \\  let world = test_world()
        \\  let hit = tick_until(|| get(Counter).n >= 1000, 0.05s)
        \\  assert(not hit)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 2), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "a tick_until budget beyond the int range fails the test" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\resource Counter { n: int = 0 }
        \\test "huge timeout" {
        \\  let world = test_world()
        \\  let hit = tick_until(|| false, 1000000000000000000000.0s)
        \\  assert(not hit)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.failed);
}

// ─── regressions: stale assert message, string-aware compare, throwing pred ─

test "a rule-body assert failure during tick does not leak into the test's message" {
    const gpa = std.testing.allocator;
    // A driven rule fails an assert (harvested); the test body then fails its own
    // plain assert. The reported message must be the test's ("assertion failed"),
    // NOT the stale rule assert ("assert_eq: 0 != 999").
    var report = try runSource(gpa,
        \\resource C { n: int = 0 }
        \\rule bad()
        \\  when resource C
        \\{
        \\  assert_eq(get(C).n, 999)
        \\}
        \\test "no stale message" {
        \\  let world = test_world()
        \\  world.tick(1)
        \\  assert(1 == 2)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    try std.testing.expect(std.mem.indexOf(u8, report.results[0].message.?, "999") == null);
}

test "assert_eq / assert_neq compare strings by bytes (no false-pass)" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "eq computed strings" { let a = "hi"  assert_eq(a + "!", "hi!") }
        \\test "neq equal strings fails" { let a = "hi"  assert_neq(a + "!", "hi!") }
    );
    defer report.deinit();
    // eq of two byte-equal strings passes; neq of two byte-equal strings FAILS
    // (without the fix, Value.eql's string-blindness would flip both).
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 1), report.failed);
}

test "a throwing tick_until predicate fails the test with the throw" {
    const gpa = std.testing.allocator;
    var report = try runSource(gpa,
        \\test "pred throws" {
        \\  let world = test_world()
        \\  let hit = tick_until(|| { throw Error { message: "boom", code: .io_fail } }, 1.0s)
        \\  assert(hit)
        \\}
    );
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    // The failure is the predicate's uncaught throw, surfaced immediately —
    // not a timeout / a downstream assert.
    try std.testing.expectEqualStrings("uncaught throw", report.results[0].message.?);
}

const RunCase = struct { name: []const u8, src: []const u8 };

/// How many of `cases` fail to check clean or to pass their one test, each
/// failure printed.
fn failingRuns(cases: []const RunCase) !usize {
    const gpa = std.testing.allocator;
    var wrong: usize = 0;
    for (cases) |c| {
        var pr = try parser_mod.parse(gpa, c.src);
        defer pr.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try types_mod.TypeChecker.check(gpa, &pr.ast, &diags);
        if (diags.items.len != 0) {
            wrong += 1;
            for (diags.items) |d| std.debug.print("{s}: {s} {s}\n", .{ c.name, d.code.code(), d.primary_message });
            continue;
        }
        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        var report = try run(gpa, threaded.io(), &pr.ast);
        defer report.deinit();
        if (report.passed != 1) {
            wrong += 1;
            for (report.results) |r| std.debug.print("{s}: {t} {s}\n", .{ c.name, r.status, r.message orelse "" });
        }
    }
    return wrong;
}

const equality_runs = [_]RunCase{
    .{ .name = "a run string against a literal", .src =
    \\test "t" {
    \\  let a = "a" + "b"
    \\  assert(a == "ab")
    \\  assert(a != "a")
    \\}
    },
    .{ .name = "strings are ordered by their bytes", .src =
    \\test "t" {
    \\  assert("a" < "b")
    \\  assert("b" > "a")
    \\  assert("ab" <= "ab")
    \\}
    },
    .{ .name = "an enum, variant against variant", .src =
    \\enum Dir { north, south }
    \\test "t" {
    \\  let d = Dir.south
    \\  assert(d == Dir.south)
    \\  assert(d != Dir.north)
    \\}
    },
    .{ .name = "an optional against some and none", .src =
    \\test "t" {
    \\  let o = some(1)
    \\  assert(o == some(1))
    \\  assert(o != some(2))
    \\  assert(o != none)
    \\  let n: int? = none
    \\  assert(n == none)
    \\  assert(none == n)
    \\}
    },
    .{ .name = "an optional of a string compares its bytes", .src =
    \\test "t" {
    \\  let s = some("a" + "b")
    \\  assert(s == some("ab"))
    \\}
    },
    .{ .name = "an entity against itself and another", .src =
    \\component C { v: int = 0 }
    \\test "t" {
    \\  let w = test_world()
    \\  let a = w.spawn_with([C { v: 1 }])
    \\  let b = w.spawn_with([C { v: 2 }])
    \\  assert(a == a)
    \\  assert(a != b)
    \\  assert(a < b)
    \\}
    },
    .{ .name = "an entity is ordered by index before generation", .src =
    \\component C { v: int = 0 }
    \\test "t" {
    \\  let w = test_world()
    \\  let a = w.spawn_with([C { v: 1 }])
    \\  let b = w.spawn_with([C { v: 2 }])
    \\  a.despawn()
    \\  w.tick(1)
    \\  let c = w.spawn_with([C { v: 3 }])
    \\  assert(c != a)
    \\  assert(c < b)
    \\}
    },
    .{ .name = "assert_eq and assert_neq on optionals", .src =
    \\test "t" {
    \\  assert_eq(some(1), some(1))
    \\  assert_neq(some(1), none)
    \\}
    },
};

test "== and != follow Eq at run time, and an ordered type orders" {
    try std.testing.expectEqual(@as(usize, 0), try failingRuns(&equality_runs));
}

const shorthand_runs = [_]RunCase{
    .{ .name = "a let with an enum annotation", .src = "enum Dir { north, south }\ntest \"t\" {\n  let e: Dir = .south\n  assert(e == Dir.south)\n}" },
    .{ .name = "a fn argument", .src = "enum Dir { north, south }\nfn is_south(d: Dir) -> bool { d == Dir.south }\ntest \"t\" {\n  assert(is_south(.south))\n}" },
    .{ .name = "a return value, trailing and by return", .src = "enum Dir { north, south }\nfn g() -> Dir { .south }\nfn h() -> Dir {\n  return .north\n}\ntest \"t\" {\n  assert(g() == Dir.south)\n  assert(h() == Dir.north)\n}" },
    .{ .name = "a reassignment", .src = "enum Dir { north, south }\ntest \"t\" {\n  let mut e: Dir = Dir.north\n  e = .south\n  assert(e == Dir.south)\n}" },
    .{ .name = "some of a shorthand", .src = "enum Dir { north, south }\ntest \"t\" {\n  let d = some(.south)\n  let v = d ?? Dir.north\n  assert(v == Dir.south)\n}" },
    .{ .name = "a struct field write", .src = "enum Dir { north, south }\nstruct T { d: Dir = .north }\ntest \"t\" {\n  let mut t = T { d: Dir.north }\n  t.d = .south\n  assert(t.d == Dir.south)\n}" },
    .{ .name = "an equality, either side", .src = "enum Dir { north, south }\ntest \"t\" {\n  let e = Dir.south\n  assert(e == .south)\n  assert(.north != e)\n}" },
    .{ .name = "the expected type picks among two enums", .src = "enum Dir { north, south }\nenum Pole { north, south }\ntest \"t\" {\n  let p: Pole = .north\n  assert(p == Pole.north)\n  let q: Pole = if true { .south } else { .north }\n  assert(q == Pole.south)\n  assert(p == .north)\n}" },
    .{ .name = "the one enum naming the variant, with nothing expected", .src = "enum Dir { north, south }\ntest \"t\" {\n  let d = .south\n  assert(d == Dir.south)\n}" },
    .{ .name = "a match arm value", .src = "enum Dir { north, south }\ntest \"t\" {\n  let v: Dir = match 1 { 1 => .south, _ => .north }\n  assert(v == Dir.south)\n}" },
};

test "a .variant shorthand runs as the variant its expected type names" {
    try std.testing.expectEqual(@as(usize, 0), try failingRuns(&shorthand_runs));
}

const option_runs = [_]RunCase{
    .{ .name = "if let and match on an optional struct", .src = "struct P { x: int = 0 }\ntest \"t\" {\n  let o = some(P { x: 7 })\n  if let p = o { assert(p.x == 7) } else { assert(false) }\n  let v = match o { some(p) => p.x, none => 0 }\n  assert(v == 7)\n}" },
    .{ .name = "an optional struct as a fn parameter and return", .src = "struct P { x: int = 0 }\nfn f(o: P?) -> int { o?.x ?? 0 }\nfn g() -> P? { some(P { x: 3 }) }\ntest \"t\" {\n  assert(f(g()) == 3)\n  assert(f(none) == 0)\n}" },
    .{ .name = "an optional struct as a method parameter and return", .src = "struct P { x: int = 0 }\nimpl P {\n  fn pick(self, o: P?) -> P? { o }\n}\ntest \"t\" {\n  let p = P { x: 1 }\n  let q = p.pick(some(P { x: 9 }))\n  assert((q?.x ?? 0) == 9)\n}" },
    .{ .name = "?. reaches an optional field, flattened", .src = "struct P { x: int = 0 }\nstruct Q { p: P? = none }\ntest \"t\" {\n  let q = some(Q { p: some(P { x: 4 }) })\n  let v = q?.p\n  assert((v?.x ?? 0) == 4)\n  let empty = some(Q { })\n  assert((empty?.p?.x ?? 1) == 1)\n}" },
    .{ .name = "?. reaches an optional method result, flattened", .src = "struct P { x: int = 0 }\nimpl P {\n  fn half(self) -> int? { some(self.x / 2) }\n}\ntest \"t\" {\n  let o = some(P { x: 6 })\n  let v = o?.half()\n  assert((v ?? 0) == 3)\n}" },
    .{ .name = "a generic optional parameter and return", .src = "fn first<T>(o: T?, d: T) -> T { o ?? d }\nfn wrap<T>(x: T) -> T? { some(x) }\nfn take<T>(o: T?) -> T { o! }\ntest \"t\" {\n  assert(first(some(2), 0) == 2)\n  assert(first(none, 5) == 5)\n  assert(wrap(2) == some(2))\n  assert(take(some(3)) == 3)\n}" },
    .{ .name = "a value wrapped into its optional", .src = "struct P { x: int = 0 }\nstruct Q { p: P? = none }\nfn f(o: P?) -> int { o?.x ?? 0 }\nfn g() -> int? { 5 }\ntest \"t\" {\n  let o: int? = 5\n  assert(o == some(5))\n  assert(f(P { x: 2 }) == 2)\n  assert(g() == some(5))\n  let q = Q { p: P { x: 8 } }\n  assert((q.p?.x ?? 0) == 8)\n}" },
    .{ .name = "an optional of a collection", .src = "test \"t\" {\n  let o: int[]? = some([1, 2])\n  if let a = o { assert(a.len() == 2) } else { assert(false) }\n  let n: int[]? = none\n  assert((n?.len() ?? 7) == 7)\n  let m: [string: int]? = some([\"a\": 1])\n  assert((m?.len() ?? 0) == 1)\n}" },
    .{ .name = "an optional of an enum, from a shorthand", .src = "enum Dir { north, south }\nenum Pole { north, south }\ntest \"t\" {\n  let d: Dir? = some(.south)\n  assert(d == some(Dir.south))\n  let e: Dir? = .north\n  assert(e == some(Dir.north))\n}" },
    .{ .name = "an optional struct unwrapped and looped", .src = "struct P { x: int = 0 }\ntest \"t\" {\n  let o = some(P { x: 9 })\n  assert(o!.x == 9)\n  let mut w = some(P { x: 2 })\n  let mut n = 0\n  while let p = w {\n    n = p.x\n    w = none\n  }\n  assert(n == 2)\n}" },

    .{ .name = "a none branch makes an if optional", .src = "test \"t\" {\n  let c = false\n  let d = true\n  let x: int? = if c { none } else { 5 }\n  assert(x == some(5))\n  let y = if c { 5 } else { none }\n  assert(y == none)\n  let z: int? = if d { 5 } else { none }\n  assert(z == some(5))\n  let o: int? = none\n  let q = if d { 5 } else { o }\n  assert(q == some(5))\n}" },
    .{ .name = "a none arm makes a match and a loop optional", .src = "test \"t\" {\n  let m: int? = match 2 { 1 => none, _ => 7 }\n  assert(m == some(7))\n  let k = match 1 { 1 => none, _ => 7 }\n  assert(k == none)\n  let mut i = 0\n  let l = loop {\n    if i > 0 {\n      break none\n    }\n    i += 1\n    break 3\n  }\n  assert(l == some(3))\n}" },
    .{ .name = "a generic value returned into its optional", .src = "fn opt<T>(x: T) -> T? { x }\ntest \"t\" {\n  assert(opt(3) == some(3))\n  let o: int? = none\n  let w = opt(o)\n  assert(w != none)\n  if let inner = w { assert(inner == none) } else { assert(false) }\n  let mut d = opt(o)\n  d = 5\n  if let inner = d { assert(inner == some(5)) } else { assert(false) }\n}" },
    .{ .name = "a generic parameter named like a declared type", .src = "struct Item { x: int = 0 }\nfn w<Item>(x: Item) -> Item? { some(x) }\ntest \"t\" {\n  let a: Item? = none\n  assert((a?.x ?? 1) == 1)\n  assert(w(5) == some(5))\n}" },
    .{ .name = "a default wrapped into its optional field", .src = "enum Dir { north, south }\nstruct S { f: int? = 5, d: Dir? = .north, n: int? = none }\ntest \"t\" {\n  let s = S { }\n  assert(s.f == some(5))\n  assert(s.d == some(Dir.north))\n  assert(s.n == none)\n}" },
    .{ .name = "a constant wrapped into its optional", .src = "const K: int? = 5\ntest \"t\" {\n  assert(K == some(5))\n}" },
    .{ .name = "an optional chain continues past a plain access", .src = "struct Q { n: int = 0 }\nimpl Q {\n  fn twice(self) -> int { self.n * 2 }\n}\nstruct P { q: Q }\ntest \"t\" {\n  let o = some(P { q: Q { n: 4 } })\n  assert((o?.q.n ?? 0) == 4)\n  assert((o?.q.twice() ?? 0) == 8)\n  let z: P? = none\n  assert((z?.q.n ?? 7) == 7)\n}" },
    .{ .name = "a named argument reaches a method through ?.", .src = "struct P { x: int = 0 }\nimpl P {\n  fn add(self, n: int) -> int { self.x + n }\n}\ntest \"t\" {\n  let o = some(P { x: 1 })\n  assert((o?.add(n: 2) ?? 0) == 3)\n}" },
    .{ .name = "an awaited value wrapped into its optional", .src = "component Box { n: int = 0, m: int = 0 }\nasync fn five() -> int { 5 }\nasync fn six() -> int {\n  return 6\n}\nasync rule r(entity: Entity) when entity has Box {\n  let x: int? = await five()\n  if x == some(5) { entity.get_mut(Box).n = 1 }\n}\nasync rule q(entity: Entity) when entity has Box {\n  let y: int? = await six()\n  if y == some(6) { entity.get_mut(Box).m = 1 }\n}\ntest \"t\" {\n  let world = test_world()\n  let e = world.spawn_with([Box { }])\n  world.tick(3)\n  assert(e.get(Box).n == 1)\n  assert(e.get(Box).m == 1)\n}" },
    .{ .name = "a resource string read through ?. outlives a later write", .src = "resource R { s: string = \"a\" }\ntest \"t\" {\n  get_mut(R).s = \"x{1}\"\n  let o = some(get(R))\n  let s = o?.s\n  get_mut(R).s = \"y{2}\"\n  assert(s == some(\"x1\"))\n}" },
};

const declared_collection_runs = [_]RunCase{
    .{ .name = "an array of structs, pushed, indexed, looped and popped", .src = "struct P { x: int = 0 }\ntest \"t\" {\n  let mut a: P[] = [P { x: 1 }]\n  a.push(P { x: 2 })\n  assert(a.len() == 2)\n  assert(a[1].x == 2)\n  let mut n = 0\n  for p in a {\n    n = n + p.x\n  }\n  assert(n == 3)\n  let last = a.pop()\n  assert((last?.x ?? 0) == 2)\n}" },
    .{ .name = "a fn taking and returning an array of structs", .src = "struct P { x: int = 0 }\nfn total(xs: P[]) -> int {\n  let mut n = 0\n  for p in xs {\n    n = n + p.x\n  }\n  n\n}\nfn make() -> P[] {\n  [P { x: 4 }, P { x: 5 }]\n}\ntest \"t\" {\n  assert(total(make()) == 9)\n}" },
    .{ .name = "a map of structs, a set of enums, a map of optionals", .src = "struct P { x: int = 0 }\nenum Dir { north, south }\ntest \"t\" {\n  let mut m: [string: P] = [\"a\": P { x: 1 }]\n  m.insert(\"b\", P { x: 2 })\n  assert((m[\"b\"]?.x ?? 0) == 2)\n  let mut s: Set<Dir> = Set.new()\n  s.insert(.north)\n  s.insert(Dir.north)\n  assert(s.len() == 1)\n  assert(s.contains(.north))\n  let w: [string: int?] = [\"a\": 1]\n  assert(w[\"a\"]! == some(1))\n}" },
    .{ .name = "a nested array, and an enum array from shorthands", .src = "enum Dir { north, south }\ntest \"t\" {\n  let ys: int[][] = [[1], [2, 3]]\n  assert(ys[1].len() == 2)\n  let ds: Dir[] = [.north, .south]\n  assert(ds[1] == Dir.south)\n}" },
    .{ .name = "a generic fn over a map, a set and a returned map", .src = "struct P { x: int = 0 }\nfn size<K, V>(m: [K: V]) -> int {\n  m.len()\n}\nfn count<T>(s: Set<T>) -> int {\n  s.len()\n}\nfn wrap<T>(x: T) -> [string: T] {\n  [\"a\": x]\n}\ntest \"t\" {\n  assert(size([\"a\": 1, \"b\": 2]) == 2)\n  assert(count(Set.from([1, 2, 3])) == 3)\n  let w = wrap(P { x: 4 })\n  assert((w[\"a\"]?.x ?? 0) == 4)\n}" },
    .{ .name = "an array type read in two generic scopes", .src = "struct P { x: int = 0 }\nfn same<P>(xs: P[]) -> P[] {\n  xs\n}\ntest \"t\" {\n  assert(same([1, 2]).len() == 2)\n  let ps: P[] = [P { x: 3 }]\n  assert(ps[0].x == 3)\n}" },
    .{ .name = "a resource array of enums takes a shorthand", .src = "enum Dir { north, south }\nresource Nav { dirs: Dir[] }\ntest \"t\" {\n  get_mut(Nav).dirs.push(.south)\n  assert(get(Nav).dirs[0] == Dir.south)\n}" },
};

test "a collection of a declared type is checked and runs" {
    try std.testing.expectEqual(@as(usize, 0), try failingRuns(&declared_collection_runs));
}

test "an optional carries any payload, checked and run" {
    try std.testing.expectEqual(@as(usize, 0), try failingRuns(&option_runs));
}
