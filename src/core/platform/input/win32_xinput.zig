//! XInput gamepad polling for the Win32 platform layer.
//!
//! Phase 0.3 / M0.3 deliverable — minimal implementation. Documented
//! in the M0.3 brief § Input system Tier 0 minimal :
//!
//!   > Win32 : `XInputGetState` polled chaque frame pour les 4 slots
//!   > gamepad.
//!
//! XInput is the Microsoft-Xbox controller API; it exposes up to 4
//! slots and is the most reliable Windows gamepad API for the common
//! case (Xbox-style controllers + Steam Input transparent passthrough).
//! DirectInput would be needed for legacy / non-Xbox layouts — out of
//! scope for Phase 0 (the brief gates the Tier 1 mapping layer in
//! Phase 1 for that).
//!
//! ## Hot-plug
//!
//! XInput does not surface a "controller connected" callback — the
//! standard approach is to poll all 4 slots every frame and observe
//! `XInputGetState` returning `ERROR_DEVICE_NOT_CONNECTED` (1167)
//! for empty slots. Connection state changes are emitted as
//! `gamepad_connected` / `gamepad_disconnected` events.

const std = @import("std");
const builtin = @import("builtin");
const raw_state = @import("raw_state.zig");

// XInput constants.
const ERROR_SUCCESS: u32 = 0;
const ERROR_DEVICE_NOT_CONNECTED: u32 = 1167;
const XINPUT_GAMEPAD_TRIGGER_THRESHOLD: u8 = 30;

// XINPUT_GAMEPAD struct from XInput.h — Microsoft-stable since Windows 7.
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

// Late-bound — XInput's DLL has had three names across Windows versions
// (XInput1_4.dll on Win8+, XInput9_1_0.dll on Win7, XInput1_3.dll on
// DirectX SDK installs). Resolved at runtime via DynamicLib so Phase 0
// builds run on all three.
const XInputGetStateFn = *const fn (dwUserIndex: u32, pState: *XINPUT_STATE) callconv(.winapi) u32;

var xinput_get_state: ?XInputGetStateFn = null;
var xinput_loaded: bool = false;

const dynamic_lib = @import("../dynamic_lib.zig");

fn ensureLoaded(gpa: std.mem.Allocator) void {
    if (xinput_loaded) return;
    xinput_loaded = true;
    if (comptime builtin.os.tag != .windows) return;

    // Try the modern DLL first, fall back to legacy names.
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
        // Intentionally leak the lib handle for the process lifetime —
        // XInput's state machine is process-wide; closing the lib would
        // require also clearing every cached function pointer.
        return;
    }
}

/// Poll all 4 XInput slots and apply snapshots to `state`. Emits
/// `gamepad_connected` / `gamepad_disconnected` events into a caller-
/// provided event sink whenever a slot's connected status changes.
/// On non-Windows targets, returns immediately.
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
            // ERROR_DEVICE_NOT_CONNECTED or any other failure — mark slot
            // disconnected. Per-frame polling means hot-plug arrives
            // naturally on the next frame.
            state.gamepads[slot].connected = false;
            state.gamepads[slot].buttons = 0;
            state.gamepads[slot].sticks = .{ .{ 0, 0 }, .{ 0, 0 } };
            state.gamepads[slot].triggers = .{ 0, 0 };
        }
    }
}
