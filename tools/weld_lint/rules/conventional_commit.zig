//! Rule `conventional_commit` — Conventional Commits validation for
//! Weld, matching `engine-development-workflow.md §4.3`.
//!
//! Format: `<type>(<scope>)?!?: <description>`
//! - type        ∈ {feat, fix, perf, refactor, test, docs, chore, breaking}
//! - scope       optional, matches `[a-z0-9-]+`
//! - !           optional, marks a breaking change
//! - description 1–72 chars, lowercase first letter, no trailing period
//!
//! Bypasses: titles that start with `Merge `, `Revert `, `fixup!`, or
//! `squash!` are accepted unconditionally (mirrors the canonical regex
//! in `scripts/check-commit-msg.sh`).
//!
//! Entry point: `validateFile` reads the commit-message file at
//! `path`, extracts the first non-empty, non-comment line, and either
//! returns silently (success) or appends one or more diagnostics to
//! `out`.

const std = @import("std");
const diag = @import("../diagnostic.zig");

pub const name = "conventional_commit";

const allowed_types = [_][]const u8{
    "feat",
    "fix",
    "perf",
    "refactor",
    "test",
    "docs",
    "chore",
    "breaking",
};

pub fn validateFile(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    const cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(arena, "cannot open commit message file: {t}", .{err});
        try out.append(arena, .{
            .file = path,
            .line = 1,
            .col = 1,
            .rule = name,
            .message = msg,
        });
        return;
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try arena.alloc(u8, size);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    const source = buf[0..written];

    const title = firstTitleLine(source) orelse {
        try out.append(arena, .{
            .file = path,
            .line = 1,
            .col = 1,
            .rule = name,
            .message = "empty commit message",
        });
        return;
    };

    try validateTitle(arena, path, title, out);
}

pub fn validateMessage(
    arena: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    const title = firstTitleLine(source) orelse {
        try out.append(arena, .{
            .file = path,
            .line = 1,
            .col = 1,
            .rule = name,
            .message = "empty commit message",
        });
        return;
    };
    try validateTitle(arena, path, title, out);
}

fn firstTitleLine(source: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        return line;
    }
    return null;
}

fn validateTitle(
    arena: std.mem.Allocator,
    path: []const u8,
    title: []const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    // Bypass merge / revert / fixup / squash titles.
    const bypass_prefixes = [_][]const u8{ "Merge ", "Revert ", "fixup!", "squash!" };
    for (bypass_prefixes) |p| {
        if (std.mem.startsWith(u8, title, p)) return;
    }

    // Parse: <type>(<scope>)?!?: <description>
    var idx: usize = 0;

    // type
    const type_start = idx;
    while (idx < title.len and isLower(title[idx])) idx += 1;
    const type_token = title[type_start..idx];
    if (type_token.len == 0 or !isAllowedType(type_token)) {
        try addError(arena, path, title, out, "title must start with one of feat|fix|perf|refactor|test|docs|chore|breaking");
        return;
    }

    // optional scope
    if (idx < title.len and title[idx] == '(') {
        idx += 1;
        const scope_start = idx;
        while (idx < title.len and title[idx] != ')') : (idx += 1) {
            const c = title[idx];
            if (!(isLower(c) or isDigit(c) or c == '-')) {
                try addError(arena, path, title, out, "scope must match [a-z0-9-]+");
                return;
            }
        }
        if (idx >= title.len or title[idx] != ')') {
            try addError(arena, path, title, out, "unterminated scope — expected `)`");
            return;
        }
        if (idx == scope_start) {
            try addError(arena, path, title, out, "scope is empty — drop the parentheses or fill in [a-z0-9-]+");
            return;
        }
        idx += 1; // consume `)`
    }

    // optional `!` for breaking change
    if (idx < title.len and title[idx] == '!') idx += 1;

    // mandatory `: `
    if (idx + 2 > title.len or title[idx] != ':' or title[idx + 1] != ' ') {
        try addError(arena, path, title, out, "expected `: ` after type/scope");
        return;
    }
    idx += 2;

    // description
    const desc = title[idx..];
    if (desc.len == 0) {
        try addError(arena, path, title, out, "description is empty");
        return;
    }
    if (desc.len > 72) {
        try addError(arena, path, title, out, "title exceeds 72 characters");
        return;
    }
    if (title.len > 72) {
        try addError(arena, path, title, out, "title exceeds 72 characters");
        return;
    }
    if (!isLower(desc[0])) {
        try addError(arena, path, title, out, "description must start with a lowercase letter");
        return;
    }
    if (desc[desc.len - 1] == '.') {
        try addError(arena, path, title, out, "description must not end with a period");
        return;
    }
}

fn addError(
    arena: std.mem.Allocator,
    path: []const u8,
    title: []const u8,
    out: *std.ArrayList(diag.Diagnostic),
    detail: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        arena,
        "{s}: \"{s}\"",
        .{ detail, title },
    );
    try out.append(arena, .{
        .file = path,
        .line = 1,
        .col = 1,
        .rule = name,
        .message = msg,
    });
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAllowedType(s: []const u8) bool {
    for (allowed_types) |t| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}
