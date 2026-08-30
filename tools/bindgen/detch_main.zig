//! CLI behind `zig build bindgen-detch` and `zig build bindgen-check`
//! (M1.1.15.2 G3, `engine-c-bindings.md` §8.4.4).
//!
//! Two modes over the same rendering, which is the point: the check cannot
//! disagree with the regeneration, because both call `emit_detch.emit` and
//! differ only in what they do with the bytes.
//!
//!   - `--write` renders every manifest entry's services and writes them in
//!     place. Manual, never on an incremental build (§8.4.4).
//!   - default renders and COMPARES against the committed artifact, reporting
//!     `E1902` with a line-by-line difference. It writes nothing, so a failing
//!     check cannot leave the tree half-regenerated.

const std = @import("std");
const emit_detch = @import("emit_detch.zig");
const manifest = @import("services.zig");
const diagnostics = @import("weld_etch").diagnostics;

const emitter_path = "tools/bindgen/emit_detch.zig";

/// The code and name are read from `weld_etch`'s own registry rather than
/// spelled here, so the tool and the compiler cannot disagree about what E1902
/// is called.
const mismatch_code = diagnostics.DiagnosticCode.declaration_file_implementation_mismatch.code();
const mismatch_name = diagnostics.DiagnosticCode.declaration_file_implementation_mismatch.name();

/// Diagnostics go through `std.debug.print` and not a buffered
/// `std.Io.File.stderr().writer`, and that is a MEASURED choice rather than a
/// stylistic one: with the buffered writer this tool printed a four-line
/// divergence report and only the LAST line reached stderr, both under `zig
/// build` and when the binary was run directly with stdout and stderr captured
/// separately. The cause is not diagnosed here — a build tool is not the place
/// to chase it — but a guard whose report is silently truncated is half a guard,
/// and the requirement is that the diff be readable.
pub fn main(init: std.process.Init) !void {
    // The process arena, like every other tool under `tools/` — this runs once
    // per build step and frees at exit, so a tracking allocator would buy
    // nothing but a teardown path to get wrong.
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var write = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--write")) write = true;
    }

    const dir = std.Io.Dir.cwd();
    var divergences: usize = 0;
    var emitted: usize = 0;

    inline for (manifest.entries) |entry| {
        inline for (comptime manifest.specsOf(entry)) |spec| {
            const path = try manifest.artifactPath(gpa, entry, spec);
            const rendered = try emit_detch.emitAlloc(gpa, spec, entry.source_path, emitter_path);
            emitted += 1;

            if (write) {
                var file = try dir.createFile(io, path, .{});
                defer file.close(io);
                var wbuf: [16 * 1024]u8 = undefined;
                var fw = file.writer(io, &wbuf);
                try fw.interface.writeAll(rendered);
                try fw.interface.flush();
                std.debug.print("bindgen-detch: wrote {s}\n", .{path});
            } else if (readWholeFile(gpa, io, dir, path)) |committed| {
                var lines: std.ArrayListUnmanaged(emit_detch.DiffLine) = .empty;
                if (try emit_detch.diff(gpa, committed, rendered, &lines)) {
                    divergences += 1;
                    std.debug.print(
                        "{s} {s}: '{s}' diverges from the emitter's output on '{s}'\n",
                        .{ mismatch_code, mismatch_name, path, entry.source_path },
                    );
                    for (lines.items) |l| {
                        switch (l.kind) {
                            .same => {},
                            .expected_only => std.debug.print("  {d:>4} - {s}\n", .{ l.line_no, l.text }),
                            .actual_only => std.debug.print("  {d:>4} + {s}\n", .{ l.line_no, l.text }),
                        }
                    }
                    std.debug.print("  (- committed, + emitted from the Zig ServiceSpec)\n", .{});
                }
            } else |e| {
                // A missing artifact is a divergence and not a soft warning: an
                // uncommitted `.d.etch` is exactly the state this guard exists to
                // refuse, and treating it as "nothing to compare" would make the
                // check pass on the one tree where it must not.
                divergences += 1;
                std.debug.print(
                    "{s} {s}: cannot read the committed artifact '{s}' ({t}) — run `zig build bindgen-detch`\n",
                    .{ mismatch_code, mismatch_name, path, e },
                );
            }
        }
    }

    if (emitted == 0) {
        // A manifest that walks to nothing would make the check pass by having
        // nothing to check — the vacuity this whole gate exists to prevent.
        std.debug.print("bindgen-detch: the manifest produced NO service; refusing to report success\n", .{});
        return error.EmptyManifest;
    }
    if (divergences != 0) return error.DeclarationFileMismatch;
    if (!write) {
        std.debug.print("bindgen-check: {d} .d.etch artifact(s) match their ServiceSpec\n", .{emitted});
    }
}

fn readWholeFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, stat.size);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    return buf[0..written];
}
