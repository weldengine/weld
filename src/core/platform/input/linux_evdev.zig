//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! Linux evdev gamepad polling.
//!
//! Minimal by design. The API surface and the device-scan loop are here; full
//! input parsing — EV_KEY for buttons, EV_ABS for axes, ioctl EVIOCGBIT for
//! capability detection — is sketched and kept minimal, because the contract that
//! matters is `InputRawState`, which the Wayland window backend already satisfies
//! through `wl_keyboard` / `wl_pointer`. Real evdev gamepad polling is the optional
//! path that lights up when a controller is plugged in.
//!
//! Hot-plug is `scanDevices()`, which scans `/dev/input/event*`; the caller invokes
//! it periodically — once per second, say — from the main loop. udev monitoring
//! would replace it if polling proves insufficient.

// TODO(Linux gamepad support): this module is a STUB. `pollAllSlots` is a no-op
// and `scanDevices` opens then closes the fds without extracting capabilities, so
// a gamepad plugged in under Linux stays INVISIBLE — mouse and keyboard go
// through `wl_pointer` / `wl_keyboard`, which cover the desktop common case. What
// it needs: EV_KEY/EV_ABS parsing via ioctl EVIOCGBIT, plus an event loop on the
// evdev fds inside the Wayland mainloop. The work belongs HERE, not in Tier 1.

const std = @import("std");
const builtin = @import("builtin");
const raw_state = @import("raw_state.zig");

/// Tracked evdev device — one per `/dev/input/eventN` we have opened.
const Device = struct {
    /// Slot assigned in `InputRawState.gamepads` (0..3).
    slot: u8,
    /// File descriptor — read non-blocking.
    fd: i32,
};

/// Global state — devices currently open + next free slot allocator.
/// Single-process model; a multi-process or sandboxed one is unimplemented.
const State = struct {
    devices: std.ArrayList(Device) = .empty,
    last_scan_ns: u64 = 0,
};

var g_state: State = .{};

// Linux ioctl + extern declarations. We keep this minimal — full evdev
// capability probing is unimplemented. Any /dev/input/event* file
// that looks like a gamepad by a name heuristic is opened.

const O_RDONLY: c_int = 0;
const O_NONBLOCK: c_int = 0x800;

extern "c" fn open(pathname: [*:0]const u8, flags: c_int) c_int;
extern "c" fn close_fd(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, nbytes: usize) isize;

/// Scan `/dev/input/` for new gamepad-like devices and open the ones
/// that aren't already tracked. Caller invokes this periodically (the
/// roughly every second is enough). Returns the number of newly
/// opened devices (0 in steady state).
pub fn scanDevices(gpa: std.mem.Allocator) usize {
    if (comptime builtin.os.tag != .linux) return 0;

    var dir = std.fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    var opened: usize = 0;
    while (iter.next() catch null) |entry| {
        if (entry.kind != .character_device) continue;
        if (!std.mem.startsWith(u8, entry.name, "event")) continue;

        var path_buf: [64]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "/dev/input/{s}", .{entry.name}) catch continue;

        // Skip if already tracked.
        const path_owned = gpa.dupeZ(u8, path_z) catch continue;
        defer gpa.free(path_owned);
        var already_tracked = false;
        for (g_state.devices.items) |dev| {
            _ = dev;
            already_tracked = false; // simplified — proper tracking is unimplemented
        }
        if (already_tracked) continue;

        const fd = open(path_z.ptr, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;

        // Capability probing via ioctl EVIOCGBIT is unimplemented: this
        // closes the fd immediately and leaves the slot free, and the
        // contract is satisfied by the wl_keyboard / wl_pointer paths in
        // wayland.zig. This stub establishes the API surface.
        _ = close_fd(fd);
        opened += 1;
    }
    return opened;
}

/// Drain any pending evdev events from the currently-open devices and
/// update `state` accordingly. On non-Linux targets, no-op.
///
/// A stub — the full EV_KEY / EV_ABS parsing is unimplemented. This
/// function is exposed so the Window backend mainloop has a stable
/// callsite; lighting it up does not require API changes downstream.
/// The `gpa` parameter mirrors `win32_xinput.pollAllSlots` so a
/// cross-OS mainloop binds a single signature — unused here
/// (this stub tracks no devices).
pub fn pollAllSlots(gpa: std.mem.Allocator, state: *raw_state.InputRawState) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = .{ gpa, state };
    // No devices tracked — the wl_pointer / wl_keyboard paths
    // cover the main keyboard + mouse via the compositor, which is the
    // common case. Real gamepad support fleshes out from `scanDevices`
    // + EV_KEY/EV_ABS parsing.
}

/// Tear down — close all open device fds.
pub fn deinit(gpa: std.mem.Allocator) void {
    if (comptime builtin.os.tag != .linux) {
        g_state.devices.deinit(gpa);
        return;
    }
    for (g_state.devices.items) |dev| {
        _ = close_fd(dev.fd);
    }
    g_state.devices.deinit(gpa);
}
