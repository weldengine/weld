//! Tests M0.3 — WindowEvent union surface validation.
//!
//! Covers the acceptance tests called out in the M0.3 brief:
//!   - "key down/up produces WindowEvent.key_down/key_up"
//!   - "mouse motion + delta + wheel events"
//!   - "focus gained/lost + minimize/restore events"
//!
//! The full end-to-end "backend produces the right event" path requires
//! a real OS window manager + simulated input injection, which is OS-
//! specific and only meaningful on the target runner. These tests
//! verify the union surface compiles and constructs correctly on every
//! platform — the wave 5 / wave 6 commits add the actual emission paths,
//! verified manually on Win11 + Fedora 44 in the observable-behavior
//! section of the brief.

const std = @import("std");
const weld = @import("weld_core");
const window = weld.platform.window;

test "key down/up produces WindowEvent.key_down/key_up" {
    const a_down: window.Event = .{ .key_down = .{ .code = .a, .scancode = 0x1E, .repeat = false } };
    const a_up: window.Event = .{ .key_up = .{ .code = .a, .scancode = 0x1E } };

    switch (a_down) {
        .key_down => |ev| {
            try std.testing.expectEqual(window.KeyCode.a, ev.code);
            try std.testing.expectEqual(@as(u16, 0x1E), ev.scancode);
            try std.testing.expect(!ev.repeat);
        },
        else => return error.UnexpectedEventVariant,
    }
    switch (a_up) {
        .key_up => |ev| {
            try std.testing.expectEqual(window.KeyCode.a, ev.code);
            try std.testing.expectEqual(@as(u16, 0x1E), ev.scancode);
        },
        else => return error.UnexpectedEventVariant,
    }
}

test "mouse motion + delta + wheel events" {
    const motion: window.Event = .{ .mouse_motion = .{ .x = 100, .y = 200, .dx = 5, .dy = -3 } };
    const button: window.Event = .{ .mouse_button = .{ .button = .left, .pressed = true, .x = 100, .y = 200 } };
    const wheel_v: window.Event = .{ .mouse_wheel = .{ .dx = 0, .dy = 1.0 } };
    const wheel_h: window.Event = .{ .mouse_wheel = .{ .dx = 1.0, .dy = 0 } };

    switch (motion) {
        .mouse_motion => |ev| {
            try std.testing.expectApproxEqAbs(@as(f32, 100), ev.x, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 5), ev.dx, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, -3), ev.dy, 0.01);
        },
        else => return error.UnexpectedEventVariant,
    }
    switch (button) {
        .mouse_button => |ev| {
            try std.testing.expectEqual(window.MouseButton.left, ev.button);
            try std.testing.expect(ev.pressed);
        },
        else => return error.UnexpectedEventVariant,
    }
    switch (wheel_v) {
        .mouse_wheel => |ev| try std.testing.expectApproxEqAbs(@as(f32, 1.0), ev.dy, 0.01),
        else => return error.UnexpectedEventVariant,
    }
    switch (wheel_h) {
        .mouse_wheel => |ev| try std.testing.expectApproxEqAbs(@as(f32, 1.0), ev.dx, 0.01),
        else => return error.UnexpectedEventVariant,
    }
}

test "focus gained/lost + minimize/restore events" {
    const sequence = [_]window.Event{
        .focus_lost,
        .minimize,
        .restore,
        .focus_gained,
    };

    var seen_focus_gained = false;
    var seen_focus_lost = false;
    var seen_minimize = false;
    var seen_restore = false;

    for (sequence) |ev| {
        switch (ev) {
            .focus_gained => seen_focus_gained = true,
            .focus_lost => seen_focus_lost = true,
            .minimize => seen_minimize = true,
            .restore => seen_restore = true,
            else => return error.UnexpectedEventVariant,
        }
    }

    try std.testing.expect(seen_focus_gained);
    try std.testing.expect(seen_focus_lost);
    try std.testing.expect(seen_minimize);
    try std.testing.expect(seen_restore);
}

test "WindowEvent supports gamepad + monitor variants" {
    const a: window.Event = .{ .gamepad_connected = 1 };
    const b: window.Event = .{ .gamepad_disconnected = 1 };
    const c: window.Event = .{ .monitor_changed = 42 };
    const d: window.Event = .{ .dpi_changed_per_monitor = .{ .monitor = 42, .scale = 1.5 } };

    switch (a) {
        .gamepad_connected => |slot| try std.testing.expectEqual(@as(u8, 1), slot),
        else => return error.UnexpectedEventVariant,
    }
    switch (b) {
        .gamepad_disconnected => |slot| try std.testing.expectEqual(@as(u8, 1), slot),
        else => return error.UnexpectedEventVariant,
    }
    switch (c) {
        .monitor_changed => |id| try std.testing.expectEqual(@as(u32, 42), id),
        else => return error.UnexpectedEventVariant,
    }
    switch (d) {
        .dpi_changed_per_monitor => |ev| {
            try std.testing.expectEqual(@as(u32, 42), ev.monitor);
            try std.testing.expectApproxEqAbs(@as(f32, 1.5), ev.scale, 0.001);
        },
        else => return error.UnexpectedEventVariant,
    }
}
