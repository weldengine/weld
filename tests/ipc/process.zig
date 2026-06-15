//! Process tests — `platform.process.spawnProcess` + `waitNonblock`
//! + `isAlive` against the real `/bin/true` and `/bin/sleep` binaries
//! (POSIX-gated). Plus `quoteArg` — the M0.7 / E3 Windows command-line
//! quoter — tested cross-platform (no Windows needed) via golden cases
//! and a round-trip through a reference `CommandLineToArgvW` parser.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const process = weld_core.platform.process;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

const timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

fn sleepMs(ms: u64) void {
    var ts = timespec{
        .tv_sec = @intCast(ms / 1_000),
        .tv_nsec = @intCast((ms % 1_000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

// `/bin/true` lives at `/usr/bin/true` on macOS (and is also at
// `/bin/true` on Linux). `/bin/sleep` is canonical on both.
const true_path = if (builtin.os.tag == .macos) "/usr/bin/true" else "/bin/true";

test "spawn true(1) and reap with waitNonblock returns exit 0" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const argv = [_][]const u8{true_path};

    var proc = try process.spawnProcess(gpa, true_path, &argv);

    // Poll up to ~1 s for the child to exit. /bin/true is near-
    // instant; the loop bound exists to keep the test from hanging
    // if the binary is missing or the spawn fails silently.
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try process.waitNonblock(&proc)) |code| {
            try std.testing.expectEqual(@as(i32, 0), code);
            return;
        }
        sleepMs(10);
    }
    return error.ChildNeverExited;
}

extern "c" fn getpid() i32;

test "isAlive returns true for current pid, false for impossible pid" {
    if (!is_posix) return error.SkipZigTest;

    // The current process always passes — `kill(pid, 0)` is a no-op
    // for the calling process. Using `getpid()` avoids `isAlive(1)`
    // which raises `EPERM` on macOS (launchd is permission-gated).
    const self_pid = getpid();
    try std.testing.expect(process.isAlive(self_pid));
    // PID very high — kernel reserves the lower range. 999_999 is not
    // a valid live process on any sane developer machine.
    try std.testing.expect(!process.isAlive(999_999));
}

test "spawn-then-kill terminates a long-running child" {
    if (!is_posix) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/sleep", "30" };

    var proc = try process.spawnProcess(gpa, "/bin/sleep", &argv);
    // Give the child a moment to actually become alive in the kernel
    // table — without this, `kill(pid, SIGKILL)` can race against
    // the spawn returning before the child is reapable on macOS.
    sleepMs(20);
    // Don't actually wait 30 s — kill and reap.
    try process.kill(&proc);

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try process.waitNonblock(&proc)) |_| return;
        sleepMs(10);
    }
    return error.ChildNeverDied;
}

test "spawnProcess runs a Windows binary and reaps exit 0" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Anti-regression for the M0.7 / E3 addendum: the first real Windows
    // run hit `CreateProcessW` → `error.SpawnFailed`. Exercise the path
    // with a binary guaranteed present (`cmd.exe /c exit 0`).
    const gpa = std.testing.allocator;
    const exe = "C:\\Windows\\System32\\cmd.exe";
    const argv = [_][]const u8{ exe, "/c", "exit 0" };

    var proc = try process.spawnProcess(gpa, exe, &argv);
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (try process.waitNonblock(&proc)) |code| {
            try std.testing.expectEqual(@as(i32, 0), code);
            return;
        }
        sleepMs(10);
    }
    return error.ChildNeverExited;
}

// ------------------------------------------------------- quoteArg tests --
//
// `quoteArg` is pure and cross-platform, so these run on every host.

/// Reference re-implementation of `CommandLineToArgvW`, UTF-8 (the
/// metacharacters are all ASCII). Used to prove `quoteArg` output parses
/// back to the original argument. Faithful to the documented rules:
/// argv[0] is delimited by quotes only (backslashes literal); the rest
/// apply the `2n`/`2n+1` backslash-before-quote rules and toggle the
/// in-quotes state. Caller owns the returned slices.
fn refParseCommandLine(gpa: std.mem.Allocator, cmdline: []const u8) ![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }
    var i: usize = 0;

    // argv[0]: quotes delimit; backslashes are literal; no escaping.
    while (i < cmdline.len and (cmdline[i] == ' ' or cmdline[i] == '\t')) i += 1;
    if (i < cmdline.len) {
        var a0: std.ArrayList(u8) = .empty;
        errdefer a0.deinit(gpa);
        if (cmdline[i] == '"') {
            i += 1;
            while (i < cmdline.len and cmdline[i] != '"') : (i += 1) try a0.append(gpa, cmdline[i]);
            if (i < cmdline.len) i += 1; // consume closing quote
        } else {
            while (i < cmdline.len and cmdline[i] != ' ' and cmdline[i] != '\t') : (i += 1) try a0.append(gpa, cmdline[i]);
        }
        try args.append(gpa, try a0.toOwnedSlice(gpa));
    }

    // Remaining args: standard backslash/quote rules.
    while (true) {
        while (i < cmdline.len and (cmdline[i] == ' ' or cmdline[i] == '\t')) i += 1;
        if (i >= cmdline.len) break;
        var arg: std.ArrayList(u8) = .empty;
        errdefer arg.deinit(gpa);
        var in_quotes = false;
        while (i < cmdline.len) {
            const c = cmdline[i];
            if (!in_quotes and (c == ' ' or c == '\t')) break;
            if (c == '\\') {
                var bs: usize = 0;
                while (i < cmdline.len and cmdline[i] == '\\') : (i += 1) bs += 1;
                if (i < cmdline.len and cmdline[i] == '"') {
                    try arg.appendNTimes(gpa, '\\', bs / 2);
                    if (bs % 2 == 1) {
                        try arg.append(gpa, '"'); // escaped literal quote
                        i += 1;
                    }
                    // even: leave the '"' for the quote branch next loop
                } else {
                    try arg.appendNTimes(gpa, '\\', bs); // backslashes literal
                }
            } else if (c == '"') {
                if (in_quotes and i + 1 < cmdline.len and cmdline[i + 1] == '"') {
                    try arg.append(gpa, '"'); // "" inside quotes → literal "
                    i += 2;
                } else {
                    in_quotes = !in_quotes;
                    i += 1;
                }
            } else {
                try arg.append(gpa, c);
                i += 1;
            }
        }
        try args.append(gpa, try arg.toOwnedSlice(gpa));
    }
    return args.toOwnedSlice(gpa);
}

test "quoteArg golden cases" {
    const gpa = std.testing.allocator;
    const Case = struct { arg: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .arg = "", .want = "\"\"" }, // empty must be quoted
        .{ .arg = "simple", .want = "simple" }, // no metachar → verbatim
        .{ .arg = "My Game", .want = "\"My Game\"" }, // space → quoted
        // Trailing backslash, no space → verbatim (NOT `"C:\dir\"`, which
        // the naive quoter would emit, escaping the closing quote).
        .{ .arg = "C:\\dir\\", .want = "C:\\dir\\" },
        // Space + trailing backslash → quoted with the backslash doubled.
        .{ .arg = "C:\\My Dir\\", .want = "\"C:\\My Dir\\\\\"" },
    };
    for (cases) |c| {
        const got = try process.quoteArg(gpa, c.arg);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "quoteArg round-trips through a CommandLineToArgvW reference parser" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "simple",
        "My Game",
        "C:\\dir\\", // trailing backslash, no space
        "C:\\Program Files\\", // space + trailing backslash
        "a\"b", // internal quote
        "x\\\"y", // backslash + quote
        "\\\\", // backslashes only
        "tab\there", // embedded tab
        "trailing\\\\\\", // three trailing backslashes
    };

    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(gpa);
    const argv0 = "prog"; // simple argv[0] — round-trips trivially
    const q0 = try process.quoteArg(gpa, argv0);
    defer gpa.free(q0);
    try cmd.appendSlice(gpa, q0);
    for (cases) |c| {
        try cmd.append(gpa, ' ');
        const q = try process.quoteArg(gpa, c);
        defer gpa.free(q);
        try cmd.appendSlice(gpa, q);
    }

    const parsed = try refParseCommandLine(gpa, cmd.items);
    defer {
        for (parsed) |p| gpa.free(p);
        gpa.free(parsed);
    }

    try std.testing.expectEqual(cases.len + 1, parsed.len);
    try std.testing.expectEqualStrings(argv0, parsed[0]);
    for (cases, 0..) |c, idx| {
        try std.testing.expectEqualStrings(c, parsed[idx + 1]);
    }
}
