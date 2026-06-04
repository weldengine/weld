//! Paeth-filter-decode throughput baseline (brief §Acceptance ▸ Benchmarks).
//!
//! **Baseline only — no parity target** (cold path; PNG defiltering runs
//! once at cook time). Tracks gross regressions, nothing more.
//!
//! Run: `zig build bench-paeth` (add `-- --smoke` for a tiny CI sanity run).

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

    const bpp: u8 = 4; // RGBA8 scanline
    const row_len: usize = if (smoke) 4 * 1024 else 4 * 1024 * 1024;
    const iterations: usize = if (smoke) 4 else 64;

    const prev = try gpa.alloc(u8, row_len);
    defer gpa.free(prev);
    const curr = try gpa.alloc(u8, row_len);
    defer gpa.free(curr);
    for (prev, 0..) |*b, i| b.* = @truncate(i *% 40_503);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;

    const vec_mbps = benchOne(simd.kernels.paeth.vectorized, prev, curr, bpp, iterations, io);
    const ref_mbps = benchOne(simd.kernels.paeth.reference, prev, curr, bpp, iterations, io);

    try out.print("## paeth_filter_decode — bench baseline\n\n", .{});
    try out.print("Scanline: {d} bytes (bpp={d}), {d} iterations\n\n", .{ row_len, bpp, iterations });
    try out.print("| Variant   | Throughput (MB/s) |\n", .{});
    try out.print("|-----------|-------------------|\n", .{});
    try out.print("| portable  | {d:.1} |\n", .{vec_mbps});
    try out.print("| reference | {d:.1} |\n", .{ref_mbps});
    try out.print("\n(baseline only — no parity target; cold path)\n", .{});
    try out.flush();
}

fn benchOne(
    comptime kernel: fn ([]const u8, []u8, u8) void,
    prev: []const u8,
    curr: []u8,
    bpp: u8,
    iterations: usize,
    io: std.Io,
) f64 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        @memcpy(curr, prev); // reset the filtered scanline each pass
        kernel(prev, curr, bpp);
    }
    const elapsed_ns: i96 = start.untilNow(io).raw.nanoseconds;
    std.mem.doNotOptimizeAway(curr.ptr);

    if (elapsed_ns <= 0) return 0;
    const total_bytes: f64 = @floatFromInt(curr.len * iterations);
    const seconds: f64 = @as(f64, @floatFromInt(@as(i64, @intCast(elapsed_ns)))) / 1_000_000_000.0;
    return total_bytes / seconds / 1_000_000.0;
}
