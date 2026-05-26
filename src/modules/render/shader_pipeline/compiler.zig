//! Shader compiler — Phase 0 / M0.4.
//!
//! Compile des shaders GLSL en SPIR-V via spawn du CLI `glslc` (cohérent
//! brief §Notes décision 7 : pas de binding shaderc/glslang, le keeper count
//! reste à 7).
//!
//! Cohérent avec brief §Notes (« glslc est une peer dependency uniquement
//! pour `zig build shaders` (régénération) ou pour le hot-reload runtime
//! dev. Le build standard `zig build` ne dépend pas de `glslc`. »). Si
//! `glslc` est absent du PATH, `compile` retourne `error.GlslcNotFound`.
//!
//! API Zig 0.16 : `std.process.run` (qui prend `io: Io`) — pas
//! `std.process.Child.init` qui n'existe plus.

const std = @import("std");

/// Compteur global pour générer des noms de fichiers temp uniques.
var unique_id: std.atomic.Value(u64) = .init(0);

/// Stage shader supporté Phase 0. Phase 1+ étend (geometry, tessellation,
/// raygen/closesthit/miss pour RT).
pub const Stage = enum {
    vertex,
    fragment,
    compute,

    pub fn glslcArg(self: Stage) []const u8 {
        return switch (self) {
            .vertex => "-fshader-stage=vertex",
            .fragment => "-fshader-stage=fragment",
            .compute => "-fshader-stage=compute",
        };
    }
};

/// Erreurs de compilation. `GlslcNotFound` est l'erreur attendue quand
/// l'outil n'est pas installé (cf. brief §Comportement observable).
pub const CompileError = error{
    GlslcNotFound,
    GlslcCrashed,
    GlslSyntaxError,
    OutOfMemory,
    InvalidUtf8,
    ProcessSpawnFailed,
};

/// Résultat d'une compilation.
pub const Result = struct {
    /// Bytes SPIR-V (4-byte aligned). Owned by le caller — à libérer via
    /// `allocator.free`.
    spv: []u8,
    /// Diagnostics retournés par glslc (stdout + stderr concaténés).
    /// Vide si la compilation a réussi sans warning.
    diagnostics: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.spv.len > 0) allocator.free(self.spv);
        if (self.diagnostics.len > 0) allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

/// Compile `source` (texte GLSL) vers SPIR-V via glslc. Le caller doit
/// passer le bon `stage` (le glslc en a besoin pour la sélection du shader
/// model). `entry_point` est par défaut "main".
///
/// Retourne `error.GlslcNotFound` si glslc n'est pas trouvable dans le
/// PATH — utilisable comme heuristique pour désactiver le hot-reload.
///
/// Phase 0 : utilise `std.process.run` (Zig 0.16 API). Le caller fournit
/// l'instance `io: std.Io` requise.
pub fn compile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    stage: Stage,
    entry_point: ?[]const u8,
) CompileError!Result {
    // Écrit le source dans un fichier temp. Nom unique via un compteur
    // atomique (évite la dépendance à `std.time.nanoTimestamp` qui
    // n'existe plus en Zig 0.16).
    const id = unique_id.fetchAdd(1, .monotonic);
    var tmp_buf: [128]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, "/tmp/weld_shader_{d}.glsl", .{id}) catch return error.OutOfMemory;

    {
        var file = std.Io.Dir.cwd().createFile(io, tmp_name, .{ .truncate = true }) catch return error.ProcessSpawnFailed;
        defer file.close(io);
        file.writeStreamingAll(io, source) catch return error.ProcessSpawnFailed;
    }
    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_name) catch {};
    }

    // Construit argv.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "glslc") catch return error.OutOfMemory;
    argv.append(allocator, stage.glslcArg()) catch return error.OutOfMemory;
    var ep_buf: ?[]u8 = null;
    defer if (ep_buf) |b| allocator.free(b);
    if (entry_point) |ep| {
        const ep_arg = std.fmt.allocPrint(allocator, "-fentry-point={s}", .{ep}) catch return error.OutOfMemory;
        ep_buf = ep_arg;
        argv.append(allocator, ep_arg) catch return error.OutOfMemory;
    }
    argv.append(allocator, "-o") catch return error.OutOfMemory;
    argv.append(allocator, "-") catch return error.OutOfMemory;
    argv.append(allocator, tmp_name) catch return error.OutOfMemory;

    const run_result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = std.Io.Limit.limited(16 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
    }) catch |e| switch (e) {
        error.FileNotFound => return error.GlslcNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProcessSpawnFailed,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .exited => |code| if (code != 0) {
            const diag = allocator.dupe(u8, run_result.stderr) catch return error.OutOfMemory;
            return Result{ .spv = &.{}, .diagnostics = diag };
        },
        else => return error.GlslcCrashed,
    }

    // SPIR-V dans stdout. Validation basique : ≥ 4 octets.
    if (run_result.stdout.len < 4) return error.GlslSyntaxError;
    const spv = allocator.dupe(u8, run_result.stdout) catch return error.OutOfMemory;
    const diag = allocator.dupe(u8, run_result.stderr) catch return error.OutOfMemory;
    return Result{ .spv = spv, .diagnostics = diag };
}

/// Vérifie si `glslc` est trouvable sur le PATH. Utile pour gater le
/// hot-reload. Retourne `false` plutôt qu'une erreur — heuristique.
pub fn isAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "glslc", "--version" },
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "compiler: Stage.glslcArg covers all stages" {
    const t = std.testing;
    try t.expectEqualStrings("-fshader-stage=vertex", Stage.vertex.glslcArg());
    try t.expectEqualStrings("-fshader-stage=fragment", Stage.fragment.glslcArg());
    try t.expectEqualStrings("-fshader-stage=compute", Stage.compute.glslcArg());
}

test "compiler: isAvailable does not crash" {
    // Test purement structural — appelle la fn et vérifie qu'elle retourne
    // un bool sans crash, indépendamment de la présence effective de glslc.
    _ = isAvailable(std.testing.allocator, std.testing.io);
}
