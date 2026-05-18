//! S6 RTT benchmark — measures Echo round-trip latency on a
//! single in-process AF_UNIX connection.
//!
//! `zig build bench-ipc-rtt -Doptimize=ReleaseSafe` runs N=10_000
//! iterations after 100 warmup iterations, reports p50/p99/max/
//! stddev, and writes `bench/results/ipc_rtt.md`. The two-process
//! variant (`run-ipc-demo`) carries the same code path but the
//! cross-process AF_UNIX handshake is already validated by
//! `tests/ipc/transport.zig` and `tests/ipc/handshake.zig`; an
//! in-process RTT yields a tight lower bound for the brief's
//! G1 < 1 ms median and G2 p99 < 5 ms gates.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;

const N_WARMUP: usize = 100;
const N_ITERS: usize = 10_000;

// `unlink` is a POSIX-only no-op on Windows (named pipes are not
// filesystem entries; the kernel reclaims them when the last handle
// closes). The `extern` is gated so the linker doesn't drag a libc
// `unlink` in on the Windows build.
const can_unlink = builtin.os.tag == .linux or builtin.os.tag == .macos;
extern "c" fn unlink(path: [*:0]const u8) c_int;
fn maybeUnlink(path: [*:0]const u8) void {
    if (comptime can_unlink) _ = unlink(path);
}
// Platform-native monotonic counter. The MinGW-based Windows libc
// shipped with Zig has a `clock_gettime(CLOCK_MONOTONIC, …)` symbol
// but its precision quantises everything down to ~16 ms on the
// dev-box driver stack — Echo round-trips well under a millisecond
// then all report 0.000 ms. The first hardware bench (Win 11 25H2 +
// RTX 4080 Super) caught it. Switch to `QueryPerformanceCounter` +
// `QueryPerformanceFrequency` on Windows (sub-microsecond on the
// validation matrix) and keep `clock_gettime(CLOCK_MONOTONIC)` on
// POSIX where it does the right thing.

const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };
const CLOCK_MONOTONIC: i32 = if (builtin.os.tag == .linux) 1 else 6;
extern "c" fn clock_gettime(clk_id: i32, tp: *timespec_t) c_int;

extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

fn nowNs() i64 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            var counter: i64 = 0;
            _ = QueryPerformanceCounter(&counter);
            const freq = qpcFreq();
            // Avoid `counter * 1_000_000_000` overflowing — split
            // into seconds + remainder so the maximum representable
            // session is bounded by `i64` seconds (~292 years), not
            // by the `i64` nanosecond range (~292 sessions of 1 h).
            const sec_part: i64 = @divFloor(counter, freq);
            const rem: i64 = counter - sec_part * freq;
            break :blk sec_part * std.time.ns_per_s + @divFloor(rem * std.time.ns_per_s, freq);
        },
        else => blk: {
            var ts = timespec_t{ .tv_sec = 0, .tv_nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            break :blk ts.tv_sec * std.time.ns_per_s + ts.tv_nsec;
        },
    };
}

var qpc_freq_cached: i64 = 0;
fn qpcFreq() i64 {
    if (qpc_freq_cached == 0) {
        _ = QueryPerformanceFrequency(&qpc_freq_cached);
    }
    return qpc_freq_cached;
}

const ServerCtx = struct {
    sock: *ipc.transport.IpcSocket,
    iters: usize,
};

fn serverLoop(ctx: *ServerCtx, gpa: std.mem.Allocator) void {
    var connection = ipc.connection.IpcConnection.init(gpa, ctx.sock);
    var scratch: [framing.frameSizeOf(messages.Echo) + 16]u8 = undefined;
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) {
        const ec = connection.recvMessage(messages.Echo, &scratch) catch return;
        const reply = messages.EchoReply{ .payload = ec.payload };
        connection.sendMessage(messages.EchoReply, 0, &reply) catch return;
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Per-PID unique base name keeps concurrent bench runs +
    // leftover pipe instances from biting each other on Windows
    // (named pipes survive until the last handle closes; a kill -9
    // can leave one behind for a brief window).
    const pid: u32 = switch (builtin.os.tag) {
        .linux, .macos => @intCast(std.c.getpid()),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => 0,
    };
    var name_buf: [64]u8 = undefined;
    const base_name = try std.fmt.bufPrint(&name_buf, "weld-bench-rtt-{d}", .{pid});

    var path_buf: [128]u8 = undefined;
    const path = try ipc.transport.buildSocketPath(&path_buf, base_name);
    maybeUnlink(path.ptr);
    defer maybeUnlink(path.ptr);

    var listener = try ipc.transport.IpcSocket.listen(path);
    defer listener.close();
    var client_socket = try ipc.transport.IpcSocket.connect(path);
    defer client_socket.close();
    var server_socket = try listener.accept();
    defer server_socket.close();

    var server_ctx = ServerCtx{
        .sock = &server_socket,
        .iters = N_WARMUP + N_ITERS,
    };
    const server_thread = try std.Thread.spawn(.{}, serverLoop, .{ &server_ctx, gpa });
    defer server_thread.join();

    var client_connection = ipc.connection.IpcConnection.init(gpa, &client_socket);
    var samples = try gpa.alloc(u64, N_ITERS);

    var echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    for (&echo.payload, 0..) |*b, idx| b.* = @intCast(idx & 0xFF);
    var reply_buf: [framing.frameSizeOf(messages.EchoReply)]u8 = undefined;

    var i: usize = 0;
    while (i < N_WARMUP) : (i += 1) {
        try client_connection.sendMessage(messages.Echo, 0, &echo);
        _ = try client_connection.recvMessage(messages.EchoReply, &reply_buf);
    }

    i = 0;
    while (i < N_ITERS) : (i += 1) {
        const t0 = nowNs();
        try client_connection.sendMessage(messages.Echo, 0, &echo);
        _ = try client_connection.recvMessage(messages.EchoReply, &reply_buf);
        samples[i] = @intCast(nowNs() - t0);
    }

    std.mem.sort(u64, samples, {}, comptime std.sort.asc(u64));
    const p50 = samples[N_ITERS / 2];
    const p99 = samples[(N_ITERS * 99) / 100];
    const max_ns = samples[N_ITERS - 1];

    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(N_ITERS));
    var sq: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        sq += d * d;
    }
    const stddev = @sqrt(sq / @as(f64, @floatFromInt(N_ITERS)));

    std.debug.print(
        \\S6 IPC RTT bench — Echo 64 B round-trip
        \\  N: {d} (after {d} warmup)
        \\  p50  : {d:.3} ms
        \\  p99  : {d:.3} ms
        \\  max  : {d:.3} ms
        \\  stddev: {d:.3} ms
        \\  mean : {d:.3} ms
        \\
    , .{
        N_ITERS,
        N_WARMUP,
        @as(f64, @floatFromInt(p50)) / 1_000_000.0,
        @as(f64, @floatFromInt(p99)) / 1_000_000.0,
        @as(f64, @floatFromInt(max_ns)) / 1_000_000.0,
        stddev / 1_000_000.0,
        mean / 1_000_000.0,
    });

    // Auto-write the markdown report. We assemble the buffer in
    // memory then flush via a single write — Zig 0.16's std.fs.File
    // writer expects a `*Io` instance we don't carry here.
    const md_bytes = try std.fmt.allocPrint(gpa,
        \\# S6 IPC RTT bench — Echo 64 B round-trip
        \\
        \\| metric | value |
        \\|---|---|
        \\| N | {d} (after {d} warmup) |
        \\| p50 | {d:.3} ms |
        \\| p99 | {d:.3} ms |
        \\| max | {d:.3} ms |
        \\| stddev | {d:.3} ms |
        \\| mean | {d:.3} ms |
        \\
        \\## Gates
        \\
        \\- G1 p50 < 1 ms — {s}
        \\- G2 p99 < 5 ms, max < 50 ms — {s}
        \\
    , .{
        N_ITERS,
        N_WARMUP,
        @as(f64, @floatFromInt(p50)) / 1_000_000.0,
        @as(f64, @floatFromInt(p99)) / 1_000_000.0,
        @as(f64, @floatFromInt(max_ns)) / 1_000_000.0,
        stddev / 1_000_000.0,
        mean / 1_000_000.0,
        if (p50 < std.time.ns_per_ms) "GO" else "NO-GO",
        if (p99 < 5 * std.time.ns_per_ms and max_ns < 50 * std.time.ns_per_ms) "GO" else "NO-GO",
    });
    defer gpa.free(md_bytes);

    const md_path: [:0]const u8 = "bench/results/ipc_rtt.md";
    const fp = fopen(md_path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    defer _ = fclose(fp.?);
    _ = fwrite(md_bytes.ptr, 1, md_bytes.len, fp.?);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
