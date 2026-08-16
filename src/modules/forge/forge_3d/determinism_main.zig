//! `zig build forge-determinism` — the instrument's command-line shell.
//!
//! DELIBERATELY THIN. Everything it reports is computed by `run.zig`, which is a
//! library precisely because two later milestones replay it (M1.1.25 at N
//! workers, M1.A on a rebuilt scheduler DAG). A harness whose logic lived in its
//! `main` would have to be re-entered through a process to be replayed.
//!
//! Usage:
//!   forge-determinism                     run, compare against committed witnesses
//!   forge-determinism --write-witness DIR generate the witnesses into DIR
//!
//! Regeneration is a DECLARED ACT — it is a separate flag, never a side effect of
//! a mismatch, and the brief requires it to be stated in the PR body with its
//! motive. A witness silently regenerated to make a cell green destroys exactly
//! the property it carries.
//!
//! **Why the entry sits HERE and not beside the harness it drives.** A Zig
//! module's import path is rooted at its root source file's directory, so an
//! executable rooted inside `tests/determinism/` cannot reach `config.zig` or
//! `root.zig` at all — measured, `error: import of file outside module path` on
//! every upward import. The harness proper stays in `tests/determinism/`; this
//! one file is the entry, and it has to live at the level its imports descend
//! from.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const run = @import("tests/determinism/run.zig");
const trace = @import("tests/determinism/trace.zig");
const witness = @import("tests/determinism/witness.zig");

// The two halves of a witness key live in `witness.zig`, beside the files they
// name. Holding a second copy here is how a key drifts from the artifact it is
// supposed to identify — the drift shape this repository has already paid for.
const precision_tag = witness.precision_tag;
const mode_tag = witness.mode_tag;

fn writeFile(io: std.Io, dir_path: []const u8, name: []const u8, bytes: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    var w = f.writer(io, &.{});
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(gpa);

    var write_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--write-witness") and i + 1 < argv.len) {
            i += 1;
            write_dir = argv[i];
        }
    }

    std.debug.print("forge-determinism: scenario=canonical precision={s} mode={s} workers=1\n", .{
        precision_tag, mode_tag,
    });

    var a = try run.runCanonical(gpa, run.chain_frames);
    defer a.deinit(gpa);

    // SELF-REPRODUCIBILITY, reported on every invocation and not only in the test
    // suite: it is the claim every other line here rests on, and a run that
    // cannot repeat itself makes the rest of the output meaningless rather than
    // merely unverified.
    var b = try run.runCanonical(gpa, run.chain_frames);
    defer b.deinit(gpa);
    const reproducible = std.mem.eql(u8, a.chain.items, b.chain.items) and
        std.mem.eql(u8, a.discrete.items, b.discrete.items) and
        std.mem.eql(u8, a.poses.items, b.poses.items);
    std.debug.print("self-reproducible : {s} ({d} frames, {d} B chain, {d} B discrete, {d} B poses)\n", .{
        if (reproducible) "OK" else "FAIL",
        run.chain_frames,
        a.chain.items.len,
        a.discrete.items.len,
        a.poses.items.len,
    });

    if (write_dir) |dir| {
        var name_buf: [128]u8 = undefined;
        try writeFile(io, dir, try std.fmt.bufPrint(&name_buf, "continuous-chain-{s}-{s}.bin", .{ precision_tag, mode_tag }), a.chain.items);
        try writeFile(io, dir, try std.fmt.bufPrint(&name_buf, "discrete-{s}.bin", .{precision_tag}), a.discrete.items);
        try writeFile(io, dir, try std.fmt.bufPrint(&name_buf, "reference-window-{s}.bin", .{precision_tag}), a.poses.items);
        std.debug.print("witnesses written : {s}\n", .{dir});
    }

    // THE CHAIN VERDICT — level 1, x86_64 only. On any other ISA the comparison
    // is SKIPPED and says so: asserting it there would be asserting inter-ISA
    // bit-exactness, which C1.1 places out of Phase 1. A skip that prints nothing
    // is indistinguishable from a pass, and this milestone has paid for that three
    // times.
    var failed = false;
    if (!witness.chain_applies) {
        std.debug.print("chain verdict     : SKIPPED (level 1 is intra-ISA; this host is {t})\n", .{builtin.cpu.arch});
    } else if (witness.chain) |w| {
        if (witness.firstChainMismatch(a.chain.items, w, trace.digest_len)) |m| {
            std.debug.print("chain verdict     : MISMATCH at frame {d}\n", .{m.frame});
            failed = true;
        } else {
            std.debug.print("chain verdict     : OK ({d} frames)\n", .{run.chain_frames});
        }
    } else {
        std.debug.print("chain verdict     : SKIPPED (no witness for mode {s})\n", .{mode_tag});
    }

    // THE FOUR TRACE VERDICTS — level 2 point 1, every cell, ISA included. Named
    // one by one because they are four independent claims and a single verdict
    // would discard which invariant moved.
    if (try witness.firstDiscreteMismatch(a.discrete.items, witness.discrete, run.window_frames)) |m| {
        for (std.enums.values(witness.Trace)) |t| {
            const bad = m.trace != null and m.trace.? == t;
            std.debug.print("trace verdict     : {s: <30} {s}\n", .{
                t.label(),
                if (bad) "MISMATCH" else "not reached",
            });
        }
        std.debug.print("                    first disagreement at frame {d}\n", .{m.frame});
        failed = true;
    } else {
        for (std.enums.values(witness.Trace)) |t| {
            std.debug.print("trace verdict     : {s: <30} OK\n", .{t.label()});
        }
    }

    // The divergence frame, measured against the COMMITTED reference window. On
    // the cell that produced it this is a self-comparison and must report none;
    // on the ARM64 cell it is the level-2 point-2 characterisation, and its
    // REGRESSION between milestones is the signal rather than its value.
    const div = try run.divergenceFrame(gpa, witness.window, a.pose_stride);
    if (div) |f| {
        std.debug.print("divergence frame  : {d}\n", .{f});
    } else {
        std.debug.print("divergence frame  : none within K={d}\n", .{run.window_frames});
    }

    if (!reproducible) return error.NotSelfReproducible;
    if (failed) return error.WitnessMismatch;
}
