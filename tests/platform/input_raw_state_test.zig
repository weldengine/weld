//! Tests M0.3 — InputRawState event-driven transitions.
//!
//! Covers the acceptance tests called out in the M0.3 brief:
//!   - "keyboard pressed/released transitions"
//!   - "mouse delta accumulation per frame"

const std = @import("std");
const weld = @import("weld_core");
const raw_state = weld.platform.input.raw_state;

test "keyboard pressed/released transitions" {
    var s: raw_state.InputRawState = .{};

    // Frame N: simulate scancode 'B' = 48 down.
    raw_state.beginFrame(&s);
    raw_state.applyEvent(&s, .{ .key_down = .{ .code = .b, .scancode = 48, .repeat = false } });
    try std.testing.expect(s.keyboard.pressed[48]);
    try std.testing.expect(s.keyboard.pressed_this_frame[48]);
    try std.testing.expect(!s.keyboard.released_this_frame[48]);

    // Frame N+1 .. N+k: 'B' is held but no event fires; pressed remains true,
    // pressed_this_frame clears.
    raw_state.beginFrame(&s);
    try std.testing.expect(s.keyboard.pressed[48]);
    try std.testing.expect(!s.keyboard.pressed_this_frame[48]);

    raw_state.beginFrame(&s);
    raw_state.beginFrame(&s);
    try std.testing.expect(s.keyboard.pressed[48]);
    try std.testing.expect(!s.keyboard.pressed_this_frame[48]);

    // Frame N+k+1: 'B' released.
    raw_state.beginFrame(&s);
    raw_state.applyEvent(&s, .{ .key_up = .{ .code = .b, .scancode = 48 } });
    try std.testing.expect(!s.keyboard.pressed[48]);
    try std.testing.expect(s.keyboard.released_this_frame[48]);

    // Frame after release: everything settled.
    raw_state.beginFrame(&s);
    try std.testing.expect(!s.keyboard.pressed[48]);
    try std.testing.expect(!s.keyboard.released_this_frame[48]);
}

test "mouse delta accumulation per frame" {
    var s: raw_state.InputRawState = .{};

    raw_state.beginFrame(&s);
    // Three motion events in the same frame.
    raw_state.applyEvent(&s, .{ .mouse_motion = .{ .x = 100, .y = 100, .dx = 1, .dy = 2 } });
    raw_state.applyEvent(&s, .{ .mouse_motion = .{ .x = 101, .y = 102, .dx = 2, .dy = 3 } });
    raw_state.applyEvent(&s, .{ .mouse_motion = .{ .x = 103, .y = 105, .dx = 3, .dy = 4 } });

    // delta accumulates additively.
    try std.testing.expectApproxEqAbs(@as(f32, 6), s.mouse.delta[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 9), s.mouse.delta[1], 0.01);
    // position reflects the latest event.
    try std.testing.expectApproxEqAbs(@as(f32, 103), s.mouse.position[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 105), s.mouse.position[1], 0.01);

    // Next frame: delta resets to zero, position preserved.
    raw_state.beginFrame(&s);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.mouse.delta[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.mouse.delta[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 103), s.mouse.position[0], 0.01);
}
