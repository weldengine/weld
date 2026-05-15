//! S3 Etch corpus driver — enumerates every `.etch` file in
//! `tests/etch/corpus/` (via the shared facade module) and asserts:
//!
//! - Files under `valid/**` produce zero diagnostics from `parse` +
//!   `typeCheck`.
//! - Files under `invalid/*.etch` produce **at least** the diagnostic code
//!   whose stable short code prefixes the file name (e.g.
//!   `E1210_unknown_component_in_when.etch`). Additional diagnostics
//!   are tolerated so the test isn't coupled to internal accumulation
//!   order.

const std = @import("std");
const etch = @import("weld_etch");
const corpus = @import("corpus_facade");

test "all valid corpus files parse and type-check with zero diagnostics" {
    const gpa = std.testing.allocator;
    for (corpus.valid) |entry| {
        var pr = try etch.parseSource(gpa, entry.source);
        defer pr.ast.deinit(gpa);
        defer if (pr.diagnostic) |*d| d.deinit(gpa);
        if (pr.diagnostic) |d| {
            std.debug.print("\nvalid file '{s}' had parse diagnostic: {s} — {s}\n", .{ entry.name, d.code.code(), d.primary_message });
            return error.UnexpectedParseDiagnostic;
        }

        var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try etch.typeCheck(gpa, &pr.ast, &diags);
        if (diags.items.len != 0) {
            std.debug.print("\nvalid file '{s}' had {d} unexpected type diagnostics:\n", .{ entry.name, diags.items.len });
            for (diags.items) |d| {
                std.debug.print("  {s} {s}: {s}\n", .{ d.code.code(), d.code.name(), d.primary_message });
            }
            return error.UnexpectedTypeDiagnostic;
        }
    }
}

test "every invalid corpus file emits the diagnostic code in its filename" {
    const gpa = std.testing.allocator;
    for (corpus.invalid) |entry| {
        var pr = try etch.parseSource(gpa, entry.source);
        defer pr.ast.deinit(gpa);
        defer if (pr.diagnostic) |*d| d.deinit(gpa);

        var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try etch.typeCheck(gpa, &pr.ast, &diags);

        const parse_matches = pr.diagnostic != null and std.mem.eql(u8, pr.diagnostic.?.code.code(), entry.expected_code);
        var type_matches = false;
        for (diags.items) |d| {
            if (std.mem.eql(u8, d.code.code(), entry.expected_code)) {
                type_matches = true;
                break;
            }
        }
        if (!parse_matches and !type_matches) {
            std.debug.print("\ninvalid file '{s}' did not emit the expected code {s}. ", .{ entry.name, entry.expected_code });
            if (pr.diagnostic) |d| {
                std.debug.print("Parse diagnostic: {s} — {s}. ", .{ d.code.code(), d.primary_message });
            }
            std.debug.print("Type diagnostics: {d}\n", .{diags.items.len});
            for (diags.items) |d| {
                std.debug.print("  {s} {s}: {s}\n", .{ d.code.code(), d.code.name(), d.primary_message });
            }
            return error.ExpectedDiagnosticNotEmitted;
        }
    }
}
