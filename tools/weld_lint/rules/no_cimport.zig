//! Rule `no_cimport` — reject any use of the `@cImport` builtin.
//!
//! `engine-zig-conventions.md §14` and `engine-c-bindings.md §1.3`
//! forbid `@cImport` everywhere in Weld. The replacement is the unified
//! `.api.zig` bindgen system (`addTranslateC` + generated wrapper).
//!
//! Strategy: tokenize the source with `std.zig.Tokenizer` and report
//! every `.builtin` token whose textual content is `@cImport`. The
//! tokenizer skips comments and string literals so naive false
//! positives are not possible.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_cimport";

/// Hook called by `main.runLint` once per `.zig` file. Tokenizes
/// `source` and appends one `Diagnostic` per `@cImport` builtin
/// encountered. Never short-circuits — every occurrence surfaces so
/// reviewers see the full bad spread, not just the first hit.
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
        if (tok.tag != .builtin) continue;
        const slice = source[tok.loc.start..tok.loc.end];
        if (!std.mem.eql(u8, slice, "@cImport")) continue;
        const pos = diag.lineColFromOffset(source, tok.loc.start);
        try out.append(arena, .{
            .file = file,
            .line = pos.line,
            .col = pos.col,
            .rule = name,
            .message = "@cImport is forbidden — use the unified .api.zig bindgen system",
        });
    }
}
