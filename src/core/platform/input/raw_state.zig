//! Input Tier 0 — `InputRawState` resource (`@transient`).
//!
//! Phase 0.3 / M0.3 deliverable. Documented in `engine-input-system.md`
//! §1 (Hardware Layer Tier 0) and the M0.3 brief.
//!
//! ## Model
//!
//! `InputRawState` is a per-frame snapshot of raw input devices —
//! keyboard, mouse, up to 4 gamepad slots. Surfaced as a Tier 0 ECS
//! resource (`@transient`, reset every frame). Consumed by the Input
//! Tier 1 module (`engine-input-system.md` Mapping Layer, Phase 1) to
//! derive `Action<T>` outputs according to the active `input_mapping`.
//!
//! ## Per-frame lifecycle
//!
//! Each frame:
//!   1. `beginFrame()` clears the `*_this_frame` transition bitsets and
//!      resets mouse delta / wheel accumulators. The "pressed" bitsets
//!      and gamepad state are preserved (they track steady-state).
//!   2. The platform window backend drains its event queue and calls
//!      `applyEvent(InputRawState, Event)` for each surfaced event.
//!   3. The gamepad polling routine (`win32_xinput` or `linux_evdev`)
//!      reads the current state of each slot and calls
//!      `applyGamepadSnapshot(self, slot, snapshot)`.
//!   4. Gameplay systems (Phase 1+) read `InputRawState` and derive
//!      typed actions.
//!
//! ## Bitset layout
//!
//! Bitsets are `[N]bool` arrays for clarity — at <512 bytes total
//! (256+256+256 = 768 bytes for the keyboard alone), the memory cost
//! is irrelevant compared to the readability win of a direct
//! `state.keyboard.pressed[scancode]` index over a packed-bitset
//! shift-and-mask. The brief gates "pressed bitset (256 scancodes)" —
//! `[256]bool` keyed by **raw scancode** is the literal interpretation.
//! Logical-key access in Phase 0 is `window.Event.code` (the frozen
//! `KeyCode` contract); a KeyCode-keyed steady-state view is the
//! Phase-1 Input Tier-1 mapping layer (`engine-input-system.md`).

const std = @import("std");
const window = @import("../window.zig");
const keycode = @import("keycode.zig");

/// Keyboard state — physical key press/release tracking.
pub const KeyboardState = extern struct {
    /// 1 if the physical key is currently held. Indexed by the **raw OS
    /// scancode** (`ev.scancode & 0xFF`), NOT by the `KeyCode` enum — the
    /// two do not share a codomain (the same logical key has different
    /// scancodes on Win32 vs evdev). This is the raw hardware layer: for
    /// logical-key input read `window.Event.code` (the frozen `KeyCode`
    /// contract); cross-backend logical-key steady-state querying is the
    /// Phase-1 Input Tier-1 mapping layer (`engine-input-system.md`).
    pressed: [256]bool = [_]bool{false} ** 256,
    /// 1 on the frame the key transitioned from up to down (rising edge).
    /// Cleared at the start of each frame.
    pressed_this_frame: [256]bool = [_]bool{false} ** 256,
    /// 1 on the frame the key transitioned from down to up (falling edge).
    /// Cleared at the start of each frame.
    released_this_frame: [256]bool = [_]bool{false} ** 256,
};

/// Mouse state — cursor position, delta, button state, scroll wheel.
pub const MouseState = extern struct {
    /// Absolute client-area position in physical pixels.
    position: [2]f32 = .{ 0, 0 },
    /// Accumulated delta this frame (sum of all motion events). Reset
    /// at the start of each frame.
    delta: [2]f32 = .{ 0, 0 },
    /// Wheel scroll accumulator: [horizontal, vertical]. Reset each
    /// frame.
    wheel: [2]f32 = .{ 0, 0 },
    /// 1 if the button is currently held. Indexed by MouseButton enum.
    buttons: [8]bool = [_]bool{false} ** 8,
    /// Rising edge bitset, cleared each frame.
    buttons_this_frame: [8]bool = [_]bool{false} ** 8,
    /// Falling edge bitset, cleared each frame.
    released_this_frame: [8]bool = [_]bool{false} ** 8,
};

/// Per-slot gamepad state. Up to 4 slots tracked simultaneously.
pub const GamepadState = extern struct {
    /// True if a controller is currently connected to this slot.
    connected: bool = false,
    /// Bitset of currently-held buttons (32 button slots max). The bit
    /// layout is backend-dependent — XInput's wButtons mask on Win32,
    /// evdev's KEY_BTN_* layout on Linux. Phase 0 ships the raw bits;
    /// Phase 1 Input Tier 1 normalizes via per-controller mappings.
    buttons: u32 = 0,
    /// Rising edge bitset, cleared each frame.
    buttons_this_frame: u32 = 0,
    /// Falling edge bitset, cleared each frame.
    released_this_frame: u32 = 0,
    /// Stick positions, raw [-1, 1] without deadzone. Layout:
    /// `sticks[0]` = left stick {x, y}; `sticks[1]` = right stick {x, y}.
    /// y is positive = up (industry convention, matches XInput post-normalisation).
    sticks: [2][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 } },
    /// Trigger positions, raw [0, 1]. Layout: `triggers[0]` = left
    /// trigger, `triggers[1]` = right trigger.
    triggers: [2]f32 = .{ 0, 0 },
};

/// Snapshot of all input devices for the current frame.
/// Allocated by the World as a Tier 0 `@transient` resource.
pub const InputRawState = extern struct {
    keyboard: KeyboardState = .{},
    mouse: MouseState = .{},
    gamepads: [4]GamepadState = [_]GamepadState{.{}} ** 4,
};

/// Clear per-frame transition bitsets and accumulators. Call at the
/// start of every frame, before draining window events.
pub fn beginFrame(self: *InputRawState) void {
    self.keyboard.pressed_this_frame = [_]bool{false} ** 256;
    self.keyboard.released_this_frame = [_]bool{false} ** 256;
    self.mouse.delta = .{ 0, 0 };
    self.mouse.wheel = .{ 0, 0 };
    self.mouse.buttons_this_frame = [_]bool{false} ** 8;
    self.mouse.released_this_frame = [_]bool{false} ** 8;
    for (&self.gamepads) |*g| {
        g.buttons_this_frame = 0;
        g.released_this_frame = 0;
    }
}

/// Apply a single `window.Event` to the state. Mouse motion, wheel,
/// and button events update the mouse sub-state; keyboard events
/// update the keyboard sub-state; gamepad connect/disconnect events
/// update the `connected` flag on the appropriate slot. Other event
/// variants are ignored.
///
/// The mouse `delta` field is accumulated additively across multiple
/// motion events in the same frame; the `position` always reflects
/// the most-recent event.
pub fn applyEvent(self: *InputRawState, event: window.Event) void {
    switch (event) {
        .key_down => |ev| {
            const idx = @as(usize, ev.scancode) & 0xFF;
            // Auto-repeat events don't fire pressed_this_frame (the brief
            // gate is rising-edge only).
            if (!self.keyboard.pressed[idx] and !ev.repeat) {
                self.keyboard.pressed_this_frame[idx] = true;
            }
            self.keyboard.pressed[idx] = true;
        },
        .key_up => |ev| {
            const idx = @as(usize, ev.scancode) & 0xFF;
            if (self.keyboard.pressed[idx]) {
                self.keyboard.released_this_frame[idx] = true;
            }
            self.keyboard.pressed[idx] = false;
        },
        .mouse_motion => |ev| {
            self.mouse.position = .{ ev.x, ev.y };
            self.mouse.delta[0] += ev.dx;
            self.mouse.delta[1] += ev.dy;
        },
        .mouse_button => |ev| {
            const b: usize = @intFromEnum(ev.button);
            if (b >= self.mouse.buttons.len) return;
            if (ev.pressed and !self.mouse.buttons[b]) {
                self.mouse.buttons_this_frame[b] = true;
            }
            if (!ev.pressed and self.mouse.buttons[b]) {
                self.mouse.released_this_frame[b] = true;
            }
            self.mouse.buttons[b] = ev.pressed;
            self.mouse.position = .{ ev.x, ev.y };
        },
        .mouse_wheel => |ev| {
            self.mouse.wheel[0] += ev.dx;
            self.mouse.wheel[1] += ev.dy;
        },
        .gamepad_connected => |slot| {
            if (slot < self.gamepads.len) {
                self.gamepads[slot].connected = true;
            }
        },
        .gamepad_disconnected => |slot| {
            if (slot < self.gamepads.len) {
                self.gamepads[slot] = .{}; // reset state on disconnect
            }
        },
        else => {},
    }
}

/// Snapshot delivered by the gamepad polling routines
/// (`win32_xinput` / `linux_evdev`) once per frame, per slot.
pub const GamepadSnapshot = struct {
    buttons: u32,
    sticks: [2][2]f32,
    triggers: [2]f32,
};

/// Apply a gamepad snapshot to slot `slot`. Computes the rising/falling
/// edge bitsets from the previous frame's buttons.
pub fn applyGamepadSnapshot(self: *InputRawState, slot: u8, snapshot: GamepadSnapshot) void {
    if (slot >= self.gamepads.len) return;
    const g = &self.gamepads[slot];
    const prev_buttons = g.buttons;
    g.buttons = snapshot.buttons;
    g.buttons_this_frame = snapshot.buttons & ~prev_buttons;
    g.released_this_frame = prev_buttons & ~snapshot.buttons;
    g.sticks = snapshot.sticks;
    g.triggers = snapshot.triggers;
}

// ============================================================== inline tests

test "InputRawState: key down/up transitions clear correctly" {
    var s: InputRawState = .{};

    // Frame N: simulate scancode 'B' = 48 down
    beginFrame(&s);
    applyEvent(&s, .{ .key_down = .{ .code = .b, .scancode = 48, .repeat = false } });
    try std.testing.expect(s.keyboard.pressed[48]);
    try std.testing.expect(s.keyboard.pressed_this_frame[48]);
    try std.testing.expect(!s.keyboard.released_this_frame[48]);

    // Frame N+1: same key still held, no event
    beginFrame(&s);
    try std.testing.expect(s.keyboard.pressed[48]);
    try std.testing.expect(!s.keyboard.pressed_this_frame[48]);

    // Frame N+2: release
    beginFrame(&s);
    applyEvent(&s, .{ .key_up = .{ .code = .b, .scancode = 48 } });
    try std.testing.expect(!s.keyboard.pressed[48]);
    try std.testing.expect(s.keyboard.released_this_frame[48]);

    // Frame N+3: nothing
    beginFrame(&s);
    try std.testing.expect(!s.keyboard.pressed[48]);
    try std.testing.expect(!s.keyboard.released_this_frame[48]);
}

test "InputRawState: mouse delta accumulates across motion events" {
    var s: InputRawState = .{};
    beginFrame(&s);

    applyEvent(&s, .{ .mouse_motion = .{ .x = 100, .y = 100, .dx = 5, .dy = 5 } });
    applyEvent(&s, .{ .mouse_motion = .{ .x = 102, .y = 103, .dx = 2, .dy = 3 } });
    applyEvent(&s, .{ .mouse_motion = .{ .x = 105, .y = 110, .dx = 3, .dy = 7 } });

    try std.testing.expectApproxEqAbs(@as(f32, 105), s.mouse.position[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 110), s.mouse.position[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), s.mouse.delta[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 15), s.mouse.delta[1], 0.01);

    // Frame boundary resets delta but keeps position.
    beginFrame(&s);
    try std.testing.expectApproxEqAbs(@as(f32, 105), s.mouse.position[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.mouse.delta[0], 0.01);
}

test "InputRawState: mouse wheel accumulates and resets" {
    var s: InputRawState = .{};
    beginFrame(&s);
    applyEvent(&s, .{ .mouse_wheel = .{ .dx = 0, .dy = 1.5 } });
    applyEvent(&s, .{ .mouse_wheel = .{ .dx = 0, .dy = 0.5 } });
    applyEvent(&s, .{ .mouse_wheel = .{ .dx = 1, .dy = 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.mouse.wheel[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), s.mouse.wheel[1], 0.01);

    beginFrame(&s);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.mouse.wheel[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.mouse.wheel[1], 0.01);
}

test "InputRawState: gamepad connect/disconnect" {
    var s: InputRawState = .{};

    applyEvent(&s, .{ .gamepad_connected = 1 });
    try std.testing.expect(s.gamepads[1].connected);

    applyEvent(&s, .{ .gamepad_disconnected = 1 });
    try std.testing.expect(!s.gamepads[1].connected);
}

test "InputRawState: gamepad snapshot computes button transitions" {
    var s: InputRawState = .{};
    s.gamepads[0].connected = true;

    applyGamepadSnapshot(&s, 0, .{
        .buttons = 0b0001, // button 0 pressed
        .sticks = .{ .{ 0.05, 0 }, .{ 0, 0 } },
        .triggers = .{ 0.5, 0 },
    });
    try std.testing.expect((s.gamepads[0].buttons & 0b0001) != 0);
    try std.testing.expect((s.gamepads[0].buttons_this_frame & 0b0001) != 0);
    // Sticks pass raw — no deadzone applied at Tier 0 (per brief).
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), s.gamepads[0].sticks[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.gamepads[0].triggers[0], 0.001);

    // Next frame: clear transitions, button still held.
    beginFrame(&s);
    applyGamepadSnapshot(&s, 0, .{
        .buttons = 0b0001,
        .sticks = .{ .{ 0.05, 0 }, .{ 0, 0 } },
        .triggers = .{ 0.5, 0 },
    });
    try std.testing.expect((s.gamepads[0].buttons & 0b0001) != 0);
    try std.testing.expect((s.gamepads[0].buttons_this_frame & 0b0001) == 0);

    // Release.
    beginFrame(&s);
    applyGamepadSnapshot(&s, 0, .{
        .buttons = 0,
        .sticks = .{ .{ 0, 0 }, .{ 0, 0 } },
        .triggers = .{ 0, 0 },
    });
    try std.testing.expect(s.gamepads[0].buttons == 0);
    try std.testing.expect((s.gamepads[0].released_this_frame & 0b0001) != 0);
}

// Ensure the KeyCode re-export is consumed (so this file pins keycode.zig
// in the analysis frontier — the inline tests of keycode also get picked up).
comptime {
    _ = keycode.KeyCode;
}
