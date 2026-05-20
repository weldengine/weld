//! Pure CLI parser for the S2 spike binary. Throwaway with the rest of
//! `src/spike/`. Tested in isolation (`tests/spike/cli_test.zig`); no
//! allocation, no I/O, deterministic.

const std = @import("std");

/// `--gpu-prefer=<…>` value — overrides the spike's default device
/// scoring policy.
pub const GpuPrefer = union(enum) {
    discrete,
    integrated,
    /// Direct index into `vkEnumeratePhysicalDevices` results.
    index: u32,
};

/// Parsed CLI argument set for the S2 spike binary.
pub const Args = struct {
    /// `--gpu-prefer=<discrete|integrated|index:N>` — overrides the default
    /// `scoreDevice` policy. `null` = use default scoring.
    gpu_prefer: ?GpuPrefer = null,
    /// `--smoke-test` — run the non-interactive capture flow.
    smoke_test: bool = false,
    /// `--measure-frame-time[=N]` — sample N **post-warmup** frame
    /// durations and emit median / p95 / max to stdout. `null` = not
    /// requested. Default N when the flag is bare: 300 (per brief).
    /// The first 10 frames are skipped — see `measure_warmup_frames` in
    /// `main.zig` and the brief's "after the first 10 frames" carve-out.
    measure_frame_time: ?u32 = null,
    /// `--verbose` — log window events to stdout in interactive mode.
    /// Always on in `--smoke-test` mode regardless of this flag.
    verbose: bool = false,
};

/// Error set surfaced by `parse`.
pub const ParseError = error{
    UnknownFlag,
    InvalidGpuPrefer,
    InvalidGpuIndex,
    InvalidMeasureFrameTime,
};

/// Parse the S2 spike CLI flags out of `args` (which excludes
/// `argv[0]`). Returns a populated `Args` on success or a typed
/// `ParseError` on unrecognised flags / malformed values.
pub fn parse(args: []const []const u8) ParseError!Args {
    var out: Args = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--smoke-test")) {
            out.smoke_test = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            out.verbose = true;
        } else if (std.mem.eql(u8, arg, "--measure-frame-time")) {
            out.measure_frame_time = 300;
        } else if (std.mem.startsWith(u8, arg, "--measure-frame-time=")) {
            const v = arg["--measure-frame-time=".len..];
            out.measure_frame_time = std.fmt.parseInt(u32, v, 10) catch return error.InvalidMeasureFrameTime;
        } else if (std.mem.startsWith(u8, arg, "--gpu-prefer=")) {
            const v = arg["--gpu-prefer=".len..];
            if (std.mem.eql(u8, v, "discrete")) {
                out.gpu_prefer = .discrete;
            } else if (std.mem.eql(u8, v, "integrated")) {
                out.gpu_prefer = .integrated;
            } else if (std.mem.startsWith(u8, v, "index:")) {
                const idx_str = v["index:".len..];
                const idx = std.fmt.parseInt(u32, idx_str, 10) catch return error.InvalidGpuIndex;
                out.gpu_prefer = .{ .index = idx };
            } else {
                return error.InvalidGpuPrefer;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        }
        // Bare positional arguments are silently ignored — the spike does
        // not take any.
    }
    return out;
}
