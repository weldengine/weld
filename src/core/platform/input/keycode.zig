//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Normalized keyboard scancode enum — common to Win32 and Wayland backends.
//!
//! Phase 0.3 / M0.3 deliverable. Documented in the M0.3 brief and
//! `engine-input-system.md` §1 (Hardware Layer Tier 0).
//!
//! ## Model
//!
//! `KeyCode` is the **physical key identifier** — a scancode that does not
//! depend on the active keyboard layout. A US layout, an AZERTY layout,
//! and a Dvorak layout all produce the same `KeyCode` for the key in the
//! upper-left letter row regardless of which character it types.
//!
//! Text input (the layout-aware "what character did the user type?")
//! requires XKB on Linux and `ToUnicodeEx` on Win32, both of which are
//! out-of-scope for Phase 0 — see `engine-phase-0-criteria.md` §C0.7 and
//! the M0.3 brief § Out-of-scope.
//!
//! ## Encoding
//!
//! Encoded as `u8` (256 values max) — the M0.3 `InputRawState.keyboard`
//! resource uses `[256]bool` bitsets indexed directly by the `@intFromEnum`
//! representation. Unknown / unhandled keys map to `.unknown` (0).
//!
//! ## Mapping tables
//!
//! The Win32 `mapFromWin32Scancode(u32) KeyCode` and Wayland
//! `mapFromEvdevCode(u32) KeyCode` helpers translate the raw OS scancodes
//! into this normalized enum. They live next to this enum so both
//! backends share a single source of truth.

const std = @import("std");

/// Physical key identifier — independent of keyboard layout.
pub const KeyCode = enum(u8) {
    unknown = 0,

    // Letters (US layout positions). Etch-friendly snake_case.
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // Digit row (top row of the main keyboard, not numpad).
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    // Function keys.
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,

    // Whitespace + control.
    escape,
    tab,
    enter,
    backspace,
    space,

    // Modifiers — explicit left/right so gameplay can distinguish.
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    /// Windows key / Cmd (macOS) / Super (Linux).
    left_super,
    right_super,

    // Arrows.
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,

    // Navigation cluster.
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,

    // Lock keys.
    caps_lock,
    num_lock,
    scroll_lock,

    // Miscellaneous.
    print_screen,
    pause,
    menu,

    // Punctuation (US layout positions).
    grave_accent, // ` ~
    minus, // - _
    equal, // = +
    left_bracket, // [ {
    right_bracket, // ] }
    backslash, // \ |
    semicolon, // ; :
    apostrophe, // ' "
    comma, // , <
    period, // . >
    slash, // / ?

    // Numpad.
    np_0,
    np_1,
    np_2,
    np_3,
    np_4,
    np_5,
    np_6,
    np_7,
    np_8,
    np_9,
    np_decimal, // .
    np_divide, // /
    np_multiply, // *
    np_subtract, // -
    np_add, // +
    np_enter,
    np_equal, // = (rare on PC, present on Mac/Sun)

    _, // open enum — leaves headroom for future additions without
    // breaking the wire format
};

/// Map a Win32 scancode (LParam bits 16-23 of WM_KEY*) to KeyCode.
/// Win32 scancodes are based on the IBM PC AT set 1 scan codes, with
/// extended keys flagged in bit 8 (E0 prefix).
///
/// Bit 24 (LParam bit 24) is the extended-key flag, distinguishing for
/// example the numpad Enter from the main Enter. We accept the full
/// (scancode, extended) tuple as `(u32)` where the high byte holds the
/// extended flag — callers extract it from LParam directly.
pub fn mapFromWin32Scancode(packed_scancode: u32) KeyCode {
    const scancode: u8 = @intCast(packed_scancode & 0xFF);
    const extended: bool = (packed_scancode & 0x100) != 0;

    // Subset table — covers the keys an engine gameplay layer needs.
    // Win32 scan codes are stable since IBM PC AT (1984).
    return switch (scancode) {
        0x01 => .escape,
        0x02 => .digit_1,
        0x03 => .digit_2,
        0x04 => .digit_3,
        0x05 => .digit_4,
        0x06 => .digit_5,
        0x07 => .digit_6,
        0x08 => .digit_7,
        0x09 => .digit_8,
        0x0A => .digit_9,
        0x0B => .digit_0,
        0x0C => .minus,
        0x0D => .equal,
        0x0E => .backspace,
        0x0F => .tab,
        0x10 => .q,
        0x11 => .w,
        0x12 => .e,
        0x13 => .r,
        0x14 => .t,
        0x15 => .y,
        0x16 => .u,
        0x17 => .i,
        0x18 => .o,
        0x19 => .p,
        0x1A => .left_bracket,
        0x1B => .right_bracket,
        0x1C => if (extended) .np_enter else .enter,
        0x1D => if (extended) .right_ctrl else .left_ctrl,
        0x1E => .a,
        0x1F => .s,
        0x20 => .d,
        0x21 => .f,
        0x22 => .g,
        0x23 => .h,
        0x24 => .j,
        0x25 => .k,
        0x26 => .l,
        0x27 => .semicolon,
        0x28 => .apostrophe,
        0x29 => .grave_accent,
        0x2A => .left_shift,
        0x2B => .backslash,
        0x2C => .z,
        0x2D => .x,
        0x2E => .c,
        0x2F => .v,
        0x30 => .b,
        0x31 => .n,
        0x32 => .m,
        0x33 => .comma,
        0x34 => .period,
        0x35 => if (extended) .np_divide else .slash,
        0x36 => .right_shift,
        0x37 => if (extended) .print_screen else .np_multiply,
        0x38 => if (extended) .right_alt else .left_alt,
        0x39 => .space,
        0x3A => .caps_lock,
        0x3B => .f1,
        0x3C => .f2,
        0x3D => .f3,
        0x3E => .f4,
        0x3F => .f5,
        0x40 => .f6,
        0x41 => .f7,
        0x42 => .f8,
        0x43 => .f9,
        0x44 => .f10,
        0x45 => if (extended) .num_lock else .pause,
        0x46 => .scroll_lock,
        0x47 => if (extended) .home else .np_7,
        0x48 => if (extended) .arrow_up else .np_8,
        0x49 => if (extended) .page_up else .np_9,
        0x4A => .np_subtract,
        0x4B => if (extended) .arrow_left else .np_4,
        0x4C => .np_5,
        0x4D => if (extended) .arrow_right else .np_6,
        0x4E => .np_add,
        0x4F => if (extended) .end else .np_1,
        0x50 => if (extended) .arrow_down else .np_2,
        0x51 => if (extended) .page_down else .np_3,
        0x52 => if (extended) .insert else .np_0,
        0x53 => if (extended) .delete else .np_decimal,
        0x57 => .f11,
        0x58 => .f12,
        0x5B => .left_super,
        0x5C => .right_super,
        0x5D => .menu,
        else => .unknown,
    };
}

/// Map a Linux evdev `KEY_*` code (from `<linux/input-event-codes.h>`) to
/// KeyCode. Both Wayland (via `wl_keyboard.key.key`) and direct evdev
/// (`/dev/input/eventN`) deliver these scan-code values.
pub fn mapFromEvdevCode(evdev: u32) KeyCode {
    return switch (evdev) {
        1 => .escape,
        2 => .digit_1,
        3 => .digit_2,
        4 => .digit_3,
        5 => .digit_4,
        6 => .digit_5,
        7 => .digit_6,
        8 => .digit_7,
        9 => .digit_8,
        10 => .digit_9,
        11 => .digit_0,
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        16 => .q,
        17 => .w,
        18 => .e,
        19 => .r,
        20 => .t,
        21 => .y,
        22 => .u,
        23 => .i,
        24 => .o,
        25 => .p,
        26 => .left_bracket,
        27 => .right_bracket,
        28 => .enter,
        29 => .left_ctrl,
        30 => .a,
        31 => .s,
        32 => .d,
        33 => .f,
        34 => .g,
        35 => .h,
        36 => .j,
        37 => .k,
        38 => .l,
        39 => .semicolon,
        40 => .apostrophe,
        41 => .grave_accent,
        42 => .left_shift,
        43 => .backslash,
        44 => .z,
        45 => .x,
        46 => .c,
        47 => .v,
        48 => .b,
        49 => .n,
        50 => .m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        54 => .right_shift,
        55 => .np_multiply,
        56 => .left_alt,
        57 => .space,
        58 => .caps_lock,
        59 => .f1,
        60 => .f2,
        61 => .f3,
        62 => .f4,
        63 => .f5,
        64 => .f6,
        65 => .f7,
        66 => .f8,
        67 => .f9,
        68 => .f10,
        69 => .num_lock,
        70 => .scroll_lock,
        71 => .np_7,
        72 => .np_8,
        73 => .np_9,
        74 => .np_subtract,
        75 => .np_4,
        76 => .np_5,
        77 => .np_6,
        78 => .np_add,
        79 => .np_1,
        80 => .np_2,
        81 => .np_3,
        82 => .np_0,
        83 => .np_decimal,
        87 => .f11,
        88 => .f12,
        96 => .np_enter,
        97 => .right_ctrl,
        98 => .np_divide,
        99 => .print_screen,
        100 => .right_alt,
        102 => .home,
        103 => .arrow_up,
        104 => .page_up,
        105 => .arrow_left,
        106 => .arrow_right,
        107 => .end,
        108 => .arrow_down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        117 => .np_equal,
        119 => .pause,
        125 => .left_super,
        126 => .right_super,
        127 => .menu,
        else => .unknown,
    };
}

test "keycode.mapFromWin32Scancode: covers main letter row" {
    try std.testing.expectEqual(KeyCode.a, mapFromWin32Scancode(0x1E));
    try std.testing.expectEqual(KeyCode.escape, mapFromWin32Scancode(0x01));
    try std.testing.expectEqual(KeyCode.space, mapFromWin32Scancode(0x39));
    try std.testing.expectEqual(KeyCode.unknown, mapFromWin32Scancode(0xFE));
}

test "keycode.mapFromWin32Scancode: extended bit distinguishes enter vs np_enter" {
    try std.testing.expectEqual(KeyCode.enter, mapFromWin32Scancode(0x1C));
    try std.testing.expectEqual(KeyCode.np_enter, mapFromWin32Scancode(0x1C | 0x100));
    try std.testing.expectEqual(KeyCode.left_ctrl, mapFromWin32Scancode(0x1D));
    try std.testing.expectEqual(KeyCode.right_ctrl, mapFromWin32Scancode(0x1D | 0x100));
}

test "keycode.mapFromEvdevCode: covers main letter row" {
    try std.testing.expectEqual(KeyCode.a, mapFromEvdevCode(30));
    try std.testing.expectEqual(KeyCode.escape, mapFromEvdevCode(1));
    try std.testing.expectEqual(KeyCode.space, mapFromEvdevCode(57));
    try std.testing.expectEqual(KeyCode.unknown, mapFromEvdevCode(9999));
}
