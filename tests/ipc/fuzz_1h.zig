//! S6 long fuzz harness — promoted to a nightly target at M0.7 / E4
//! (was manual-only at S6). Stresses the **whole message catalogue**, not
//! just `Echo`: each iteration the writer picks a random message type
//! (incl. `ShmRegionsHandoff`, hardened in E1, and every E2 command) and
//! sends a well-formed frame. Interleaving heterogeneous frame *sizes* is
//! the real test — it exercises the length-prefixed framing's delimiting
//! over tens of millions of back-to-back frames (the "no magic desync"
//! gate). A counting allocator wraps `page_allocator` so any leak fails
//! the run; `sent == recv` and a clean reader confirm no desync.
//!
//! Run via `zig build test-ipc-fuzz-1h` (1 h default). Pass a shorter
//! duration for a local smoke run:
//!
//!     zig build test-ipc-fuzz-1h -- --duration-ms=3000
//!
//! Cross-platform — runs on Linux / macOS / Windows. The nightly cron
//! (`.github/workflows/nightly-fuzz.yml`) runs it on Linux + Windows and
//! archives the stdout digest as an artifact (G3 gate).

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;

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

// The fuzzed slice of the catalogue. A deliberate spread of payload sizes
// — tiny (`Play`/`Pause`/`Stop`), mid (`Echo`/`Heartbeat`), and large
// (`LoadScene`/`SaveScene`/`ShmRegionsHandoff`) — so the stream constantly
// changes frame length and the reader's delimiting is genuinely stressed.
const fuzz_types = [_]type{
    messages.Echo,            messages.Heartbeat,    messages.SpawnEntity,
    messages.ModifyComponent, messages.LogMessage,   messages.Play,
    messages.Pause,           messages.Stop,         messages.LoadScene,
    messages.HotReloadScript, messages.SaveScene,    messages.SaveProject,
    messages.ProjectSaved,    messages.RuntimeError, messages.ShmRegionsHandoff,
};

// Reader scratch must hold the largest frame in `fuzz_types`, else a big
// frame trips `error.PayloadTooLarge` and reads as a (false) desync.
const max_frame_size = blk: {
    var m: usize = @sizeOf(framing.Header);
    for (fuzz_types) |T| m = @max(m, framing.frameSizeOf(T));
    break :blk m;
};

// Encode a well-formed frame for `fuzz_types[idx]` with a zeroed body. The
// body content is irrelevant to the framing/transport stress; the type
// (hence the frame length + `msg_type`) is what varies.
fn encodeRandom(gpa: std.mem.Allocator, idx: usize, seq: u32) ![]u8 {
    inline for (fuzz_types, 0..) |T, i| {
        if (i == idx) {
            const msg: T = std.mem.zeroes(T);
            return framing.encode(gpa, T, seq, &msg);
        }
    }
    unreachable;
}

const FuzzCtx = struct {
    server_sock: *ipc.transport.IpcSocket,
    client_sock: *ipc.transport.IpcSocket,
    duration_ms: i64,
    /// Writer-owned. Outgoing `seq_id` source; 1 h × ~1 M msg/s stays far
    /// below `u32` overflow, so `+%` is theoretical.
    sent: u32 = 0,
    /// Reader-owned. Compared to `sent` after join — equality proves every
    /// frame was received intact and in order (no desync, no drop).
    recv: u32 = 0,
    /// Set by the reader on a real desync / catastrophic error (any framing
    /// error before teardown, or a non-teardown error class).
    fault: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Published by the writer (release) before the teardown sentinel.
    stop: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
};

fn writerLoop(ctx: *FuzzCtx, gpa: std.mem.Allocator) void {
    const t_start = nowMs();
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const rng = prng.random();
    while (nowMs() - t_start < ctx.duration_ms) {
        const idx = rng.intRangeLessThan(usize, 0, fuzz_types.len);
        const buf = encodeRandom(gpa, idx, ctx.sent +% 1) catch {
            ctx.fault.store(1, .release);
            break;
        };
        defer gpa.free(buf);
        ctx.client_sock.send(buf) catch {
            ctx.fault.store(1, .release);
            break;
        };
        ctx.sent += 1;
    }
    // Deterministic teardown. Publish `stop` (release) BEFORE the sentinel
    // so the reader's acquire-load — run only after it receives the
    // sentinel — always observes stop == 1 and treats the resulting
    // `InvalidMagic` as the expected end-of-stream, not a mid-run desync.
    // A 16-byte bad-magic frame unblocks the reader's blocking `recvFrame`.
    ctx.stop.store(1, .release);
    const sentinel = [_]u8{0xFF} ** @sizeOf(framing.Header);
    ctx.client_sock.send(&sentinel) catch {};
}

fn readerLoop(ctx: *FuzzCtx, gpa: std.mem.Allocator) void {
    var connection = ipc.connection.IpcConnection.init(gpa, ctx.server_sock);
    var scratch: [max_frame_size]u8 = undefined;
    while (true) {
        _ = connection.recvFrame(&scratch) catch |e| {
            // After teardown, the bad-magic sentinel (`InvalidMagic`) and a
            // torn-down socket (`UnexpectedEof` / `BrokenPipe`) are the
            // expected end. The same errors *before* teardown — or any
            // other error class at any time (a version / msg_type / size
            // desync) — are real faults.
            const stopped = ctx.stop.load(.acquire) == 1;
            const benign_teardown = switch (e) {
                error.InvalidMagic, error.UnexpectedEof, error.BrokenPipe => true,
                else => false,
            };
            if (!stopped or !benign_teardown) ctx.fault.store(1, .release);
            return;
        };
        ctx.recv += 1;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Duration override: `zig build test-ipc-fuzz-1h -- --duration-ms=N`.
    // Env vars (`std.posix.getenv` / `hasEnvVarConstant`) were removed in
    // 0.16, so argv is the portable knob. The nightly cron uses the 1 h
    // default; a local smoke run passes a few seconds. A separate
    // `page_allocator` parses argv so it cannot pollute the leak counters.
    var duration_ms: i64 = 60 * 60 * 1000;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.args, std.heap.page_allocator);
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |a| {
            if (std.mem.startsWith(u8, a, "--duration-ms=")) {
                duration_ms = std.fmt.parseInt(i64, a["--duration-ms=".len..], 10) catch duration_ms;
            }
        }
    }

    // Leak detection: counting allocator over page_allocator. After join,
    // alloc_count must equal free_count and the byte tallies must balance.
    var counter = CountingAllocator.init(std.heap.page_allocator);
    const gpa = counter.allocator();

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
        .duration_ms = duration_ms,
    };
    const reader = try std.Thread.spawn(.{}, readerLoop, .{ &ctx, gpa });
    const writer = try std.Thread.spawn(.{}, writerLoop, .{ &ctx, gpa });
    writer.join();
    reader.join();

    const snap = counter.snapshot();
    const leaked = snap.alloc_count != snap.free_count or
        snap.bytes_allocated != snap.bytes_freed;
    std.debug.print(
        "fuzz_1h: duration_ms={d} types={d} sent={d} recv={d} fault={d} " ++
            "alloc={d} free={d} bytes_alloc={d} bytes_freed={d}\n",
        .{
            duration_ms,     fuzz_types.len,           ctx.sent,
            ctx.recv,        ctx.fault.load(.acquire), snap.alloc_count,
            snap.free_count, snap.bytes_allocated,     snap.bytes_freed,
        },
    );

    // Non-zero exit on any failure so the nightly job goes red.
    if (ctx.fault.load(.acquire) != 0) return error.FuzzReaderFault;
    if (ctx.sent == 0) return error.FuzzNoTraffic;
    if (ctx.sent != ctx.recv) return error.FuzzSentRecvMismatch;
    if (leaked) return error.FuzzLeak;
}
