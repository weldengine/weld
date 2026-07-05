//! Etch `test` runner (M1.0.15, `etch-reference-part2.md` §32 normative block).
//!
//! Orchestration only: iterate the `test` blocks of a type-checked AST in
//! declaration order, run each in FULL ISOLATION (a fresh `World` + fresh
//! `Interpreter` compiled from the shared AST — the E1 recon finding: type
//! registration lives in `Interpreter.compile`, so a fresh compile re-registers
//! every component / resource / event / rule), honour `@skip` / `@only`, and
//! convert each body's outcome into a per-test result carrying the test name,
//! a message, the failure source span, and the wall-clock duration.
//!
//! The body execution + failure conversion live in `interp.runTestBody` (a
//! failed `assert*`, an uncaught `throw`, or any runtime failure becomes a
//! `.fail` outcome — NOT an aggregated `runtime_errors` count, §32). The
//! test-world surface (`test_world`/`spawn_with`/`emit`/`tick`) and the
//! assertion family (`assert_eq`, `measure`, `tick_until`) land in M1.0.15 E3/E4;
//! this library is stable against them (it drives `runTestBody`, which grows the
//! builtins underneath it).
//!
//! `RunReport` OWNS its strings (an internal arena); the caller need only keep
//! `ast` alive for the duration of `run`. The `weld test` CLI (`engine-spec.md`
//! §26.1) will consume this same library — the `etch_test` shim (E5) is its
//! Phase-1 driver.

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

/// Run every `test` block in a type-checked `ast` (M1.0.15, §32). Declaration
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
                // Copy the borrowed message into report memory BEFORE the next
                // test's interpreter overwrites it (string-discipline, §32 trap).
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

// ─── E3: test-world surface ──────────────────────────────────────────────────

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
    // body's `resetRunStrings` would free it (the M1.0.14 UAF class) without the
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
