//! `tools/asm_inventory` — mechanical inventory of EXTERNAL TRANSCENDENTAL
//! CALLS in emitted assembly (`ARCH-031` rule 4, conformance test 2: "the
//! inventory is read in the emitted assembly, not in the intentions of the
//! code").
//!
//! Takes one or more `.s` files and exits non-zero if any of them contains a
//! call to a libm transcendental. Used by `zig build forge-asm-inventory`,
//! which emits the assembly of `forge_3d` for the three targets the engine
//! ships and hands the paths here.
//!
//! **Why a Zig scanner and not `grep`.** The brief for M1.1.14 requires the
//! pattern to be anchored on the instruction mnemonic at line start and warns
//! against `\b`, a GNU extension that silently matches NOTHING on BSD grep —
//! the failure mode being a check that reports clean because it never matched
//! anything at all. Substituting a scanner removes the whole class rather than
//! working around one instance of it: there is no regular expression here, no
//! shell quoting, and identical behaviour on every host. The substitution is
//! named, as the brief requires.
//!
//! **What this inventory does NOT establish, and it has to be said here because
//! the next reader will assume otherwise.** `ARCH-031` rule 2 — no implicit
//! multiply-add contraction — is exercised on ONE of the three targets, not
//! three, and the reason is the `-Dcpu=baseline` pinning the same invariant's
//! rule 6 requires. Measured, at baseline, on a two-line probe:
//!
//! - **aarch64**: `@mulAdd` emits `fmadd d0, d0, d1, d2`. `FMADD` is in the
//!   ARMv8-A base ISA, so the backend COULD contract and does not — rule 2 is
//!   genuinely observed there, and the zero-fused-instruction count over
//!   `forge_3d`'s listing is a real measurement rather than a vacuous one.
//! - **x86_64**: `@mulAdd` emits `jmp fma@PLT`. FMA3 is Haswell and later, so
//!   baseline (SSE2) has no fusion instruction at all and rule 2 holds there by
//!   ABSENCE OF HARDWARE rather than by respect of a contract. Structurally in
//!   the engine's favour, and worth nothing as evidence.
//!
//! Note also that `fma` is not among the thirteen names below — `ARCH-031`
//! rule 2 admits an explicit `@mulAdd` as a declared exception at its site — so
//! this inventory would NOT flag that external call. It is not meant to: rule 2
//! is about what the backend does silently, rule 4 about what the source calls.
//!
//! **What it looks for, and why that shape.** A transcendental reaches the
//! object as a CALL to a named symbol. So the scanner reads each line, takes
//! the first token as a mnemonic, keeps only branch-with-link and tail-call
//! mnemonics, and inspects the operand. Anchoring on the mnemonic is what makes
//! the answer trustworthy: the strings `cos` and `exp` also appear in comments,
//! in section names, in mangled Zig symbols like `..cosine_test`, and in
//! `.ascii` payloads, and a substring search over whole lines would flag all of
//! them and be tuned into uselessness within a week.

const std = @import("std");

/// The thirteen names `ARCH-031` rule 4 enumerates.
///
/// The list is the invariant's, verbatim and in its order, so that a reader can
/// check the two against each other without interpreting. Suffixed and
/// decorated spellings are handled by `matchesForbidden`, not by expanding this
/// table — one name per mathematical function, one place to edit.
const forbidden = [_][]const u8{
    "sin", "cos", "tan", "asin", "acos",  "atan", "atan2",
    "pow", "exp", "log", "fmod", "hypot", "cbrt",
};

/// Mnemonics that transfer control to a named symbol.
///
/// `jmp` / `b` are here because a TAIL CALL is a call: a leaf that ends in
/// `jmp cosf` has called `cosf` just as surely as one that ends in
/// `call cosf; ret`, and at `-OReleaseSafe` the backend emits both shapes. An
/// inventory that only knew `call` would be blind to exactly the optimised form
/// the shipped build uses.
const call_mnemonics = [_][]const u8{
    // x86_64
    "call", "callq", "jmp", "jmpq",
    // AArch64
    "bl",   "blr",   "b",   "br",
};

/// A finding: where, and what.
const Hit = struct {
    file: []const u8,
    line_no: usize,
    line: []const u8,
    symbol: []const u8,
};

/// Whether `c` can appear inside an assembler symbol name.
fn isSymbolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$';
}

/// Strip the decorations a linker or an ABI puts around a symbol name, leaving
/// the bare C identifier.
///
/// Three, each observed on a target the engine ships: a leading `__imp_`
/// (Windows import thunks), leading underscores (Mach-O prefixes exactly one,
/// a C library's internal alias may carry two), and a trailing `@PLT` /
/// `@GOTPCREL` / `@plt` relocation suffix (ELF). `__imp_` is removed FIRST,
/// because stripping underscores first would eat its own prefix and leave
/// `imp_cos`, which matches nothing.
fn bareSymbol(token: []const u8) []const u8 {
    var s = token;
    if (std.mem.startsWith(u8, s, "__imp_")) s = s["__imp_".len..];
    while (s.len > 0 and s[0] == '_') s = s[1..];
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[0..at];
    return s;
}

/// Whether an operand names a forbidden function, in any addressing form.
///
/// The operand is TOKENISED and every token tested, rather than the operand
/// being treated as one symbol. A direct call is `call cosf@PLT`, but the same
/// call under `-fno-plt` is `call qword ptr [rip + cosf@GOTPCREL]` and on
/// AArch64 a far call goes through `adrp`/`ldr` into `blr xN`. Reading the
/// operand as a single name serves the first shape and silently misses the
/// second — a false negative on exactly the build flags a distribution is most
/// likely to add. Tokenising costs nothing in false positives, since matching
/// is exact against thirteen names and no register, size keyword or address
/// arithmetic spells one of them.
fn operandNamesForbidden(operand: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < operand.len) {
        if (!isSymbolChar(operand[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < operand.len and (isSymbolChar(operand[i]) or operand[i] == '@')) i += 1;
        if (matchesForbidden(bareSymbol(operand[start..i]))) |name| return name;
    }
    return null;
}

/// Whether `symbol` is one of the forbidden functions, in any of the spellings
/// a C library uses.
///
/// A libm function `f` ships as `f` (double), `f` + `"f"` (single) and `f` +
/// `"l"` (long double). Matching is EXACT against those three spellings and
/// never by prefix: a prefix test would flag `cosine_of`, `expand`, `logger`,
/// `powerset` and every Zig symbol whose mangled name happens to begin with one
/// of the thirteen — which is how an inventory acquires a suppression list and
/// stops meaning anything.
fn matchesForbidden(symbol: []const u8) ?[]const u8 {
    for (forbidden) |name| {
        if (std.mem.eql(u8, symbol, name)) return name;
        if (symbol.len == name.len + 1 and
            std.mem.startsWith(u8, symbol, name) and
            (symbol[name.len] == 'f' or symbol[name.len] == 'l')) return name;
    }
    return null;
}

/// Scan one assembly listing, appending every finding to `out`.
///
/// Returns the number of call instructions examined. The COUNT is returned and
/// reported, not discarded: an inventory that examined zero calls and found
/// zero transcendentals is indistinguishable, from its exit code alone, from
/// one that examined thousands — and the first is a broken harness reporting
/// success, which is the failure mode this whole file is shaped against.
fn scan(
    gpa: std.mem.Allocator,
    file: []const u8,
    text: []const u8,
    out: *std.ArrayListUnmanaged(Hit),
) !usize {
    var examined: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // First token is the mnemonic. ANCHORED at the start of the trimmed
        // line — never a substring search over the whole line.
        const mnemonic_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const mnemonic = line[0..mnemonic_end];

        var is_call = false;
        for (call_mnemonics) |m| {
            if (std.mem.eql(u8, mnemonic, m)) {
                is_call = true;
                break;
            }
        }
        if (!is_call) continue;
        examined += 1;

        // Operand: the rest of the line up to a comment. The comma is NOT a
        // terminator — `call qword ptr [rip + sym]` has none and an AArch64
        // `blr` operand may be a register list — so the whole operand is
        // tokenised instead (see `operandNamesForbidden`).
        var operand = std.mem.trim(u8, line[mnemonic_end..], " \t");
        for ([_][]const u8{ "//", "#", ";" }) |marker| {
            if (std.mem.indexOf(u8, operand, marker)) |c| operand = operand[0..c];
        }
        operand = std.mem.trim(u8, operand, " \t");
        if (operand.len == 0) continue;

        if (operandNamesForbidden(operand)) |name| {
            try out.append(gpa, .{
                .file = file,
                .line_no = line_no,
                .line = line,
                .symbol = name,
            });
        }
    }
    return examined;
}

/// Read a whole assembly listing into `gpa`.
fn readListing(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, @intCast(stat.size));
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(buf);
    return buf;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        std.debug.print("usage: asm_inventory <file.s> [file.s ...]\n", .{});
        return error.NoInput;
    }

    var hits: std.ArrayListUnmanaged(Hit) = .empty;
    var total_calls: usize = 0;

    for (args[1..]) |path| {
        const text = readListing(gpa, io, path) catch |err| {
            std.debug.print("asm_inventory: cannot read {s}: {t}\n", .{ path, err });
            return err;
        };
        const examined = try scan(gpa, path, text, &hits);
        total_calls += examined;
        std.debug.print("asm_inventory: {s} — {d} call sites examined\n", .{ path, examined });
    }

    // NON-VACUITY, enforced rather than hoped for. Reading a listing with no
    // call instruction at all means the emit path changed under us (wrong
    // artifact, empty file, a flag that stopped producing assembly), and a
    // clean bill of health from such a run is worthless. Fail loudly instead.
    if (total_calls == 0) {
        std.debug.print(
            "asm_inventory: FAIL — zero call sites across {d} file(s). " ++
                "The listings are empty or are not assembly; the inventory proved nothing.\n",
            .{args.len - 1},
        );
        return error.NoCallSitesExamined;
    }

    if (hits.items.len == 0) {
        std.debug.print(
            "asm_inventory: OK — no external transcendental in {d} call site(s) across {d} file(s).\n",
            .{ total_calls, args.len - 1 },
        );
        return;
    }

    std.debug.print("asm_inventory: FAIL — {d} external transcendental call(s):\n", .{hits.items.len});
    for (hits.items) |h| {
        std.debug.print("  {s}:{d}: [{s}] {s}\n", .{ h.file, h.line_no, h.symbol, h.line });
    }
    return error.ExternalTranscendentalFound;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

fn scanText(text: []const u8) !struct { hits: usize, examined: usize } {
    var out: std.ArrayListUnmanaged(Hit) = .empty;
    defer out.deinit(testing.allocator);
    const examined = try scan(testing.allocator, "<fixture>", text, &out);
    return .{ .hits = out.items.len, .examined = examined };
}

/// Assert that every line in `cases` is flagged exactly once, NAMING the case
/// that failed. A loop under a bare `expectEqual` reports "expected 1, found 0"
/// and leaves the reader to find which of a dozen strings stopped matching.
fn expectAllFlagged(cases: []const []const u8) !void {
    for (cases) |c| {
        const r = try scanText(c);
        if (r.hits != 1) {
            std.debug.print("asm_inventory: case should have been flagged: {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
}

/// The mirror: assert that no line in `cases` is flagged, naming the offender.
fn expectNoneFlagged(cases: []const []const u8) !void {
    for (cases) |c| {
        const r = try scanText(c);
        if (r.hits != 0) {
            std.debug.print("asm_inventory: case should NOT have been flagged: {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
}

test "asm_inventory: flags a direct call, in each platform's symbol spelling" {
    // THE counter-factual, first half. A scanner that never fires is
    // indistinguishable from a clean tree. Each line is a spelling actually
    // emitted by one of the three targets — the ELF PLT form, the Mach-O
    // leading underscore, the Windows import thunk, the AArch64
    // branch-with-link — so this block owns exactly one mechanism: resolving a
    // direct operand to a bare C identifier.
    try expectAllFlagged(&.{
        "\tcallq\tcosf@PLT",
        "  call  cos",
        "\tcall\t_cosf",
        "\tcall\t__imp_cos",
        "\tbl\t_sinf",
        "\tbl\tatan2",
        "\tcallq\tfmodl",
        "\tbl\tcbrt",
        "\tcall\tlogf",
        "\tbl\tacos",
        "\tcall\ttanf",
        "\tbl\tasin",
    });
}

test "asm_inventory: flags a TAIL call, which an optimised leaf emits" {
    // Its own block because it owns a DIFFERENT mechanism: the mnemonic table,
    // not the operand parse. A leaf ending in `jmp cosf` has called `cosf` just
    // as surely as one ending in `call cosf; ret`, and an inventory that knew
    // only `call` would be blind to precisely the optimised shape the shipped
    // build uses. Folded into the block above, a mnemonic table that lost `jmp`
    // would still leave that block green on its other eleven rows.
    try expectAllFlagged(&.{
        "\tjmp\tpowf@PLT",
        "\tb\texp",
        "\tjmpq\tsin",
        "\tbr\tcosf",
    });
}

test "asm_inventory: flags an INDIRECT call through the GOT" {
    // Third mechanism: tokenising the operand rather than reading it as one
    // symbol. `-fno-plt` turns every direct call into a load through the GOT,
    // and a scanner that reads the operand whole misses all of these — a false
    // negative on exactly the build flag a distribution is most likely to add.
    try expectAllFlagged(&.{
        "\tcall\t*hypot@GOTPCREL(%rip)",
        "\tcall\tqword ptr [rip + cosf@GOTPCREL]",
        "\tcallq\t*sin@GOTPCREL(%rip)",
    });
}

test "asm_inventory: flags a symbol behind more than one leading underscore" {
    // Fourth mechanism: decoration stripping. A C library's internal alias
    // carries two underscores where Mach-O prefixes one, so stripping exactly
    // one would let `__sinf` through.
    try expectAllFlagged(&.{
        "\tbl\t__sinf",
        "\tcall\t__cos",
    });
}

test "asm_inventory: does not flag a name that merely contains a forbidden one" {
    // The reason matching is EXACT rather than by prefix. Every operand below is
    // a real shape from a Zig listing; a prefix test flags all of them and the
    // inventory acquires a suppression list within a week, at which point it has
    // stopped meaning anything.
    try expectNoneFlagged(&.{
        "\tcall\tcosine_table",
        "\tcall\texpand_buffer",
        "\tbl\tlogger_write",
        "\tcall\tpowerset",
        "\tcall\ttangent_basis",
        "\tbl\tforge_3d.trig.cos", // a Zig namespace path, not the C symbol
        "\tcall\t__zig_probe_stack",
        "\tbl\tmemcpy",
        "\tcall\tsqrt", // ARCH-031 rule 4 exempts @sqrt explicitly
    });
}

test "asm_inventory: tokenising an operand does not invent a symbol from it" {
    // The cost side of the indirect-call mechanism above, and its own claim:
    // registers, size keywords and address arithmetic are tokens too, and none
    // of them may be read as a function name. Folded into the block above, a
    // tokeniser regression would be reported as a prefix-matching regression.
    try expectNoneFlagged(&.{
        "\tcall\tqword ptr [rip + memcpy@GOTPCREL]",
        "\tblr\tx16",
        "\tcall\tqword ptr [rbx + 8]",
        "\tbl\tx0",
    });
}

test "asm_inventory: the mnemonic anchor rejects text that is not an instruction" {
    // ONE mechanism — the anchor — sampled across the line kinds a listing
    // actually contains. Kept as a single block for that reason, with the case
    // named on failure: these are not independent claims, they are one claim
    // under the shapes that would break it.
    try expectNoneFlagged(&.{
        "\t.section\t.text.cos,\"ax\",@progbits",
        "\t# call cosf here once, in 2023",
        "cosf:",
        "\t.ascii\t\"call exp\"",
        "\t.type\tcos,@function",
        "\tmovsd\tcos_table(%rip), %xmm0",
        "// bl atan2 — an old comment",
    });
}

test "asm_inventory: call sites are counted, so a silent empty listing is visible" {
    // The count is the harness's own liveness signal — `main` refuses a run
    // that examined zero call sites. This pins that the counter counts calls
    // and not lines.
    const listing =
        "\t.text\n" ++
        "\tpushq\t%rbp\n" ++
        "\tcall\tmemcpy@PLT\n" ++
        "\tbl\tsome_zig_fn\n" ++
        "\tret\n";
    const r = try scanText(listing);
    try testing.expectEqual(@as(usize, 2), r.examined);
    try testing.expectEqual(@as(usize, 0), r.hits);

    const empty = try scanText("\t.text\n\tnop\n");
    try testing.expectEqual(@as(usize, 0), empty.examined);
}

test "asm_inventory: the forbidden table is the invariant's list, all thirteen" {
    // A count pin. `ARCH-031` rule 4 enumerates thirteen names; a table that
    // silently loses one would leave a real call unreported and every test
    // above would still pass, since none of them sweeps the table.
    try testing.expectEqual(@as(usize, 13), forbidden.len);
    for (forbidden) |name| {
        try testing.expect(matchesForbidden(name) != null);
        // …and each in its `f` and `l` spellings.
        var buf: [16]u8 = undefined;
        try testing.expect(matchesForbidden(try std.fmt.bufPrint(&buf, "{s}f", .{name})) != null);
        try testing.expect(matchesForbidden(try std.fmt.bufPrint(&buf, "{s}l", .{name})) != null);
    }
}
