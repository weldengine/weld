//! Emit idiomatic Zig (per `engine-c-bindings.md` §4.2) from a filtered
//! vk.xml model.
//!
//! Output structure:
//!   1. Header + std imports
//!   2. Built-in basetype aliases (`Bool32 = u32`, …)
//!   3. API Constants
//!   4. Handle types (opaques)
//!   5. Enums
//!   6. Bitmask flag types (packed struct or u32 alias)
//!   7. Function pointer typedefs (callbacks; opaque for non-trivial ones)
//!   8. Structs / Unions
//!   9. Error set + checkResult helper
//!  10. PFN_* function pointer types (synthesized from parsed commands)
//!  11. BaseDispatch / InstanceDispatch / DeviceDispatch structs
//!  12. dlopen helpers (loadLoader / loadInstance / loadDevice)
//!  13. Top-level functions (loader-level commands)
//!  14. Methods on handle types
//!
//! Throwaway code for S2. Replaced in S3 by the unified emitter.

const std = @import("std");
const parser = @import("parser.zig");

const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    A: std.mem.Allocator,
    model: parser.FilteredModel,
    out: *std.ArrayList(u8),
    /// Set of all type names known to the emitter (after stripping Vk prefix).
    /// Used to decide how to render type references.
    type_names: std.StringHashMapUnmanaged(TypeKind) = .empty,

    const TypeKind = enum {
        handle_dispatchable,
        handle_non_dispatchable,
        @"enum",
        bitmask,
        @"struct",
        @"union",
        funcpointer,
        basetype,
    };

    fn deinit(self: *Ctx) void {
        self.arena.deinit();
    }

    fn append(self: *Ctx, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn print(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.A, fmt, args);
        try self.append(s);
    }
};

/// Fourth stage of the vk_gen pipeline: render `model` (already
/// whitelist-trimmed) into idiomatic Zig source appended to `out`.
/// The output is the complete `src/core/platform/vk.zig` body — the
/// caller writes it to disk and pipes it through `zig fmt`.
pub fn emit(gpa: std.mem.Allocator, model: parser.FilteredModel, out: *std.ArrayList(u8)) !void {
    var ctx: Ctx = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .A = undefined,
        .model = model,
        .out = out,
    };
    ctx.A = ctx.arena.allocator();
    defer ctx.deinit();

    try collectTypeNames(&ctx);
    try writeHeader(&ctx);
    try writeBasetypes(&ctx);
    try writePlatformTypes(&ctx);
    try writeApiConstants(&ctx);
    try writeEnums(&ctx);
    try writeBitmasks(&ctx);
    try writeFuncpointers(&ctx);
    try writeStructs(&ctx);
    try writeUnions(&ctx);
    try writeAliases(&ctx);
    try writeErrorSet(&ctx);
    try writePfnTypes(&ctx);
    try writeDispatchTables(&ctx);
    try writeLoader(&ctx);
    try writeLoaderFunctions(&ctx);
    // Handles emitted last so their inline methods can reference any earlier
    // declaration (struct types, dispatch tables, error sets).
    try writeHandles(&ctx);
}

// ============================================================== name maps =

fn collectTypeNames(ctx: *Ctx) !void {
    for (ctx.model.handles) |h| {
        try ctx.type_names.put(ctx.A, h.name, if (h.dispatchable) .handle_dispatchable else .handle_non_dispatchable);
    }
    for (ctx.model.enum_groups) |g| {
        try ctx.type_names.put(ctx.A, g.name, .@"enum");
    }
    for (ctx.model.bitmasks) |bm| {
        try ctx.type_names.put(ctx.A, bm.name, .bitmask);
    }
    for (ctx.model.structs) |s| {
        try ctx.type_names.put(ctx.A, s.name, .@"struct");
    }
    for (ctx.model.unions) |u| {
        try ctx.type_names.put(ctx.A, u.name, .@"union");
    }
    for (ctx.model.funcpointers) |f| {
        try ctx.type_names.put(ctx.A, f.name, .funcpointer);
    }
    for (ctx.model.basetypes) |b| {
        try ctx.type_names.put(ctx.A, b.name, .basetype);
    }
}

// ================================================================ header =

fn writeHeader(ctx: *Ctx) !void {
    try ctx.append(
        \\//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-vk`.
        \\//!
        \\//! Vulkan binding emitted from `bindings/upstream/vulkan/vk.xml`
        \\//! (Vulkan-Headers vulkan-sdk-1.4.341.0).
        \\//! Whitelist: Vulkan 1.3 core + VK_KHR_surface + VK_KHR_swapchain
        \\//! + VK_KHR_wayland_surface + VK_KHR_win32_surface + VK_EXT_debug_utils.
        \\//!
        \\//! Throwaway in the strict sense — refactored in S3 by the unified
        \\//! bindgen system (cf. `engine-c-bindings.md` §10.1). The public
        \\//! Zig surface (handle types, struct layouts, method names) is a
        \\//! conformance target of `engine-c-bindings.md` §4.2 idioms so the
        \\//! S3 regeneration produces zero diff at call sites.
        \\
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\
    );
}

// ============================================================== basetypes =

fn writeBasetypes(ctx: *Ctx) !void {
    try ctx.append("// ---- C basetype aliases ----\n\n");
    for (ctx.model.basetypes) |b| {
        const zig_name = stripVkPrefix(b.name);
        // Map known basetype declarations to Zig types.
        const mapped = mapBasetypeDecl(b.c_decl) orelse {
            try ctx.print("// TODO basetype {s}: {s}\n", .{ b.name, b.c_decl });
            continue;
        };
        try ctx.print("pub const {s} = {s};\n", .{ zig_name, mapped });
    }
    try ctx.append("\n");
}

fn mapBasetypeDecl(c_decl: []const u8) ?[]const u8 {
    // Only map a handful of known basetypes — others are platform handles
    // (ANativeWindow, IOSurfaceRef, …) that S2 doesn't need.
    if (std.mem.indexOf(u8, c_decl, "uint32_t") != null and std.mem.indexOf(u8, c_decl, "VkBool32") != null) return "u32";
    if (std.mem.indexOf(u8, c_decl, "uint64_t") != null and std.mem.indexOf(u8, c_decl, "VkDeviceSize") != null) return "u64";
    if (std.mem.indexOf(u8, c_decl, "uint64_t") != null and std.mem.indexOf(u8, c_decl, "VkDeviceAddress") != null) return "u64";
    if (std.mem.indexOf(u8, c_decl, "uint32_t") != null and std.mem.indexOf(u8, c_decl, "VkSampleMask") != null) return "u32";
    if (std.mem.indexOf(u8, c_decl, "uint32_t") != null and std.mem.indexOf(u8, c_decl, "VkFlags") != null and std.mem.indexOf(u8, c_decl, "VkFlags64") == null) return "u32";
    if (std.mem.indexOf(u8, c_decl, "uint64_t") != null and std.mem.indexOf(u8, c_decl, "VkFlags64") != null) return "u64";
    return null;
}

// =========================================================== platform types =
//
// vk.xml lists categoryless platform-specific types (`HINSTANCE`, `wl_display`,
// …) as forward declarations. The S2 whitelist only pulls Wayland and Win32
// types; we emit a small hardcoded mapping per name. Other targets fall back
// to a plain `opaque {}` so the binding still compiles when transitively
// referenced — the call sites are guarded by `builtin.os.tag` anyway.

const PlatformMapping = struct {
    name: []const u8,
    /// Zig type expression. `null` means "emit `opaque {}`".
    zig: ?[]const u8,
};

const platform_mappings = [_]PlatformMapping{
    // Win32 — these are pointer types in `windows.h`, so we emit them as
    // pointers to opaque storage.
    .{ .name = "HINSTANCE", .zig = "*opaque {}" },
    .{ .name = "HWND", .zig = "*opaque {}" },
    .{ .name = "HMONITOR", .zig = "*opaque {}" },
    .{ .name = "HANDLE", .zig = "*opaque {}" },
    .{ .name = "SECURITY_ATTRIBUTES", .zig = "opaque {}" },
    .{ .name = "DWORD", .zig = "u32" },
    .{ .name = "LPCWSTR", .zig = "[*:0]const u16" },
    // Wayland — used as `wl_display*` / `wl_surface*` in vk.xml; emit
    // opaque types so callers spell `*wl_display`.
    .{ .name = "wl_display", .zig = "opaque {}" },
    .{ .name = "wl_surface", .zig = "opaque {}" },
};

fn lookupPlatformZig(name: []const u8) ?[]const u8 {
    for (platform_mappings) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.zig;
    }
    return null;
}

fn writePlatformTypes(ctx: *Ctx) !void {
    if (ctx.model.platform_types.len == 0) return;
    try ctx.append("// ---- Platform forward declarations ----\n\n");
    for (ctx.model.platform_types) |pt| {
        const zig = lookupPlatformZig(pt.name) orelse "opaque {}";
        try ctx.print("pub const {s} = {s};\n", .{ pt.name, zig });
    }
    try ctx.append("\n");
}

// =========================================================== api_constants =

fn writeApiConstants(ctx: *Ctx) !void {
    try ctx.append("// ---- API Constants ----\n\n");
    for (ctx.model.api_constants) |c| {
        const zig_name = stripVkPrefix(c.name);
        const decl = try renderConstantDecl(ctx, c);
        try ctx.print("pub const {s}{s};\n", .{ zig_name, decl });
    }
    try ctx.append("\n");
}

/// Render the type-annotation + initializer for a `pub const NAME …;`
/// declaration. Returns the suffix (`: u32 = 0xFFFF_FFFE`, ` = 4`, …).
fn renderConstantDecl(ctx: *Ctx, c: parser.ApiConstant) ![]const u8 {
    const v = std.mem.trim(u8, c.value, " ()\t");

    // Bitwise-not idioms `(~NU)`, `(~NULL)`, written by Vulkan to denote
    // "all-1s minus N" sentinels. Render them as typed `@as(u32, value)`
    // expressions per `engine-c-bindings.md` review item #5 — keeps them
    // out of `comptime_int` arithmetic where `~1` would mean -2.
    if (parseTildeForm(v)) |tilde| {
        const ty: []const u8 = if (tilde.bits == 64) "u64" else "u32";
        if (tilde.bits == 64) {
            const inv: u64 = ~tilde.n;
            return try std.fmt.allocPrint(ctx.A, ": {s} = 0x{X:0>16}", .{ ty, inv });
        } else {
            const inv: u32 = ~@as(u32, @intCast(tilde.n));
            return try std.fmt.allocPrint(ctx.A, ": {s} = 0x{X:0>8}", .{ ty, inv });
        }
    }

    // Aliases (value carries the canonical name, not a numeric literal).
    if (v.len > 0 and (std.ascii.isAlphabetic(v[0]) or v[0] == '_') and !std.mem.eql(u8, v, "true") and !std.mem.eql(u8, v, "false")) {
        const target = stripVkPrefix(v);
        return try std.fmt.allocPrint(ctx.A, " = {s}", .{target});
    }

    // Numeric / float literals — strip C suffixes.
    var end = v.len;
    while (end > 0 and (v[end - 1] == 'U' or v[end - 1] == 'L' or v[end - 1] == 'F' or v[end - 1] == 'f')) {
        end -= 1;
    }
    const numeric = v[0..end];

    if (c.c_type) |ty| {
        const zig_ty = mapBaseName(ty);
        return try std.fmt.allocPrint(ctx.A, ": {s} = {s}", .{ zig_ty, numeric });
    }
    return try std.fmt.allocPrint(ctx.A, " = {s}", .{numeric});
}

const TildeForm = struct { n: u64, bits: u8 };

fn parseTildeForm(v: []const u8) ?TildeForm {
    // Match `~<digits>U`, `~<digits>ULL`, optionally with `-1` / `-2` etc.
    if (v.len < 3 or v[0] != '~') return null;
    var i: usize = 1;
    var n: u64 = 0;
    while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
        n = n * 10 + (v[i] - '0');
    }
    if (i == 1) return null;

    var bits: u8 = 32;
    if (i + 3 <= v.len and std.mem.eql(u8, v[i .. i + 3], "ULL")) {
        bits = 64;
        i += 3;
    } else if (i < v.len and (v[i] == 'U' or v[i] == 'u')) {
        i += 1;
    }
    // Optional `-K` decrement.
    if (i < v.len and v[i] == '-') {
        i += 1;
        var dec: u64 = 0;
        while (i < v.len and std.ascii.isDigit(v[i])) : (i += 1) {
            dec = dec * 10 + (v[i] - '0');
        }
        // We want the bit-flipped value of (n + dec), so just bump n.
        n += dec;
    }
    if (i != v.len) return null;
    return .{ .n = n, .bits = bits };
}

// ================================================================ handles =

fn writeHandles(ctx: *Ctx) !void {
    try ctx.append("// ---- Handle types (with methods) ----\n\n");
    for (ctx.model.handles) |h| {
        const zig_name = stripVkPrefix(h.name);
        if (h.dispatchable) {
            // Dispatchable handle = opaque pointer target. Methods that take
            // `*Self` as first parameter are placed inline so the user can
            // call `instance.createDevice(…)` per `engine-c-bindings.md` §4.2.
            try ctx.print("pub const {s} = opaque {{\n", .{zig_name});
            for (ctx.model.commands) |c| {
                if (c.alias_of != null) continue;
                if (c.params.len == 0) continue;
                if (!std.mem.eql(u8, c.params[0].c_type.base, h.name)) continue;
                try emitWrapper(ctx, c, classifyCommand(ctx, c), h);
            }
            try ctx.append("};\n\n");
        } else {
            // Non-dispatchable handles are uint64 in the Vulkan ABI.
            // We expose them as typed enums to prevent accidental cross-handle
            // misuse. Methods on non-dispatchable handles are rare in Vulkan
            // so we don't emit any inline.
            try ctx.print("pub const {s} = enum(u64) {{ null = 0, _ }};\n", .{zig_name});
        }
    }
    try ctx.append("\n");
}

// ================================================================== enums =

fn writeEnums(ctx: *Ctx) !void {
    try ctx.append("// ---- Enums (and bitmask FlagBits enums) ----\n\n");
    for (ctx.model.enum_groups) |g| {
        if (g.kind == .api_constants) continue;
        // Bitmask enums (`VkXxxFlagBits`) are emitted both here as enums and
        // in `writeBitmasks` as `packed struct(u32)` flag types. The two
        // surfaces coexist: struct fields typed `VkXxxFlagBits` reference
        // the enum, fields typed `VkXxxFlags` reference the packed struct.

        const zig_name = stripVkPrefix(g.name);
        const repr = if (g.bit_width == 64) "u64" else "i32";
        try ctx.print("pub const {s} = enum({s}) {{\n", .{ zig_name, repr });

        // De-duplicate by numeric value (the registry sometimes adds aliases
        // that share the same integer with the canonical name).
        var seen_values: std.StringHashMapUnmanaged(void) = .empty;
        defer seen_values.deinit(ctx.A);
        for (g.values) |v| {
            if (v.alias != null) continue; // Aliases handled below as `pub const`.
            // bitmask enums use `bitpos` rather than `value`. Compute the
            // integer (1 << bp) so the FlagBits enum carries the same
            // numeric values as the corresponding packed-struct flag type.
            // Arena-allocate the key so the dedupe map keeps it valid
            // across iterations.
            const key: []const u8 = blk: {
                if (v.value) |s| break :blk s;
                if (v.bitpos) |bp| {
                    const n: u64 = @as(u64, 1) << @intCast(bp);
                    break :blk try std.fmt.allocPrint(ctx.A, "{d}", .{n});
                }
                continue;
            };
            const r = try seen_values.getOrPut(ctx.A, key);
            if (r.found_existing) continue;
            const variant_name = try stripEnumPrefix(ctx, g.name, v.name);
            try ctx.print("    {s} = {s},\n", .{ variant_name, key });
        }
        try ctx.append("    _,\n};\n");

        // Aliases as `pub const` after the enum body — they reference the
        // enum's canonical variant.
        for (g.values) |v| {
            const alias = v.alias orelse continue;
            const variant_name = try stripEnumPrefix(ctx, g.name, v.name);
            const target_name = try stripEnumPrefix(ctx, g.name, alias);
            try ctx.print("pub const {s}_{s}: {s} = .{s};\n", .{ zig_name, try snakeCase(ctx.A, variant_name), zig_name, target_name });
        }
        try ctx.append("\n");
    }
}

// ============================================================== bitmasks =

fn writeBitmasks(ctx: *Ctx) !void {
    try ctx.append("// ---- Bitmask flag types ----\n\n");
    for (ctx.model.bitmasks) |bm| {
        const zig_name = stripVkPrefix(bm.name);
        const repr = if (bm.width == 64) "u64" else "u32";

        // If we have a corresponding enum group, render as a packed struct.
        const enum_group = if (bm.requires_enum) |req| findEnumGroup(ctx.model.enum_groups, req) else null;
        if (enum_group) |g| {
            try ctx.print("pub const {s} = packed struct({s}) {{\n", .{ zig_name, repr });
            // Reserve all bit positions [0, width). Named bits map to
            // `field_name: bool`. Unnamed bits become `_reservedN: bool`.
            var bits_used = std.StaticBitSet(64).initEmpty();
            // Collect named bits.
            const NamedBit = struct { pos: u8, name: []const u8 };
            var bits: std.ArrayList(NamedBit) = .empty;
            defer bits.deinit(ctx.A);
            for (g.values) |v| {
                if (v.alias != null) continue;
                if (v.bitpos) |bp| {
                    if (bp >= 64) continue;
                    if (bits_used.isSet(bp)) continue;
                    bits_used.set(bp);
                    const stripped = try stripEnumPrefix(ctx, g.name, v.name);
                    const flag_name = try stripBitSuffix(ctx.A, stripped);
                    try bits.append(ctx.A, .{ .pos = bp, .name = flag_name });
                }
            }
            // Sort by position.
            std.mem.sort(NamedBit, bits.items, {}, struct {
                fn lt(_: void, a: NamedBit, b: NamedBit) bool {
                    return a.pos < b.pos;
                }
            }.lt);
            // Emit fields in order, padding with reserved bits.
            var pos: u8 = 0;
            for (bits.items) |b| {
                while (pos < b.pos) : (pos += 1) {
                    try ctx.print("    _reserved_{d}: bool = false,\n", .{pos});
                }
                try ctx.print("    {s}: bool = false,\n", .{b.name});
                pos += 1;
            }
            const total: u8 = if (bm.width == 64) 64 else 32;
            while (pos < total) : (pos += 1) {
                try ctx.print("    _reserved_{d}: bool = false,\n", .{pos});
            }
            try ctx.append("\n    pub const empty: @This() = .{};\n");
            try ctx.append("};\n\n");
            continue;
        }
        // No FlagBits enum yet — emit as a packed struct of all-reserved
        // bits, uniform with the named-bit case so flag struct-fields
        // always support `.empty` regardless of whether the registry has
        // assigned individual bits.
        try ctx.print("pub const {s} = packed struct({s}) {{\n", .{ zig_name, repr });
        const total: u8 = if (bm.width == 64) 64 else 32;
        var i: u8 = 0;
        while (i < total) : (i += 1) {
            try ctx.print("    _reserved_{d}: bool = false,\n", .{i});
        }
        try ctx.append("\n    pub const empty: @This() = .{};\n");
        try ctx.append("};\n\n");
    }
    try ctx.append("\n");
}

fn findEnumGroup(groups: []const parser.EnumGroup, name: []const u8) ?*const parser.EnumGroup {
    for (groups) |*g| if (std.mem.eql(u8, g.name, name)) return g;
    return null;
}

// ========================================================== funcpointers =

fn writeFuncpointers(ctx: *Ctx) !void {
    try ctx.append("// ---- Function pointer typedefs (callbacks) ----\n");
    try ctx.append("// Emitted as opaque pointers in S2; the C decl is preserved as a comment\n");
    try ctx.append("// for hand-casting at call sites. Replaced by typed signatures in S3.\n\n");
    for (ctx.model.funcpointers) |f| {
        const zig_name = f.name; // PFN_* names kept verbatim
        // The C decl can span multiple lines; comment each line.
        var it = std.mem.splitScalar(u8, trimWhitespace(f.c_decl), '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            try ctx.print("// {s}\n", .{trimmed});
        }
        try ctx.print("pub const {s} = ?*const anyopaque;\n\n", .{zig_name});
    }
}

fn trimWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

// ================================================================ structs =

fn writeStructs(ctx: *Ctx) !void {
    try ctx.append("// ---- Structs ----\n\n");
    for (ctx.model.structs) |s| {
        try emitStructLike(ctx, s, "extern struct");
    }
    try ctx.append("\n");
}

fn writeUnions(ctx: *Ctx) !void {
    try ctx.append("// ---- Unions ----\n\n");
    for (ctx.model.unions) |u| {
        try emitStructLike(ctx, u, "extern union");
    }
    try ctx.append("\n");
}

fn emitStructLike(ctx: *Ctx, s: parser.Struct, kw: []const u8) !void {
    const zig_name = stripVkPrefix(s.name);
    try ctx.print("pub const {s} = {s} {{\n", .{ zig_name, kw });
    for (s.members) |m| {
        const field_name = try snakeCase(ctx.A, m.name);
        const type_expr = try mapMemberType(ctx, m);
        const default = try memberDefault(ctx, m, s.s_type_value);
        if (default) |d| {
            try ctx.print("    {s}: {s} = {s},\n", .{ field_name, type_expr, d });
        } else {
            try ctx.print("    {s}: {s},\n", .{ field_name, type_expr });
        }
    }
    try ctx.append("};\n\n");
}

fn memberDefault(ctx: *Ctx, m: parser.Member, s_type_value: ?[]const u8) !?[]const u8 {
    if (s_type_value != null and std.mem.eql(u8, m.name, "sType")) {
        return try std.fmt.allocPrint(ctx.A, ".{s}", .{try stripEnumPrefix(ctx, "VkStructureType", s_type_value.?)});
    }
    if (std.mem.eql(u8, m.name, "pNext")) return "null";
    return null;
}

fn mapMemberType(ctx: *Ctx, m: parser.Member) ![]const u8 {
    return try mapCType(ctx, m.c_type, m.optional, m.len, .struct_field);
}

// ================================================================ aliases =

fn writeAliases(ctx: *Ctx) !void {
    try ctx.append("// ---- Aliases ----\n\n");
    for (ctx.model.aliases) |a| {
        const lhs = stripVkPrefix(a.name);
        const rhs = stripVkPrefix(a.target);
        if (std.mem.eql(u8, lhs, rhs)) continue;
        try ctx.print("pub const {s} = {s};\n", .{ lhs, rhs });
    }
    try ctx.append("\n");
}

// ============================================================== error set =

fn writeErrorSet(ctx: *Ctx) !void {
    try ctx.append(
        \\// ---- Error set + checkResult helper ----
        \\
        \\pub const Error = error{
        \\    LoaderNotFound,
        \\    SymbolNotFound,
        \\    Unknown,
        \\    OutOfHostMemory,
        \\    OutOfDeviceMemory,
        \\    InitializationFailed,
        \\    DeviceLost,
        \\    MemoryMapFailed,
        \\    LayerNotPresent,
        \\    ExtensionNotPresent,
        \\    FeatureNotPresent,
        \\    IncompatibleDriver,
        \\    TooManyObjects,
        \\    FormatNotSupported,
        \\    FragmentedPool,
        \\    SurfaceLost,
        \\    NativeWindowInUse,
        \\    OutOfDate,
        \\    IncompatibleDisplay,
        \\    ValidationFailed,
        \\    InvalidShader,
        \\    OutOfPoolMemory,
        \\    InvalidExternalHandle,
        \\    Fragmentation,
        \\    InvalidOpaqueCaptureAddress,
        \\    PipelineCompileRequired,
        \\    UnknownVkResult,
        \\};
        \\
        \\pub fn checkResult(r: Result) Error!void {
        \\    return switch (r) {
        \\        .success, .not_ready, .timeout, .event_set, .event_reset, .incomplete, .suboptimal_khr => {},
        \\        .error_out_of_host_memory => error.OutOfHostMemory,
        \\        .error_out_of_device_memory => error.OutOfDeviceMemory,
        \\        .error_initialization_failed => error.InitializationFailed,
        \\        .error_device_lost => error.DeviceLost,
        \\        .error_memory_map_failed => error.MemoryMapFailed,
        \\        .error_layer_not_present => error.LayerNotPresent,
        \\        .error_extension_not_present => error.ExtensionNotPresent,
        \\        .error_feature_not_present => error.FeatureNotPresent,
        \\        .error_incompatible_driver => error.IncompatibleDriver,
        \\        .error_too_many_objects => error.TooManyObjects,
        \\        .error_format_not_supported => error.FormatNotSupported,
        \\        .error_fragmented_pool => error.FragmentedPool,
        \\        .error_surface_lost_khr => error.SurfaceLost,
        \\        .error_native_window_in_use_khr => error.NativeWindowInUse,
        \\        .error_out_of_date_khr => error.OutOfDate,
        \\        .error_incompatible_display_khr => error.IncompatibleDisplay,
        \\        .error_validation_failed => error.ValidationFailed,
        \\        .error_invalid_shader_nv => error.InvalidShader,
        \\        else => if (@intFromEnum(r) < 0) error.Unknown else {},
        \\    };
        \\}
        \\
        \\
    );
}

// =========================================================== PFN_* types =

fn writePfnTypes(ctx: *Ctx) !void {
    try ctx.append("// ---- PFN_* command function pointer types ----\n\n");
    // For each non-alias command, synthesize a function pointer type.
    for (ctx.model.commands) |c| {
        if (c.alias_of != null) continue;
        try ctx.print("pub const PFN_{s} = *const fn (", .{c.name});
        for (c.params, 0..) |p, i| {
            if (i > 0) try ctx.append(", ");
            const t = try mapCType(ctx, p.c_type, p.optional, p.len, .pfn_param);
            try ctx.print("{s}", .{t});
        }
        const ret = try mapCType(ctx, c.return_type, false, null, .pfn_return);
        try ctx.print(") callconv(.c) {s};\n", .{ret});
    }
    // Aliases reference the canonical PFN.
    for (ctx.model.commands) |c| {
        const alias = c.alias_of orelse continue;
        try ctx.print("pub const PFN_{s} = PFN_{s};\n", .{ c.name, alias });
    }
    try ctx.append("\n");
}

// ====================================================== Dispatch tables =

const Dispatch = enum { base, instance, device };

fn classifyCommand(ctx: *Ctx, c: parser.Command) Dispatch {
    // `vkGetInstanceProcAddr` is conceptually loader-level even though its
    // first parameter is `VkInstance` — it accepts a null instance to
    // resolve loader-level symbols, and it must be the first thing dlsym'd
    // before any other Vulkan call. Special-case it into BaseDispatch.
    if (std.mem.eql(u8, c.name, "vkGetInstanceProcAddr")) return .base;
    // Same logic for `vkGetDeviceProcAddr` — must live in InstanceDispatch
    // (loaded before the DeviceDispatch table is filled), not DeviceDispatch.
    if (std.mem.eql(u8, c.name, "vkGetDeviceProcAddr")) return .instance;
    if (c.params.len == 0) return .base;
    const first = c.params[0].c_type.base;
    if (std.mem.eql(u8, first, "VkInstance") or std.mem.eql(u8, first, "VkPhysicalDevice")) return .instance;
    // Device-like first params.
    const dev_set = [_][]const u8{
        "VkDevice",              "VkCommandBuffer",  "VkQueue",
        "VkDescriptorSet",       "VkBuffer",         "VkImage",
        "VkSwapchainKHR",        "VkSurfaceKHR",     "VkSemaphore",
        "VkFence",               "VkPipelineLayout", "VkRenderPass",
        "VkPipeline",            "VkShaderModule",   "VkDescriptorPool",
        "VkDescriptorSetLayout", "VkCommandPool",    "VkSampler",
        "VkBufferView",          "VkImageView",      "VkFramebuffer",
        "VkDeviceMemory",        "VkPipelineCache",  "VkQueryPool",
        "VkEvent",
    };
    for (dev_set) |d| if (std.mem.eql(u8, first, d)) return .device;
    if (ctx.model.findHandle(first)) |h| {
        // Other dispatchable handles — we don't have a per-instance/per-device
        // categorization for them in S2, default to device.
        if (h.dispatchable) return .device;
    }
    return .base;
}

fn writeDispatchTables(ctx: *Ctx) !void {
    try ctx.append("// ---- Dispatch tables ----\n\n");
    for ([_]Dispatch{ .base, .instance, .device }) |kind| {
        const struct_name = switch (kind) {
            .base => "BaseDispatch",
            .instance => "InstanceDispatch",
            .device => "DeviceDispatch",
        };
        try ctx.print("pub const {s} = struct {{\n", .{struct_name});
        for (ctx.model.commands) |c| {
            if (c.alias_of != null) continue;
            if (classifyCommand(ctx, c) != kind) continue;
            try ctx.print("    {s}: PFN_{s} = undefined,\n", .{ c.name, c.name });
        }
        try ctx.append("};\n\n");
    }
    try ctx.append("pub var base: BaseDispatch = .{};\n");
    try ctx.append("pub var instance_dispatch: InstanceDispatch = .{};\n");
    try ctx.append("pub var device_dispatch: DeviceDispatch = .{};\n\n");
}

// ================================================================ loader =

fn writeLoader(ctx: *Ctx) !void {
    try ctx.append(
        \\// ---- Loader ----
        \\//
        \\// Phase 1: dlopen libvulkan, resolve `vkGetInstanceProcAddr`,
        \\//          fill the `BaseDispatch` table with loader-level entries.
        \\// Phase 2: once `vkCreateInstance` returns, call `loadInstance(handle)`
        \\//          to fill the `InstanceDispatch` table via vkGetInstanceProcAddr.
        \\// Phase 3: once `vkCreateDevice` returns, call `loadDevice(handle)` to
        \\//          fill the `DeviceDispatch` table via vkGetDeviceProcAddr.
        \\
        \\var lib_handle: ?*anyopaque = null;
        \\
        \\// `std.DynLib` is `@compileError("unsupported platform")` on Windows in
        \\// Zig 0.16's stdlib, so we hand-roll a tiny dlopen/LoadLibrary
        \\// abstraction here. Linux + macOS use POSIX `dlopen`/`dlsym`; Windows
        \\// uses `LoadLibraryA`/`GetProcAddress`. Both keep the loader as a
        \\// `?*anyopaque` so the surrounding code stays OS-agnostic.
        \\const _dl = if (builtin.os.tag == .windows) struct {
        \\    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
        \\    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
        \\} else struct {
        \\    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
        \\    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
        \\};
        \\
        \\fn _dlOpen(path_z: [*:0]const u8) ?*anyopaque {
        \\    return if (comptime builtin.os.tag == .windows)
        \\        _dl.LoadLibraryA(path_z)
        \\    else
        \\        _dl.dlopen(path_z, 2); // RTLD_NOW
        \\}
        \\
        \\fn _dlLookup(handle: *anyopaque, name_z: [*:0]const u8) ?*anyopaque {
        \\    return if (comptime builtin.os.tag == .windows)
        \\        _dl.GetProcAddress(handle, name_z)
        \\    else
        \\        _dl.dlsym(handle, name_z);
        \\}
        \\
        \\pub fn loadLoader() Error!void {
        \\    const candidates: []const [:0]const u8 = switch (builtin.os.tag) {
        \\        .linux => &.{ "libvulkan.so.1", "libvulkan.so" },
        \\        .windows => &.{"vulkan-1.dll"},
        \\        .macos, .ios => &.{ "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib" },
        \\        else => return error.LoaderNotFound,
        \\    };
        \\    for (candidates) |path| {
        \\        if (_dlOpen(path.ptr)) |h| {
        \\            lib_handle = h;
        \\            break;
        \\        }
        \\    }
        \\    if (lib_handle == null) return error.LoaderNotFound;
        \\
        \\    // Resolve every BaseDispatch symbol directly — vkGetInstanceProcAddr
        \\    // would work for instance-level lookups but the C ABI requires an
        \\    // instance handle (vk.xml does not mark it optional), so we sidestep
        \\    // by calling the OS loader for everything here.
        \\    inline for (@typeInfo(BaseDispatch).@"struct".fields) |f| {
        \\        const sym = _dlLookup(lib_handle.?, f.name.ptr) orelse return error.SymbolNotFound;
        \\        @field(base, f.name) = @ptrCast(@alignCast(sym));
        \\    }
        \\}
        \\
        \\// InstanceDispatch / DeviceDispatch mix universal entry points with
        \\// platform- and extension-conditional ones (e.g. `vkCreateWin32SurfaceKHR`
        \\// is NULL on Linux, `vkCreateDebugUtilsMessengerEXT` is NULL whenever
        \\// `VK_EXT_debug_utils` is not enabled in the InstanceCreateInfo). A
        \\// missing symbol is *not* an error — callers are responsible for only
        \\// invoking entry points whose extension / platform precondition holds.
        \\// Slots that the loader could not resolve stay at their default
        \\// (`= undefined`); calling them is a programmer bug, same as calling
        \\// `vkDestroyInstance` after `vkDestroyInstance`.
        \\pub fn loadInstance(instance: *Instance) Error!void {
        \\    inline for (@typeInfo(InstanceDispatch).@"struct".fields) |f| {
        \\        if (base.vkGetInstanceProcAddr(instance, f.name.ptr)) |sym| {
        \\            @field(instance_dispatch, f.name) = @ptrCast(@alignCast(sym));
        \\        }
        \\    }
        \\}
        \\
        \\pub fn loadDevice(device: *Device) Error!void {
        \\    inline for (@typeInfo(DeviceDispatch).@"struct".fields) |f| {
        \\        if (instance_dispatch.vkGetDeviceProcAddr(device, f.name.ptr)) |sym| {
        \\            @field(device_dispatch, f.name) = @ptrCast(@alignCast(sym));
        \\        }
        \\    }
        \\}
        \\
        \\
    );
}

// ============================================== Loader-level functions =

fn writeLoaderFunctions(ctx: *Ctx) !void {
    try ctx.append("// ---- Loader-level functions (no `self`) ----\n\n");
    for (ctx.model.commands) |c| {
        if (c.alias_of != null) continue;
        if (classifyCommand(ctx, c) != .base) continue;
        if (std.mem.eql(u8, c.name, "vkGetInstanceProcAddr")) continue; // accessed via base.*
        try emitWrapper(ctx, c, .base, null);
    }
}

/// Per-command rendering plan. Captures the §4.2 idiomatic transformations:
/// hoisted out-params (review item #2), two-pass count/array hoisting
/// (review item #3), and slice-input collapse (review item #4).
const WrapperPlan = struct {
    /// Param indices to drop from the wrapper signature (their value is
    /// computed inside the wrapper body).
    omitted: []const usize,
    /// Pairs (slice_idx, count_idx) — the count param is omitted, the slice
    /// param keeps its position with type `[]T` (or `[]const T`).
    slice_inputs: []const SliceInput,
    /// Indices of slice-typed params whose `len` is a composite expression
    /// (`pAllocateInfo->commandBufferCount`, …). Rendered as Zig slices in
    /// the signature; the body passes `slice.ptr` and the matching length
    /// is the caller's responsibility (it lives in a struct field).
    composite_slices: []const usize,
    /// Out-param hoist (singular). `null` if no hoist.
    out_param: ?usize,
    /// Two-pass count/array hoist.
    two_pass: ?TwoPass,
    /// Wrapper signature kind.
    kind: enum {
        plain,
        check_result_void,
        plain_hoist,
        check_result_hoist,
        two_pass_hoist,
    },
    /// Resulting Zig return type expression.
    return_type: []const u8,
    /// Whether the wrapper takes an extra `gpa: std.mem.Allocator` param
    /// (always paired with `two_pass_hoist`).
    needs_allocator: bool,
};

const SliceInput = struct {
    slice_idx: usize,
    count_idx: usize,
};

const TwoPass = struct {
    count_idx: usize,
    array_idx: usize,
};

fn buildPlan(ctx: *Ctx, c: parser.Command, has_self: bool) !WrapperPlan {
    var omitted: std.ArrayList(usize) = .empty;
    var slices: std.ArrayList(SliceInput) = .empty;
    var composite_slices: std.ArrayList(usize) = .empty;

    const returns_vk_result = std.mem.eql(u8, c.return_type.base, "VkResult");

    // -- Slice inputs (review item #4) ---------------------------------
    // For each parameter `p` with a `len` attribute, render as a Zig slice.
    //   - If `len` matches a sibling u32 param, drop that count (slice_inputs).
    //   - If `len` references a struct field (e.g. `pAllocateInfo->X`), keep
    //     the param as a slice but rely on the caller to size it (composite_slices).
    //   - `len="null-terminated"` is a cstring and handled by mapCType.
    for (c.params, 0..) |p, i| {
        if (has_self and i == 0) continue;
        const len = p.len orelse continue;
        if (p.c_type.pointer_depth == 0) continue;
        if (std.mem.eql(u8, len, "null-terminated")) continue;
        if (std.mem.indexOfAny(u8, len, "->,()") != null) {
            try composite_slices.append(ctx.A, i);
            continue;
        }
        var matched = false;
        for (c.params, 0..) |sibling, j| {
            if (j == i) continue;
            if (!std.mem.eql(u8, sibling.name, len)) continue;
            if (!std.mem.eql(u8, sibling.c_type.base, "uint32_t") and !std.mem.eql(u8, sibling.c_type.base, "size_t")) continue;
            if (sibling.c_type.pointer_depth != 0) continue;
            try slices.append(ctx.A, .{ .slice_idx = i, .count_idx = j });
            var already = false;
            for (omitted.items) |o| if (o == j) {
                already = true;
                break;
            };
            if (!already) try omitted.append(ctx.A, j);
            matched = true;
            break;
        }
        if (!matched) {
            // `len` references something we couldn't resolve (e.g. literal
            // `commandBufferCount` from the same param list but typed
            // unusually). Keep it as a slice without dropping anything.
            try composite_slices.append(ctx.A, i);
        }
    }

    // -- Two-pass count/array (review item #3) -------------------------
    // VkResult or void command whose two trailing params are
    // `(uint32_t* pCount, T* pArray)` with `pArray` having `len="pCount"`.
    var two_pass: ?TwoPass = null;
    if (c.params.len >= 2) {
        const count_idx = c.params.len - 2;
        const array_idx = c.params.len - 1;
        const cnt = c.params[count_idx];
        const arr = c.params[array_idx];
        const looks_like_count = std.mem.eql(u8, cnt.c_type.base, "uint32_t") and cnt.c_type.pointer_depth == 1 and !cnt.c_type.is_const;
        const arr_len = arr.len orelse "";
        const len_matches_count = std.mem.eql(u8, arr_len, cnt.name);
        const arr_is_array_out = arr.c_type.pointer_depth == 1 and !arr.c_type.is_const;
        if (looks_like_count and len_matches_count and arr_is_array_out) {
            two_pass = .{ .count_idx = count_idx, .array_idx = array_idx };
            // The two trailing params become the (gpa, return-slice).
            try omitted.append(ctx.A, count_idx);
            try omitted.append(ctx.A, array_idx);
        }
    }

    // -- Singular out-param (review item #2) ---------------------------
    // Only when no two-pass hoist already claimed the trailing param.
    var out_param: ?usize = null;
    if (two_pass == null and c.params.len > 0) {
        const last_idx = c.params.len - 1;
        const last = c.params[last_idx];
        const not_self = !(has_self and last_idx == 0);
        const eligible = not_self and last.c_type.pointer_depth >= 1 and !last.c_type.is_const and !last.optional and last.len == null;
        if (eligible and !indexInList(omitted.items, last_idx)) {
            out_param = last_idx;
            try omitted.append(ctx.A, last_idx);
        }
    }

    // -- Decide return type + body kind --------------------------------
    var return_type: []const u8 = undefined;
    var kind: @TypeOf(@as(WrapperPlan, undefined).kind) = undefined;
    var needs_allocator = false;

    if (two_pass) |tp| {
        const elem_ty = try hoistedElementType(ctx, c.params[tp.array_idx]);
        return_type = try std.fmt.allocPrint(ctx.A, "Error![]{s}", .{elem_ty});
        kind = .two_pass_hoist;
        needs_allocator = true;
    } else if (out_param) |op| {
        const ret_inner = try hoistedReturnInner(ctx, c.params[op]);
        if (returns_vk_result) {
            return_type = try std.fmt.allocPrint(ctx.A, "Error!{s}", .{ret_inner});
            kind = .check_result_hoist;
        } else {
            return_type = ret_inner;
            kind = .plain_hoist;
        }
    } else if (returns_vk_result) {
        return_type = "Error!void";
        kind = .check_result_void;
    } else {
        const ret_zig = try mapCType(ctx, c.return_type, false, null, .api_return);
        return_type = ret_zig;
        kind = .plain;
    }

    return .{
        .omitted = try omitted.toOwnedSlice(ctx.A),
        .slice_inputs = try slices.toOwnedSlice(ctx.A),
        .composite_slices = try composite_slices.toOwnedSlice(ctx.A),
        .out_param = out_param,
        .two_pass = two_pass,
        .kind = kind,
        .return_type = return_type,
        .needs_allocator = needs_allocator,
    };
}

fn indexInList(list: []const usize, x: usize) bool {
    for (list) |v| if (v == x) return true;
    return false;
}

/// Strip the leading `pp_` / `p_` Hungarian prefix from a wrapper parameter
/// name (review item #1). Struct field names keep their prefix because they
/// document the underlying ABI shape.
fn stripParamPrefix(s: []const u8) []const u8 {
    var t = s;
    while (true) {
        if (std.mem.startsWith(u8, t, "p_") and t.len > 2 and !std.ascii.isDigit(t[2])) {
            t = t[2..];
            continue;
        }
        break;
    }
    return t;
}

/// For a `T**` out-param (last param of a `vkCreate*` command), the hoisted
/// return type is `*T` (pointer to opaque) when T is dispatchable, or `T`
/// (value) when T is a struct or non-dispatchable handle.
fn hoistedReturnInner(ctx: *Ctx, p: parser.Member) ![]const u8 {
    // `void**` out-param (vkMapMemory): the inner value is the data pointer
    // itself (`void*` in C, `?*anyopaque` in Zig).
    if (std.mem.eql(u8, p.c_type.base, "void") and p.c_type.pointer_depth >= 1) {
        return "?*anyopaque";
    }
    const base = mapBaseName(p.c_type.base);
    const handle_kind = ctx.type_names.get(p.c_type.base) orelse Ctx.TypeKind.basetype;
    if (handle_kind == .handle_dispatchable) {
        return try std.fmt.allocPrint(ctx.A, "*{s}", .{base});
    }
    return base;
}

/// Slice element type for `Error![]T`. Same logic as `hoistedReturnInner`
/// but never wraps in a pointer — slice element is the value type.
fn hoistedElementType(ctx: *Ctx, p: parser.Member) ![]const u8 {
    const base = mapBaseName(p.c_type.base);
    const handle_kind = ctx.type_names.get(p.c_type.base) orelse Ctx.TypeKind.basetype;
    if (handle_kind == .handle_dispatchable) {
        return try std.fmt.allocPrint(ctx.A, "*{s}", .{base});
    }
    return base;
}

fn emitWrapper(ctx: *Ctx, c: parser.Command, dispatch: Dispatch, _self: ?parser.Handle) !void {
    const method_name = try methodName(ctx.A, c.name, _self);
    const dispatch_var = switch (dispatch) {
        .base => "base",
        .instance => "instance_dispatch",
        .device => "device_dispatch",
    };
    const indent: []const u8 = if (_self != null) "    " else "";
    const has_self = _self != null;

    const plan = try buildPlan(ctx, c, has_self);

    // --- Signature ----------------------------------------------------
    try ctx.print("{s}pub fn {s}(", .{ indent, method_name });
    var first_emitted = true;
    for (c.params, 0..) |p, i| {
        if (indexInList(plan.omitted, i)) continue;
        if (!first_emitted) try ctx.append(", ");
        first_emitted = false;
        if (has_self and i == 0) {
            try ctx.print("self: *{s}", .{stripVkPrefix(_self.?.name)});
            continue;
        }
        const pname_raw = try snakeCase(ctx.A, p.name);
        const pname = stripParamPrefix(pname_raw);
        // Slice inputs (paired count or composite-len) render as `[]T`.
        if (findSliceInput(plan.slice_inputs, i) != null or indexInList(plan.composite_slices, i)) {
            const elem = mapBaseName(p.c_type.base);
            const handle_kind = ctx.type_names.get(p.c_type.base) orelse Ctx.TypeKind.basetype;
            const elem_zig = if (handle_kind == .handle_dispatchable)
                try std.fmt.allocPrint(ctx.A, "*{s}", .{elem})
            else
                try ctx.A.dupe(u8, elem);
            const ty = if (p.c_type.is_const)
                try std.fmt.allocPrint(ctx.A, "[]const {s}", .{elem_zig})
            else
                try std.fmt.allocPrint(ctx.A, "[]{s}", .{elem_zig});
            try ctx.print("{s}: {s}", .{ pname, ty });
            continue;
        }
        const ptype = try mapCType(ctx, p.c_type, p.optional, p.len, .api_param);
        try ctx.print("{s}: {s}", .{ pname, ptype });
    }
    if (plan.needs_allocator) {
        if (!first_emitted) try ctx.append(", ");
        try ctx.append("gpa: std.mem.Allocator");
        first_emitted = false;
    }
    try ctx.print(") {s} {{\n", .{plan.return_type});

    // --- Body ----------------------------------------------------------
    switch (plan.kind) {
        .plain => try emitBodyPlain(ctx, c, dispatch_var, has_self, plan, indent),
        .check_result_void => try emitBodyCheckResultVoid(ctx, c, dispatch_var, has_self, plan, indent),
        .plain_hoist => try emitBodyPlainHoist(ctx, c, dispatch_var, has_self, plan, indent),
        .check_result_hoist => try emitBodyCheckResultHoist(ctx, c, dispatch_var, has_self, plan, indent),
        .two_pass_hoist => try emitBodyTwoPass(ctx, c, dispatch_var, has_self, plan, indent),
    }
    try ctx.print("{s}}}\n\n", .{indent});
}

fn findSliceInput(slices: []const SliceInput, idx: usize) ?SliceInput {
    for (slices) |si| if (si.slice_idx == idx) return si;
    return null;
}

fn writeCallArgs(
    ctx: *Ctx,
    c: parser.Command,
    has_self: bool,
    plan: WrapperPlan,
    /// When non-null, override the value emitted at this index.
    override_idx: ?usize,
    override_value: ?[]const u8,
) !void {
    for (c.params, 0..) |p, i| {
        if (i > 0) try ctx.append(", ");
        if (override_idx) |oi| if (oi == i) {
            try ctx.append(override_value.?);
            continue;
        };
        if (has_self and i == 0) {
            try ctx.append("self");
            continue;
        }
        // Slice param (paired or composite): pass `.ptr` cast to whatever
        // the PFN expects (`?*T` in vk.xml's C ABI; the Zig type system
        // refuses the implicit `[*]T → ?*T` conversion even though the
        // ABI representation is identical).
        if (findSliceInput(plan.slice_inputs, i) != null or indexInList(plan.composite_slices, i)) {
            const pname = stripParamPrefix(try snakeCase(ctx.A, p.name));
            try ctx.print("@ptrCast({s}.ptr)", .{pname});
            continue;
        }
        // Sibling count of a paired slice: emit `@intCast(slice.len)`.
        if (sliceCountSource(plan.slice_inputs, i)) |slice_idx| {
            const slice_p = c.params[slice_idx];
            const sname = stripParamPrefix(try snakeCase(ctx.A, slice_p.name));
            try ctx.print("@intCast({s}.len)", .{sname});
            continue;
        }
        const pname = stripParamPrefix(try snakeCase(ctx.A, p.name));
        try ctx.append(pname);
    }
}

fn sliceCountSource(slices: []const SliceInput, idx: usize) ?usize {
    for (slices) |si| if (si.count_idx == idx) return si.slice_idx;
    return null;
}

fn emitBodyPlain(ctx: *Ctx, c: parser.Command, dispatch_var: []const u8, has_self: bool, plan: WrapperPlan, indent: []const u8) !void {
    try ctx.print("{s}    return {s}.{s}(", .{ indent, dispatch_var, c.name });
    try writeCallArgs(ctx, c, has_self, plan, null, null);
    try ctx.append(");\n");
}

fn emitBodyCheckResultVoid(ctx: *Ctx, c: parser.Command, dispatch_var: []const u8, has_self: bool, plan: WrapperPlan, indent: []const u8) !void {
    try ctx.print("{s}    const _r = {s}.{s}(", .{ indent, dispatch_var, c.name });
    try writeCallArgs(ctx, c, has_self, plan, null, null);
    try ctx.append(");\n");
    try ctx.print("{s}    try checkResult(_r);\n", .{indent});
}

fn emitBodyPlainHoist(ctx: *Ctx, c: parser.Command, dispatch_var: []const u8, has_self: bool, plan: WrapperPlan, indent: []const u8) !void {
    const op = plan.out_param.?;
    const inner = try hoistedReturnInner(ctx, c.params[op]);
    try ctx.print("{s}    var _out: {s} = undefined;\n", .{ indent, inner });
    try ctx.print("{s}    {s}.{s}(", .{ indent, dispatch_var, c.name });
    try writeCallArgs(ctx, c, has_self, plan, op, "&_out");
    try ctx.append(");\n");
    try ctx.print("{s}    return _out;\n", .{indent});
}

fn emitBodyCheckResultHoist(ctx: *Ctx, c: parser.Command, dispatch_var: []const u8, has_self: bool, plan: WrapperPlan, indent: []const u8) !void {
    const op = plan.out_param.?;
    const inner = try hoistedReturnInner(ctx, c.params[op]);
    try ctx.print("{s}    var _out: {s} = undefined;\n", .{ indent, inner });
    try ctx.print("{s}    const _r = {s}.{s}(", .{ indent, dispatch_var, c.name });
    try writeCallArgs(ctx, c, has_self, plan, op, "&_out");
    try ctx.append(");\n");
    try ctx.print("{s}    try checkResult(_r);\n", .{indent});
    try ctx.print("{s}    return _out;\n", .{indent});
}

fn emitBodyTwoPass(ctx: *Ctx, c: parser.Command, dispatch_var: []const u8, has_self: bool, plan: WrapperPlan, indent: []const u8) !void {
    const tp = plan.two_pass.?;
    const arr_p = c.params[tp.array_idx];
    const elem = try hoistedElementType(ctx, arr_p);
    const returns_vk_result = std.mem.eql(u8, c.return_type.base, "VkResult");
    try ctx.print("{s}    var _count: u32 = 0;\n", .{indent});
    // First call: query count, pass null for the array.
    try ctx.print("{s}    ", .{indent});
    if (returns_vk_result) try ctx.append("{ const _r = ") else try ctx.append("{ ");
    try ctx.print("{s}.{s}(", .{ dispatch_var, c.name });
    try writeCallArgsTwoPass(ctx, c, has_self, plan, tp, "&_count", "null");
    try ctx.append(");\n");
    if (returns_vk_result) try ctx.print("{s}        try checkResult(_r);\n", .{indent});
    try ctx.print("{s}    }}\n", .{indent});
    try ctx.print("{s}    const _out = gpa.alloc({s}, _count) catch return error.OutOfHostMemory;\n", .{ indent, elem });
    try ctx.print("{s}    errdefer gpa.free(_out);\n", .{indent});
    try ctx.print("{s}    ", .{indent});
    if (returns_vk_result) try ctx.append("{ const _r = ") else try ctx.append("{ ");
    try ctx.print("{s}.{s}(", .{ dispatch_var, c.name });
    try writeCallArgsTwoPass(ctx, c, has_self, plan, tp, "&_count", "@ptrCast(_out.ptr)");
    try ctx.append(");\n");
    if (returns_vk_result) try ctx.print("{s}        try checkResult(_r);\n", .{indent});
    try ctx.print("{s}    }}\n", .{indent});
    try ctx.print("{s}    return _out[0.._count];\n", .{indent});
}

fn writeCallArgsTwoPass(
    ctx: *Ctx,
    c: parser.Command,
    has_self: bool,
    plan: WrapperPlan,
    tp: TwoPass,
    count_arg: []const u8,
    array_arg: []const u8,
) !void {
    for (c.params, 0..) |p, i| {
        if (i > 0) try ctx.append(", ");
        if (i == tp.count_idx) {
            try ctx.append(count_arg);
            continue;
        }
        if (i == tp.array_idx) {
            try ctx.append(array_arg);
            continue;
        }
        if (has_self and i == 0) {
            try ctx.append("self");
            continue;
        }
        if (findSliceInput(plan.slice_inputs, i) != null or indexInList(plan.composite_slices, i)) {
            const pname = stripParamPrefix(try snakeCase(ctx.A, p.name));
            try ctx.print("@ptrCast({s}.ptr)", .{pname});
            continue;
        }
        if (sliceCountSource(plan.slice_inputs, i)) |slice_idx| {
            const sname = stripParamPrefix(try snakeCase(ctx.A, c.params[slice_idx].name));
            try ctx.print("@intCast({s}.len)", .{sname});
            continue;
        }
        const pname = stripParamPrefix(try snakeCase(ctx.A, p.name));
        try ctx.append(pname);
    }
}

fn methodName(A: std.mem.Allocator, c_name: []const u8, _self: ?parser.Handle) ![]const u8 {
    var n = c_name;
    if (std.mem.startsWith(u8, n, "vk")) n = n[2..];
    if (_self) |h| {
        // Strip the handle's PascalCase name from the front of the method
        // when present (e.g. `Device.createBuffer` instead of `Device.deviceCreateBuffer`).
        const strip = stripVkPrefix(h.name);
        if (std.mem.startsWith(u8, n, strip)) {
            n = n[strip.len..];
        }
    }
    if (n.len == 0) return try A.dupe(u8, c_name);
    var buf: std.ArrayList(u8) = .empty;
    // Lowercase first character.
    try buf.append(A, std.ascii.toLower(n[0]));
    try buf.appendSlice(A, n[1..]);
    return try buf.toOwnedSlice(A);
}

// =========================================================== Type mapping =

const Context = enum {
    /// A field inside an `extern struct`.
    struct_field,
    /// A parameter of a synthesized `PFN_*` function pointer.
    pfn_param,
    /// The return type of a synthesized `PFN_*` function pointer.
    pfn_return,
    /// A parameter of an idiomatic Zig wrapper.
    api_param,
    /// The return type of an idiomatic Zig wrapper (informational only —
    /// the wrapper hoists out-params and Result codes via `Error!`).
    api_return,
};

fn mapCType(
    ctx: *Ctx,
    ct: parser.CType,
    optional: bool,
    len: ?[]const u8,
    use: Context,
) ![]const u8 {
    // `void` only makes sense as a value type in Zig (the unit type) and as a
    // pointer-target via `*anyopaque`. Vulkan uses `void*` for opaque buffers
    // and `void` as a function return — handle both.
    const base = if (std.mem.eql(u8, ct.base, "void") and ct.pointer_depth > 0)
        "anyopaque"
    else
        mapBaseName(ct.base);

    // `void**` (caller-supplied out-pointer for `vkMapMemory`) is the only
    // double-indirection-to-opaque the API uses. Zig rejects `[*c]anyopaque`
    // (no indexing into opaque), so emit a typed pointer chain.
    if (std.mem.eql(u8, ct.base, "void") and ct.pointer_depth == 2) {
        return if (ct.is_const) "?*const ?*anyopaque" else "?*?*anyopaque";
    }
    const handle_kind = ctx.type_names.get(ct.base) orelse Ctx.TypeKind.basetype;

    // Array suffix (`T name[N]`) — render as `[N]T` regardless of context.
    if (ct.array_size) |size| {
        const size_zig = renderArraySize(size);
        if (ct.pointer_depth == 0) {
            return try std.fmt.allocPrint(ctx.A, "[{s}]{s}", .{ size_zig, base });
        }
    }

    // Cstrings: `const char*` with `len="null-terminated"` or `pApplicationName`.
    if (std.mem.eql(u8, ct.base, "char") and ct.pointer_depth == 1 and ct.is_const) {
        if (len) |l| {
            if (std.mem.eql(u8, l, "null-terminated")) {
                return if (optional) "?[*:0]const u8" else "[*:0]const u8";
            }
        }
        // No len = single cstring (most common).
        return if (optional) "?[*:0]const u8" else "[*:0]const u8";
    }
    // Cstring array (`const char* const*`) with explicit len → `[*]const [*:0]const u8`.
    if (std.mem.eql(u8, ct.base, "char") and ct.pointer_depth == 2 and ct.is_const and ct.is_inner_const) {
        return if (optional) "?[*]const [*:0]const u8" else "[*]const [*:0]const u8";
    }

    // Pointer → handle dispatchable: `*T` (S2 keeps handles as opaque pointers).
    if (handle_kind == .handle_dispatchable and ct.pointer_depth == 0) {
        return try std.fmt.allocPrint(ctx.A, "*{s}", .{base});
    }

    // Plain value, no pointer.
    if (ct.pointer_depth == 0) {
        return base;
    }

    // Pointer to handle dispatchable (e.g. `*Instance` out-param) → `**T`.
    if (handle_kind == .handle_dispatchable and ct.pointer_depth == 1) {
        return if (optional)
            try std.fmt.allocPrint(ctx.A, "?*{s}{s}", .{ if (ct.is_const) "const *" else "*", base })
        else
            try std.fmt.allocPrint(ctx.A, "*{s}{s}", .{ if (ct.is_const) "const *" else "*", base });
    }

    // Slice candidates in idiomatic API context: `T*` with len → `[]T`.
    if (use == .api_param and len != null and ct.pointer_depth == 1) {
        const inner = if (ct.is_const)
            try std.fmt.allocPrint(ctx.A, "[]const {s}", .{base})
        else
            try std.fmt.allocPrint(ctx.A, "[]{s}", .{base});
        return if (optional) try std.fmt.allocPrint(ctx.A, "?{s}", .{inner}) else inner;
    }

    // Default: emit a raw pointer that mirrors the C declaration.
    if (ct.pointer_depth == 1) {
        const inner = if (ct.is_const)
            try std.fmt.allocPrint(ctx.A, "*const {s}", .{base})
        else
            try std.fmt.allocPrint(ctx.A, "*{s}", .{base});
        return if (optional) try std.fmt.allocPrint(ctx.A, "?{s}", .{inner}) else inner;
    }

    // Pointer-to-pointer fallback.
    return try std.fmt.allocPrint(ctx.A, "[*c]{s}{s}", .{
        if (ct.is_const) "const " else "",
        base,
    });
}

fn mapBaseName(name: []const u8) []const u8 {
    // C primitives.
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "char")) return "u8";
    if (std.mem.eql(u8, name, "int")) return "c_int";
    if (std.mem.eql(u8, name, "uint8_t")) return "u8";
    if (std.mem.eql(u8, name, "uint16_t")) return "u16";
    if (std.mem.eql(u8, name, "uint32_t")) return "u32";
    if (std.mem.eql(u8, name, "uint64_t")) return "u64";
    if (std.mem.eql(u8, name, "int8_t")) return "i8";
    if (std.mem.eql(u8, name, "int16_t")) return "i16";
    if (std.mem.eql(u8, name, "int32_t")) return "i32";
    if (std.mem.eql(u8, name, "int64_t")) return "i64";
    if (std.mem.eql(u8, name, "size_t")) return "usize";
    if (std.mem.eql(u8, name, "float")) return "f32";
    if (std.mem.eql(u8, name, "double")) return "f64";
    return stripVkPrefix(name);
}

fn renderArraySize(s: []const u8) []const u8 {
    // Strip Vk prefix from VK_MAX_X constants used as array sizes.
    if (std.mem.startsWith(u8, s, "VK_")) return s[3..];
    return s;
}

// ============================================================ name utils =

fn stripVkPrefix(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "Vk")) return s[2..];
    // Note: PFN_* names are kept verbatim — they are explicitly Vulkan
    // function pointer typedefs and the `PFN_` prefix is part of the Vulkan
    // public surface in every binding ecosystem.
    if (std.mem.startsWith(u8, s, "VK_")) return s[3..];
    return s;
}

/// Convert a Vulkan enum variant name to its short form by stripping the
/// type-derived prefix and lowercasing.
///
///   stripEnumPrefix("VkResult", "VK_SUCCESS") == "success"
///   stripEnumPrefix("VkFormat", "VK_FORMAT_R8G8B8A8_UNORM") == "r8g8b8a8_unorm"
fn stripEnumPrefix(ctx: *Ctx, type_name: []const u8, variant: []const u8) ![]const u8 {
    const prefix = try enumPrefix(ctx.A, type_name);
    var s = variant;
    if (std.mem.startsWith(u8, s, prefix)) {
        s = s[prefix.len..];
    } else if (std.mem.startsWith(u8, s, "VK_")) {
        s = s[3..];
    }
    // Trim a trailing vendor tag (KHR, EXT, …) when the type name has one.
    const tag = trailingTag(type_name);
    if (tag.len > 0 and std.mem.endsWith(u8, s, tag)) {
        // Also drop the underscore preceding the tag.
        const cut = s.len - tag.len - 1;
        if (cut < s.len and s[cut] == '_') {
            s = s[0..cut];
        }
    }
    // Identifiers that begin with a digit need a leading underscore.
    var buf: std.ArrayList(u8) = .empty;
    if (s.len > 0 and std.ascii.isDigit(s[0])) try buf.append(ctx.A, '_');
    for (s) |b| {
        try buf.append(ctx.A, std.ascii.toLower(b));
    }
    const lowered = try buf.toOwnedSlice(ctx.A);
    return try escapeKeyword(ctx.A, lowered);
}

/// Build the SCREAMING_SNAKE prefix for an enum's variants.
///
///   enumPrefix("VkFormat") == "VK_FORMAT_"
///   enumPrefix("VkColorSpaceKHR") == "VK_COLOR_SPACE_"
///   enumPrefix("VkBufferUsageFlagBits") == "VK_BUFFER_USAGE_"
fn enumPrefix(A: std.mem.Allocator, type_name: []const u8) ![]const u8 {
    var base = type_name;
    // Drop trailing vendor tag (KHR, EXT, NV, AMD, …).
    const tag = trailingTag(type_name);
    if (tag.len > 0) base = base[0 .. base.len - tag.len];
    // Drop trailing FlagBits / FlagBits2.
    const flagbits_suffix = blk: {
        if (std.mem.endsWith(u8, base, "FlagBits2")) break :blk @as(usize, 9);
        if (std.mem.endsWith(u8, base, "FlagBits")) break :blk @as(usize, 8);
        break :blk @as(usize, 0);
    };
    if (flagbits_suffix > 0) base = base[0 .. base.len - flagbits_suffix];

    // Strip "Vk" prefix.
    if (std.mem.startsWith(u8, base, "Vk")) base = base[2..];

    // PascalCase → SCREAMING_SNAKE_CASE.
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(A, "VK_");
    for (base, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i > 0 and !std.ascii.isUpper(base[i - 1])) {
            try buf.append(A, '_');
        }
        try buf.append(A, std.ascii.toUpper(c));
    }
    try buf.append(A, '_');
    return try buf.toOwnedSlice(A);
}

fn trailingTag(name: []const u8) []const u8 {
    const tags = [_][]const u8{ "KHR", "EXT", "NV", "AMD", "INTEL", "GOOGLE", "ARM", "VALVE", "QCOM", "FUCHSIA", "ANDROID", "MVK", "MSFT", "QNX", "IMG", "HUAWEI", "GGP", "NN", "SEC", "JOST", "CHROMIUM" };
    for (tags) |t| if (std.mem.endsWith(u8, name, t)) return t;
    return "";
}

fn snakeCase(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return try A.dupe(u8, s);
    var buf: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i > 0 and !std.ascii.isUpper(s[i - 1])) {
            try buf.append(A, '_');
        }
        try buf.append(A, std.ascii.toLower(c));
    }
    // Avoid colliding with Zig keywords.
    const out = try buf.toOwnedSlice(A);
    return try escapeKeyword(A, out);
}

fn escapeKeyword(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    const kws = [_][]const u8{ "type", "error", "fn", "var", "const", "pub", "test", "struct", "enum", "union", "opaque", "extern", "async", "comptime", "inline", "callconv", "for", "while", "if", "else", "switch", "and", "or", "not", "true", "false", "null", "undefined", "unreachable", "noinline", "noreturn", "anyframe", "anyopaque", "anytype", "void", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "bool", "isize", "usize", "c_int", "c_uint", "c_long", "c_ulong", "c_longlong", "c_ulonglong" };
    for (kws) |kw| if (std.mem.eql(u8, kw, s)) {
        return try std.fmt.allocPrint(A, "@\"{s}\"", .{s});
    };
    return s;
}

fn stripBitSuffix(A: std.mem.Allocator, s: []const u8) ![]const u8 {
    var t = s;
    // Bitmask variants in vk.xml end in `_BIT` or `_BIT_<VENDOR>` (e.g.
    // `_BIT_KHR`, `_BIT_EXT`). After lowercasing we may see `_bit_khr`,
    // `_bit_ext`, `_bit_amd`, etc. — strip both the bit marker and the
    // vendor tag so the field name is just the semantic part.
    const vendor_tags = [_][]const u8{ "_khr", "_ext", "_nv", "_amd", "_intel", "_google", "_arm", "_valve", "_qcom", "_fuchsia", "_android", "_mvk", "_msft", "_qnx", "_img", "_huawei", "_ggp", "_nn", "_sec" };
    for (vendor_tags) |tag| {
        if (std.mem.endsWith(u8, t, tag)) {
            t = t[0 .. t.len - tag.len];
            break;
        }
    }
    if (std.mem.endsWith(u8, t, "_bit")) t = t[0 .. t.len - 4];
    if (t.len == 0) t = "_unnamed";
    // Review item #6: align named "reserved_N" bits with the synthesized
    // unnamed bits so the field naming is uniformly `_reserved_N`.
    if (std.mem.startsWith(u8, t, "reserved")) {
        return try std.fmt.allocPrint(A, "_{s}", .{t});
    }
    const dup = try A.dupe(u8, t);
    return try escapeKeyword(A, dup);
}
