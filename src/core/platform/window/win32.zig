//! Native Win32 `Window` backend for the S2 spike. Throwaway? No — the
//! brief makes this Tier 0 from S2 onward. Phase 0.3 extends with input
//! handling under the same public surface.
//!
//! Hand-written `extern fn` declarations against `user32.dll` /
//! `gdi32.dll` / `kernel32.dll`. Static linkage via Zig import libs;
//! no `dlopen`, no `translate-c`, no XML.

const std = @import("std");
const window = @import("../window.zig");

// ============================================================== Win32 ABI =

const HINSTANCE = *opaque {};
const HWND = *opaque {};
const HMENU = ?*opaque {};
const HICON = ?*opaque {};
const HCURSOR = ?*opaque {};
const HBRUSH = ?*opaque {};
const DPI_AWARENESS_CONTEXT = *opaque {};
const HMODULE = HINSTANCE;

const LPCWSTR = [*:0]const u16;
const LPVOID = ?*anyopaque;
const ATOM = u16;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const DWORD = u32;
const UINT = u32;
const BOOL = i32;
const INT = i32;
const LONG = i32;
const ULONG_PTR = usize;
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT;

const WS_OVERLAPPED: u32 = 0x00000000;
const WS_CAPTION: u32 = 0x00C00000;
const WS_SYSMENU: u32 = 0x00080000;
const WS_THICKFRAME: u32 = 0x00040000;
const WS_MINIMIZEBOX: u32 = 0x00020000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_OVERLAPPEDWINDOW: u32 = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;

const GWLP_USERDATA: i32 = -21;

const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_SETFOCUS: u32 = 0x0007;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_CLOSE: u32 = 0x0010;
const WM_NCCREATE: u32 = 0x0081;
// Keyboard
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_SYSKEYDOWN: u32 = 0x0104;
const WM_SYSKEYUP: u32 = 0x0105;
// Mouse
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_MBUTTONDOWN: u32 = 0x0207;
const WM_MBUTTONUP: u32 = 0x0208;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_XBUTTONDOWN: u32 = 0x020B;
const WM_XBUTTONUP: u32 = 0x020C;
const WM_MOUSEHWHEEL: u32 = 0x020E;
// Multi-monitor / DPI
const WM_DPICHANGED: u32 = 0x02E0;

// SIZE_* wParam values for WM_SIZE.
const SIZE_RESTORED: u32 = 0;
const SIZE_MINIMIZED: u32 = 1;
const SIZE_MAXIMIZED: u32 = 2;

// MONITOR_DEFAULT* for MonitorFromWindow.
const MONITOR_DEFAULTTONEAREST: u32 = 2;

// Mouse wheel delta — 120 == one "notch" per Win32 convention.
const WHEEL_DELTA: f32 = 120.0;

const PM_REMOVE: u32 = 0x0001;

const SW_SHOW: i32 = 5;

/// `MAKEINTRESOURCE(32512)` → standard arrow cursor.
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`. Fakes a HANDLE value of -4
/// per Win32 convention.
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

const POINT = extern struct { x: LONG, y: LONG };
const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    w_param: WPARAM,
    l_param: LPARAM,
    time: DWORD,
    pt: POINT,
    private: DWORD,
};

const WNDCLASSEXW = extern struct {
    cb_size: UINT,
    style: UINT,
    lpfn_wnd_proc: WNDPROC,
    cb_cls_extra: INT,
    cb_wnd_extra: INT,
    h_instance: HINSTANCE,
    h_icon: HICON,
    h_cursor: HCURSOR,
    hbr_background: HBRUSH,
    lpsz_menu_name: ?LPCWSTR,
    lpsz_class_name: LPCWSTR,
    h_icon_sm: HICON,
};

const CREATESTRUCTW = extern struct {
    lp_create_params: LPVOID,
    h_instance: HINSTANCE,
    h_menu: HMENU,
    hwnd_parent: ?HWND,
    cy: INT,
    cx: INT,
    y: INT,
    x: INT,
    style: LONG,
    lpsz_name: ?LPCWSTR,
    lpsz_class: ?LPCWSTR,
    dw_ex_style: DWORD,
};

extern "kernel32" fn GetModuleHandleW(lp_module_name: ?LPCWSTR) callconv(.c) HMODULE;
extern "user32" fn LoadCursorW(h_instance: ?HINSTANCE, lp_cursor_name: LPCWSTR) callconv(.c) HCURSOR;
extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.c) ATOM;
extern "user32" fn UnregisterClassW(lp_class_name: LPCWSTR, h_instance: HINSTANCE) callconv(.c) BOOL;
extern "user32" fn CreateWindowExW(
    dw_ex_style: DWORD,
    lp_class_name: LPCWSTR,
    lp_window_name: LPCWSTR,
    dw_style: DWORD,
    x: INT,
    y: INT,
    n_width: INT,
    n_height: INT,
    hwnd_parent: ?HWND,
    h_menu: HMENU,
    h_instance: HINSTANCE,
    lp_param: LPVOID,
) callconv(.c) ?HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.c) BOOL;
extern "user32" fn ShowWindow(hwnd: HWND, n_cmd_show: INT) callconv(.c) BOOL;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, w_param: WPARAM, l_param: LPARAM) callconv(.c) LRESULT;
extern "user32" fn PeekMessageW(lp_msg: *MSG, hwnd: ?HWND, w_msg_filter_min: UINT, w_msg_filter_max: UINT, w_remove_msg: UINT) callconv(.c) BOOL;
extern "user32" fn TranslateMessage(lp_msg: *const MSG) callconv(.c) BOOL;
extern "user32" fn DispatchMessageW(lp_msg: *const MSG) callconv(.c) LRESULT;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, n_index: INT, dw_new_long: ULONG_PTR) callconv(.c) ULONG_PTR;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, n_index: INT) callconv(.c) ULONG_PTR;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.c) UINT;
extern "user32" fn SetProcessDpiAwarenessContext(value: DPI_AWARENESS_CONTEXT) callconv(.c) BOOL;

// M0.3 multi-monitor surface.
extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.c) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(hMonitor: *anyopaque, lpmi: *MONITORINFOEXW) callconv(.c) BOOL;
extern "shcore" fn GetDpiForMonitor(hMonitor: *anyopaque, dpiType: UINT, dpiX: *UINT, dpiY: *UINT) callconv(.c) i32;
extern "user32" fn EnumDisplayMonitors(
    hdc: ?*anyopaque,
    lprcClip: ?*const RECT,
    lpfnEnum: *const fn (hMonitor: *anyopaque, hdc: ?*anyopaque, lprcMonitor: *const RECT, dwData: LPARAM) callconv(.c) BOOL,
    dwData: LPARAM,
) callconv(.c) BOOL;

const MONITORINFOEXW = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
    szDevice: [32]u16,
};

// =============================================================== Backend =

// M0.3 — Win32 thread safety patch (dette D-S2-win32-globals).
//
// Phase 0 Win32 backend used three plain `var` globals (class_atom,
// class_open_count, dpi_awareness_set) that were race-condition prone
// under concurrent createWindow/destroyWindow. M0.3 migrates them to:
//
//   - `class_once` (Once)      — registers the window class exactly once
//                                 per process lifetime. Class atom value
//                                 is stored next to it.
//   - `class_open_count`       — atomic refcount via fetchAdd/fetchSub
//                                 (acq_rel). The class is NOT
//                                 unregistered on count=0 — a single
//                                 class atom per process is the standard
//                                 Win32 pattern and avoids the TOCTOU
//                                 between "decrement → check 0 →
//                                 unregister" that the previous code had.
//   - `dpi_awareness_once`     — Once-protected SetProcessDpiAwarenessContext.
//
// Tested by `tests/platform/win32_thread_safety_test.zig` (8 threads ×
// 1000 iter; skipped on non-Windows runners).

const once_mod = @import("../once.zig");
const keycode_mod = @import("../input/keycode.zig");

/// Class registration once-init. After successful init, `class_atom`
/// is populated and `class_once.isDone() == true`. The class is kept
/// registered for the lifetime of the process — the Win32 kernel
/// recycles atoms automatically, so 50× open/close cycles cost a single
/// atom slot, not N.
var class_once: once_mod.Once = .{};
var class_atom: ATOM = 0;
const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("WeldS2WindowClass");

/// Live-window refcount. Incremented on `createWindow` after the class
/// is registered, decremented on `destroyWindow`. Used by tests to
/// confirm balanced create/destroy across threads.
var class_open_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// `SetProcessDpiAwarenessContext` is called once per process. Failures
/// are non-fatal — a Windows version that does not support per-monitor
/// v2 simply does not deliver `WM_DPICHANGED`, which is acceptable.
var dpi_awareness_once: once_mod.Once = .{};

fn dpiAwarenessInit() anyerror!void {
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // Failures here are tolerable — we do not propagate the error so
    // the Once transitions to DONE permanently.
}

fn ensureDpiAwareness() void {
    // Busy-yield variant — avoids threading an `io` parameter through
    // the public `Window.create` API. Contention window is microseconds.
    dpi_awareness_once.callBusyYield(dpiAwarenessInit) catch {};
}

fn classInit() anyerror!void {
    const wc = WNDCLASSEXW{
        .cb_size = @sizeOf(WNDCLASSEXW),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfn_wnd_proc = wndProc,
        .cb_cls_extra = 0,
        .cb_wnd_extra = 0,
        .h_instance = GetModuleHandleW(null),
        .h_icon = null,
        .h_cursor = LoadCursorW(null, IDC_ARROW),
        .hbr_background = null,
        .lpsz_menu_name = null,
        .lpsz_class_name = class_name_w,
        .h_icon_sm = null,
    };
    const atom = RegisterClassExW(&wc);
    if (atom == 0) return error.BackendInitFailed;
    class_atom = atom;
}

fn ensureClassRegistered() window.Error!void {
    class_once.callBusyYield(classInit) catch return error.BackendInitFailed;
    _ = class_open_count.fetchAdd(1, .acq_rel);
}

fn releaseClass() void {
    _ = class_open_count.fetchSub(1, .acq_rel);
    // The class atom intentionally stays registered for the lifetime of
    // the process. See top-of-file comment for rationale.
}

/// Read the live window count. Used by tests.
pub fn classOpenCount() u32 {
    return class_open_count.load(.acquire);
}

/// Read the class atom. Used by tests to verify stability across threads.
pub fn classAtom() ATOM {
    return class_atom;
}

/// Heap-allocated state. The `*State` pointer goes into `GWLP_USERDATA` so
/// `wndProc` can route messages back; the pointer must therefore be stable
/// across moves of the surrounding `Window` value.
const State = struct {
    hwnd: HWND,
    events: std.ArrayList(window.Event),
    gpa: std.mem.Allocator,
    title_w: [:0]u16,
    /// Last delivered DPI scale, so `WM_DPICHANGED` skips no-op ticks.
    last_dpi: u32 = 96,
    // M0.3 — mouse state tracking for delta computation.
    last_mouse_x: i32 = 0,
    last_mouse_y: i32 = 0,
    mouse_in_window: bool = false,
    // M0.3 — multi-monitor: last known HMONITOR for change detection.
    last_monitor: ?*anyopaque = null,
};

/// Native Win32 handles needed by Vulkan to create a `VkSurfaceKHR`.
pub const NativeHandles = struct {
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

/// Win32 implementation of the public `Window` interface. Owns the
/// `HWND` plus the registered window-class atom and event pump state.
pub const Backend = struct {
    state: *State,

    pub fn nativeHandles(self: *const Backend) NativeHandles {
        return .{
            .hinstance = @ptrCast(GetModuleHandleW(null)),
            .hwnd = @ptrCast(self.state.hwnd),
        };
    }

    pub fn create(gpa: std.mem.Allocator, desc: window.Desc) window.Error!Backend {
        ensureDpiAwareness();
        try ensureClassRegistered();
        errdefer releaseClass();

        const state = try gpa.create(State);
        errdefer gpa.destroy(state);

        const utf16 = std.unicode.utf8ToUtf16LeAlloc(gpa, desc.title) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WindowCreateFailed,
        };
        defer gpa.free(utf16);
        const title_w = try gpa.allocSentinel(u16, utf16.len, 0);
        errdefer gpa.free(title_w);
        @memcpy(title_w[0..utf16.len], utf16);

        state.* = .{
            .hwnd = undefined,
            .events = .empty,
            .gpa = gpa,
            .title_w = title_w,
        };
        errdefer state.events.deinit(gpa);

        const hwnd = CreateWindowExW(
            0,
            class_name_w,
            title_w,
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(desc.width),
            @intCast(desc.height),
            null,
            null,
            GetModuleHandleW(null),
            state,
        ) orelse return error.WindowCreateFailed;
        state.hwnd = hwnd;

        // The lpCreateParam path stores `state` via `WM_NCCREATE`; if the
        // OS skipped that message (custom subclassing, …) we set it
        // explicitly here so `wndProc` always finds the backref.
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intFromPtr(state));

        return .{ .state = state };
    }

    pub fn destroy(self: *Backend) void {
        const s = self.state;
        // Clear the user-data backref before DestroyWindow so the
        // synchronous `WM_DESTROY` does not re-enter `s` after we have
        // started tearing it down.
        _ = SetWindowLongPtrW(s.hwnd, GWLP_USERDATA, 0);
        _ = DestroyWindow(s.hwnd);
        // Drain any pending messages so subsequent windows do not inherit
        // stale state on the per-thread queue.
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        s.events.deinit(s.gpa);
        s.gpa.free(s.title_w);
        s.gpa.destroy(s);
        releaseClass();
    }

    pub fn close(self: *Backend) void {
        // Synthesize a close event the same way a user-driven X click would.
        self.state.events.append(self.state.gpa, .close) catch {};
    }

    pub fn pollEvent(self: *Backend) ?window.Event {
        // Pump until either the queue has something or there are no more
        // OS messages.
        while (self.state.events.items.len == 0) {
            var msg: MSG = undefined;
            if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) == 0) break;
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        if (self.state.events.items.len == 0) return null;
        return self.state.events.orderedRemove(0);
    }
};

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) LRESULT {
    // `WM_NCCREATE` carries our `lpCreateParam` (the heap-allocated `State`).
    // Stash it in user-data so subsequent messages can find it without a
    // global lookup.
    if (msg == WM_NCCREATE) {
        // `lparam` carries the CREATESTRUCTW pointer as an isize. Use
        // `@bitCast` (not `@intCast`) so the conversion preserves the bit
        // pattern even if the address has the high bit set — `@intCast`
        // would panic on a negative isize that's a valid usize address.
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lp_create_params) |p| {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intFromPtr(p));
        }
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ud = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ud == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
    const state: *State = @ptrFromInt(ud);

    switch (msg) {
        WM_CLOSE => {
            state.events.append(state.gpa, .close) catch {};
            return 0;
        },
        WM_SIZE => {
            // wparam = SIZE_*; lparam low/high = client width/height.
            const w: u32 = @intCast(@as(u32, @bitCast(@as(i32, @truncate(lparam)))) & 0xFFFF);
            const h: u32 = @intCast((@as(u32, @bitCast(@as(i32, @truncate(lparam)))) >> 16) & 0xFFFF);
            state.events.append(state.gpa, .{ .resize = .{ .width = w, .height = h } }) catch {};
            switch (@as(u32, @intCast(wparam))) {
                SIZE_MINIMIZED => state.events.append(state.gpa, .minimize) catch {},
                SIZE_RESTORED, SIZE_MAXIMIZED => state.events.append(state.gpa, .restore) catch {},
                else => {},
            }
            return 0;
        },
        WM_DPICHANGED => {
            const new_dpi: u32 = @intCast(wparam & 0xFFFF);
            if (new_dpi != state.last_dpi and new_dpi != 0) {
                state.last_dpi = new_dpi;
                const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / 96.0;
                state.events.append(state.gpa, .{ .dpi_changed = scale }) catch {};
                // Also report per-monitor: the window may have moved to a
                // different monitor — re-resolve and surface that explicitly.
                if (MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)) |mon| {
                    const mon_id: u32 = @truncate(@intFromPtr(mon));
                    state.events.append(state.gpa, .{ .dpi_changed_per_monitor = .{ .monitor = mon_id, .scale = scale } }) catch {};
                    if (state.last_monitor != mon) {
                        state.last_monitor = mon;
                        state.events.append(state.gpa, .{ .monitor_changed = mon_id }) catch {};
                    }
                }
            }
            return 0;
        },

        // ============================== M0.3 — Keyboard events
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            // LParam bits 16-23: scan code. Bit 24: extended key flag.
            // Bit 30: previous key state (1 = was down → repeat).
            const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
            const scancode: u8 = @intCast((lp >> 16) & 0xFF);
            const extended: bool = (lp & (1 << 24)) != 0;
            const repeat: bool = (lp & (1 << 30)) != 0;
            const packed_sc: u32 = @as(u32, scancode) | (if (extended) @as(u32, 0x100) else 0);
            const code = keycode_mod.mapFromWin32Scancode(packed_sc);
            state.events.append(state.gpa, .{ .key_down = .{ .code = code, .scancode = @intCast(scancode), .repeat = repeat } }) catch {};
            return 0;
        },
        WM_KEYUP, WM_SYSKEYUP => {
            const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
            const scancode: u8 = @intCast((lp >> 16) & 0xFF);
            const extended: bool = (lp & (1 << 24)) != 0;
            const packed_sc: u32 = @as(u32, scancode) | (if (extended) @as(u32, 0x100) else 0);
            const code = keycode_mod.mapFromWin32Scancode(packed_sc);
            state.events.append(state.gpa, .{ .key_up = .{ .code = code, .scancode = @intCast(scancode) } }) catch {};
            return 0;
        },

        // ============================== M0.3 — Mouse events
        WM_MOUSEMOVE => {
            const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(lp)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(lp >> 16)))));
            const dx: i32 = if (state.mouse_in_window) x - state.last_mouse_x else 0;
            const dy: i32 = if (state.mouse_in_window) y - state.last_mouse_y else 0;
            state.last_mouse_x = x;
            state.last_mouse_y = y;
            state.mouse_in_window = true;
            state.events.append(state.gpa, .{ .mouse_motion = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .dx = @floatFromInt(dx),
                .dy = @floatFromInt(dy),
            } }) catch {};
            return 0;
        },
        WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_XBUTTONDOWN, WM_XBUTTONUP => {
            const lp: u32 = @bitCast(@as(i32, @truncate(lparam)));
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(lp)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @truncate(lp >> 16)))));
            const button: window.MouseButton = switch (msg) {
                WM_LBUTTONDOWN, WM_LBUTTONUP => .left,
                WM_RBUTTONDOWN, WM_RBUTTONUP => .right,
                WM_MBUTTONDOWN, WM_MBUTTONUP => .middle,
                WM_XBUTTONDOWN, WM_XBUTTONUP => blk: {
                    // High word of wparam encodes XBUTTON1 (1) or XBUTTON2 (2).
                    const xb = (wparam >> 16) & 0xFFFF;
                    break :blk if (xb == 1) .x1 else .x2;
                },
                else => unreachable,
            };
            const pressed: bool = switch (msg) {
                WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN => true,
                else => false,
            };
            state.events.append(state.gpa, .{ .mouse_button = .{
                .button = button,
                .pressed = pressed,
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
            } }) catch {};
            // XBUTTON* messages expect a return of TRUE.
            return if (msg == WM_XBUTTONDOWN or msg == WM_XBUTTONUP) 1 else 0;
        },
        WM_MOUSEWHEEL => {
            // High word of wparam is the wheel delta (signed).
            const raw: i16 = @bitCast(@as(u16, @truncate((wparam >> 16) & 0xFFFF)));
            const dy: f32 = @as(f32, @floatFromInt(raw)) / WHEEL_DELTA;
            state.events.append(state.gpa, .{ .mouse_wheel = .{ .dx = 0, .dy = dy } }) catch {};
            return 0;
        },
        WM_MOUSEHWHEEL => {
            const raw: i16 = @bitCast(@as(u16, @truncate((wparam >> 16) & 0xFFFF)));
            const dx: f32 = @as(f32, @floatFromInt(raw)) / WHEEL_DELTA;
            state.events.append(state.gpa, .{ .mouse_wheel = .{ .dx = dx, .dy = 0 } }) catch {};
            return 0;
        },

        // ============================== M0.3 — Focus events
        WM_SETFOCUS => {
            state.events.append(state.gpa, .focus_gained) catch {};
            return 0;
        },
        WM_KILLFOCUS => {
            state.events.append(state.gpa, .focus_lost) catch {};
            return 0;
        },

        WM_DESTROY => {
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// =============================================================== Multi-monitor

const MonitorEnumCtx = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayList(window.MonitorInfo),
    /// Constrained to `std.mem.Allocator.Error` so the inferred error
    /// set of `enumerateMonitors` matches `window.QueryError` exactly.
    err: ?std.mem.Allocator.Error = null,
};

fn enumMonitorCallback(hMonitor: *anyopaque, hdc: ?*anyopaque, lprcMonitor: *const RECT, dwData: LPARAM) callconv(.c) BOOL {
    _ = hdc;
    const ctx: *MonitorEnumCtx = @ptrFromInt(@as(usize, @bitCast(dwData)));

    var info: MONITORINFOEXW = undefined;
    info.cbSize = @sizeOf(MONITORINFOEXW);
    if (GetMonitorInfoW(hMonitor, &info) == 0) {
        // Failed to query — skip but continue enumeration.
        return 1;
    }

    var dpi_x: UINT = 96;
    var dpi_y: UINT = 96;
    _ = GetDpiForMonitor(hMonitor, 0, &dpi_x, &dpi_y); // MDT_EFFECTIVE_DPI = 0

    var mi: window.MonitorInfo = .{
        .id = @truncate(@intFromPtr(hMonitor)),
        .x = lprcMonitor.left,
        .y = lprcMonitor.top,
        .width = @intCast(lprcMonitor.right - lprcMonitor.left),
        .height = @intCast(lprcMonitor.bottom - lprcMonitor.top),
        .dpi_scale = @as(f32, @floatFromInt(dpi_x)) / 96.0,
    };
    // Copy device name (UTF-16) → UTF-8 name buffer, truncating to 63 chars + NUL.
    var k: usize = 0;
    while (k < info.szDevice.len and info.szDevice[k] != 0 and k + 1 < mi.name.len) : (k += 1) {
        // Naïve ASCII truncation — Win32 device names are ASCII-safe
        // (\\.\DISPLAY1 etc.).
        const c = info.szDevice[k];
        mi.name[k] = if (c < 0x80) @intCast(c) else '?';
    }
    mi.name[k] = 0;

    ctx.list.append(ctx.gpa, mi) catch |err| {
        ctx.err = err;
        return 0; // stop enumeration
    };
    return 1;
}

/// Win32 implementation of `enumerateMonitors` — delegates to `EnumDisplayMonitors`.
pub fn enumerateMonitors(gpa: std.mem.Allocator) std.mem.Allocator.Error![]window.MonitorInfo {
    var list: std.ArrayList(window.MonitorInfo) = .empty;
    errdefer list.deinit(gpa);

    var ctx: MonitorEnumCtx = .{ .gpa = gpa, .list = &list };
    _ = EnumDisplayMonitors(null, null, enumMonitorCallback, @bitCast(@as(usize, @intFromPtr(&ctx))));
    if (ctx.err) |e| return e;

    return list.toOwnedSlice(gpa);
}

/// Win32 implementation of `currentMonitor` — `MonitorFromWindow` with
/// `MONITOR_DEFAULTTONEAREST`.
pub fn currentMonitor(backend_ptr: *const Backend) ?u32 {
    const hwnd = backend_ptr.state.hwnd;
    const mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) orelse return null;
    return @truncate(@intFromPtr(mon));
}
