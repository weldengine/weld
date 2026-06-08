//! Etch parser diagnostics — typed `Diagnostic`, stable `DiagnosticCode`
//! names cross-version, and on-demand `(line, column)` computation from a
//! `LineIndex` built once per source.
//!
//! The S3 subset emits the codes listed in `briefs/S3-etch-parser-subset.md`
//! Scope / Diagnostics typed API. Codes are stable cross-version per the
//! reference catalogue in `etch-diagnostics.md` §1; new variants may be
//! added in later phases without renumbering existing ones.

const std = @import("std");
const token = @import("token.zig");

const SourceSpan = token.SourceSpan;

/// Severity classes recognised by the S3 type-checker. The brief carves
/// `error_` and `warning`; the wider catalogue (`note`, `hint`) is
/// documented for forward compatibility but unused in S3.
pub const Severity = enum {
    error_,
    warning,
};

/// Stable cross-version diagnostic codes. The variant name (e.g.
/// `parse_error`) maps to the canonical short code (`E0001`) via
/// `code()` and to the canonical PascalCase name (`ParseError`) via
/// `name()`. S3 emits only the variants commented `S3`; the others are
/// reserved here so the enum can be extended additively in later phases.
pub const DiagnosticCode = enum {
    // ── Parse / lex errors (E0001-E0099) ──
    parse_error, // S3 — E0001 ParseError

    // ── Resolver — symbols / paths (E0100-E0199) ──
    duplicate_symbol, // S3 — E0101 DuplicateSymbol
    undefined_symbol, // S3 — E0102 UndefinedSymbol
    enum_variant_not_found, // M0.8 — E0105 EnumVariantNotFound

    // ── Type errors (E0200-E0299) ──
    type_mismatch, // S3 — E0200 TypeMismatch

    // ── ECS access errors (E0300-E0399) ──
    resource_expected_component_given, // M0.8 — E0301 ResourceExpectedComponentGiven
    component_expected_resource_given, // M0.8 — E0302 ComponentExpectedResourceGiven

    // ── Annotation errors (E0500-E0599) ──
    annotation_misapplied, // M0.8 — E0502 AnnotationMisapplied

    // ── Const eval errors (E1100-E1199) ──
    not_const_evaluable, // S3 — E1101 NotConstEvaluable

    // ── Rule-specific errors (E1200-E1299) ──
    unknown_component_in_when, // S3 — E1210 UnknownComponentInWhen
    invalid_field_filter, // S3 — E1211 InvalidFieldFilter
    resource_expected_in_when, // S3 — E1213 ResourceExpectedInWhen
    non_exhaustive_match, // M0.8 — E1230 NonExhaustiveMatch

    /// Canonical short code, e.g. `"E0001"`.
    pub fn code(self: DiagnosticCode) []const u8 {
        return switch (self) {
            .parse_error => "E0001",
            .duplicate_symbol => "E0101",
            .undefined_symbol => "E0102",
            .enum_variant_not_found => "E0105",
            .type_mismatch => "E0200",
            .resource_expected_component_given => "E0301",
            .component_expected_resource_given => "E0302",
            .annotation_misapplied => "E0502",
            .not_const_evaluable => "E1101",
            .unknown_component_in_when => "E1210",
            .invalid_field_filter => "E1211",
            .resource_expected_in_when => "E1213",
            .non_exhaustive_match => "E1230",
        };
    }

    /// Canonical PascalCase name, e.g. `"ParseError"`.
    pub fn name(self: DiagnosticCode) []const u8 {
        return switch (self) {
            .parse_error => "ParseError",
            .duplicate_symbol => "DuplicateSymbol",
            .undefined_symbol => "UndefinedSymbol",
            .enum_variant_not_found => "EnumVariantNotFound",
            .type_mismatch => "TypeMismatch",
            .resource_expected_component_given => "ResourceExpectedComponentGiven",
            .component_expected_resource_given => "ComponentExpectedResourceGiven",
            .annotation_misapplied => "AnnotationMisapplied",
            .not_const_evaluable => "NotConstEvaluable",
            .unknown_component_in_when => "UnknownComponentInWhen",
            .invalid_field_filter => "InvalidFieldFilter",
            .resource_expected_in_when => "ResourceExpectedInWhen",
            .non_exhaustive_match => "NonExhaustiveMatch",
        };
    }
};

/// A single diagnostic. Owns its `primary_message` slice — duplicated via
/// the caller's allocator when constructed; the type-checker / parser keep
/// the diagnostic list in an `ArrayListUnmanaged(Diagnostic)` and free
/// each `primary_message` at `deinit`.
pub const Diagnostic = struct {
    code: DiagnosticCode,
    severity: Severity,
    primary_span: SourceSpan,
    primary_message: []const u8,

    pub fn deinit(self: *Diagnostic, gpa: std.mem.Allocator) void {
        gpa.free(self.primary_message);
    }
};

/// `LineIndex` precomputes the byte offset of each line start so that
/// `(line, column)` can be resolved in `O(log n)` from a `SourceSpan`.
/// Built once per source.
pub const LineIndex = struct {
    /// `line_starts[i]` is the byte offset of the first character on
    /// line `i` (1-indexed: `line_starts[0]` is the start of line 1).
    line_starts: std.ArrayListUnmanaged(u32),
    source_len: u32,

    pub fn init(gpa: std.mem.Allocator, source: []const u8) !LineIndex {
        var line_starts: std.ArrayListUnmanaged(u32) = .empty;
        errdefer line_starts.deinit(gpa);
        try line_starts.append(gpa, 0);
        var i: u32 = 0;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\n') {
                try line_starts.append(gpa, i + 1);
            }
        }
        return .{
            .line_starts = line_starts,
            .source_len = @intCast(source.len),
        };
    }

    pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void {
        self.line_starts.deinit(gpa);
    }

    /// 1-indexed (line, column). Column counts bytes from the start of
    /// the line; for ASCII / single-byte spans this matches the visual
    /// column. Multi-byte UTF-8 in string literals is reported by its
    /// leading byte offset, which is sufficient for S3 diagnostics.
    pub const LineColumn = struct {
        line: u32,
        column: u32,
    };

    pub fn lineColumn(self: *const LineIndex, byte_offset: u32) LineColumn {
        // Binary search for the largest line_starts[i] <= byte_offset.
        const starts = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= byte_offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return .{
            .line = @intCast(lo + 1),
            .column = byte_offset - starts[lo] + 1,
        };
    }
};

test "Diagnostic line/column computed correctly from byte span" {
    const gpa = std.testing.allocator;
    const source = "abc\ndef\nghijkl\nmno";
    var idx = try LineIndex.init(gpa, source);
    defer idx.deinit(gpa);

    // 'a' → line 1 col 1
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 1, .column = 1 }, idx.lineColumn(0));
    // 'd' (line 2, col 1)
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 2, .column = 1 }, idx.lineColumn(4));
    // 'i' on line 3 col 3
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 3, .column = 3 }, idx.lineColumn(10));
    // 'm' on line 4 col 1
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 4, .column = 1 }, idx.lineColumn(15));
}

test "DiagnosticCode code and name are stable cross-version" {
    try std.testing.expectEqualStrings("E0001", DiagnosticCode.parse_error.code());
    try std.testing.expectEqualStrings("ParseError", DiagnosticCode.parse_error.name());
    try std.testing.expectEqualStrings("E0101", DiagnosticCode.duplicate_symbol.code());
    try std.testing.expectEqualStrings("E1210", DiagnosticCode.unknown_component_in_when.code());
    try std.testing.expectEqualStrings("UnknownComponentInWhen", DiagnosticCode.unknown_component_in_when.name());
    try std.testing.expectEqualStrings("E1213", DiagnosticCode.resource_expected_in_when.code());
}
