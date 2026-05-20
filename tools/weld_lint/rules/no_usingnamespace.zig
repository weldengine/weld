//! Rule `no_usingnamespace` — reject any use of `usingnamespace`.
//!
//! `engine-zig-conventions.md §1` forbids `usingnamespace` everywhere
//! in Weld. Explicit `pub const` re-exports are the canonical
//! replacement. In Zig 0.16 the keyword has been removed, so any
//! remaining occurrence reaches the tokenizer as a regular identifier;
//! matching by textual content covers both the legacy keyword case and
//! any future re-introduction.
//!
//! Strategy: tokenize the source and report every token (identifier or
//! the historical `keyword_usingnamespace` tag if still present) whose
//! text equals `"usingnamespace"`. Tokenization avoids false positives
//! inside comments and string literals.

const std = @import("std");
const diag = @import("../diagnostic.zig");

pub const name = "no_usingnamespace";

pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        const slice = source[tok.loc.start..tok.loc.end];
        if (!std.mem.eql(u8, slice, "usingnamespace")) continue;
        const pos = diag.lineColFromOffset(source, tok.loc.start);
        try out.append(arena, .{
            .file = file,
            .line = pos.line,
            .col = pos.col,
            .rule = name,
            .message = "usingnamespace is forbidden — use explicit `pub const` re-exports",
        });
    }
}
