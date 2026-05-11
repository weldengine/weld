//! Step (i) of the S2 brief: Wayland message-table layout gate. For the
//! four interfaces the spike actually wires (`wl_surface`, `xdg_surface`,
//! `xdg_toplevel`, `zxdg_toplevel_decoration_v1`), pin:
//!   * request opcodes match the protocol XML order,
//!   * listener slot ordering matches the protocol XML event order,
//!   * `WlInterface.method_count` / `event_count` match the generated
//!     request / event constant counts.
//!
//! Purely synthetic — no live Wayland connection, no dlopen. Runs on
//! every host as part of the default `zig build test` step. If
//! `wayland_gen` regresses (or upstream wayland-protocols re-orders a
//! request), this file fails at compile time or in the first assertion.

const std = @import("std");
const wl = @import("wl_protocols");
const core = wl.core;
const xdg_shell = wl.xdg_shell;
const xdg_decoration = wl.xdg_decoration;

test "wl_surface request opcodes match XML order" {
    const r = core.wl_surface_request;
    try std.testing.expectEqual(@as(u32, 0), r.destroy);
    try std.testing.expectEqual(@as(u32, 1), r.attach);
    try std.testing.expectEqual(@as(u32, 2), r.damage);
    try std.testing.expectEqual(@as(u32, 3), r.frame);
    try std.testing.expectEqual(@as(u32, 4), r.set_opaque_region);
    try std.testing.expectEqual(@as(u32, 5), r.set_input_region);
    try std.testing.expectEqual(@as(u32, 6), r.commit);
    try std.testing.expectEqual(@as(u32, 7), r.set_buffer_transform);
    try std.testing.expectEqual(@as(u32, 8), r.set_buffer_scale);
    try std.testing.expectEqual(@as(u32, 9), r.damage_buffer);
    try std.testing.expectEqual(@as(u32, 10), r.offset);
    try std.testing.expectEqual(@as(u32, 11), r.get_release);
}

test "wl_surface event opcodes + listener slots in XML order" {
    const e = core.wl_surface_event;
    try std.testing.expectEqual(@as(u32, 0), e.enter);
    try std.testing.expectEqual(@as(u32, 1), e.leave);
    try std.testing.expectEqual(@as(u32, 2), e.preferred_buffer_scale);
    try std.testing.expectEqual(@as(u32, 3), e.preferred_buffer_transform);

    // Listener struct layout: the field order on the extern struct IS the
    // dispatch slot order libwayland reads. Assert the four event fields
    // appear in the canonical order — this is what makes
    // `wl_proxy_add_listener` route a given event to the right callback.
    const fields = @typeInfo(core.wl_surface_listener).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("enter", fields[0].name);
    try std.testing.expectEqualStrings("leave", fields[1].name);
    try std.testing.expectEqualStrings("preferred_buffer_scale", fields[2].name);
    try std.testing.expectEqualStrings("preferred_buffer_transform", fields[3].name);
}

test "wl_surface interface metadata is consistent" {
    try std.testing.expectEqualStrings("wl_surface", std.mem.sliceTo(core.wl_surface_interface.name, 0));
    try std.testing.expectEqual(@as(u32, 12), core.wl_surface_interface.method_count);
    try std.testing.expectEqual(@as(u32, 4), core.wl_surface_interface.event_count);
}

test "xdg_surface request opcodes match XML order" {
    const r = xdg_shell.xdg_surface_request;
    try std.testing.expectEqual(@as(u32, 0), r.destroy);
    try std.testing.expectEqual(@as(u32, 1), r.get_toplevel);
    try std.testing.expectEqual(@as(u32, 2), r.get_popup);
    try std.testing.expectEqual(@as(u32, 3), r.set_window_geometry);
    try std.testing.expectEqual(@as(u32, 4), r.ack_configure);
}

test "xdg_surface event opcodes + listener slots in XML order" {
    try std.testing.expectEqual(@as(u32, 0), xdg_shell.xdg_surface_event.configure);
    const fields = @typeInfo(xdg_shell.xdg_surface_listener).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("configure", fields[0].name);
}

test "xdg_surface interface metadata is consistent" {
    try std.testing.expectEqualStrings("xdg_surface", std.mem.sliceTo(xdg_shell.xdg_surface_interface.name, 0));
    try std.testing.expectEqual(@as(u32, 5), xdg_shell.xdg_surface_interface.method_count);
    try std.testing.expectEqual(@as(u32, 1), xdg_shell.xdg_surface_interface.event_count);
}

test "xdg_toplevel request opcodes match XML order" {
    const r = xdg_shell.xdg_toplevel_request;
    try std.testing.expectEqual(@as(u32, 0), r.destroy);
    try std.testing.expectEqual(@as(u32, 1), r.set_parent);
    try std.testing.expectEqual(@as(u32, 2), r.set_title);
    try std.testing.expectEqual(@as(u32, 3), r.set_app_id);
    try std.testing.expectEqual(@as(u32, 4), r.show_window_menu);
    try std.testing.expectEqual(@as(u32, 5), r.move);
    try std.testing.expectEqual(@as(u32, 6), r.resize);
    try std.testing.expectEqual(@as(u32, 7), r.set_max_size);
    try std.testing.expectEqual(@as(u32, 8), r.set_min_size);
    try std.testing.expectEqual(@as(u32, 9), r.set_maximized);
    try std.testing.expectEqual(@as(u32, 10), r.unset_maximized);
    try std.testing.expectEqual(@as(u32, 11), r.set_fullscreen);
    try std.testing.expectEqual(@as(u32, 12), r.unset_fullscreen);
    try std.testing.expectEqual(@as(u32, 13), r.set_minimized);
}

test "xdg_toplevel event opcodes + listener slots in XML order" {
    const e = xdg_shell.xdg_toplevel_event;
    try std.testing.expectEqual(@as(u32, 0), e.configure);
    try std.testing.expectEqual(@as(u32, 1), e.close);
    try std.testing.expectEqual(@as(u32, 2), e.configure_bounds);
    try std.testing.expectEqual(@as(u32, 3), e.wm_capabilities);

    const fields = @typeInfo(xdg_shell.xdg_toplevel_listener).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("configure", fields[0].name);
    try std.testing.expectEqualStrings("close", fields[1].name);
    try std.testing.expectEqualStrings("configure_bounds", fields[2].name);
    try std.testing.expectEqualStrings("wm_capabilities", fields[3].name);
}

test "xdg_toplevel interface metadata is consistent" {
    try std.testing.expectEqualStrings("xdg_toplevel", std.mem.sliceTo(xdg_shell.xdg_toplevel_interface.name, 0));
    try std.testing.expectEqual(@as(u32, 14), xdg_shell.xdg_toplevel_interface.method_count);
    try std.testing.expectEqual(@as(u32, 4), xdg_shell.xdg_toplevel_interface.event_count);
}

test "zxdg_toplevel_decoration_v1 request opcodes match XML order" {
    const r = xdg_decoration.zxdg_toplevel_decoration_v1_request;
    try std.testing.expectEqual(@as(u32, 0), r.destroy);
    try std.testing.expectEqual(@as(u32, 1), r.set_mode);
    try std.testing.expectEqual(@as(u32, 2), r.unset_mode);
}

test "zxdg_toplevel_decoration_v1 listener slot order" {
    try std.testing.expectEqual(
        @as(u32, 0),
        xdg_decoration.zxdg_toplevel_decoration_v1_event.configure,
    );
    const fields = @typeInfo(xdg_decoration.zxdg_toplevel_decoration_v1_listener).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("configure", fields[0].name);
}

test "zxdg_toplevel_decoration_v1 interface metadata is consistent" {
    const iface = xdg_decoration.zxdg_toplevel_decoration_v1_interface;
    try std.testing.expectEqualStrings("zxdg_toplevel_decoration_v1", std.mem.sliceTo(iface.name, 0));
    try std.testing.expectEqual(@as(u32, 3), iface.method_count);
    try std.testing.expectEqual(@as(u32, 1), iface.event_count);
}

test "every listener field is callconv(.c) and starts with data+proxy" {
    // libwayland calls every listener slot with (data, proxy, args...).
    // A drift in `wayland_gen` that demoted a field to `callconv(.zig)`
    // or omitted the first two args would crash libwayland at dispatch
    // time; lock it down here.
    const interfaces = .{
        core.wl_surface_listener,
        xdg_shell.xdg_surface_listener,
        xdg_shell.xdg_toplevel_listener,
        xdg_decoration.zxdg_toplevel_decoration_v1_listener,
    };
    inline for (interfaces) |Listener| {
        inline for (@typeInfo(Listener).@"struct".fields) |f| {
            const FieldFn = switch (@typeInfo(f.type)) {
                .pointer => |p| p.child,
                else => @compileError("listener field is not a pointer: " ++ f.name),
            };
            const fn_info = @typeInfo(FieldFn).@"fn";
            // `CallingConvention` is a tagged union since 0.16; comparing
            // `.c` directly would mismatch because `.c` resolves to the
            // target-specific underlying convention (e.g.
            // `aarch64_aapcs_darwin`). Use `.eql(.c)` so we accept any
            // variant that aliases the C ABI on the current target.
            try std.testing.expect(fn_info.calling_convention.eql(.c));
            try std.testing.expect(fn_info.params.len >= 2);
            // First param: `data: ?*anyopaque`.
            try std.testing.expectEqual(@as(type, ?*anyopaque), fn_info.params[0].type.?);
        }
    }
}
