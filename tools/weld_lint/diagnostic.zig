//! Diagnostic struct + `file:line:col:rule:message` formatter.
//!
//! Owned by `tools/weld_lint/main.zig`. Each rule populates a list of
//! diagnostics; the dispatcher prints them in deterministic order
//! (file → line → col) and returns a non-zero exit code if the list
//! is non-empty.

const std = @import("std");

/// One linter violation. Strings are owned by the arena passed to the
/// rule that produced this diagnostic — the consumer must keep that
/// arena alive until after the diagnostic is printed.
pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    rule: []const u8,
    message: []const u8,

    pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        const file_order = std.mem.order(u8, a.file, b.file);
        if (file_order != .eq) return file_order == .lt;
        if (a.line != b.line) return a.line < b.line;
        if (a.col != b.col) return a.col < b.col;
        return std.mem.lessThan(u8, a.rule, b.rule);
    }
};

/// Compute 1-based line and column from a 0-based byte offset into a
/// UTF-8 source. Column counts bytes, not codepoints — sufficient for
/// linter diagnostics on ASCII-heavy Zig source.
pub fn lineColFromOffset(source: []const u8, offset: usize) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    const limit = @min(offset, source.len);
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}
