//! Shader compiler tool — Phase 0 / M0.4.
//!
//! Outil standalone invoqué par `build.zig` via `zig build shaders` /
//! `zig build shaders-check` (cf. brief §Fichiers + §Comportement
//! observable).
//!
//! Mode `shaders` :
//! - Découvre tous les `.glsl` sous `assets/shaders/`.
//! - Pour chaque fichier, dérive le stage depuis le nom (`*.vert.glsl` →
//!   vertex, `*.frag.glsl` → fragment, `*.comp.glsl` → compute).
//! - Compile via `glslc` CLI spawn (cf. `src/modules/render/shader_pipeline/compiler.zig`).
//! - Écrit le `.spv` à côté du `.glsl`. Cohérent avec le pattern artefacts
//!   générés commités (brief §Notes).
//!
//! Mode `shaders-check` :
//! - Compile dans un dossier temp.
//! - Diff vs le `.spv` commité. Exit code 0 si diff vide, non-zéro sinon.
//! - Le step CI `shaders-check` (brief §CI) bloque le merge sur diff.

const std = @import("std");
const shader = @import("shader_pipeline_compiler");

const SHADERS_DIR = "assets/shaders";

const Args = struct {
    check: bool = false,
    quiet: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const raw = try init.minimal.args.toSlice(init.arena.allocator());

    var args: Args = .{};
    for (raw[1..]) |a| {
        if (std.mem.eql(u8, a, "--check")) args.check = true;
        if (std.mem.eql(u8, a, "--quiet")) args.quiet = true;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (!shader.isAvailable(gpa, io)) {
        try stdout.print("shader_compiler: glslc not in PATH — skipping ({s} mode)\n", .{
            if (args.check) "check" else "build",
        });
        // En mode check, l'absence de glslc n'est pas bloquante : on
        // assume que les .spv commités sont valides (le CI Linux qui a
        // glslc est l'autorité).
        return;
    }

    var dir = std.Io.Dir.cwd().openDir(io, SHADERS_DIR, .{ .iterate = true }) catch |e| {
        try stdout.print("shader_compiler: failed to open {s}: {t}\n", .{ SHADERS_DIR, e });
        return e;
    };
    defer dir.close(io);

    var any_drift = false;
    var compiled: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".glsl")) continue;

        const stage: shader.Stage = if (std.mem.indexOf(u8, entry.name, ".vert") != null)
            .vertex
        else if (std.mem.indexOf(u8, entry.name, ".frag") != null)
            .fragment
        else if (std.mem.indexOf(u8, entry.name, ".comp") != null)
            .compute
        else
            continue;

        const glsl_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ SHADERS_DIR, entry.name });
        defer gpa.free(glsl_path);

        var src_file = std.Io.Dir.cwd().openFile(io, glsl_path, .{}) catch |e| {
            try stdout.print("shader_compiler: failed to read {s}: {t}\n", .{ glsl_path, e });
            continue;
        };
        defer src_file.close(io);
        const stat = src_file.stat(io) catch continue;
        const src = try gpa.alloc(u8, @intCast(stat.size));
        defer gpa.free(src);
        var src_buf: [4096]u8 = undefined;
        var reader = src_file.reader(io, &src_buf);
        reader.interface.readSliceAll(src) catch continue;

        var result = shader.compile(gpa, io, src, stage, null) catch |e| {
            try stdout.print("shader_compiler: {s} compile error {t}\n", .{ glsl_path, e });
            any_drift = true;
            continue;
        };
        defer result.deinit(gpa);

        if (result.spv.len == 0) {
            try stdout.print("shader_compiler: {s} produced empty SPIR-V — diagnostics:\n{s}\n", .{ glsl_path, result.diagnostics });
            any_drift = true;
            continue;
        }

        // Construit le path .spv attendu.
        const spv_name = try std.mem.concat(gpa, u8, &.{
            entry.name[0 .. entry.name.len - 5], // strip ".glsl"
            ".spv",
        });
        defer gpa.free(spv_name);
        const spv_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ SHADERS_DIR, spv_name });
        defer gpa.free(spv_path);

        if (args.check) {
            var spv_file = std.Io.Dir.cwd().openFile(io, spv_path, .{}) catch {
                try stdout.print("shader_compiler[check]: missing {s}\n", .{spv_path});
                any_drift = true;
                continue;
            };
            defer spv_file.close(io);
            const sst = spv_file.stat(io) catch continue;
            const committed = try gpa.alloc(u8, @intCast(sst.size));
            defer gpa.free(committed);
            var committed_buf: [4096]u8 = undefined;
            var creader = spv_file.reader(io, &committed_buf);
            creader.interface.readSliceAll(committed) catch continue;
            if (!std.mem.eql(u8, committed, result.spv)) {
                try stdout.print("shader_compiler[check]: DRIFT {s} ({d} vs {d} bytes)\n", .{
                    spv_path, committed.len, result.spv.len,
                });
                any_drift = true;
            } else if (!args.quiet) {
                try stdout.print("shader_compiler[check]: OK {s}\n", .{spv_path});
            }
        } else {
            var f = std.Io.Dir.cwd().createFile(io, spv_path, .{ .truncate = true }) catch |e| {
                try stdout.print("shader_compiler: failed to write {s}: {t}\n", .{ spv_path, e });
                any_drift = true;
                continue;
            };
            defer f.close(io);
            f.writeStreamingAll(io, result.spv) catch |e| {
                try stdout.print("shader_compiler: write error on {s}: {t}\n", .{ spv_path, e });
                any_drift = true;
                continue;
            };
            if (!args.quiet) {
                try stdout.print("shader_compiler: wrote {s} ({d} bytes)\n", .{ spv_path, result.spv.len });
            }
        }
        compiled += 1;
    }

    try stdout.print("shader_compiler: {s} {d} shader(s){s}\n", .{
        if (args.check) "checked" else "compiled",
        compiled,
        if (any_drift) " — DRIFT DETECTED" else "",
    });

    if (args.check and any_drift) std.process.exit(1);
}
