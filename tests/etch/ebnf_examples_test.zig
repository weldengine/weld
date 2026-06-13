//! M0.8 EBNF harness — extracts every fenced ```etch block from the in-repo
//! example corpus (`ebnf_examples.md`) and feeds each to the parser, asserting
//! that all of them parse without error. A doc example that uses a construct
//! the parser does not yet support fails CI (brief §E1 + §E7).
//!
//! The spec documents (`etch-grammar.md`, `etch-reference-part*.md`) are not in
//! the repo, so the harness embeds an in-repo example corpus instead. The
//! extraction machinery (markdown ```etch fences) is the reusable part: when
//! the grammar enters the repo (re-evaluated in Phase 0) the same iterator can
//! be pointed at it. As later stages land constructs, their example blocks are
//! appended to `ebnf_examples.md`.

const std = @import("std");
const weld_etch = @import("weld_etch");

const examples_md = @embedFile("ebnf_examples.md");

/// Minimum number of example blocks the corpus must contain. Raised to 82 at
/// M0.9 / E2-A (the triple-quote block strictly increases the count vs the
/// M0.8 close of 81), pinning the new block against accidental removal.
const min_blocks: usize = 82;

/// Iterates the fenced ```etch blocks of a markdown document, yielding the raw
/// source between each opening ```` ```etch ```` fence and its closing ```` ``` ````.
const BlockIterator = struct {
    src: []const u8,
    pos: usize = 0,

    fn nextLine(self: *BlockIterator) ?struct { text: []const u8, next: usize } {
        if (self.pos >= self.src.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
        const text = std.mem.trim(u8, self.src[self.pos..end], " \t\r");
        return .{ .text = text, .next = end + 1 };
    }

    fn next(self: *BlockIterator) ?[]const u8 {
        while (self.nextLine()) |line| {
            self.pos = line.next;
            if (!std.mem.eql(u8, line.text, "```etch")) continue;
            // Inside a block: accumulate until the closing fence line.
            const block_start = self.pos;
            while (self.nextLine()) |inner| {
                if (std.mem.eql(u8, inner.text, "```")) {
                    const block = self.src[block_start..self.pos];
                    self.pos = inner.next;
                    return block;
                }
                self.pos = inner.next;
            }
            return null; // unterminated fence — stop
        }
        return null;
    }
};

test "EBNF example blocks all parse without error" {
    const gpa = std.testing.allocator;
    var count: usize = 0;
    var it = BlockIterator{ .src = examples_md };
    while (it.next()) |block| {
        count += 1;
        var result = try weld_etch.parser.parse(gpa, block);
        defer result.deinit(gpa);
        if (result.diagnostics.len > 0) {
            std.debug.print(
                "EBNF example block #{d} failed to parse: {s}\n--- block ---\n{s}\n-------------\n",
                .{ count, result.diagnostics[0].primary_message, block },
            );
            try std.testing.expect(false);
        }
    }
    // Report the count so CI logs show how many blocks were exercised.
    std.debug.print("EBNF harness: {d} example blocks parsed clean\n", .{count});
    try std.testing.expect(count >= min_blocks);
}
