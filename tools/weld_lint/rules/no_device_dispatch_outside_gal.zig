//! Rule `no_device_dispatch_outside_gal` — `vk.device_dispatch.*`
//! accesses are only allowed from files inside `src/modules/render/gal/vulkan/`.
//!
//! No call site references `device_dispatch` directly — everything goes through
//! the idiomatic wrappers or the `*Raw` variants. The Vulkan backend is the only
//! legitimate site, since it implements the GAL on top of the dynamic dispatch,
//! and it is the one place the rule skips.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_device_dispatch_outside_gal";
/// Accepted path forms for the legitimate prefix, one per separator.
///
/// `scan.zig` joins paths with `std.fs.path.join`, which yields `/` on POSIX and
/// `\` on Win32. WITHOUT THE BACKSLASH VARIANT the rule fires on the Vulkan
/// backend itself under Windows — measured, on a red Windows cell.
const allowed_prefix_posix = "src/modules/render/gal/vulkan/";
const allowed_prefix_win = "src\\modules\\render\\gal\\vulkan\\";

/// The legacy grandfather marker, which is FORBIDDEN rather than honoured.
///
/// Every `device_dispatch` site has been migrated onto the idiomatic wrappers, so
/// the marker's presence in a file header is itself a lint error: no file may opt
/// out of this rule.
const legacy_marker = "WELD_LEGACY_VK_DISPATCH";

/// Hook called by `main.runLint` once per `.zig` file.
///
/// Files under `gal/vulkan/` are skipped ENTIRELY, marker included: they are the
/// legitimate dispatch site.
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

    // Flag the marker, then KEEP SCANNING: a file carrying it may also carry a
    // real access, and returning here would report the opt-out and hide the use.
    if (legacyMarkerOffset(source)) |off| {
        const pos = diag.lineColFromOffset(source, off);
        try out.append(arena, .{
            .file = file,
            .line = pos.line,
            .col = pos.col,
            .rule = name,
            .message = "`WELD_LEGACY_VK_DISPATCH` marker is forbidden — the device-dispatch grandfather escape was removed in M0.5; route through the idiomatic `vk.*` wrappers (or the GAL) instead",
        });
    }

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

/// Returns the byte offset of the legacy marker if it appears in the file
/// header (scans the first 8 lines to tolerate an introductory block comment),
/// else null. Header-only by design: this matches how the marker was always
/// written (a file-top `//!` line) and keeps this rule file — which names the
/// marker in its own body below line 8 — from flagging itself.
fn legacyMarkerOffset(source: []const u8) ?usize {
    var line_count: u32 = 0;
    var start: usize = 0;
    while (start < source.len and line_count < 8) {
        const eol = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..eol];
        if (std.mem.indexOf(u8, line, legacy_marker)) |rel| return start + rel;
        start = eol + 1;
        line_count += 1;
    }
    return null;
}
