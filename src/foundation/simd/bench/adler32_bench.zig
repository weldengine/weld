//! ADLER32 throughput baseline (brief §Acceptance ▸ Benchmarks).
//!
//! Records the portable `@Vector` and scalar-reference throughput on a fixed
//! buffer. **Baseline only — no parity target.** ADLER32 sits on a cold
//! path (it runs once at cook time; the runtime mmaps the cooked `.bin`), so
//! a zlib-ng parity target is explicitly out of scope (brief §Notes —
//! cold-path principle). The number exists to track gross regressions, not
//! to chase a reference.
//!
//! Run: `zig build bench-adler32` (add `-- --smoke` for a tiny CI sanity run).

const std = @import("std");
const simd = @import("foundation").simd;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var smoke = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--smoke")) smoke = true;
    }

    const buf_len: usize = if (smoke) 64 * 1024 else 8 * 1024 * 1024;
    const iterations: usize = if (smoke) 4 else 64;

    const buf = try gpa.alloc(u8, buf_len);
    defer gpa.free(buf);
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 2_654_435_761);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;

    const vec_mbps = benchOne(simd.kernels.adler32.vectorized, buf, iterations, io);
    const ref_mbps = benchOne(simd.kernels.adler32.reference, buf, iterations, io);

    try out.print("## adler32 — bench baseline\n\n", .{});
    try out.print("Buffer: {d} bytes, {d} iterations\n\n", .{ buf_len, iterations });
    try out.print("| Variant   | Throughput (MB/s) |\n", .{});
    try out.print("|-----------|-------------------|\n", .{});
    try out.print("| portable  | {d:.1} |\n", .{vec_mbps});
    try out.print("| reference | {d:.1} |\n", .{ref_mbps});
    try out.print("\n(baseline only — no parity target; cold path)\n", .{});
    try out.flush();
}

fn benchOne(comptime kernel: fn ([]const u8) u32, buf: []const u8, iterations: usize, io: std.Io) f64 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var sink: u32 = 0;
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        sink ^= kernel(buf);
    }
    const elapsed_ns: i96 = start.untilNow(io).raw.nanoseconds;
    std.mem.doNotOptimizeAway(sink);

    if (elapsed_ns <= 0) return 0;
    const total_bytes: f64 = @floatFromInt(buf.len * iterations);
    const seconds: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(elapsed_ns)))) / 1_000_000_000.0;
    return total_bytes / seconds / 1_000_000.0;
}
