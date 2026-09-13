//! `tools/view_asm_equiv` — establish, in EMITTED ASSEMBLY, that reaching a
//! component through a declared-access `View` costs what reaching it through a
//! `*World` costs.
//!
//! The claim is about generated code, so it is read in the listing and not in
//! the source — the same discipline, and the same mechanism, as
//! `tools/asm_inventory`: a build step emits the assembly of a witness pair and
//! hands the path here.
//!
//! **Two verdicts, and the stronger one is the common case.** A backend that
//! finds the two bodies byte-identical emits ONE and aliases both exported
//! names to it. That is identity rather than equality, and it is what this pair
//! actually produces at `-OReleaseSafe` — so the scanner resolves alias chains
//! first and reports folding when it finds it. When the two names resolve to
//! different labels, it falls back on comparing the bodies instruction for
//! instruction.
//!
//! **Why a scanner and not `diff`.** Two bodies identical in every way that
//! matters still differ textually: local labels are numbered per function, so
//! `LBB398_2` faces `LBB412_2`. A textual diff reports those and says nothing
//! about the instructions. The scanner normalises the function ordinal out of
//! every local label and compares what is left.
//!
//! **The vacuity guard earns the verdict.** Two empty bodies compare equal, and
//! two names aliased to a body that emits nothing fold trivially. A resolved
//! body with no instruction is an ERROR and never a pass — `asm_inventory`
//! learned that on a re-export file that emitted nothing and would otherwise
//! have reported clean.

const std = @import("std");

/// The two exported symbols. `via_view` is the subject; `via_world` is the
/// reference.
const via_view = "weld_zero_cost_via_view";
const via_world = "weld_zero_cost_via_world";

/// Whether `line` defines a label.
fn isLabel(line: []const u8) bool {
    return std.mem.endsWith(u8, line, ":");
}

/// Whether `line` is an assembler directive rather than an instruction.
///
/// Directives carry alignment, section, CFI and debug metadata; none of it is
/// executed, and two functions at different offsets legitimately differ there.
fn isDirective(line: []const u8) bool {
    return line.len > 0 and line[0] == '.';
}

/// Drop a leading `_`, which Mach-O prepends to every external symbol.
fn bare(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "_")) name[1..] else name;
}

/// Resolve `symbol` through the listing's alias chain.
///
/// An emitter that folds two identical functions keeps both exported names and
/// binds them to one body with `_name = _target` (Mach-O) or
/// `.set name, target` (ELF). Following the chain is what lets folding be
/// REPORTED instead of read as a missing symbol — which is how the first
/// version of this scanner failed on its own witness.
///
/// Returns the last name in the chain, which is the label the body carries.
fn resolveAlias(listing: []const u8, symbol: []const u8) []const u8 {
    var current = symbol;
    // Bounded: a chain longer than the listing's line count cannot exist, and
    // a cyclic `.set` would otherwise spin here forever.
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        var found: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, ".set ")) {
                const rest = std.mem.trim(u8, line[5..], " \t");
                var parts = std.mem.splitScalar(u8, rest, ',');
                const lhs = std.mem.trim(u8, parts.next() orelse continue, " \t");
                const rhs = std.mem.trim(u8, parts.next() orelse continue, " \t");
                if (std.mem.eql(u8, bare(lhs), bare(current))) found = rhs;
                continue;
            }
            // `_name = _target`, with no directive and no trailing colon.
            if (isDirective(line) or isLabel(line)) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const lhs = std.mem.trim(u8, line[0..eq], " \t");
            const rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (lhs.len == 0 or rhs.len == 0) continue;
            if (std.mem.indexOfAny(u8, lhs, " \t") != null) continue;
            if (std.mem.eql(u8, bare(lhs), bare(current))) found = rhs;
        }
        const next = found orelse return current;
        if (std.mem.eql(u8, bare(next), bare(current))) return current;
        current = next;
    }
    return current;
}

/// Rewrite the per-function ordinal out of `LBB<fn>_<n>` and `Lfunc_end<fn>`,
/// and drop the temporary labels an emitter numbers globally.
///
/// Only the ordinal goes; the block index stays. Two bodies branching to
/// DIFFERENT blocks must still differ.
fn normalise(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "LBB")) {
            try out.appendSlice(arena, "LBB");
            i += 3;
            while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], "Lfunc_end")) {
            try out.appendSlice(arena, "Lfunc_end");
            i += 9;
            while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
            continue;
        }
        try out.append(arena, line[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Whether `line` is a label an emitter numbers globally rather than per
/// function (`Ltmp1234:`, `Lloh99:`). Two identical bodies at different offsets
/// carry different ones, and none of them is executed.
fn isEmitterTempLabel(line: []const u8) bool {
    if (!isLabel(line)) return false;
    return std.mem.startsWith(u8, line, "Ltmp") or std.mem.startsWith(u8, line, "Lloh") or
        std.mem.startsWith(u8, line, "Lfunc_begin");
}

/// Collect the instructions of the function whose body carries `label`.
fn bodyOf(arena: std.mem.Allocator, listing: []const u8, label: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    var inside = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (!inside) {
            if (isLabel(line) and std.mem.eql(u8, bare(line[0 .. line.len - 1]), bare(label))) {
                inside = true;
            }
            continue;
        }
        if (isDirective(line)) {
            // `.cfi_endproc` closes the body on both emitters this build targets.
            if (std.mem.startsWith(u8, line, ".cfi_endproc")) break;
            if (std.mem.startsWith(u8, line, ".size")) break;
            continue;
        }
        if (isEmitterTempLabel(line)) continue;
        if (isLabel(line) and !std.mem.startsWith(u8, line, "L") and
            !std.mem.startsWith(u8, line, ".L")) break;
        try out.append(arena, try normalise(arena, line));
    }
    if (!inside) return error.SymbolNotFound;
    return out.toOwnedSlice(arena);
}

/// Read a whole assembly listing. Same shape as `tools/asm_inventory`, and for
/// the same reason: `std.fs.cwd()` is gone in Zig 0.16 and the replacement
/// takes the `io` the Juicy Main hands down.
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
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 2) {
        std.debug.print("usage: view_asm_equiv <listing.s>\n", .{});
        return error.BadUsage;
    }

    const listing = readListing(arena, io, args[1]) catch |e| {
        std.debug.print("view-asm-equiv: cannot read {s}: {t}\n", .{ args[1], e });
        return e;
    };

    const view_label = resolveAlias(listing, via_view);
    const world_label = resolveAlias(listing, via_world);

    const folded = std.mem.eql(u8, bare(view_label), bare(world_label));

    const subject = bodyOf(arena, listing, view_label) catch |e| {
        std.debug.print(
            "view-asm-equiv: `{s}` resolves to `{s}`, whose body is not in {s} ({t})\n",
            .{ via_view, view_label, args[1], e },
        );
        return error.SymbolNotFound;
    };

    // NON-VACUITY, enforced rather than hoped for. Two empty bodies compare
    // equal and two names aliased to an empty body fold; either way the run
    // would report a zero-cost view having examined nothing.
    if (subject.len == 0) {
        std.debug.print(
            "view-asm-equiv: REFUSED — `{s}` resolves to `{s}` with ZERO instructions. " ++
                "An empty body proves nothing; the listing is not what was measured.\n",
            .{ via_view, view_label },
        );
        return error.EmptyBody;
    }

    if (folded) {
        std.debug.print(
            "view-asm-equiv: OK — `{s}` and `{s}` are ONE body of {d} instruction(s) " ++
                "(`{s}`). The backend found them byte-identical and emitted a single " ++
                "function: identity, not equality.\n",
            .{ via_view, via_world, subject.len, view_label },
        );
        return;
    }

    const reference = bodyOf(arena, listing, world_label) catch |e| {
        std.debug.print(
            "view-asm-equiv: `{s}` resolves to `{s}`, whose body is not in {s} ({t})\n",
            .{ via_world, world_label, args[1], e },
        );
        return error.SymbolNotFound;
    };
    if (reference.len == 0) {
        std.debug.print(
            "view-asm-equiv: REFUSED — `{s}` resolves to `{s}` with ZERO instructions.\n",
            .{ via_world, world_label },
        );
        return error.EmptyBody;
    }

    if (subject.len != reference.len) {
        std.debug.print(
            "view-asm-equiv: DIFFERENT LENGTH — `{s}` emits {d} instruction(s), `{s}` emits {d}.\n",
            .{ via_view, subject.len, via_world, reference.len },
        );
        dump(subject, reference);
        return error.NotEquivalent;
    }
    for (subject, reference, 0..) |a, b, i| {
        if (!std.mem.eql(u8, a, b)) {
            std.debug.print(
                "view-asm-equiv: DIVERGES at instruction {d}\n  via view : {s}\n  via world: {s}\n",
                .{ i, a, b },
            );
            dump(subject, reference);
            return error.NotEquivalent;
        }
    }

    std.debug.print(
        "view-asm-equiv: OK — {d} instruction(s) compared one by one, identical.\n",
        .{subject.len},
    );
}

fn dump(subject: []const []const u8, reference: []const []const u8) void {
    std.debug.print("--- {s} ---\n", .{via_view});
    for (subject) |i| std.debug.print("  {s}\n", .{i});
    std.debug.print("--- {s} ---\n", .{via_world});
    for (reference) |i| std.debug.print("  {s}\n", .{i});
}

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an alias chain resolves to the body's label" {
    const listing =
        "_weld_zero_cost_via_world = _surface.body\n" ++
        "_weld_zero_cost_via_view = _surface.body\n" ++
        "_surface.body:\n\tret\n";
    try testing.expectEqualStrings("_surface.body", resolveAlias(listing, via_view));
    try testing.expectEqualStrings("_surface.body", resolveAlias(listing, via_world));
}

test "a symbol with no alias resolves to itself" {
    const listing = "_weld_zero_cost_via_view:\n\tret\n";
    try testing.expectEqualStrings(via_view, resolveAlias(listing, via_view));
}

test "the body stops at cfi_endproc and drops emitter temporaries" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const listing =
        "_sym:\n" ++
        "\t.cfi_startproc\n" ++
        "Ltmp1:\n" ++
        "\ttst\tx0, #0x7\n" ++
        "\tb.ne\tLBB398_2\n" ++
        "Lloh9:\n" ++
        "LBB398_2:\n" ++
        "\tret\n" ++
        "\t.cfi_endproc\n" ++
        "_other:\n" ++
        "\tnop\n";
    const body = try bodyOf(arena.allocator(), listing, "_sym");
    // Four entries: two instructions, the block label, and the final `ret`.
    // `Ltmp1` and `Lloh9` are gone — an emitter numbers them globally, so two
    // identical bodies at different offsets carry different ones.
    try testing.expectEqual(@as(usize, 4), body.len);
    try testing.expectEqualStrings("tst\tx0, #0x7", body[0]);
    try testing.expectEqualStrings("b.ne\tLBB_2", body[1]);
    try testing.expectEqualStrings("LBB_2:", body[2]);
    try testing.expectEqualStrings("ret", body[3]);
}

test "normalise drops the function ordinal and keeps the block index" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = try normalise(arena.allocator(), "b.ne\tLBB398_2");
    const b = try normalise(arena.allocator(), "b.ne\tLBB412_2");
    const c = try normalise(arena.allocator(), "b.ne\tLBB412_3");
    // Same block, different function: equal. Different block: NOT equal —
    // without that, two bodies branching elsewhere would compare identical.
    try testing.expectEqualStrings(a, b);
    try testing.expect(!std.mem.eql(u8, a, c));
}

test "a missing symbol is an error, never an empty body" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const listing = "_elsewhere:\n\tret\n";
    try testing.expectError(error.SymbolNotFound, bodyOf(arena.allocator(), listing, "_absent"));
}
