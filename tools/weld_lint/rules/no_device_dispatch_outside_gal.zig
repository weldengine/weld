//! Rule `no_device_dispatch_outside_gal` — `vk.device_dispatch.*`
//! accesses are only allowed from files inside `src/modules/render/gal/vulkan/`.
//!
//! Architectural discipline, brief §CI: no GAL call site references
//! `device_dispatch` directly — everything goes through the idiomatic wrappers
//! or the `*Raw` variants (cf. brief §Scope D-S2-dispatch-bypass).
//! The Vulkan backend itself is the only legitimate site since it
//! implements the GAL on top of the dynamic dispatch.
//!
//! Strategy: tokenize the source and look for the identifier `vk` followed
//! by `.` then `device_dispatch`. Skip if the file lives under
//! `src/modules/render/gal/vulkan/`.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_device_dispatch_outside_gal";
/// Accepted path forms for the "legitimate" prefix. `scan.zig` joins the
/// paths via `std.fs.path.join`, which produces `/` on POSIX and `\` on
/// Win32 — hence the two variants. Without the backslash version, the rule
/// would trigger on the Vulkan backend itself when `weld_lint` runs
/// under Windows (cf. the Windows-Debug bug of run 26473017061).
const allowed_prefix_posix = "src/modules/render/gal/vulkan/";
const allowed_prefix_win = "src\\modules\\render\\gal\\vulkan\\";

/// Opt-in marker for the legacy S6 files that call `device_dispatch`
/// before the GAL Phase 1+ migration. Present at the head of the file in
/// the form:
///     //! WELD_LEGACY_VK_DISPATCH — pre-M0.4 code, migration tracked Phase 1+
const legacy_marker = "WELD_LEGACY_VK_DISPATCH";

/// Hook called by `main.runLint` once per `.zig` file. Skip immediately
/// if the file lives under `gal/vulkan/` (legitimate case) or carries the
/// `WELD_LEGACY_VK_DISPATCH` marker (S6 grandfather case). Otherwise, scan the
/// source for the `vk.device_dispatch` pattern and emit one diagnostic per
/// occurrence.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    // Path normalization: the runner may pass absolute or relative
    // paths. We accept both by searching for the prefix as a substring,
    // on both separators (POSIX `/`, Win32 `\`).
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

/// Checks whether the source carries the legacy marker at the head (scans the
/// first 8 lines to tolerate an introductory block comment).
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
