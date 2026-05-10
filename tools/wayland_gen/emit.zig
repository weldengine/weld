//! Emit Wayland protocol bindings as Zig source. Throwaway in S3.
//!
//! Output per `<protocol>`:
//!   * Opaque proxy types (`pub const wl_surface = opaque {};`)
//!   * Enum types (`pub const wl_display_error = enum(u32) { ... };`)
//!   * Opcode constants (`pub const wl_surface_request = struct { pub const destroy: u32 = 0; ... };`)
//!   * Listener structs (`pub const wl_surface_listener = extern struct { enter: *const fn(...) callconv(.c) void, ... };`)
//!   * `WlMessage` arrays + `WlInterface` per interface (consumed by
//!     `libwayland-client`'s `wl_proxy_marshal_array_flags` and
//!     `wl_proxy_add_listener`).
//!
//! `WlInterface` / `WlMessage` are declared once in `core.zig`; the other
//! protocol files import them.

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

/// Catalog mapping each interface name to the `(module_name, var_name)`
/// pair in the generated code. Used to emit cross-protocol type refs.
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
    if (is_core) try ctx.writeCommonTypes();
    try ctx.writeImports();
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

    fn writeHeader(self: *Ctx) !void {
        try self.print(
            "//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-wayland`.\n" ++
                "//!\n" ++
                "//! Wayland protocol `{s}` bindings emitted from upstream XML.\n" ++
                "//! Throwaway: S3 unifier replaces this generator.\n\n",
            .{self.decl.protocol.name},
        );
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
            \\
        );
    }

    fn writeImports(self: *Ctx) !void {
        // For non-core protocol files, always import the `core` module so
        // we can reach `WlInterface`, `WlMessage`, and any cross-protocol
        // wl_* type referenced by our `<request>` / `<event>` args. Other
        // module imports (e.g. xdg_decoration → xdg_shell) are added on
        // demand.
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
            if (std.mem.eql(u8, mod, "core")) continue; // covered above
            try self.print("const {s} = @import(\"{s}.zig\");\n", .{ mod, mod });
            emitted_any = true;
        }
        if (emitted_any) try self.append("\n");
    }

    fn writeInterface(self: *Ctx, iface: parser.Interface) !void {
        try self.print("// ---- {s} (v{d}) ----\n\n", .{ iface.name, iface.version });

        // Opaque proxy type.
        try self.print("pub const {s} = opaque {{}};\n\n", .{iface.name});

        // Enums.
        for (iface.enums) |en| {
            const repr = if (en.bitfield) "u32" else "u32";
            try self.print("pub const {s}_{s} = enum({s}) {{\n", .{ iface.name, en.name, repr });
            // Some enums duplicate values via aliases — dedupe.
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.A);
            for (en.entries) |e| {
                const r = try seen.getOrPut(self.A, e.value);
                if (r.found_existing) continue;
                try self.print("    {s} = {d},\n", .{ try identifierize(self.A, e.name), e.value });
            }
            try self.append("    _,\n};\n\n");
        }

        // Request opcodes.
        if (iface.requests.len > 0) {
            try self.print("pub const {s}_request = struct {{\n", .{iface.name});
            for (iface.requests) |r| {
                try self.print("    pub const {s}: u32 = {d};\n", .{ try identifierize(self.A, r.name), r.opcode });
            }
            try self.append("};\n\n");
        }

        // Event opcodes.
        if (iface.events.len > 0) {
            try self.print("pub const {s}_event = struct {{\n", .{iface.name});
            for (iface.events) |e| {
                try self.print("    pub const {s}: u32 = {d};\n", .{ try identifierize(self.A, e.name), e.opcode });
            }
            try self.append("};\n\n");
        }

        // Listener struct (events).
        if (iface.events.len > 0) {
            try self.print("pub const {s}_listener = extern struct {{\n", .{iface.name});
            for (iface.events) |e| {
                try self.print("    {s}: *const fn (data: ?*anyopaque, proxy: *{s}", .{ try identifierize(self.A, e.name), iface.name });
                for (e.args) |a| {
                    const aname = try identifierize(self.A, a.name);
                    const aty = try self.argZigType(a);
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
    }

    fn writeMessageEntry(self: *Ctx, m: parser.Message) !void {
        // Build the wire-format signature string. Wayland convention:
        //   * `?` prefix marks nullable args (object/string/array)
        //   * `i u f s o n a h` per arg type
        //   * `new_id` without interface expands to `sun` (registry.bind)
        // The leading `<since>` version prefix is omitted; S2 does not
        // enforce since-version negotiation, the spike runs on current
        // compositors that support all referenced versions.
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

        // We do not populate the `types` array — `wl_proxy_marshal_array_flags`
        // takes the new_id interface as an explicit parameter, and event
        // dispatch on the spike's small surface does not need per-arg
        // interface tagging. S3 may revisit and emit full types arrays.
        try self.print("    .{{ .name = \"{s}\", .signature = \"{s}\", .types = null }},\n", .{ m.name, sig_str });
    }

    fn argZigType(self: *Ctx, a: parser.Arg) ![]const u8 {
        const wl_array = if (self.is_core) "WlArray" else "core.WlArray";
        return switch (a.type) {
            .int, .fd, .fixed => "i32",
            .uint => "u32",
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
            } else if (a.allow_null) "?*anyopaque" else "*anyopaque",
        };
    }

    fn crossProtoPrefix(self: *Ctx, iface_name: []const u8) ![]const u8 {
        const e = self.catalog.lookup(iface_name) orelse return "";
        if (std.mem.eql(u8, e.module, self.decl.module_name)) return "";
        return try std.fmt.allocPrint(self.A, "{s}.", .{e.module});
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

/// Convert a Wayland identifier (lowercase snake_case already) into a Zig
/// identifier. Escapes Zig keywords and prefixes leading-digit identifiers
/// with `_`.
fn identifierize(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return try A.dupe(u8, s);
    const out = if (std.ascii.isDigit(s[0]))
        try std.fmt.allocPrint(A, "_{s}", .{s})
    else
        try A.dupe(u8, s);
    return try escapeKeyword(A, out);
}

fn escapeKeyword(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    const kws = [_][]const u8{ "type", "error", "fn", "var", "const", "pub", "test", "struct", "enum", "union", "opaque", "extern", "async", "comptime", "inline", "callconv", "for", "while", "if", "else", "switch", "and", "or", "true", "false", "null", "undefined", "unreachable", "noinline", "noreturn", "anyframe", "anyopaque", "anytype", "void", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "bool", "isize", "usize" };
    for (kws) |kw| if (std.mem.eql(u8, kw, s)) return try std.fmt.allocPrint(A, "@\"{s}\"", .{s});
    return s;
}
