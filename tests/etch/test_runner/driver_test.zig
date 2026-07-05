//! M1.0.15 acceptance driver for the Etch test runner. Drives the PUBLIC
//! `weld_etch` surface (parseSource → TypeChecker.check → test_runner.run) from
//! OUTSIDE the etch module, over the `.etch` fixtures in this directory
//! (`@embedFile`d so the tests track the real files the `etch_test` shim reads)
//! plus inline sources for the diagnostic cases. All allocations run under
//! `std.testing.allocator`, so a leak anywhere fails the suite.

const std = @import("std");
const weld_etch = @import("weld_etch");

const Diagnostic = weld_etch.Diagnostic;
const DiagnosticCode = weld_etch.diagnostics.DiagnosticCode;
const TestStatus = weld_etch.TestStatus;

// ─── helpers ────────────────────────────────────────────────────────────────

/// Parse + type-check (both asserted clean) + run a source's tests; returns the
/// report (caller `deinit`s). A throwaway `std.Io.Threaded` supplies the clock.
fn run(gpa: std.mem.Allocator, source: []const u8) !weld_etch.RunReport {
    var pr = try weld_etch.parseSource(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return try weld_etch.test_runner.run(gpa, threaded.io(), &pr.ast);
}

/// True iff type-checking `source` (parse asserted clean) yields `code`.
fn checkHasCode(gpa: std.mem.Allocator, source: []const u8, code: DiagnosticCode) !bool {
    var pr = try weld_etch.parseSource(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.TypeChecker.check(gpa, &pr.ast, &diags);
    for (diags.items) |d| if (d.code == code) return true;
    return false;
}

/// Number of type-check diagnostics for `source` (parse asserted clean).
fn checkDiagCount(gpa: std.mem.Allocator, source: []const u8) !usize {
    var pr = try weld_etch.parseSource(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.TypeChecker.check(gpa, &pr.ast, &diags);
    return diags.items.len;
}

fn resultByName(report: weld_etch.RunReport, name: []const u8) ?weld_etch.TestResult {
    for (report.results) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

// ─── run-outcome fixtures ───────────────────────────────────────────────────

test "passing test reports pass" {
    const gpa = std.testing.allocator;
    var report = try run(gpa, @embedFile("green.etch"));
    defer report.deinit();
    // green.etch: 2 passing + 1 @skip.
    try std.testing.expectEqual(@as(u32, 2), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
    try std.testing.expectEqual(@as(u32, 1), report.skipped);
    const p = resultByName(report, "arithmetic holds").?;
    try std.testing.expectEqual(TestStatus.passed, p.status);
}

test "failing assertion reports name, message, and span" {
    const gpa = std.testing.allocator;
    var report = try run(gpa, @embedFile("failing.etch"));
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 1), report.passed);
    try std.testing.expectEqual(@as(u32, 1), report.failed);
    const f = resultByName(report, "two plus two is not five").?;
    try std.testing.expectEqual(TestStatus.failed, f.status);
    // Message carries both compared values (4 and 5).
    try std.testing.expect(std.mem.indexOf(u8, f.message.?, "4") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.message.?, "5") != null);
    // Source span is present and non-empty.
    try std.testing.expect(f.span != null);
    try std.testing.expect(f.span.?.byte_end > f.span.?.byte_start);
}

test "skip and only semantics" {
    const gpa = std.testing.allocator;
    // @skip: reported skipped with its reason, body not run (green.etch's).
    var green = try run(gpa, @embedFile("green.etch"));
    defer green.deinit();
    const s = resultByName(green, "not ready yet").?;
    try std.testing.expectEqual(TestStatus.skipped, s.status);
    try std.testing.expectEqualStrings("documented WIP", s.message.?);

    // @only: only the focused test runs; the other is skipped (never fails).
    var only = try run(gpa, @embedFile("only.etch"));
    defer only.deinit();
    try std.testing.expectEqual(@as(u32, 1), only.passed);
    try std.testing.expectEqual(@as(u32, 0), only.failed);
    try std.testing.expectEqual(@as(u32, 1), only.skipped);
    try std.testing.expectEqual(TestStatus.passed, resultByName(only, "focused").?.status);
    try std.testing.expectEqual(TestStatus.skipped, resultByName(only, "would fail if run").?.status);
}

test "fresh world per test" {
    const gpa = std.testing.allocator;
    var report = try run(gpa, @embedFile("isolation.etch"));
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 2), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "spawn_with returns a live handle and fires observers; tick drives rules and events" {
    const gpa = std.testing.allocator;
    var report = try run(gpa, @embedFile("world.etch"));
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 2), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

test "measure returns a positive duration; tick_until stops on predicate and timeout" {
    const gpa = std.testing.allocator;
    var report = try run(gpa, @embedFile("timing.etch"));
    defer report.deinit();
    try std.testing.expectEqual(@as(u32, 3), report.passed);
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

// ─── diagnostic cases (inline: broken programs, not run) ────────────────────

test "test name no longer collides with component name" {
    const gpa = std.testing.allocator;
    const n = try checkDiagCount(gpa,
        \\component Foo { x: int = 0 }
        \\test "Foo" { assert(true) }
    );
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "duplicate test names are E0101" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try checkHasCode(gpa,
        \\test "dup" { assert(true) }
        \\test "dup" { assert(true) }
    , .duplicate_symbol));
}

test "await in test body is E0901" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try checkHasCode(gpa,
        \\test "no await" { await wait(1.0s) }
    , .async_call_in_non_async_context));
}

test "measure outside test body is E0910" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try checkHasCode(gpa,
        \\fn timed() -> Duration { measure { } }
    , .measure_outside_test));
}
