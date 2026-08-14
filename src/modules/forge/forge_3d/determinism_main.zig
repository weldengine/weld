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

/// The precision half of a witness key — the file names are keyed by it because
/// `-Dphysics_f64` changes every byte of every artifact.
const precision_tag = if (config.Real == f32) "f32" else "f64";
/// The optimize half. Keyed because Debug/ReleaseSafe equality under `.strict` is
/// a HYPOTHESIS; keying it makes the hypothesis a test rather than an assumption.
const mode_tag = @tagName(builtin.mode);

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

    // The divergence frame, measured against this run's OWN reference window.
    // On x86_64 that is a self-comparison and must report none; the number that
    // matters is the one the ARM64 cell computes against the COMMITTED window,
    // and that comparison lands with the witnesses at Gate C/D.
    const div = try run.divergenceFrame(gpa, a.poses.items, a.pose_stride);
    if (div) |f| {
        std.debug.print("divergence frame  : {d}\n", .{f});
    } else {
        std.debug.print("divergence frame  : none within K={d}\n", .{run.window_frames});
    }

    if (!reproducible) return error.NotSelfReproducible;
}
