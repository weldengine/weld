//! Rule `no_device_dispatch_outside_gal` — `vk.device_dispatch.*`
//! accesses are only allowed from files inside `src/modules/render/gal/vulkan/`.
//!
//! Discipline architecturale brief §CI : aucun call site GAL ne référence
//! `device_dispatch` directement — tout passe par les wrappers idiomatiques
//! ou les `*Raw` variants (cf. brief §Scope D-S2-dispatch-bypass).
//! Le backend Vulkan lui-même est le seul site légitime puisqu'il
//! implémente la GAL au-dessus du dispatch dynamique.
//!
//! Strategy : tokenize la source et cherche le motif identifier `vk` suivi
//! de `.` puis `device_dispatch`. Skip si le fichier vit sous
//! `src/modules/render/gal/vulkan/`.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_device_dispatch_outside_gal";
/// Path forms acceptés pour le préfixe « légitime ». `scan.zig` joint les
/// chemins via `std.fs.path.join`, qui produit `/` sous POSIX et `\` sous
/// Win32 — d'où les deux variantes. Sans la version backslash, la règle
/// déclencherait sur le backend Vulkan lui-même quand `weld_lint` tourne
/// sous Windows (cf. bug Windows-Debug du run 26473017061).
const allowed_prefix_posix = "src/modules/render/gal/vulkan/";
const allowed_prefix_win = "src\\modules\\render\\gal\\vulkan\\";

/// Marker opt-in pour les fichiers legacy S6 qui appellent `device_dispatch`
/// avant la migration GAL Phase 1+. Présent en tête du fichier sous la
/// forme :
///     //! WELD_LEGACY_VK_DISPATCH — pre-M0.4 code, migration tracée Phase 1+
const legacy_marker = "WELD_LEGACY_VK_DISPATCH";

/// Hook called by `main.runLint` once per `.zig` file. Skip immediately
/// si le fichier vit sous `gal/vulkan/` (cas légitime) ou s'il porte le
/// marker `WELD_LEGACY_VK_DISPATCH` (cas grandfather S6). Sinon, scan le
/// source pour le pattern `vk.device_dispatch` et émet un diagnostic par
/// occurrence.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    // Path normalization : le runner peut passer des paths absolus ou
    // relatifs. On accepte les deux en cherchant le préfixe en suffix,
    // sur les deux séparateurs (POSIX `/`, Win32 `\`).
    if (std.mem.indexOf(u8, file, allowed_prefix_posix) != null) return;
    if (std.mem.indexOf(u8, file, allowed_prefix_win) != null) return;
    if (hasLegacyMarker(source)) return;

    var tokenizer = std.zig.Tokenizer.init(source);
    var last_ident_was_vk: bool = false;
    var last_was_period: bool = false;
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        const slice = source[tok.loc.start..tok.loc.end];
        switch (tok.tag) {
            .identifier => {
                if (last_was_period and last_ident_was_vk and std.mem.eql(u8, slice, "device_dispatch")) {
                    const pos = diag.lineColFromOffset(source, tok.loc.start);
                    try out.append(arena, .{
                        .file = file,
                        .line = pos.line,
                        .col = pos.col,
                        .rule = name,
                        .message = "`vk.device_dispatch.*` is only allowed inside `src/modules/render/gal/vulkan/` — use the idiomatic wrapper or the `*Raw` variant",
                    });
                }
                last_ident_was_vk = std.mem.eql(u8, slice, "vk");
                last_was_period = false;
            },
            .period => {
                last_was_period = true;
            },
            else => {
                last_ident_was_vk = false;
                last_was_period = false;
            },
        }
    }
}

/// Vérifie si la source porte le marker legacy en tête (scan des 8
/// premières lignes pour tolérer un commentaire-bloc d'introduction).
fn hasLegacyMarker(source: []const u8) bool {
    var line_count: u32 = 0;
    var start: usize = 0;
    while (start < source.len and line_count < 8) {
        const eol = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..eol];
        if (std.mem.indexOf(u8, line, legacy_marker) != null) return true;
        start = eol + 1;
        line_count += 1;
    }
    return false;
}
