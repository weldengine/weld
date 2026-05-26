//! Minimal XML parser for vk.xml (and protocol XMLs).
//!
//! Throwaway code for S2. Handles only the subset of XML used by Khronos
//! registries and Wayland protocols: tags with double-quoted attributes,
//! mixed content, self-closing tags, comments, `<?xml ... ?>` declarations,
//! `&lt; &gt; &amp; &quot; &apos;` entity references. No CDATA (not used by
//! vk.xml or wayland-protocols), no namespaces, no DOCTYPE handling beyond
//! skipping.
//!
//! All output strings are owned by the Tree's arena.

const std = @import("std");

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

const Element = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const Child,

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    pub fn firstChild(self: Element, tag: []const u8) ?*const Element {
        for (self.children) |*c| {
            if (c.* == .elem and std.mem.eql(u8, c.elem.tag, tag)) return &c.elem;
        }
        return null;
    }

    /// Concatenate all direct text children into a single arena-allocated
    /// string (whitespace preserved). Useful for inspecting `<name>X</name>`.
    pub fn directText(self: Element, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (self.children) |c| {
            if (c == .text) try out.appendSlice(gpa, c.text);
        }
        return out.toOwnedSlice(gpa);
    }
};

const Child = union(enum) {
    elem: Element,
    text: []const u8,
};

const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: Element,

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }
};

const ParseError = error{
    UnexpectedEof,
    UnexpectedChar,
    BadAttribute,
    UnterminatedTag,
    UnterminatedString,
    MismatchedClose,
    UnknownEntity,
} || std.mem.Allocator.Error;

/// First stage of the vk_gen pipeline: scan the raw `vk.xml` bytes
/// into a `Tree` of `Element`s. The returned `Tree` owns an arena
/// holding every string slice — `tree.deinit()` reclaims everything
/// the model / filter / emit passes might still reference.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) ParseError!Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    var p: Parser = .{ .src = source, .pos = 0, .arena = aalloc };

    // Skip leading prolog (XML decl, comments, whitespace, DOCTYPE).
    try p.skipProlog();

    // Root element.
    if (!p.match('<')) return error.UnexpectedChar;
    const root = try p.parseElement();

    return .{ .arena = arena, .root = root };
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,

    fn peek(self: Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn match(self: *Parser, c: u8) bool {
        if (self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn matchSlice(self: *Parser, s: []const u8) bool {
        if (self.pos + s.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s)) return false;
        self.pos += s.len;
        return true;
    }

    fn skipWs(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                else => break,
            }
        }
    }

    fn skipProlog(self: *Parser) ParseError!void {
        while (true) {
            self.skipWs();
            if (self.matchSlice("<?")) {
                // <?xml ... ?>
                while (self.advance()) |c| {
                    if (c == '?' and self.peek() == '>') {
                        self.pos += 1;
                        break;
                    }
                } else return error.UnterminatedTag;
                continue;
            }
            if (self.matchSlice("<!--")) {
                while (self.pos + 3 <= self.src.len) {
                    if (std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "-->")) {
                        self.pos += 3;
                        break;
                    }
                    self.pos += 1;
                } else return error.UnterminatedTag;
                continue;
            }
            if (self.matchSlice("<!DOCTYPE")) {
                // Skip up to matching '>'. Naive — vk.xml's DOCTYPE is one-liner if any.
                var depth: i32 = 1;
                while (depth > 0) {
                    const c = self.advance() orelse return error.UnterminatedTag;
                    if (c == '<') depth += 1;
                    if (c == '>') depth -= 1;
                }
                continue;
            }
            return;
        }
    }

    /// Called immediately after the leading '<' has been consumed.
    fn parseElement(self: *Parser) ParseError!Element {
        // Tag name.
        const start = self.pos;
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n', '/', '>' => break,
                else => self.pos += 1,
            }
        }
        if (self.pos == start) return error.UnexpectedChar;
        const tag = self.src[start..self.pos];

        // Attributes.
        var attrs: std.ArrayList(Attr) = .empty;
        defer attrs.deinit(self.arena);
        while (true) {
            self.skipWs();
            const c = self.peek() orelse return error.UnterminatedTag;
            if (c == '/' or c == '>') break;
            const a = try self.parseAttr();
            try attrs.append(self.arena, a);
        }

        // Self-closing or end of opening tag.
        const self_closing = self.match('/');
        if (!self.match('>')) return error.UnterminatedTag;

        if (self_closing) {
            return .{
                .tag = try self.arena.dupe(u8, tag),
                .attrs = try attrs.toOwnedSlice(self.arena),
                .children = &.{},
            };
        }

        // Children: parse until matching </tag>.
        var children: std.ArrayList(Child) = .empty;
        defer children.deinit(self.arena);
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(self.arena);

        while (true) {
            const c = self.peek() orelse return error.UnexpectedEof;
            if (c == '<') {
                // Flush accumulated text.
                if (text_buf.items.len > 0) {
                    try children.append(self.arena, .{ .text = try self.arena.dupe(u8, text_buf.items) });
                    text_buf.clearRetainingCapacity();
                }
                self.pos += 1;
                if (self.peek() == '/') {
                    self.pos += 1;
                    // Closing tag.
                    const close_start = self.pos;
                    while (self.peek()) |cc| {
                        if (cc == '>' or cc == ' ' or cc == '\t' or cc == '\r' or cc == '\n') break;
                        self.pos += 1;
                    }
                    const close_tag = self.src[close_start..self.pos];
                    if (!std.mem.eql(u8, close_tag, tag)) return error.MismatchedClose;
                    self.skipWs();
                    if (!self.match('>')) return error.UnterminatedTag;
                    return .{
                        .tag = try self.arena.dupe(u8, tag),
                        .attrs = try attrs.toOwnedSlice(self.arena),
                        .children = try children.toOwnedSlice(self.arena),
                    };
                }
                if (self.matchSlice("!--")) {
                    // Comment — skip.
                    while (self.pos + 3 <= self.src.len) {
                        if (std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "-->")) {
                            self.pos += 3;
                            break;
                        }
                        self.pos += 1;
                    } else return error.UnterminatedTag;
                    continue;
                }
                // Nested element.
                const child = try self.parseElement();
                try children.append(self.arena, .{ .elem = child });
            } else if (c == '&') {
                self.pos += 1;
                const ent = try self.parseEntity();
                try text_buf.append(self.arena, ent);
            } else {
                try text_buf.append(self.arena, c);
                self.pos += 1;
            }
        }
    }

    fn parseAttr(self: *Parser) ParseError!Attr {
        // Name.
        const ns = self.pos;
        while (self.peek()) |c| {
            switch (c) {
                '=', ' ', '\t', '\r', '\n', '/', '>' => break,
                else => self.pos += 1,
            }
        }
        if (self.pos == ns) return error.BadAttribute;
        const name = self.src[ns..self.pos];

        self.skipWs();
        if (!self.match('=')) return error.BadAttribute;
        self.skipWs();

        const quote = self.advance() orelse return error.BadAttribute;
        if (quote != '"' and quote != '\'') return error.BadAttribute;

        var value_buf: std.ArrayList(u8) = .empty;
        defer value_buf.deinit(self.arena);
        while (true) {
            const c = self.peek() orelse return error.UnterminatedString;
            if (c == quote) {
                self.pos += 1;
                break;
            }
            if (c == '&') {
                self.pos += 1;
                const e = try self.parseEntity();
                try value_buf.append(self.arena, e);
                continue;
            }
            try value_buf.append(self.arena, c);
            self.pos += 1;
        }

        return .{
            .name = try self.arena.dupe(u8, name),
            .value = try self.arena.dupe(u8, value_buf.items),
        };
    }

    fn parseEntity(self: *Parser) ParseError!u8 {
        // Standard 5 entities + numeric (&#NN; or &#xNN;) — the registry
        // uses these only sparingly, but we must handle them.
        if (self.matchSlice("lt;")) return '<';
        if (self.matchSlice("gt;")) return '>';
        if (self.matchSlice("amp;")) return '&';
        if (self.matchSlice("quot;")) return '"';
        if (self.matchSlice("apos;")) return '\'';
        if (self.match('#')) {
            // Numeric. Read digits up to ';'.
            const hex = self.match('x') or self.match('X');
            var n: u32 = 0;
            while (self.peek()) |c| {
                if (c == ';') {
                    self.pos += 1;
                    if (n > 0x7F) return error.UnknownEntity; // ASCII only here
                    return @intCast(n);
                }
                const d: u32 = if (hex) blk: {
                    break :blk if (c >= '0' and c <= '9') @as(u32, c - '0') else if (c >= 'a' and c <= 'f') @as(u32, c - 'a' + 10) else if (c >= 'A' and c <= 'F') @as(u32, c - 'A' + 10) else return error.UnknownEntity;
                } else if (c >= '0' and c <= '9') @as(u32, c - '0') else return error.UnknownEntity;
                n = n * @as(u32, if (hex) 16 else 10) + d;
                self.pos += 1;
            }
            return error.UnknownEntity;
        }
        return error.UnknownEntity;
    }
};

// =====================================================================
// vk.xml-specific model + extractor
// =====================================================================
//
// The model is a flat, lossy representation of the registry entries that
// the S2 emitter cares about. Variadic functions, video codec entries,
// and most pragmas are skipped on purpose.

const Model = struct {
    arena: std.heap.ArenaAllocator,
    /// Header file → category → C built-in basetypes / aliases (e.g. `VkBool32 = uint32_t`).
    basetypes: []const Basetype,
    platform_types: []const PlatformType,
    handles: []const Handle,
    /// Enum groups keyed by name (`VkResult`, `VkFormat`, …).
    enum_groups: []const EnumGroup,
    bitmasks: []const Bitmask,
    structs: []const Struct,
    unions: []const Struct,
    funcpointers: []const FuncPointer,
    aliases: []const Alias,
    api_constants: []const ApiConstant,
    commands: []const Command,
    extensions: []const Extension,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
    }

    pub fn findCommand(self: Model, name: []const u8) ?*const Command {
        for (self.commands) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

const Basetype = struct {
    /// Vulkan name (e.g. `VkBool32`, `VkDeviceSize`).
    name: []const u8,
    /// C declaration body so the emitter can decide the Zig mapping.
    /// Example: `typedef uint32_t VkBool32;`
    c_decl: []const u8,
};

/// Platform type forward-declaration (e.g. `<type requires="windows.h" name="HINSTANCE"/>`)
/// — no body, just a name and the originating header. The emitter decides
/// the Zig representation per name.
pub const PlatformType = struct {
    name: []const u8,
    requires: []const u8,
};

/// Opaque Vulkan handle entry (`VkInstance`, `VkBuffer`, etc.).
/// Consumed by `emit.zig` to decide whether to emit a dispatchable
/// `*opaque{}` (real C pointer) or a non-dispatchable `u64`.
pub const Handle = struct {
    name: []const u8,
    /// `true` for `VK_DEFINE_HANDLE` (dispatchable, real C pointer),
    /// `false` for `VK_DEFINE_NON_DISPATCHABLE_HANDLE` (uint64 in 64-bit
    /// builds, real pointer in 32-bit but Vulkan deprecated 32-bit so we
    /// always emit u64).
    dispatchable: bool,
    parent: ?[]const u8,
};

/// Bundle of enum variants resolved from the registry's `<enums>`
/// elements + per-feature / per-extension extras. The emitter looks
/// up groups by name when emitting struct field defaults, function
/// argument types, and `Result` mappings.
pub const EnumGroup = struct {
    name: []const u8,
    kind: Kind,
    bit_width: u32 = 32,
    values: []const EnumValue,

    pub const Kind = enum { @"enum", bitmask, api_constants };
};

const EnumValue = struct {
    name: []const u8,
    /// Raw value as text (`"0"`, `"-1"`, `"0x10000000"`) when the registry
    /// uses `value=`. Mutually exclusive with `bitpos` and `alias`.
    value: ?[]const u8 = null,
    bitpos: ?u8 = null,
    alias: ?[]const u8 = null,
    /// Source feature/extension that defines this entry. Used for diagnostics
    /// and for emitting comment trails.
    source: []const u8 = "",
};

const Bitmask = struct {
    /// Flag-typedef name (`VkBufferUsageFlags`).
    name: []const u8,
    /// Bits enum it points at (`VkBufferUsageFlagBits`), or null if the
    /// flags type has no enum yet (registry has plenty of these — emit as
    /// raw integer alias).
    requires_enum: ?[]const u8,
    /// 32 or 64.
    width: u32 = 32,
};

/// Resolved Vulkan struct/union entry consumed by `emit.zig` to
/// render `extern struct` declarations and their `sType` defaults.
pub const Struct = struct {
    name: []const u8,
    members: []const Member,
    /// `VK_STRUCTURE_TYPE_*` literal pulled from `<member values="…">` on the
    /// `sType` field, when present.
    s_type_value: ?[]const u8,
    /// `<type>` `returnedonly="true"` — emit no default `sType` and skip
    /// from `pNext` chains (informational only for S2).
    returned_only: bool = false,
};

const FuncPointer = struct {
    name: []const u8,
    /// Full C declaration text (e.g. `typedef void (VKAPI_PTR *PFN_vkVoidFunction)(void);`).
    /// Parsed by the emitter — keeping the raw form avoids reinventing a
    /// C function-prototype parser inside the generator.
    c_decl: []const u8,
};

const Alias = struct {
    name: []const u8,
    target: []const u8,
};

/// Registry `<enums name="API Constants">` entry — a single named
/// macro the emitter renders as a `pub const`. Surfaced to
/// `emit.zig` (which resolves the `(~0U)`-style values) and
/// otherwise opaque to callers.
pub const ApiConstant = struct {
    name: []const u8,
    /// Raw value text. May be a numeric literal, hex, float, or `(~0U)`
    /// expression — emitter resolves the small handful of well-known
    /// idioms.
    value: []const u8,
    /// Original C type attribute when present (`uint32_t`, `uint64_t`,
    /// `float`, …). Lets the emitter pick the correct Zig representation
    /// for `(~NU)` style values.
    c_type: ?[]const u8 = null,
};

/// Resolved Vulkan command entry. Consumed by `emit.zig` to render
/// the Zig wrapper, decide its dispatch table membership (instance
/// vs device vs loader), and pull the return / error code lists.
pub const Command = struct {
    name: []const u8,
    /// Resolved at extraction time when `<command alias="…">` is used.
    alias_of: ?[]const u8 = null,
    return_type: CType,
    params: []const Member,
    success_codes: []const []const u8,
    error_codes: []const []const u8,
    /// `<command queues="…">` — informational.
    queues: []const u8 = "",
    api: []const u8 = "",
};

/// Resolved struct field / command parameter. Carries the original
/// nullability and length-expression attributes so `emit.zig` can
/// build slice wrappers and optional types correctly.
pub const Member = struct {
    name: []const u8,
    c_type: CType,
    optional: bool = false,
    /// Length expression: another field name, `null-terminated`, or a
    /// comma-separated list (rare). Empty when len is implicit.
    len: ?[]const u8 = null,
    /// `values=` attribute — used for sType discriminants.
    values: ?[]const u8 = null,
};

/// Resolved C-type triplet (`base`, pointer depth, qualifiers).
/// Surfaced so `emit.zig` can map raw C declarators into Zig types
/// (`?*const T`, `[]T`, etc.) without re-parsing the registry XML.
pub const CType = struct {
    /// Base C identifier (`VkBuffer`, `uint32_t`, `void`, `char`).
    base: []const u8,
    /// `const` qualifier on the immediate declaration (covers `const T`
    /// and `const T*`; we do not model `T* const` since the registry
    /// never uses it on parameters that matter for S2).
    is_const: bool = false,
    /// 0 = value, 1 = `T*`, 2 = `T**`.
    pointer_depth: u8 = 0,
    /// `const` on the second indirection (`T* const*` is impossible in
    /// Vulkan, but `const T* const*` for arrays of cstrings appears).
    is_inner_const: bool = false,
    /// Trailing array suffix when present, e.g. `[16]` or `[VK_UUID_SIZE]`.
    /// The emitter resolves enum constants by name.
    array_size: ?[]const u8 = null,
};

const Extension = struct {
    name: []const u8,
    type: []const u8, // "instance" or "device" or ""
    platform: ?[]const u8 = null,
    /// Already collapsed across all `<require>` blocks.
    types: []const []const u8,
    commands: []const []const u8,
    enum_extensions: []const EnumExtension,
};

const EnumExtension = struct {
    extends: []const u8,
    name: []const u8,
    value: ?[]const u8 = null,
    bitpos: ?u8 = null,
    offset: ?i64 = null,
    extnumber: ?i64 = null,
    /// `negative` direction for offset-based enum extensions.
    negative: bool = false,
    alias: ?[]const u8 = null,
};

// ---------- Extractor -----------------------------------------------------

/// Second stage of the vk_gen pipeline: lift the raw XML `Tree` into
/// the typed `Model` consumed by the filter / emit stages. `tree` is
/// borrowed (it stays alive across calls); the returned `Model` owns
/// its own arena so the caller can free `tree` before emitting.
pub fn extractModel(gpa: std.mem.Allocator, tree: Tree) !Model {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const A = arena.allocator();

    var basetypes: std.ArrayList(Basetype) = .empty;
    var platform_types: std.ArrayList(PlatformType) = .empty;
    var handles: std.ArrayList(Handle) = .empty;
    var enum_groups: std.ArrayList(EnumGroup) = .empty;
    var bitmasks: std.ArrayList(Bitmask) = .empty;
    var structs: std.ArrayList(Struct) = .empty;
    var unions: std.ArrayList(Struct) = .empty;
    var funcpointers: std.ArrayList(FuncPointer) = .empty;
    var aliases: std.ArrayList(Alias) = .empty;
    var api_constants: std.ArrayList(ApiConstant) = .empty;
    var commands: std.ArrayList(Command) = .empty;
    var extensions: std.ArrayList(Extension) = .empty;

    // --------- types ------------
    if (tree.root.firstChild("types")) |types_elem| {
        for (types_elem.children) |child| {
            if (child != .elem or !std.mem.eql(u8, child.elem.tag, "type")) continue;
            const t = &child.elem;
            // Aliases via `alias=` attribute.
            if (t.attr("alias")) |alias_target| {
                const name = t.attr("name") orelse continue;
                try aliases.append(A, .{ .name = try A.dupe(u8, name), .target = try A.dupe(u8, alias_target) });
                continue;
            }
            // Platform forward-declarations live in vk.xml as categoryless
            // `<type requires="…" name="…"/>` placeholders. Capture them as
            // `PlatformType` entries so the emitter can render the correct
            // Zig representation per OS.
            if (t.attr("category") == null) {
                // Skip C primitives forwarded from `vk_platform` (`void`, `int`,
                // `char`, …) — those are mapped directly by the emitter.
                if (t.attr("name")) |nm| if (t.attr("requires")) |rq| {
                    if (!std.mem.eql(u8, rq, "vk_platform")) {
                        try platform_types.append(A, .{
                            .name = try A.dupe(u8, nm),
                            .requires = try A.dupe(u8, rq),
                        });
                    }
                };
                continue;
            }
            const cat = t.attr("category").?;
            // vk.xml carries Vulkan SC duplicates of some flag types via
            // `api="vulkansc"`. We only emit the desktop Vulkan surface in S2.
            if (t.attr("api")) |a| if (!apiMatches(a)) continue;
            if (std.mem.eql(u8, cat, "handle")) {
                // Body looks like `<type>VK_DEFINE_HANDLE</type>(<name>VkInstance</name>)`.
                const macro_elem = t.firstChild("type") orelse continue;
                const name_elem = t.firstChild("name") orelse continue;
                const macro = try macro_elem.directText(A);
                const name = try name_elem.directText(A);
                const dispatchable = std.mem.eql(u8, macro, "VK_DEFINE_HANDLE");
                try handles.append(A, .{
                    .name = name,
                    .dispatchable = dispatchable,
                    .parent = if (t.attr("parent")) |p| try A.dupe(u8, p) else null,
                });
            } else if (std.mem.eql(u8, cat, "basetype")) {
                // Look for explicit name child; otherwise derive from text.
                const name = if (t.firstChild("name")) |n| try n.directText(A) else (try A.dupe(u8, t.attr("name") orelse continue));
                // Reconstruct the C declaration text for downstream mapping.
                var buf: std.ArrayList(u8) = .empty;
                try writeFlattened(t, A, &buf);
                try basetypes.append(A, .{ .name = name, .c_decl = try buf.toOwnedSlice(A) });
            } else if (std.mem.eql(u8, cat, "bitmask")) {
                // `typedef <type>VkFlags</type> <name>VkFooFlags</name>;`
                const name = if (t.firstChild("name")) |n| try n.directText(A) else continue;
                const inner = if (t.firstChild("type")) |x| try x.directText(A) else "VkFlags";
                const width: u32 = if (std.mem.eql(u8, inner, "VkFlags64")) 64 else 32;
                try bitmasks.append(A, .{
                    .name = name,
                    .requires_enum = if (t.attr("requires")) |r| try A.dupe(u8, r) else (if (t.attr("bitvalues")) |b| try A.dupe(u8, b) else null),
                    .width = width,
                });
            } else if (std.mem.eql(u8, cat, "enum")) {
                // Just a forward-decl placeholder — the actual values live in
                // a sibling `<enums>` block. Nothing to emit yet.
            } else if (std.mem.eql(u8, cat, "struct") or std.mem.eql(u8, cat, "union")) {
                const name = t.attr("name") orelse continue;
                var members: std.ArrayList(Member) = .empty;
                var s_type_value: ?[]const u8 = null;
                for (t.children) |mc| {
                    if (mc != .elem) continue;
                    if (!std.mem.eql(u8, mc.elem.tag, "member")) continue;
                    if (mc.elem.attr("api")) |a| if (!apiMatches(a)) continue;
                    const m = try parseMemberLike(A, &mc.elem);
                    if (m.values != null and std.mem.eql(u8, m.name, "sType")) {
                        s_type_value = m.values;
                    }
                    try members.append(A, m);
                }
                const def: Struct = .{
                    .name = try A.dupe(u8, name),
                    .members = try members.toOwnedSlice(A),
                    .s_type_value = s_type_value,
                    .returned_only = if (t.attr("returnedonly")) |ro| std.mem.eql(u8, ro, "true") else false,
                };
                if (std.mem.eql(u8, cat, "struct")) try structs.append(A, def) else try unions.append(A, def);
            } else if (std.mem.eql(u8, cat, "funcpointer")) {
                // The newer vk.xml shape wraps the name in a <proto> child:
                //   <type category="funcpointer">
                //     <proto><type>void</type> <name>PFN_vkX</name></proto>
                //     ...
                // Older shapes embed <name> directly under <type>.
                var name_elem: ?*const Element = null;
                if (t.firstChild("proto")) |p| {
                    name_elem = p.firstChild("name");
                }
                if (name_elem == null) name_elem = t.firstChild("name");
                if (name_elem == null) continue;
                const fname = try name_elem.?.directText(A);
                var buf: std.ArrayList(u8) = .empty;
                try writeFlattened(t, A, &buf);
                try funcpointers.append(A, .{ .name = fname, .c_decl = try buf.toOwnedSlice(A) });
            }
        }
    }

    // --------- enums (top-level <enums>) ----------
    for (tree.root.children) |child| {
        if (child != .elem) continue;
        if (!std.mem.eql(u8, child.elem.tag, "enums")) continue;
        const e = &child.elem;
        const ename_attr = e.attr("name") orelse continue;
        const etype_attr = e.attr("type") orelse "";
        const is_constants = std.mem.eql(u8, ename_attr, "API Constants");
        const is_bitmask = std.mem.eql(u8, etype_attr, "bitmask");
        const bit_width: u32 = if (e.attr("bitwidth")) |bw| std.fmt.parseInt(u32, bw, 10) catch 32 else 32;

        if (is_constants) {
            for (e.children) |vc| {
                if (vc != .elem or !std.mem.eql(u8, vc.elem.tag, "enum")) continue;
                const ec = &vc.elem;
                const cname = ec.attr("name") orelse continue;
                const cval = ec.attr("value") orelse ec.attr("alias") orelse continue;
                try api_constants.append(A, .{
                    .name = try A.dupe(u8, cname),
                    .value = try A.dupe(u8, cval),
                    .c_type = if (ec.attr("type")) |ty| try A.dupe(u8, ty) else null,
                });
            }
            continue;
        }

        var values: std.ArrayList(EnumValue) = .empty;
        for (e.children) |vc| {
            if (vc != .elem or !std.mem.eql(u8, vc.elem.tag, "enum")) continue;
            const ec = &vc.elem;
            const vname = ec.attr("name") orelse continue;
            var ev: EnumValue = .{ .name = try A.dupe(u8, vname) };
            if (ec.attr("value")) |v| ev.value = try A.dupe(u8, v);
            if (ec.attr("bitpos")) |bp| ev.bitpos = std.fmt.parseInt(u8, bp, 10) catch null;
            if (ec.attr("alias")) |al| ev.alias = try A.dupe(u8, al);
            try values.append(A, ev);
        }
        try enum_groups.append(A, .{
            .name = try A.dupe(u8, ename_attr),
            .kind = if (is_bitmask) .bitmask else .@"enum",
            .bit_width = bit_width,
            .values = try values.toOwnedSlice(A),
        });
    }

    // --------- commands ----------
    if (tree.root.firstChild("commands")) |cmds_elem| {
        for (cmds_elem.children) |child| {
            if (child != .elem or !std.mem.eql(u8, child.elem.tag, "command")) continue;
            const c = &child.elem;
            if (c.attr("api")) |a| if (!apiMatches(a)) continue;
            if (c.attr("alias")) |a| {
                const cname = c.attr("name") orelse continue;
                try commands.append(A, .{
                    .name = try A.dupe(u8, cname),
                    .alias_of = try A.dupe(u8, a),
                    .return_type = .{ .base = try A.dupe(u8, "void") },
                    .params = &.{},
                    .success_codes = &.{},
                    .error_codes = &.{},
                });
                continue;
            }
            const proto = c.firstChild("proto") orelse continue;
            const cname = if (proto.firstChild("name")) |n| try n.directText(A) else continue;
            const ret_member = try parseMemberLike(A, proto);
            var params: std.ArrayList(Member) = .empty;
            for (c.children) |pc| {
                if (pc != .elem or !std.mem.eql(u8, pc.elem.tag, "param")) continue;
                if (pc.elem.attr("api")) |a| if (!apiMatches(a)) continue;
                const p = try parseMemberLike(A, &pc.elem);
                try params.append(A, p);
            }
            const success_codes = try splitCsv(A, c.attr("successcodes") orelse "");
            const error_codes = try splitCsv(A, c.attr("errorcodes") orelse "");
            try commands.append(A, .{
                .name = cname,
                .return_type = ret_member.c_type,
                .params = try params.toOwnedSlice(A),
                .success_codes = success_codes,
                .error_codes = error_codes,
                .queues = if (c.attr("queues")) |q| try A.dupe(u8, q) else "",
                .api = if (c.attr("api")) |a| try A.dupe(u8, a) else "",
            });
        }
    }

    // --------- extensions ----------
    if (tree.root.firstChild("extensions")) |exts_elem| {
        for (exts_elem.children) |child| {
            if (child != .elem or !std.mem.eql(u8, child.elem.tag, "extension")) continue;
            const ex = &child.elem;
            const xname = ex.attr("name") orelse continue;
            const xtype = ex.attr("type") orelse "";
            const xnumber: i64 = if (ex.attr("number")) |n| std.fmt.parseInt(i64, n, 10) catch 0 else 0;

            var types_l: std.ArrayList([]const u8) = .empty;
            var cmds_l: std.ArrayList([]const u8) = .empty;
            var ext_l: std.ArrayList(EnumExtension) = .empty;
            for (ex.children) |rc| {
                if (rc != .elem or !std.mem.eql(u8, rc.elem.tag, "require")) continue;
                for (rc.elem.children) |item| {
                    if (item != .elem) continue;
                    const tag = item.elem.tag;
                    const nm = item.elem.attr("name") orelse continue;
                    if (std.mem.eql(u8, tag, "type")) {
                        try types_l.append(A, try A.dupe(u8, nm));
                    } else if (std.mem.eql(u8, tag, "command")) {
                        try cmds_l.append(A, try A.dupe(u8, nm));
                    } else if (std.mem.eql(u8, tag, "enum")) {
                        const extends = item.elem.attr("extends") orelse continue;
                        var entry: EnumExtension = .{
                            .extends = try A.dupe(u8, extends),
                            .name = try A.dupe(u8, nm),
                        };
                        if (item.elem.attr("value")) |v| entry.value = try A.dupe(u8, v);
                        if (item.elem.attr("bitpos")) |bp| entry.bitpos = std.fmt.parseInt(u8, bp, 10) catch null;
                        if (item.elem.attr("offset")) |of| entry.offset = std.fmt.parseInt(i64, of, 10) catch null;
                        if (item.elem.attr("extnumber")) |en| entry.extnumber = std.fmt.parseInt(i64, en, 10) catch null;
                        if (entry.extnumber == null) entry.extnumber = xnumber;
                        if (item.elem.attr("dir")) |d| entry.negative = std.mem.eql(u8, d, "-");
                        if (item.elem.attr("alias")) |al| entry.alias = try A.dupe(u8, al);
                        try ext_l.append(A, entry);
                    }
                }
            }

            try extensions.append(A, .{
                .name = try A.dupe(u8, xname),
                .type = try A.dupe(u8, xtype),
                .platform = if (ex.attr("platform")) |p| try A.dupe(u8, p) else null,
                .types = try types_l.toOwnedSlice(A),
                .commands = try cmds_l.toOwnedSlice(A),
                .enum_extensions = try ext_l.toOwnedSlice(A),
            });
        }
    }

    // --------- core feature enum extensions (sType, structuretypes, …) ----
    // The new vk.xml structure adds enums to feature `<require>` blocks the
    // same way extensions do. We collect them and apply them later in
    // applyEnumExtensions.
    // For S2 these are only relevant if our whitelist pulls them in via the
    // base feature set; we ingest them regardless and let the whitelist filter.
    var feature_enum_extensions: std.ArrayList(EnumExtension) = .empty;
    for (tree.root.children) |child| {
        if (child != .elem or !std.mem.eql(u8, child.elem.tag, "feature")) continue;
        // Feature numbers (1.0, 1.1, …) are kept implicitly via the require
        // walker; no need to surface them at extraction time.
        for (child.elem.children) |rc| {
            if (rc != .elem or !std.mem.eql(u8, rc.elem.tag, "require")) continue;
            for (rc.elem.children) |item| {
                if (item != .elem or !std.mem.eql(u8, item.elem.tag, "enum")) continue;
                const extends = item.elem.attr("extends") orelse continue;
                const nm = item.elem.attr("name") orelse continue;
                var entry: EnumExtension = .{
                    .extends = try A.dupe(u8, extends),
                    .name = try A.dupe(u8, nm),
                };
                if (item.elem.attr("value")) |v| entry.value = try A.dupe(u8, v);
                if (item.elem.attr("bitpos")) |bp| entry.bitpos = std.fmt.parseInt(u8, bp, 10) catch null;
                if (item.elem.attr("offset")) |of| entry.offset = std.fmt.parseInt(i64, of, 10) catch null;
                if (item.elem.attr("extnumber")) |en| entry.extnumber = std.fmt.parseInt(i64, en, 10) catch null;
                if (item.elem.attr("dir")) |d| entry.negative = std.mem.eql(u8, d, "-");
                if (item.elem.attr("alias")) |al| entry.alias = try A.dupe(u8, al);
                try feature_enum_extensions.append(A, entry);
            }
        }
    }

    // Apply enum extensions (from features and extensions) to enum_groups.
    try applyEnumExtensions(A, enum_groups.items, feature_enum_extensions.items, "core");
    for (extensions.items) |ext| {
        try applyEnumExtensions(A, enum_groups.items, ext.enum_extensions, ext.name);
    }

    return .{
        .arena = arena,
        .basetypes = try basetypes.toOwnedSlice(A),
        .platform_types = try platform_types.toOwnedSlice(A),
        .handles = try handles.toOwnedSlice(A),
        .enum_groups = try enum_groups.toOwnedSlice(A),
        .bitmasks = try bitmasks.toOwnedSlice(A),
        .structs = try structs.toOwnedSlice(A),
        .unions = try unions.toOwnedSlice(A),
        .funcpointers = try funcpointers.toOwnedSlice(A),
        .aliases = try aliases.toOwnedSlice(A),
        .api_constants = try api_constants.toOwnedSlice(A),
        .commands = try commands.toOwnedSlice(A),
        .extensions = try extensions.toOwnedSlice(A),
    };
}

fn applyEnumExtensions(
    A: std.mem.Allocator,
    groups: []EnumGroup,
    extensions: []const EnumExtension,
    source: []const u8,
) !void {
    for (extensions) |ext| {
        // Find the target group.
        for (groups) |*g| {
            if (!std.mem.eql(u8, g.name, ext.extends)) continue;

            // Skip duplicates (extensions sometimes redefine entries).
            var already = false;
            for (g.values) |v| {
                if (std.mem.eql(u8, v.name, ext.name)) {
                    already = true;
                    break;
                }
            }
            if (already) break;

            var ev: EnumValue = .{
                .name = ext.name,
                .source = source,
            };
            if (ext.alias) |a| ev.alias = a;
            if (ext.bitpos) |bp| ev.bitpos = bp;
            if (ext.value) |v| ev.value = v;
            if (ext.offset) |off| {
                const extnum = ext.extnumber orelse 0;
                const base: i64 = 1_000_000_000;
                const range: i64 = 1000;
                var n: i64 = base + (extnum - 1) * range + off;
                if (ext.negative) n = -n;
                ev.value = try std.fmt.allocPrint(A, "{d}", .{n});
            }
            const new_values = try A.alloc(EnumValue, g.values.len + 1);
            @memcpy(new_values[0..g.values.len], g.values);
            new_values[g.values.len] = ev;
            g.values = new_values;
            break;
        }
    }
}

/// Parse a `<member>`, `<param>`, or `<proto>` element. The C declaration
/// for these is a mix of text and `<type>` / `<name>` / `<enum>` children;
/// we walk in order and use simple heuristics for `const`, pointer depth,
/// and array suffixes.
fn parseMemberLike(A: std.mem.Allocator, element: *const Element) !Member {
    var prefix: std.ArrayList(u8) = .empty;
    var middle: std.ArrayList(u8) = .empty;
    var suffix: std.ArrayList(u8) = .empty;
    var array_enum: ?[]const u8 = null;
    var name: []const u8 = "";
    var base: []const u8 = "";

    var phase: enum { before_type, after_type, after_name } = .before_type;

    for (element.children) |c| switch (c) {
        .text => |t| {
            switch (phase) {
                .before_type => try prefix.appendSlice(A, t),
                .after_type => try middle.appendSlice(A, t),
                .after_name => try suffix.appendSlice(A, t),
            }
        },
        .elem => |e| {
            if (std.mem.eql(u8, e.tag, "type")) {
                base = try e.directText(A);
                phase = .after_type;
            } else if (std.mem.eql(u8, e.tag, "name")) {
                name = try e.directText(A);
                phase = .after_name;
            } else if (std.mem.eql(u8, e.tag, "enum")) {
                array_enum = try e.directText(A);
            } else if (std.mem.eql(u8, e.tag, "comment")) {
                // ignore
            }
        },
    };

    const all_pre = prefix.items;
    const all_mid = middle.items;
    const all_suf = suffix.items;

    const c_type = try classifyCType(A, base, all_pre, all_mid, all_suf, array_enum);

    var len: ?[]const u8 = null;
    if (element.attr("len")) |l| len = try A.dupe(u8, l);
    var values: ?[]const u8 = null;
    if (element.attr("values")) |v| values = try A.dupe(u8, v);
    const optional = blk: {
        const opt_attr = element.attr("optional") orelse break :blk false;
        // Vulkan uses "true,false" for optional list params; first segment is for outermost pointer.
        var it = std.mem.splitScalar(u8, opt_attr, ',');
        const first = it.next() orelse break :blk false;
        break :blk std.mem.eql(u8, first, "true");
    };

    return .{
        .name = name,
        .c_type = c_type,
        .optional = optional,
        .len = len,
        .values = values,
    };
}

fn classifyCType(
    A: std.mem.Allocator,
    base: []const u8,
    pre: []const u8,
    mid: []const u8,
    suf: []const u8,
    array_enum: ?[]const u8,
) !CType {
    var ct: CType = .{ .base = try A.dupe(u8, base) };

    // const qualifier — `const T`, `const T*`, or `const struct …`.
    if (std.mem.indexOf(u8, pre, "const") != null) ct.is_const = true;
    if (std.mem.indexOf(u8, mid, "const") != null) ct.is_inner_const = true;

    // Pointer depth — count '*' characters in pre+mid+suf.
    var stars: u8 = 0;
    for (pre) |b| if (b == '*') {
        stars += 1;
    };
    for (mid) |b| if (b == '*') {
        stars += 1;
    };
    for (suf) |b| if (b == '*') {
        stars += 1;
    };
    ct.pointer_depth = stars;

    // Array suffix in `suf` — either `[16]` (text) or `[<enum>VK_X</enum>]`
    // captured separately as `array_enum`.
    if (array_enum) |en| {
        ct.array_size = try A.dupe(u8, en);
    } else if (std.mem.indexOfScalar(u8, suf, '[')) |open| {
        if (std.mem.indexOfScalarPos(u8, suf, open + 1, ']')) |close| {
            const num = std.mem.trim(u8, suf[open + 1 .. close], " \t");
            if (num.len > 0) ct.array_size = try A.dupe(u8, num);
        }
    }

    return ct;
}

/// Vulkan SC ships its own variants of some types/commands tagged via
/// `api="vulkansc"`. The S2 generator only targets desktop Vulkan, so anything
/// that is *not* claimed by `vulkan` or `vulkanbase` is dropped.
fn apiMatches(api: []const u8) bool {
    var it = std.mem.splitScalar(u8, api, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, trimmed, "vulkan") or std.mem.eql(u8, trimmed, "vulkanbase")) return true;
    }
    return false;
}

fn writeFlattened(elem: *const Element, A: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    for (elem.children) |c| switch (c) {
        .text => |t| try out.appendSlice(A, t),
        .elem => |e| {
            try writeFlattened(&e, A, out);
        },
    };
}

fn splitCsv(A: std.mem.Allocator, src: []const u8) ![][]const u8 {
    if (src.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        try out.append(A, try A.dupe(u8, trimmed));
    }
    return try out.toOwnedSlice(A);
}

// =====================================================================
// Whitelist application
// =====================================================================

/// Caller-supplied scope of the S2 spike's Vulkan surface. Drives
/// `applyWhitelist` to drop every feature / extension outside that
/// scope plus the transitive closure of their types.
pub const Whitelist = struct {
    /// Feature names that are kept (e.g. `VK_BASE_VERSION_1_0`,
    /// `VK_GRAPHICS_VERSION_1_3`).
    features: []const []const u8,
    /// Extension names (e.g. `VK_KHR_surface`).
    extensions: []const []const u8,
    /// Platforms allowed. Extensions tagged with a `platform` not in this
    /// list are skipped.
    platforms: []const []const u8,
};

/// Whitelist-trimmed projection of `Model`. Same shape as `Model`
/// but only the kept entities plus the closure they pull in. Owns
/// its own arena so the input `Model` can be freed once the filter
/// returns.
pub const FilteredModel = struct {
    arena: std.heap.ArenaAllocator,

    /// Names of each entity that survived the whitelist + transitive
    /// closure pass. Order is stable.
    handles: []const Handle,
    enum_groups: []const EnumGroup,
    bitmasks: []const Bitmask,
    structs: []const Struct,
    unions: []const Struct,
    funcpointers: []const FuncPointer,
    basetypes: []const Basetype,
    platform_types: []const PlatformType,
    aliases: []const Alias,
    api_constants: []const ApiConstant,
    commands: []const Command,
    /// Ordered list of platform-conditional extension command sets — used
    /// by the emitter to wrap with `if (builtin.os.tag …)`.
    extensions: []const Extension,

    pub fn deinit(self: *FilteredModel) void {
        self.arena.deinit();
    }

    pub fn findHandle(self: FilteredModel, name: []const u8) ?*const Handle {
        for (self.handles) |*h| if (std.mem.eql(u8, h.name, name)) return h;
        return null;
    }

    pub fn isHandle(self: FilteredModel, name: []const u8) bool {
        return self.findHandle(name) != null;
    }
};

/// Third stage of the vk_gen pipeline: trim `Model` down to the
/// `Whitelist` scope plus the transitive closure of types each kept
/// command / struct depends on. Skipping the closure would leave
/// `Command` parameters referencing types that were filtered out.
pub fn applyWhitelist(
    gpa: std.mem.Allocator,
    model: Model,
    whitelist: Whitelist,
    tree: Tree,
) !FilteredModel {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const A = arena.allocator();

    // Sets of needed names (use string -> void hashmaps as sets).
    var needed_types: std.StringHashMapUnmanaged(void) = .empty;
    var needed_commands: std.StringHashMapUnmanaged(void) = .empty;

    // Walk feature blocks in tree and collect items belonging to whitelisted
    // features.
    for (tree.root.children) |child| {
        if (child != .elem or !std.mem.eql(u8, child.elem.tag, "feature")) continue;
        const fname = child.elem.attr("name") orelse continue;
        if (!stringInList(fname, whitelist.features)) continue;
        try collectFromRequires(A, &child.elem, &needed_types, &needed_commands);
    }

    // Walk extensions.
    if (tree.root.firstChild("extensions")) |exts| {
        for (exts.children) |child| {
            if (child != .elem or !std.mem.eql(u8, child.elem.tag, "extension")) continue;
            const xname = child.elem.attr("name") orelse continue;
            if (!stringInList(xname, whitelist.extensions)) continue;
            const platform = child.elem.attr("platform");
            if (platform) |p| {
                if (!stringInList(p, whitelist.platforms)) continue;
            }
            try collectFromRequires(A, &child.elem, &needed_types, &needed_commands);
        }
    }

    // Closure: walk through types and commands and pull in their type refs.
    try closeOverTypes(A, model, &needed_types, &needed_commands);

    // Collect filtered objects in the original declaration order.
    var handles: std.ArrayList(Handle) = .empty;
    for (model.handles) |h| if (needed_types.contains(h.name)) try handles.append(A, h);

    var basetypes: std.ArrayList(Basetype) = .empty;
    for (model.basetypes) |b| if (needed_types.contains(b.name)) try basetypes.append(A, b);

    var platform_types: std.ArrayList(PlatformType) = .empty;
    for (model.platform_types) |pt| if (needed_types.contains(pt.name)) try platform_types.append(A, pt);

    // M0.4 — whitelist closure étendue aux variants d'enum (brief
    // §Scope D-S2-vk-whitelist). Filtre `EnumGroup.values` par
    // `source` : on garde les variants du base enum (`source == ""`),
    // ceux ajoutés par les features core (`source == "core"`, on ne
    // distingue pas les minor versions Phase 0), et ceux ajoutés par
    // les extensions whitelistées. Les variants des extensions hors
    // whitelist (centaines de bits pour VkStructureType, VkFormat,
    // VkAccessFlagBits2, etc.) sont droppés — c'est le principal levier
    // de réduction de lignes.
    var enum_groups: std.ArrayList(EnumGroup) = .empty;
    for (model.enum_groups) |g| {
        if (!needed_types.contains(g.name)) continue;
        var kept_values: std.ArrayList(EnumValue) = .empty;
        for (g.values) |v| {
            if (variantInWhitelist(v.source, whitelist)) {
                try kept_values.append(A, v);
            }
        }
        try enum_groups.append(A, .{
            .name = g.name,
            .kind = g.kind,
            .bit_width = g.bit_width,
            .values = try kept_values.toOwnedSlice(A),
        });
    }

    var bitmasks: std.ArrayList(Bitmask) = .empty;
    for (model.bitmasks) |bm| if (needed_types.contains(bm.name)) try bitmasks.append(A, bm);

    var structs: std.ArrayList(Struct) = .empty;
    for (model.structs) |s| if (needed_types.contains(s.name)) try structs.append(A, s);

    var unions: std.ArrayList(Struct) = .empty;
    for (model.unions) |u| if (needed_types.contains(u.name)) try unions.append(A, u);

    var funcpointers: std.ArrayList(FuncPointer) = .empty;
    for (model.funcpointers) |f| if (needed_types.contains(f.name)) try funcpointers.append(A, f);

    var aliases: std.ArrayList(Alias) = .empty;
    for (model.aliases) |a| if (needed_types.contains(a.name)) try aliases.append(A, a);

    // Always include API constants — they're cheap and often referenced
    // implicitly via array suffixes.
    var api_constants: std.ArrayList(ApiConstant) = .empty;
    for (model.api_constants) |c| try api_constants.append(A, c);

    var commands: std.ArrayList(Command) = .empty;
    for (model.commands) |c| if (needed_commands.contains(c.name)) try commands.append(A, c);

    var ext_keep: std.ArrayList(Extension) = .empty;
    for (model.extensions) |ext| {
        if (!stringInList(ext.name, whitelist.extensions)) continue;
        if (ext.platform) |p| if (!stringInList(p, whitelist.platforms)) continue;
        try ext_keep.append(A, ext);
    }

    return .{
        .arena = arena,
        .handles = try handles.toOwnedSlice(A),
        .enum_groups = try enum_groups.toOwnedSlice(A),
        .bitmasks = try bitmasks.toOwnedSlice(A),
        .structs = try structs.toOwnedSlice(A),
        .unions = try unions.toOwnedSlice(A),
        .funcpointers = try funcpointers.toOwnedSlice(A),
        .basetypes = try basetypes.toOwnedSlice(A),
        .platform_types = try platform_types.toOwnedSlice(A),
        .aliases = try aliases.toOwnedSlice(A),
        .api_constants = try api_constants.toOwnedSlice(A),
        .commands = try commands.toOwnedSlice(A),
        .extensions = try ext_keep.toOwnedSlice(A),
    };
}

fn stringInList(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// M0.4 — détermine si un variant d'enum doit être gardé par le filtre
/// whitelist. Règles (cf. brief §Scope D-S2-vk-whitelist) :
/// - `source == ""` : variant du base enum (pas via feature/extension) → keep
/// - `source == "core"` : variant ajouté par une feature core (1.0-1.3) → keep
///   (on ne discrimine pas par minor Phase 0 — toutes les versions core sont
///   dans la whitelist Phase 0).
/// - autre : variant ajouté par une extension nommée → keep iff l'extension
///   est dans `whitelist.extensions`.
fn variantInWhitelist(source: []const u8, whitelist: Whitelist) bool {
    if (source.len == 0) return true;
    if (std.mem.eql(u8, source, "core")) return true;
    return stringInList(source, whitelist.extensions);
}

fn collectFromRequires(
    A: std.mem.Allocator,
    elem: *const Element,
    needed_types: *std.StringHashMapUnmanaged(void),
    needed_commands: *std.StringHashMapUnmanaged(void),
) !void {
    for (elem.children) |child| {
        if (child != .elem or !std.mem.eql(u8, child.elem.tag, "require")) continue;
        for (child.elem.children) |item| {
            if (item != .elem) continue;
            const tag = item.elem.tag;
            const nm = item.elem.attr("name") orelse continue;
            if (std.mem.eql(u8, tag, "type")) {
                _ = try needed_types.getOrPut(A, try A.dupe(u8, nm));
            } else if (std.mem.eql(u8, tag, "command")) {
                _ = try needed_commands.getOrPut(A, try A.dupe(u8, nm));
            } else if (std.mem.eql(u8, tag, "enum")) {
                // Also pull in the extends-target so the enum block is emitted.
                if (item.elem.attr("extends")) |ext| {
                    _ = try needed_types.getOrPut(A, try A.dupe(u8, ext));
                }
            }
        }
    }
}

fn closeOverTypes(
    A: std.mem.Allocator,
    model: Model,
    needed_types: *std.StringHashMapUnmanaged(void),
    needed_commands: *std.StringHashMapUnmanaged(void),
) !void {
    var changed = true;
    var iterations: u32 = 0;
    while (changed and iterations < 32) {
        changed = false;
        iterations += 1;

        // Resolve aliases: if X is an alias of Y and X is needed, Y is needed.
        for (model.aliases) |a| {
            if (needed_types.contains(a.name) and !needed_types.contains(a.target)) {
                _ = try needed_types.getOrPut(A, a.target);
                changed = true;
            }
        }

        // Bitmask flag-typedefs reference an enum group.
        for (model.bitmasks) |bm| {
            if (needed_types.contains(bm.name)) {
                if (bm.requires_enum) |req| {
                    if (!needed_types.contains(req)) {
                        _ = try needed_types.getOrPut(A, req);
                        changed = true;
                    }
                }
            }
        }

        // Structs: pull in member types.
        for (model.structs) |s| {
            if (!needed_types.contains(s.name)) continue;
            for (s.members) |m| {
                if (!needed_types.contains(m.c_type.base)) {
                    _ = try needed_types.getOrPut(A, m.c_type.base);
                    changed = true;
                }
            }
        }
        for (model.unions) |s| {
            if (!needed_types.contains(s.name)) continue;
            for (s.members) |m| {
                if (!needed_types.contains(m.c_type.base)) {
                    _ = try needed_types.getOrPut(A, m.c_type.base);
                    changed = true;
                }
            }
        }

        // Commands pull in their parameter types and return type.
        for (model.commands) |c| {
            if (!needed_commands.contains(c.name)) continue;
            // alias → keep target command and its types.
            if (c.alias_of) |target| {
                if (!needed_commands.contains(target)) {
                    _ = try needed_commands.getOrPut(A, target);
                    changed = true;
                }
                continue;
            }
            if (!needed_types.contains(c.return_type.base)) {
                _ = try needed_types.getOrPut(A, c.return_type.base);
                changed = true;
            }
            for (c.params) |p| {
                if (!needed_types.contains(p.c_type.base)) {
                    _ = try needed_types.getOrPut(A, p.c_type.base);
                    changed = true;
                }
            }
        }

        // Funcpointer types — we don't parse their inner types here, the
        // emitter passes the raw C declaration straight through.
    }
}

// ---------------------------------------------------------------- Tests --

test "parse a tiny document" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>
        \\  <foo a="1" b="two">hello</foo>
        \\  <bar/>
        \\  <mixed>start <inner>middle</inner> end</mixed>
        \\</root>
    ;
    var tree = try parse(std.testing.allocator, src);
    defer tree.deinit();

    try std.testing.expectEqualStrings("root", tree.root.tag);
    try std.testing.expectEqual(@as(usize, 0), tree.root.attrs.len);

    // Children: text, elem(foo), text, elem(bar), text, elem(mixed), text
    var elems: usize = 0;
    for (tree.root.children) |c| if (c == .elem) {
        elems += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), elems);

    const foo = tree.root.firstChild("foo").?;
    try std.testing.expectEqualStrings("1", foo.attr("a").?);
    try std.testing.expectEqualStrings("two", foo.attr("b").?);

    const mixed = tree.root.firstChild("mixed").?;
    // mixed should have text "start ", elem inner, text " end"
    var saw_text_start = false;
    var saw_inner = false;
    var saw_text_end = false;
    for (mixed.children) |c| switch (c) {
        .text => |t| {
            if (std.mem.indexOf(u8, t, "start") != null) saw_text_start = true;
            if (std.mem.indexOf(u8, t, "end") != null) saw_text_end = true;
        },
        .elem => |e| if (std.mem.eql(u8, e.tag, "inner")) {
            saw_inner = true;
        },
    };
    try std.testing.expect(saw_text_start);
    try std.testing.expect(saw_inner);
    try std.testing.expect(saw_text_end);
}

test "parse handles entity references" {
    const src =
        \\<root attr="a&amp;b">x &lt; y</root>
    ;
    var tree = try parse(std.testing.allocator, src);
    defer tree.deinit();
    try std.testing.expectEqualStrings("a&b", tree.root.attr("attr").?);
    var saw = false;
    for (tree.root.children) |c| switch (c) {
        .text => |t| if (std.mem.indexOf(u8, t, "x < y") != null) {
            saw = true;
        },
        .elem => {},
    };
    try std.testing.expect(saw);
}

test "parse a vk.xml-like member element" {
    const src =
        \\<member optional="true">const <type>void</type>* <name>pNext</name></member>
    ;
    var tree = try parse(std.testing.allocator, src);
    defer tree.deinit();
    const m = tree.root;
    try std.testing.expectEqualStrings("member", m.tag);
    try std.testing.expectEqualStrings("true", m.attr("optional").?);
    const ty = m.firstChild("type").?;
    const name = m.firstChild("name").?;
    const ty_text = try ty.directText(std.testing.allocator);
    defer std.testing.allocator.free(ty_text);
    const name_text = try name.directText(std.testing.allocator);
    defer std.testing.allocator.free(name_text);
    try std.testing.expectEqualStrings("void", ty_text);
    try std.testing.expectEqualStrings("pNext", name_text);
}
