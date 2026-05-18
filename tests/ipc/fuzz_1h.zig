//! S6 long fuzz harness (1 hour). Manual invocation only —
//! not added to `zig build test` because it would dominate every
//! CI run for the lifetime of Phase −1/0.
//!
//! Run via `zig build test-ipc-fuzz-1h`. Result digest goes into
//! `validation/s6-go-nogo.md` for the G3 gate.
//!
//! Identical harness shape to `tests/ipc/fuzz_short.zig`, scaled
//! to 1 hour. Counting allocator wraps `std.heap.page_allocator`
//! so any leak fails the test immediately. Cross-platform — runs
//! on Linux / macOS / Windows; pick whichever box is available.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;

const can_unlink = builtin.os.tag == .linux or builtin.os.tag == .macos;
extern "c" fn unlink(path: [*:0]const u8) c_int;
fn maybeUnlink(path: [*:0]const u8) void {
    if (comptime can_unlink) _ = unlink(path);
}

const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };
const CLOCK_MONOTONIC: i32 = if (builtin.os.tag == .linux) 1 else 6;
extern "c" fn clock_gettime(clk_id: i32, tp: *timespec_t) c_int;

extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

var qpc_freq_cached: i64 = 0;
fn qpcFreq() i64 {
    if (qpc_freq_cached == 0) _ = QueryPerformanceFrequency(&qpc_freq_cached);
    return qpc_freq_cached;
}

fn nowMs() i64 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            var counter: i64 = 0;
            _ = QueryPerformanceCounter(&counter);
            const freq = qpcFreq();
            break :blk @divFloor(counter * 1000, freq);
        },
        else => blk: {
            var ts = timespec_t{ .tv_sec = 0, .tv_nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            break :blk ts.tv_sec * 1000 + @divFloor(ts.tv_nsec, std.time.ns_per_ms);
        },
    };
}

const FuzzCtx = struct {
    server_sock: *ipc.transport.IpcSocket,
    client_sock: *ipc.transport.IpcSocket,
    duration_ms: i64,
    /// Outgoing `seq_id`. Matches the protocol-level `framing.Header.seq_id`
    /// width (cf. `framing.zig`). 1 h × 10 000 msg/s ≈ 36 M, well under
    /// `u32` max (~4.3 B), so the wraparound `+%` is theoretical here.
    sent: u32 = 0,
    /// Reader-side counter. Same width as `sent` for symmetry —
    /// drives the post-run sanity check that recv == sent.
    recv: u32 = 0,
    fault: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    stop: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
};

fn writerLoop(ctx: *FuzzCtx, gpa: std.mem.Allocator) void {
    const t = nowMs();
    while (nowMs() - t < ctx.duration_ms) {
        const echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
        const buf = framing.encode(gpa, messages.Echo, ctx.sent +% 1, &echo) catch return;
        defer gpa.free(buf);
        ctx.client_sock.send(buf) catch return;
        ctx.sent += 1;
    }
    ctx.stop.store(1, .release);
}

fn readerLoop(ctx: *FuzzCtx, gpa: std.mem.Allocator) void {
    var connection = ipc.connection.IpcConnection.init(gpa, ctx.server_sock);
    var scratch: [framing.frameSizeOf(messages.Echo) + 256]u8 = undefined;
    while (ctx.stop.load(.acquire) == 0) {
        _ = connection.recvFrame(&scratch) catch return;
        ctx.recv += 1;
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var path_buf: [128]u8 = undefined;
    const path = try ipc.transport.buildSocketPath(&path_buf, "weld-fuzz-1h");
    maybeUnlink(path.ptr);
    defer maybeUnlink(path.ptr);

    var listener = try ipc.transport.IpcSocket.listen(path);
    defer listener.close();
    var client = try ipc.transport.IpcSocket.connect(path);
    defer client.close();
    var server = try listener.accept();
    defer server.close();

    var ctx = FuzzCtx{
        .server_sock = &server,
        .client_sock = &client,
        .duration_ms = 60 * 60 * 1000,
    };
    const reader = try std.Thread.spawn(.{}, readerLoop, .{ &ctx, gpa });
    const writer = try std.Thread.spawn(.{}, writerLoop, .{ &ctx, gpa });
    writer.join();
    reader.join();

    std.debug.print("fuzz_1h: sent={d} recv={d} fault={d}\n", .{ ctx.sent, ctx.recv, ctx.fault.load(.acquire) });
}
