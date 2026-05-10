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
const WM_CLOSE: u32 = 0x0010;
const WM_NCCREATE: u32 = 0x0081;
const WM_DPICHANGED: u32 = 0x02E0;

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

// =============================================================== Backend =

/// Class registration is process-wide. We register lazily on first create
/// and unregister on the last destroy (refcounted) so 50× open/close
/// cycles do not accumulate stale class atoms.
var class_atom: ATOM = 0;
var class_open_count: u32 = 0;
const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("WeldS2WindowClass");

/// `SetProcessDpiAwarenessContext` is called once per process. Failures are
/// non-fatal — a Windows version that does not support per-monitor v2
/// simply does not deliver `WM_DPICHANGED`, which is acceptable for S2.
var dpi_awareness_set: bool = false;

fn ensureDpiAwareness() void {
    if (dpi_awareness_set) return;
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    dpi_awareness_set = true;
}

fn ensureClassRegistered() window.Error!void {
    if (class_open_count == 0) {
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
    class_open_count += 1;
}

fn releaseClass() void {
    if (class_open_count == 0) return;
    class_open_count -= 1;
    if (class_open_count == 0) {
        _ = UnregisterClassW(class_name_w, GetModuleHandleW(null));
        class_atom = 0;
    }
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
};

pub const NativeHandles = struct {
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

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
            const w: u32 = @intCast(@as(u32, @bitCast(@as(i32, @truncate(lparam)))) & 0xFFFF);
            const h: u32 = @intCast((@as(u32, @bitCast(@as(i32, @truncate(lparam)))) >> 16) & 0xFFFF);
            state.events.append(state.gpa, .{ .resize = .{ .width = w, .height = h } }) catch {};
            return 0;
        },
        WM_DPICHANGED => {
            const new_dpi: u32 = @intCast(wparam & 0xFFFF);
            if (new_dpi != state.last_dpi and new_dpi != 0) {
                state.last_dpi = new_dpi;
                const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / 96.0;
                state.events.append(state.gpa, .{ .dpi_changed = scale }) catch {};
            }
            return 0;
        },
        WM_DESTROY => {
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
