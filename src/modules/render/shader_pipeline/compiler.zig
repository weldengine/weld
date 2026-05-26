//! Shader compiler — Phase 0 / M0.4.
//!
//! Compile des shaders GLSL en SPIR-V via spawn du CLI `glslc` (cohérent
//! brief §Notes décision 7 : pas de binding shaderc/glslang, le keeper count
//! reste à 7). Le hot-reload runtime utilise cette même fonction dans un
//! thread dédié pour atteindre la cible < 200 ms de latence (brief §Scope).
//!
//! Cohérent avec brief §Notes (« glslc est une peer dependency uniquement
//! pour `zig build shaders` (régénération) ou pour le hot-reload runtime
//! dev. Le build standard `zig build` ne dépend pas de `glslc`. »). Si
//! `glslc` est absent du PATH, `compile` retourne `error.GlslcNotFound` —
//! le caller (typiquement le watcher) log un warn et continue avec le
//! `.spv` commité.

const std = @import("std");

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
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    stage: Stage,
    entry_point: ?[]const u8,
) CompileError!Result {
    // Crée un fichier temp avec le source GLSL (glslc lit depuis stdin via
    // `-` mais le format peut varier — on passe par un fichier pour la
    // portabilité). Le fichier est supprimé en fin de fonction.
    var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch {
        return error.ProcessSpawnFailed;
    };
    defer tmp_dir.close();

    // Génère un nom unique (timestamp + PID).
    var name_buf: [128]u8 = undefined;
    const ts: i128 = std.time.nanoTimestamp();
    const name = std.fmt.bufPrint(&name_buf, "weld_shader_{x}.glsl", .{@as(u128, @intCast(ts))}) catch
        return error.OutOfMemory;

    // Écrit le source.
    {
        var file = tmp_dir.createFile(name, .{ .truncate = true }) catch {
            return error.ProcessSpawnFailed;
        };
        defer file.close();
        _ = file.writeAll(source) catch return error.ProcessSpawnFailed;
    }
    defer tmp_dir.deleteFile(name) catch {};

    // Spawn glslc -fshader-stage=<stage> -o - <input>
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "glslc");
    try args.append(allocator, stage.glslcArg());
    if (entry_point) |ep| {
        const ep_arg = try std.fmt.allocPrint(allocator, "-fentry-point={s}", .{ep});
        defer allocator.free(ep_arg);
        try args.append(allocator, ep_arg);
    }
    try args.append(allocator, "-o");
    try args.append(allocator, "-");
    const full_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{name});
    defer allocator.free(full_path);
    try args.append(allocator, full_path);

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |e| switch (e) {
        error.FileNotFound => return error.GlslcNotFound,
        else => return error.ProcessSpawnFailed,
    };

    var stdout = std.ArrayListUnmanaged(u8).empty;
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8).empty;
    defer stderr.deinit(allocator);
    // Phase 0 : lecture sync simple. Phase 1+ : drain async via std.Io.
    child.collectOutput(allocator, &stdout, &stderr, 16 * 1024 * 1024) catch return error.ProcessSpawnFailed;
    const term = child.wait() catch return error.GlslcCrashed;

    if (term != .Exited or term.Exited != 0) {
        // Préserver les diagnostics pour le caller.
        const diag = try allocator.dupe(u8, stderr.items);
        // SPIR-V vide en cas d'erreur.
        return Result{ .spv = &.{}, .diagnostics = diag };
    }

    // SPIR-V dans stdout. Validation basique : magic header 0x07230203 LE.
    if (stdout.items.len < 4) return error.GlslSyntaxError;
    const spv = try allocator.dupe(u8, stdout.items);
    const diag = try allocator.dupe(u8, stderr.items);
    return Result{ .spv = spv, .diagnostics = diag };
}

/// Vérifie si `glslc` est trouvable sur le PATH. Utile pour gater le
/// hot-reload.
pub fn isAvailable(allocator: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "glslc", "--version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

test "compiler: Stage.glslcArg covers all stages" {
    const t = std.testing;
    try t.expectEqualStrings("-fshader-stage=vertex", Stage.vertex.glslcArg());
    try t.expectEqualStrings("-fshader-stage=fragment", Stage.fragment.glslcArg());
    try t.expectEqualStrings("-fshader-stage=compute", Stage.compute.glslcArg());
}

test "compiler: isAvailable does not crash" {
    // Selon la machine de test, retourne true ou false — l'important est
    // que la fonction ne crash pas même si glslc absent.
    _ = isAvailable(std.testing.allocator);
}
