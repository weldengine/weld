//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Linux evdev gamepad polling. Hot-plug is by periodic `scanDevices()` over
//! `/dev/input/event*`, which the caller drives from its own loop.

// THIS MODULE IS A STUB: `pollAllSlots` is a no-op and `scanDevices` opens then
// closes each fd without extracting capabilities, so a gamepad plugged in under
// Linux stays INVISIBLE. Mouse and keyboard go through the Wayland protocols
// instead. Completing it means EV_KEY / EV_ABS parsing via EVIOCGBIT and an event
// loop folded into the Wayland mainloop — and it happens HERE, not in Tier 1.

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

/// Devices currently open, plus the next free slot.
const State = struct {
    devices: std.ArrayList(Device) = .empty,
    last_scan_ns: u64 = 0,
};

var g_state: State = .{};

// Minimal by intent; the full ioctl surface is not needed by the stub.

const O_RDONLY: c_int = 0;
const O_NONBLOCK: c_int = 0x800;

extern "c" fn open(pathname: [*:0]const u8, flags: c_int) c_int;
extern "c" fn close_fd(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, nbytes: usize) isize;

/// Scan `/dev/input/` for gamepad-like devices and open them into free slots.
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
            already_tracked = false; // simplified — proper tracking is Phase 1+
        }
        if (already_tracked) continue;

        const fd = open(path_z.ptr, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;

        // Capability probing is what this stub does not do.
        _ = close_fd(fd);
        opened += 1;
    }
    return opened;
}

/// Drain pending evdev events from the open devices — a no-op in this stub.
pub fn pollAllSlots(gpa: std.mem.Allocator, state: *raw_state.InputRawState) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = .{ gpa, state };
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
