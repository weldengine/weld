//! EBNF harness — extracts every fenced ```etch block from `ebnf_examples.md`
//! and feeds each to the parser, so a documented example using a construct the
//! parser does not support fails CI.
//!
//! The spec documents (`etch-grammar.md`, `etch-reference-part*.md`) live
//! outside the repo, which is why the corpus is an in-repo file.
//!
//! POINTING THIS ITERATOR AT THE GRAMMAR WOULD NOT WORK, and that is measured
//! rather than expected. This header used to promise it as the plan for the day
//! the grammar enters the repo. Fed the grammar's own 15 ```etch blocks, the
//! parser refuses 11, in three distinct classes:
//!
//!   - TWO are refused BY DESIGN — a block using `override`, which is reserved
//!     and absent from the accepted top-level set, and one declaring a
//!     `service`, valid only in a `.d.etch`. A grammar documents the language
//!     including what a plain `.etch` must reject, so extraction needs a
//!     per-block expected verdict, which "extract and parse" has nowhere to put.
//!   - ONE is a defect in the document: EBNF comment syntax `(* … *)` inside an
//!     ```etch fence.
//!   - EIGHT are real divergence between documented and parsed Etch, and THE SIDE
//!     IS NOT UNIFORM. `import ui.theme` is the document's: `theme` has since
//!     become a top-level keyword, so a documented import became unparseable
//!     without either side noticing. A widget block is the PARSER's: it carries a
//!     trailing comma in an argument list, which `arg_list` explicitly permits
//!     (`arg , { "," , arg } , [ "," ]`), and the parser refuses it in all three
//!     argument shapes under two messages that name the wrong fault — one of them
//!     the positional-before-named rule, which the block does not break. The same
//!     optional comma is HONOURED in array, struct, map and match-arm literals, so
//!     the refusal is confined to argument lists. The other six are unattributed:
//!     one side was measured, and generalising from it is how the widget block was
//!     first misfiled here.
//!
//! So the corpus below is CURATED to parse, not extracted, and that is the
//! property the harness rests on. What it cannot do is notice a construct the
//! spec documents and nobody transcribed — the divergence above is measured on
//! the grammar's 15 blocks and unmeasured on the corpus's other 951.

const std = @import("std");
const weld_etch = @import("weld_etch");

const examples_md = @embedFile("ebnf_examples.md");

/// Minimum number of example blocks the corpus must contain. Raised whenever a
/// block is added, which is what pins the new one against accidental removal.
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
