//! Emit Wayland protocol bindings as Zig source. Throwaway in S3.
//!
//! Output per `<protocol>`:
//!   * Per-interface metadata (enums, opcode structs, `wl_X_listener`,
//!     `WlMessage` arrays, `WlInterface` constant)
//!   * Opaque proxy type with idiomatic methods inside, mirroring vk.zig:
//!         pub const wl_compositor = opaque {
//!             pub fn createSurface(self: *wl_compositor) Error!*wl_surface { ... }
//!             pub fn addListener(self: *wl_compositor, …) Error!void { ... }
//!         };
//!   * `core.zig` additionally emits the libwayland-client common types
//!     (`WlInterface`, `WlMessage`, `WlArray`, `WlArgument`, `Fixed`),
//!     the `WL_MARSHAL_FLAG_DESTROY` flag, the `Error` set, the
//!     `LibWaylandDispatch` struct + `lib_wayland` global, and the
//!     `loadLibWayland()` dlopen helper.
//!
//! Other protocol files import `core` and reference these via `core.X`.

const std = @import("std");
const parser = @import("parser.zig");

pub const ProtocolDecl = struct {
    /// Output module name (`core`, `xdg_shell`, `xdg_decoration`).
    module_name: []const u8,
    /// Output Zig path (`src/core/platform/window/wayland_protocols/<module>.zig`).
    output_path: []const u8,
    /// Parsed protocol model.
    protocol: parser.Protocol,
};

pub const InterfaceCatalog = struct {
    entries: []const Entry,

    pub const Entry = struct {
        interface: []const u8,
        module: []const u8,
    };

    pub fn lookup(self: InterfaceCatalog, name: []const u8) ?Entry {
        for (self.entries) |e| if (std.mem.eql(u8, e.interface, name)) return e;
        return null;
    }
};

pub fn buildCatalog(gpa: std.mem.Allocator, decls: []const ProtocolDecl) !InterfaceCatalog {
    var out: std.ArrayList(InterfaceCatalog.Entry) = .empty;
    for (decls) |d| {
        for (d.protocol.interfaces) |iface| {
            try out.append(gpa, .{ .interface = iface.name, .module = d.module_name });
        }
    }
    return .{ .entries = try out.toOwnedSlice(gpa) };
}

pub fn emitProtocol(
    gpa: std.mem.Allocator,
    decl: ProtocolDecl,
    catalog: InterfaceCatalog,
    is_core: bool,
    out: *std.ArrayList(u8),
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const A = arena.allocator();

    var ctx: Ctx = .{
        .gpa = gpa,
        .A = A,
        .decl = decl,
        .catalog = catalog,
        .is_core = is_core,
        .out = out,
    };

    try ctx.writeHeader();
    try ctx.writeImports();
    if (is_core) try ctx.writeCommonTypes();
    for (decl.protocol.interfaces) |iface| {
        try ctx.writeInterface(iface);
    }
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    A: std.mem.Allocator,
    decl: ProtocolDecl,
    catalog: InterfaceCatalog,
    is_core: bool,
    out: *std.ArrayList(u8),

    fn append(self: *Ctx, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }
    fn print(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.A, fmt, args);
        try self.append(s);
    }

    /// Cross-module-prefix helper: returns `"WlX"` inside core, `"core.WlX"` elsewhere.
    fn coreRef(self: *Ctx, name: []const u8) ![]const u8 {
        return if (self.is_core) try self.A.dupe(u8, name) else try std.fmt.allocPrint(self.A, "core.{s}", .{name});
    }

    fn writeHeader(self: *Ctx) !void {
        try self.print(
            "//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-wayland`.\n" ++
                "//!\n" ++
                "//! Wayland protocol `{s}` bindings emitted from upstream XML.\n" ++
                "//! Throwaway: S3 unifier replaces this generator.\n\n" ++
                "const std = @import(\"std\");\n",
            .{self.decl.protocol.name},
        );
    }

    fn writeImports(self: *Ctx) !void {
        // For non-core protocol files, always import `core` so we can reach
        // `WlInterface`, `WlMessage`, `WlArgument`, `lib_wayland`, etc., and
        // any cross-protocol wl_* type referenced by our request/event args.
        var needed: std.StringHashMapUnmanaged(void) = .empty;
        for (self.decl.protocol.interfaces) |iface| {
            for (iface.requests) |m| try collectInterfaceRefs(&needed, self.A, m, self.catalog, self.decl.module_name);
            for (iface.events) |m| try collectInterfaceRefs(&needed, self.A, m, self.catalog, self.decl.module_name);
        }

        if (!self.is_core) {
            try self.append("const core = @import(\"core.zig\");\n");
            try self.append("const WlInterface = core.WlInterface;\n");
            try self.append("const WlMessage = core.WlMessage;\n");
        }

        var it = needed.iterator();
        var emitted_any = !self.is_core;
        while (it.next()) |entry| {
            const mod = entry.key_ptr.*;
            if (std.mem.eql(u8, mod, self.decl.module_name)) continue;
            if (std.mem.eql(u8, mod, "core")) continue;
            try self.print("const {s} = @import(\"{s}.zig\");\n", .{ mod, mod });
            emitted_any = true;
        }
        if (emitted_any) try self.append("\n");
    }

    fn writeCommonTypes(self: *Ctx) !void {
        try self.append(
            \\// ---- Wayland C ABI (libwayland-client) common types ----
            \\
            \\pub const WlInterface = extern struct {
            \\    name: [*:0]const u8,
            \\    version: c_int,
            \\    method_count: c_int,
            \\    methods: ?[*]const WlMessage,
            \\    event_count: c_int,
            \\    events: ?[*]const WlMessage,
            \\};
            \\
            \\pub const WlMessage = extern struct {
            \\    name: [*:0]const u8,
            \\    signature: [*:0]const u8,
            \\    types: ?[*]const ?*const WlInterface,
            \\};
            \\
            \\pub const WlArray = extern struct {
            \\    size: usize,
            \\    alloc: usize,
            \\    data: ?*anyopaque,
            \\};
            \\
            \\/// Argument union passed to `wl_proxy_marshal_array_flags`. Field tags match
            \\/// the wire-signature characters: i u f s o n a h.
            \\pub const WlArgument = extern union {
            \\    i: i32,
            \\    u: u32,
            \\    f: i32, // wl_fixed_t (24.8 fixed-point)
            \\    s: ?[*:0]const u8,
            \\    o: ?*anyopaque,
            \\    n: u32,
            \\    a: ?*WlArray,
            \\    h: i32,
            \\};
            \\
            \\/// 24.8 fixed-point scalar used by Wayland for sub-pixel coordinates.
            \\pub const Fixed = enum(i32) {
            \\    _,
            \\    pub fn fromDouble(d: f64) Fixed {
            \\        return @enumFromInt(@as(i32, @intFromFloat(d * 256.0)));
            \\    }
            \\    pub fn toDouble(self: Fixed) f64 {
            \\        return @as(f64, @floatFromInt(@intFromEnum(self))) / 256.0;
            \\    }
            \\    pub fn fromInt(i: i32) Fixed {
            \\        return @enumFromInt(i << 8);
            \\    }
            \\    pub fn toInt(self: Fixed) i32 {
            \\        return @intFromEnum(self) >> 8;
            \\    }
            \\};
            \\
            \\/// `flags` argument passed to `wl_proxy_marshal_array_flags`. Set on
            \\/// destructor requests to free the proxy after the call returns.
            \\pub const WL_MARSHAL_FLAG_DESTROY: u32 = 1;
            \\
            \\pub const Error = error{
            \\    LibraryNotFound,
            \\    SymbolNotFound,
            \\    ListenerAlreadySet,
            \\    ProxyMarshalFailed,
            \\    ConnectFailed,
            \\};
            \\
            \\// ---- libwayland-client dispatch ----
            \\//
            \\// dlopen the wayland client library and resolve the function pointers
            \\// the spike binary needs. Variadic marshal entry points are kept in the
            \\// dispatch table as `*const anyopaque` for completeness — the actual
            \\// generated wrappers below all call `wl_proxy_marshal_array_flags`,
            \\// the non-variadic equivalent.
            \\
            \\pub const LibWaylandDispatch = struct {
            \\    // Display lifecycle and event pumping.
            \\    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*wl_display = undefined,
            \\    wl_display_disconnect: *const fn (*wl_display) callconv(.c) void = undefined,
            \\    wl_display_dispatch: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\    wl_display_dispatch_pending: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\    wl_display_prepare_read: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\    wl_display_read_events: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\    wl_display_cancel_read: *const fn (*wl_display) callconv(.c) void = undefined,
            \\    wl_display_roundtrip: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\    wl_display_flush: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\    wl_display_get_fd: *const fn (*wl_display) callconv(.c) c_int = undefined,
            \\
            \\    // Variadic marshalling — opaque pointers (variadic ABI is not exposed by
            \\    // generated wrappers). Kept here for callers that need them.
            \\    wl_proxy_marshal_constructor: *const anyopaque = undefined,
            \\    wl_proxy_marshal_constructor_versioned: *const anyopaque = undefined,
            \\    wl_proxy_marshal_flags: *const anyopaque = undefined,
            \\
            \\    // Non-variadic marshalling — every generated method calls this.
            \\    wl_proxy_marshal_array_flags: *const fn (
            \\        proxy: *anyopaque,
            \\        opcode: u32,
            \\        interface: ?*const WlInterface,
            \\        version: u32,
            \\        flags: u32,
            \\        args: ?[*]WlArgument,
            \\    ) callconv(.c) ?*anyopaque = undefined,
            \\
            \\    // Listener registration + lifecycle.
            \\    wl_proxy_add_listener: *const fn (*anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) c_int = undefined,
            \\    wl_proxy_destroy: *const fn (*anyopaque) callconv(.c) void = undefined,
            \\    wl_proxy_get_version: *const fn (*anyopaque) callconv(.c) u32 = undefined,
            \\    wl_proxy_set_user_data: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void = undefined,
            \\    wl_proxy_get_user_data: *const fn (*anyopaque) callconv(.c) ?*anyopaque = undefined,
            \\};
            \\
            \\pub var lib_wayland: LibWaylandDispatch = .{};
            \\var lib_handle: ?*anyopaque = null;
            \\
            \\// `std.DynLib` is `@compileError("unsupported platform")` on Windows
            \\// in Zig 0.16's stdlib, so we hand-roll a tiny dlopen abstraction.
            \\// In practice `loadLibWayland` is only called on Linux (the Wayland
            \\// backend is wired only there) but the generated code must still
            \\// compile on Windows / macOS targets.
            \\const _dl = if (@import("builtin").os.tag == .windows) struct {
            \\    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
            \\    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
            \\} else struct {
            \\    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
            \\    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
            \\};
            \\
            \\fn _dlOpen(path_z: [*:0]const u8) ?*anyopaque {
            \\    return if (comptime @import("builtin").os.tag == .windows)
            \\        _dl.LoadLibraryA(path_z)
            \\    else
            \\        _dl.dlopen(path_z, 2); // RTLD_NOW
            \\}
            \\
            \\fn _dlLookup(handle: *anyopaque, name_z: [*:0]const u8) ?*anyopaque {
            \\    return if (comptime @import("builtin").os.tag == .windows)
            \\        _dl.GetProcAddress(handle, name_z)
            \\    else
            \\        _dl.dlsym(handle, name_z);
            \\}
            \\
            \\pub fn loadLibWayland() Error!void {
            \\    if (lib_handle != null) return; // idempotent
            \\    const candidates = &[_][:0]const u8{ "libwayland-client.so.0", "libwayland-client.so" };
            \\    for (candidates) |path| {
            \\        if (_dlOpen(path.ptr)) |h| {
            \\            lib_handle = h;
            \\            break;
            \\        }
            \\    }
            \\    if (lib_handle == null) return error.LibraryNotFound;
            \\
            \\    inline for (@typeInfo(LibWaylandDispatch).@"struct".fields) |f| {
            \\        const sym = _dlLookup(lib_handle.?, f.name.ptr) orelse return error.SymbolNotFound;
            \\        @field(lib_wayland, f.name) = @ptrCast(@alignCast(sym));
            \\    }
            \\}
            \\
            \\
        );
    }

    fn writeInterface(self: *Ctx, iface: parser.Interface) !void {
        try self.print("// ---- {s} (v{d}) ----\n\n", .{ iface.name, iface.version });

        // Module-level metadata first. The opaque type with inline methods
        // comes at the end of the block — Zig resolves forward references
        // for the listener struct's `*wl_X` fields against the opaque
        // declared later.

        // Enums.
        for (iface.enums) |en| {
            try self.print("pub const {s}_{s} = enum(u32) {{\n", .{ iface.name, en.name });
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.A);
            for (en.entries) |e| {
                const r = try seen.getOrPut(self.A, e.value);
                if (r.found_existing) continue;
                try self.print("    {s} = {d},\n", .{ try identifierize(self.A, e.name), e.value });
            }
            try self.append("    _,\n};\n\n");
        }

        // Request opcode constants.
        if (iface.requests.len > 0) {
            try self.print("pub const {s}_request = struct {{\n", .{iface.name});
            for (iface.requests) |r| {
                try self.print("    pub const {s}: u32 = {d};\n", .{ try identifierize(self.A, r.name), r.opcode });
            }
            try self.append("};\n\n");
        }

        // Event opcode constants.
        if (iface.events.len > 0) {
            try self.print("pub const {s}_event = struct {{\n", .{iface.name});
            for (iface.events) |e| {
                try self.print("    pub const {s}: u32 = {d};\n", .{ try identifierize(self.A, e.name), e.opcode });
            }
            try self.append("};\n\n");
        }

        // Listener struct (forward-references the opaque declared below).
        if (iface.events.len > 0) {
            try self.print("pub const {s}_listener = extern struct {{\n", .{iface.name});
            for (iface.events) |e| {
                try self.print("    {s}: *const fn (data: ?*anyopaque, proxy: *{s}", .{ try identifierize(self.A, e.name), iface.name });
                for (e.args) |a| {
                    const aname = try identifierize(self.A, a.name);
                    const aty = try self.eventArgType(a);
                    try self.print(", {s}: {s}", .{ aname, aty });
                }
                try self.append(") callconv(.c) void,\n");
            }
            try self.append("};\n\n");
        }

        // WlMessage arrays + WlInterface metadata.
        if (iface.requests.len > 0) {
            try self.print("const {s}_requests = [_]WlMessage{{\n", .{iface.name});
            for (iface.requests) |r| try self.writeMessageEntry(r);
            try self.append("};\n\n");
        }
        if (iface.events.len > 0) {
            try self.print("const {s}_events = [_]WlMessage{{\n", .{iface.name});
            for (iface.events) |e| try self.writeMessageEntry(e);
            try self.append("};\n\n");
        }
        try self.print("pub const {s}_interface = WlInterface{{\n", .{iface.name});
        try self.print("    .name = \"{s}\",\n", .{iface.name});
        try self.print("    .version = {d},\n", .{iface.version});
        try self.print("    .method_count = {d},\n", .{iface.requests.len});
        if (iface.requests.len > 0) {
            try self.print("    .methods = &{s}_requests,\n", .{iface.name});
        } else {
            try self.append("    .methods = null,\n");
        }
        try self.print("    .event_count = {d},\n", .{iface.events.len});
        if (iface.events.len > 0) {
            try self.print("    .events = &{s}_events,\n", .{iface.name});
        } else {
            try self.append("    .events = null,\n");
        }
        try self.append("};\n\n");

        // Opaque with inline methods — symmetric to vk.zig's handle types.
        try self.print("pub const {s} = opaque {{\n", .{iface.name});
        for (iface.requests) |r| {
            try self.writeRequestMethod(iface, r);
        }
        if (iface.events.len > 0) {
            try self.writeAddListener(iface);
        }
        try self.append("};\n\n");
    }

    /// Build the wire-format signature string for `WlMessage`.
    fn writeMessageEntry(self: *Ctx, m: parser.Message) !void {
        var sig: std.ArrayList(u8) = .empty;
        for (m.args) |a| {
            if (a.allow_null) try sig.append(self.A, '?');
            switch (a.type) {
                .int => try sig.append(self.A, 'i'),
                .uint => try sig.append(self.A, 'u'),
                .fixed => try sig.append(self.A, 'f'),
                .string => try sig.append(self.A, 's'),
                .object => try sig.append(self.A, 'o'),
                .new_id => {
                    if (a.interface == null) {
                        try sig.append(self.A, 's');
                        try sig.append(self.A, 'u');
                    }
                    try sig.append(self.A, 'n');
                },
                .array => try sig.append(self.A, 'a'),
                .fd => try sig.append(self.A, 'h'),
            }
        }
        const sig_str = try sig.toOwnedSlice(self.A);
        try self.print("    .{{ .name = \"{s}\", .signature = \"{s}\", .types = null }},\n", .{ m.name, sig_str });
    }

    /// Idiomatic Zig type for a parameter of a request method (caller-provided).
    fn requestArgType(self: *Ctx, a: parser.Arg) ![]const u8 {
        const fixed_ref = try self.coreRef("Fixed");
        const wl_array = try self.coreRef("WlArray");
        return switch (a.type) {
            .int => "i32",
            .uint => "u32",
            .fixed => fixed_ref,
            .fd => "std.posix.fd_t",
            .string => if (a.allow_null) "?[*:0]const u8" else "[*:0]const u8",
            .array => if (a.allow_null)
                try std.fmt.allocPrint(self.A, "?*{s}", .{wl_array})
            else
                try std.fmt.allocPrint(self.A, "*{s}", .{wl_array}),
            .object => if (a.interface) |iface_name| blk: {
                const prefix = try self.crossProtoPrefix(iface_name);
                if (a.allow_null) {
                    break :blk try std.fmt.allocPrint(self.A, "?*{s}{s}", .{ prefix, iface_name });
                } else {
                    break :blk try std.fmt.allocPrint(self.A, "*{s}{s}", .{ prefix, iface_name });
                }
            } else "?*anyopaque",
            // new_id does not appear as a normal request param — it is
            // hoisted into the return type by `writeRequestMethod`. The
            // wl_registry.bind pattern (no-interface new_id) injects
            // explicit `interface` / `version` params instead.
            .new_id => unreachable,
        };
    }

    /// Idiomatic Zig type for an event arg (used in listener struct fields).
    /// Object/new_id args without an explicit interface are nullable per
    /// review item — `wl_display.error.object_id` is the canonical case.
    fn eventArgType(self: *Ctx, a: parser.Arg) ![]const u8 {
        const fixed_ref = try self.coreRef("Fixed");
        const wl_array = try self.coreRef("WlArray");
        return switch (a.type) {
            .int => "i32",
            .uint => "u32",
            .fixed => fixed_ref,
            .fd => "std.posix.fd_t",
            .string => if (a.allow_null) "?[*:0]const u8" else "[*:0]const u8",
            .array => if (a.allow_null)
                try std.fmt.allocPrint(self.A, "?*{s}", .{wl_array})
            else
                try std.fmt.allocPrint(self.A, "*{s}", .{wl_array}),
            .object, .new_id => if (a.interface) |iface_name| blk: {
                const prefix = try self.crossProtoPrefix(iface_name);
                if (a.allow_null) {
                    break :blk try std.fmt.allocPrint(self.A, "?*{s}{s}", .{ prefix, iface_name });
                } else {
                    break :blk try std.fmt.allocPrint(self.A, "*{s}{s}", .{ prefix, iface_name });
                }
            } else "?*anyopaque",
        };
    }

    fn crossProtoPrefix(self: *Ctx, iface_name: []const u8) ![]const u8 {
        const e = self.catalog.lookup(iface_name) orelse return "";
        if (std.mem.eql(u8, e.module, self.decl.module_name)) return "";
        return try std.fmt.allocPrint(self.A, "{s}.", .{e.module});
    }

    fn writeRequestMethod(self: *Ctx, iface: parser.Interface, r: parser.Message) !void {
        const method_name = try toCamelCase(self.A, r.name);
        const error_ref = try self.coreRef("Error");
        const lib_ref = try self.coreRef("lib_wayland");
        const arg_ref = try self.coreRef("WlArgument");
        const flag_ref = try self.coreRef("WL_MARSHAL_FLAG_DESTROY");

        // Find the new_id arg (at most one in Wayland requests).
        var new_id_idx: ?usize = null;
        var new_id_typed_iface: ?[]const u8 = null;
        for (r.args, 0..) |a, i| {
            if (a.type != .new_id) continue;
            new_id_idx = i;
            new_id_typed_iface = a.interface;
            break;
        }

        // Determine return type.
        const return_type: []const u8 = blk: {
            if (new_id_idx == null) break :blk "void";
            if (new_id_typed_iface) |iface_name| {
                const prefix = try self.crossProtoPrefix(iface_name);
                break :blk try std.fmt.allocPrint(self.A, "{s}!*{s}{s}", .{ error_ref, prefix, iface_name });
            }
            // wl_registry.bind pattern — no explicit interface; user must pass one.
            break :blk try std.fmt.allocPrint(self.A, "{s}!*anyopaque", .{error_ref});
        };

        // Signature.
        try self.print("    pub fn {s}(self: *{s}", .{ method_name, iface.name });
        for (r.args) |a| {
            // new_id with interface is hoisted to return value — no param emitted.
            if (a.type == .new_id and a.interface != null) continue;
            try self.append(", ");
            // new_id without interface (wl_registry.bind) → inject typed
            // interface + version params instead.
            if (a.type == .new_id and a.interface == null) {
                try self.print("interface: *const {s}, version: u32", .{try self.coreRef("WlInterface")});
                continue;
            }
            const aname = try identifierize(self.A, a.name);
            const aty = try self.requestArgType(a);
            try self.print("{s}: {s}", .{ aname, aty });
        }
        try self.print(") {s} {{\n", .{return_type});

        // Body.
        var wire_count: usize = 0;
        for (r.args) |a| {
            wire_count += if (a.type == .new_id and a.interface == null) 3 else 1;
        }

        // Args array (when any).
        if (wire_count > 0) {
            try self.print("        var args: [{d}]{s} = undefined;\n", .{ wire_count, arg_ref });
        }

        var w: usize = 0;
        for (r.args) |a| {
            const aname = try identifierize(self.A, a.name);
            switch (a.type) {
                .int => try self.print("        args[{d}].i = {s};\n", .{ w, aname }),
                .uint => try self.print("        args[{d}].u = {s};\n", .{ w, aname }),
                .fixed => try self.print("        args[{d}].f = @intFromEnum({s});\n", .{ w, aname }),
                .fd => try self.print("        args[{d}].h = {s};\n", .{ w, aname }),
                .string => try self.print("        args[{d}].s = {s};\n", .{ w, aname }),
                .object => {
                    if (a.allow_null) {
                        try self.print("        args[{d}].o = if ({s}) |__p| @ptrCast(__p) else null;\n", .{ w, aname });
                    } else {
                        try self.print("        args[{d}].o = @ptrCast({s});\n", .{ w, aname });
                    }
                },
                .array => try self.print("        args[{d}].a = {s};\n", .{ w, aname }),
                .new_id => {
                    if (a.interface == null) {
                        try self.print("        args[{d}].s = interface.name;\n", .{w});
                        try self.print("        args[{d}].u = version;\n", .{w + 1});
                        try self.print("        args[{d}].n = 0;\n", .{w + 2});
                    } else {
                        try self.print("        args[{d}].n = 0;\n", .{w});
                    }
                },
            }
            w += if (a.type == .new_id and a.interface == null) 3 else 1;
        }

        // Marshal call.
        const flag_expr = if (r.destructor) flag_ref else "0";

        // For new_id with explicit interface, hand libwayland the
        // `<interface>_interface` constant. For wl_registry.bind, the user
        // passed `interface`. Otherwise null.
        const marshal_iface_expr: []const u8 = blk: {
            if (new_id_idx == null) break :blk "null";
            if (new_id_typed_iface) |iface_name| {
                const e = self.catalog.lookup(iface_name) orelse break :blk "null";
                if (std.mem.eql(u8, e.module, self.decl.module_name)) {
                    break :blk try std.fmt.allocPrint(self.A, "&{s}_interface", .{iface_name});
                }
                break :blk try std.fmt.allocPrint(self.A, "&{s}.{s}_interface", .{ e.module, iface_name });
            }
            // wl_registry.bind pattern.
            break :blk "interface";
        };

        // Version arg passed to wl_proxy_marshal_array_flags.
        const version_expr: []const u8 = blk: {
            if (new_id_idx != null and new_id_typed_iface == null) break :blk "version";
            break :blk try std.fmt.allocPrint(self.A, "{s}.wl_proxy_get_version(@ptrCast(self))", .{lib_ref});
        };

        const args_ptr_expr: []const u8 = if (wire_count == 0) "null" else "&args";

        if (new_id_idx == null) {
            try self.print(
                "        _ = {s}.wl_proxy_marshal_array_flags(@ptrCast(self), {s}_request.{s}, {s}, {s}, {s}, {s});\n",
                .{ lib_ref, iface.name, try identifierize(self.A, r.name), marshal_iface_expr, version_expr, flag_expr, args_ptr_expr },
            );
        } else {
            try self.print(
                "        const _proxy = {s}.wl_proxy_marshal_array_flags(@ptrCast(self), {s}_request.{s}, {s}, {s}, {s}, {s}) orelse return error.ProxyMarshalFailed;\n",
                .{ lib_ref, iface.name, try identifierize(self.A, r.name), marshal_iface_expr, version_expr, flag_expr, args_ptr_expr },
            );
            try self.append("        return @ptrCast(_proxy);\n");
        }
        try self.append("    }\n\n");
    }

    fn writeAddListener(self: *Ctx, iface: parser.Interface) !void {
        const error_ref = try self.coreRef("Error");
        const lib_ref = try self.coreRef("lib_wayland");
        try self.print(
            "    pub fn addListener(self: *{s}, listener: *const {s}_listener, data: ?*anyopaque) {s}!void {{\n",
            .{ iface.name, iface.name, error_ref },
        );
        try self.print(
            "        if ({s}.wl_proxy_add_listener(@ptrCast(self), @ptrCast(listener), data) != 0) {{\n",
            .{lib_ref},
        );
        try self.append("            return error.ListenerAlreadySet;\n");
        try self.append("        }\n");
        try self.append("    }\n\n");
    }
};

fn collectInterfaceRefs(
    set: *std.StringHashMapUnmanaged(void),
    A: std.mem.Allocator,
    m: parser.Message,
    catalog: InterfaceCatalog,
    self_module: []const u8,
) !void {
    for (m.args) |a| {
        if (a.type != .object and a.type != .new_id) continue;
        const iface_name = a.interface orelse continue;
        const e = catalog.lookup(iface_name) orelse continue;
        if (std.mem.eql(u8, e.module, self_module)) continue;
        _ = try set.getOrPut(A, e.module);
    }
}

fn identifierize(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return try A.dupe(u8, s);
    const out = if (std.ascii.isDigit(s[0]))
        try std.fmt.allocPrint(A, "_{s}", .{s})
    else
        try A.dupe(u8, s);
    return try escapeKeyword(A, out);
}

/// `create_surface` → `createSurface`. Escapes Zig keywords if the result
/// (rare) collides.
fn toCamelCase(A: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var capitalize = false;
    for (snake) |c| {
        if (c == '_') {
            capitalize = true;
            continue;
        }
        if (capitalize) {
            try buf.append(A, std.ascii.toUpper(c));
            capitalize = false;
        } else {
            try buf.append(A, c);
        }
    }
    const out = try buf.toOwnedSlice(A);
    return try escapeKeyword(A, out);
}

fn escapeKeyword(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    const kws = [_][]const u8{ "type", "error", "fn", "var", "const", "pub", "test", "struct", "enum", "union", "opaque", "extern", "async", "comptime", "inline", "callconv", "for", "while", "if", "else", "switch", "and", "or", "true", "false", "null", "undefined", "unreachable", "noinline", "noreturn", "anyframe", "anyopaque", "anytype", "void", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "bool", "isize", "usize", "return" };
    for (kws) |kw| if (std.mem.eql(u8, kw, s)) return try std.fmt.allocPrint(A, "@\"{s}\"", .{s});
    return s;
}
