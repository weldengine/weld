//! Rule `no_raw_named_type_read` — the Etch AST's `named_types` slab is read only
//! through `AstArena.namedTypeName`, outside the file that owns it.
//!
//! A type node's `data` indexes the slab of its own kind, so indexing
//! `named_types` with the data of a `.slice`, `.optional` or `.path` node selects
//! an unrelated name, or reads out of bounds. `namedTypeName` returns null for
//! every kind but `.named`, which makes the non-named branch a decision each site
//! has to write.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_raw_named_type_read";

/// The owner of the slab, one form per path separator.
const owner_posix = "src/etch/ast.zig";
const owner_win = "src\\etch\\ast.zig";

/// Hook called by `main.runLint` once per `.zig` file.
///
/// Flags every field access `.named_types`. The owner file is skipped: it
/// declares, fills and frees the slab, and holds the accessor.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    if (std.mem.endsWith(u8, file, owner_posix)) return;
    if (std.mem.endsWith(u8, file, owner_win)) return;

    var tokenizer = std.zig.Tokenizer.init(source);
    var last_was_period = false;
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        if (tok.tag == .identifier and last_was_period and
            std.mem.eql(u8, source[tok.loc.start..tok.loc.end], "named_types"))
        {
            const pos = diag.lineColFromOffset(source, tok.loc.start);
            try out.append(arena, .{
                .file = file,
                .line = pos.line,
                .col = pos.col,
                .rule = name,
                .message = "`named_types` is indexed by the data of a `.named` type node only — read it through `AstArena.namedTypeName`, which returns null for every other kind",
            });
        }
        last_was_period = tok.tag == .period;
    }
}

/// Runs the rule over `source` as file `file` and returns the diagnostic count.
fn countOn(file: []const u8, source: [:0]const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try check(arena_state.allocator(), file, source, &diags);
    return diags.items.len;
}

test "a raw read of the slab is flagged, each occurrence once" {
    try std.testing.expectEqual(@as(usize, 2), try countOn("src/etch/interp.zig",
        \\const a = ast.named_types.items[ast.typeNodeData(n)];
        \\const slab = self.ast.named_types;
        \\
    ));
}

test "the owner file is exempt on both separators" {
    const src = "const a = self.named_types.items[0];\n";
    try std.testing.expectEqual(@as(usize, 0), try countOn("src/etch/ast.zig", src));
    try std.testing.expectEqual(@as(usize, 0), try countOn("src\\etch\\ast.zig", src));
    try std.testing.expectEqual(@as(usize, 1), try countOn("src/etch/ast_helpers.zig", src));
}

test "the name in prose or as a declaration is not a read" {
    try std.testing.expectEqual(@as(usize, 0), try countOn("src/etch/types.zig",
        \\// indexes the `named_types` slab
        \\const named_types = 3;
        \\const msg = "ast.named_types";
        \\
    ));
}
