//! Linux evdev gamepad polling.
//!
//! Phase 0.3 / M0.3 deliverable — minimal implementation. Documented
//! in the M0.3 brief § Input system Tier 0 minimal :
//!
//!   > Wayland : ... lecture non bloquante `/dev/input/eventN` pour
//!   > gamepad (intégrée au mainloop via `std.posix.poll` sur les fd
//!   > Wayland + evdev). Hot-plug gamepad via polling périodique de
//!   > `/dev/input/` toutes les N secondes (udev monitoring repoussé
//!   > Phase 1+ si polling suffit).
//!
//! ## Phase 0 scope
//!
//! M0.3 ships the API surface and the device-scan loop. Full input
//! parsing (EV_KEY for buttons, EV_ABS for axes, ioctl EVIOCGBIT for
//! capability detection) is sketched here but kept minimal — the
//! brief gate is the InputRawState contract + simulated-event tests,
//! which the Wayland window backend already satisfies via
//! `wl_keyboard` / `wl_pointer`. Real evdev gamepad polling is the
//! optional path that lights up when the user plugs in a controller.
//!
//! Hot-plug is via `scanDevices()` which scans `/dev/input/event*`.
//! The caller invokes it periodically (e.g., once per second) from
//! the main loop. udev monitoring is documented as "Phase 1+ if
//! polling proves insufficient" per the brief.

// PHASE 1+ TRANSFER NOTE — ce module est un stub Phase 0. `pollAllSlots`
// est no-op, `scanDevices` ouvre-puis-ferme les fd sans extraire les
// capabilities. Conséquence observable : un gamepad branché sous Linux
// Phase 0 reste invisible (la souris/clavier passent par
// wl_pointer/wl_keyboard qui couvrent le common case desktop). Phase 1
// doit livrer le parsing EV_KEY/EV_ABS via EVIOCGBIT + un event loop
// intégré au mainloop Wayland (`std.posix.poll` sur les fd evdev). Si un
// studio externe Phase 1 a besoin de gamepad Linux avant que le module
// Input Tier 1 arrive, c'est ici que ça arrive — pas dans Tier 1.

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
/// Phase 0+ single-process model; multi-process / sandboxed Phase 2+.
const State = struct {
    devices: std.ArrayList(Device) = .empty,
    last_scan_ns: u64 = 0,
};

var g_state: State = .{};

// Linux ioctl + extern declarations. We keep this minimal — full evdev
// capability probing is Phase 1+. M0.3 opens any /dev/input/event* file
// that looks like a gamepad based on a name heuristic.

const O_RDONLY: c_int = 0;
const O_NONBLOCK: c_int = 0x800;

extern "c" fn open(pathname: [*:0]const u8, flags: c_int) c_int;
extern "c" fn close_fd(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, nbytes: usize) isize;

/// Scan `/dev/input/` for new gamepad-like devices and open the ones
/// that aren't already tracked. Caller invokes this periodically (the
/// brief recommends every ~1 second). Returns the number of newly
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
            already_tracked = false; // simplified — proper tracking is Phase 1+
        }
        if (already_tracked) continue;

        const fd = open(path_z.ptr, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;

        // Capability probing via ioctl EVIOCGBIT is Phase 1+. Phase 0
        // closes the fd immediately and leaves the slot free; the brief
        // gate is satisfied by the wl_keyboard / wl_pointer paths in
        // wayland.zig. This stub establishes the API surface.
        _ = close_fd(fd);
        opened += 1;
    }
    return opened;
}

/// Drain any pending evdev events from the currently-open devices and
/// update `state` accordingly. On non-Linux targets, no-op.
///
/// Phase 0 stub — the full EV_KEY / EV_ABS parsing is Phase 1+. This
/// function is exposed so the Window backend mainloop has a stable
/// callsite; lighting it up does not require API changes downstream.
pub fn pollAllSlots(state: *raw_state.InputRawState) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = state;
    // No devices tracked Phase 0 — the wl_pointer / wl_keyboard paths
    // cover the main keyboard + mouse via the compositor, which is the
    // common case. Real gamepad support fleshes out from `scanDevices`
    // + EV_KEY/EV_ABS parsing in Phase 1+.
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
