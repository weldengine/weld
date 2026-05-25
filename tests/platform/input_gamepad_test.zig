//! Tests M0.3 — gamepad connect/disconnect + raw stick values.
//!
//! Covers the acceptance tests called out in the M0.3 brief:
//!   - "gamepad connect/disconnect updates GamepadState.connected"
//!   - "gamepad sticks raw values in [-1, 1] without deadzone"

const std = @import("std");
const weld = @import("weld_core");
const raw_state = weld.platform.input.raw_state;

test "gamepad connect/disconnect updates GamepadState.connected" {
    var s: raw_state.InputRawState = .{};
    try std.testing.expect(!s.gamepads[0].connected);
    try std.testing.expect(!s.gamepads[2].connected);

    // Simulated connection event for slot 2.
    raw_state.applyEvent(&s, .{ .gamepad_connected = 2 });
    try std.testing.expect(s.gamepads[2].connected);
    // Other slots untouched.
    try std.testing.expect(!s.gamepads[0].connected);
    try std.testing.expect(!s.gamepads[1].connected);
    try std.testing.expect(!s.gamepads[3].connected);

    // Disconnect.
    raw_state.applyEvent(&s, .{ .gamepad_disconnected = 2 });
    try std.testing.expect(!s.gamepads[2].connected);
}

test "gamepad sticks raw values in [-1, 1] without deadzone" {
    var s: raw_state.InputRawState = .{};
    s.gamepads[0].connected = true;

    // Push a small stick value (0.05) — must pass through untouched.
    // Tier 0 applies no deadzone; that's the Tier 1 mapping layer's job.
    raw_state.applyGamepadSnapshot(&s, 0, .{
        .buttons = 0,
        .sticks = .{ .{ 0.05, -0.03 }, .{ 0.0, 0.99 } },
        .triggers = .{ 0.0, 0.5 },
    });
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), s.gamepads[0].sticks[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.03), s.gamepads[0].sticks[0][1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.99), s.gamepads[0].sticks[1][1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.gamepads[0].triggers[1], 0.001);
}
