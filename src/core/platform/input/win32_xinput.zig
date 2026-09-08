//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! XInput surfaces no connect/disconnect callback, so all 4 slots are polled every
//! frame and an empty slot is the `ERROR_DEVICE_NOT_CONNECTED` return.

const std = @import("std");
const builtin = @import("builtin");
const raw_state = @import("raw_state.zig");

const ERROR_SUCCESS: u32 = 0;
const ERROR_DEVICE_NOT_CONNECTED: u32 = 1167;
const XINPUT_GAMEPAD_TRIGGER_THRESHOLD: u8 = 30;

// Mirrors `XINPUT_GAMEPAD` in XInput.h — field order and widths are the ABI.
const XINPUT_GAMEPAD = extern struct {
    wButtons: u16,
    bLeftTrigger: u8,
    bRightTrigger: u8,
    sThumbLX: i16,
    sThumbLY: i16,
    sThumbRX: i16,
    sThumbRY: i16,
};

const XINPUT_STATE = extern struct {
    dwPacketNumber: u32,
    Gamepad: XINPUT_GAMEPAD,
};

// Late-bound: the DLL name differs across Windows versions.
const XInputGetStateFn = *const fn (dwUserIndex: u32, pState: *XINPUT_STATE) callconv(.winapi) u32;

var xinput_get_state: ?XInputGetStateFn = null;
var xinput_loaded: bool = false;

const dynamic_lib = @import("../dynamic_lib.zig");

fn ensureLoaded(gpa: std.mem.Allocator) void {
    if (xinput_loaded) return;
    xinput_loaded = true;
    if (comptime builtin.os.tag != .windows) return;

    // Newest DLL first — the order is the fallback chain.
    const candidates = [_][]const u8{
        "XInput1_4.dll",
        "XInput9_1_0.dll",
        "XInput1_3.dll",
    };
    for (candidates) |name| {
        var lib = dynamic_lib.DynamicLib.open(gpa, name) catch continue;
        const sym = lib.lookup(gpa, "XInputGetState") catch {
            lib.close();
            continue;
        };
        xinput_get_state = @ptrCast(@alignCast(sym));
        // The handle is leaked for the process lifetime on purpose: closing it
        // would leave `xinput_get_state` dangling.
        return;
    }
}

/// Poll all 4 XInput slots into `state`; a no-op off Windows.
pub fn pollAllSlots(gpa: std.mem.Allocator, state: *raw_state.InputRawState) void {
    if (comptime builtin.os.tag != .windows) return;
    ensureLoaded(gpa);
    const get_state = xinput_get_state orelse return;

    var slot: u8 = 0;
    while (slot < 4) : (slot += 1) {
        var xs: XINPUT_STATE = std.mem.zeroes(XINPUT_STATE);
        const rc = get_state(@as(u32, slot), &xs);
        if (rc == ERROR_SUCCESS) {
            state.gamepads[slot].connected = true;
            const lx: f32 = @as(f32, @floatFromInt(xs.Gamepad.sThumbLX)) / 32767.0;
            const ly: f32 = @as(f32, @floatFromInt(xs.Gamepad.sThumbLY)) / 32767.0;
            const rx: f32 = @as(f32, @floatFromInt(xs.Gamepad.sThumbRX)) / 32767.0;
            const ry: f32 = @as(f32, @floatFromInt(xs.Gamepad.sThumbRY)) / 32767.0;
            const lt: f32 = @as(f32, @floatFromInt(xs.Gamepad.bLeftTrigger)) / 255.0;
            const rt: f32 = @as(f32, @floatFromInt(xs.Gamepad.bRightTrigger)) / 255.0;
            raw_state.applyGamepadSnapshot(state, slot, .{
                .buttons = @as(u32, xs.Gamepad.wButtons),
                .sticks = .{ .{ lx, ly }, .{ rx, ry } },
                .triggers = .{ lt, rt },
            });
        } else {
            // Any non-success return clears the slot, so stale state cannot survive.
            state.gamepads[slot].connected = false;
            state.gamepads[slot].buttons = 0;
            state.gamepads[slot].sticks = .{ .{ 0, 0 }, .{ 0, 0 } };
            state.gamepads[slot].triggers = .{ 0, 0 };
        }
    }
}
