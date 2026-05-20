//! XML parser + Wayland-protocol model extractor for the S2 spike.
//! Throwaway in S3 (cf. `engine-c-bindings.md` §10.1).
//!
//! Wayland protocol XML format is far more regular than `vk.xml`:
//! `<protocol name="X">` containing `<interface name="X" version="N">`
//! containing `<request>`, `<event>`, and `<enum>` blocks. Each request
//! and event lists `<arg>` elements with a fixed set of types.

const std = @import("std");

// ============================================================== XML core =

const Attr = struct { name: []const u8, value: []const u8 };

const Element = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const Child,

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    pub fn elemChildren(self: Element, A: std.mem.Allocator, tag: []const u8) ![]const *const Element {
        var out: std.ArrayList(*const Element) = .empty;
        for (self.children) |*c| {
            if (c.* == .elem and std.mem.eql(u8, c.elem.tag, tag)) try out.append(A, &c.elem);
        }
        return try out.toOwnedSlice(A);
    }
};

const Child = union(enum) { elem: Element, text: []const u8 };

/// XML tree produced by `parse` and consumed by `extractProtocol`.
/// Owns an arena that backs every string slice — `tree.deinit()`
/// frees everything reachable through the tree and through any
/// `Protocol` extracted from it.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: Element,
    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }
};

const ParseError = error{ UnexpectedEof, UnexpectedChar, BadAttribute, UnterminatedTag, UnterminatedString, MismatchedClose, UnknownEntity } || std.mem.Allocator.Error;

/// First stage of the wayland_gen pipeline: scan a protocol `.xml`
/// file into a `Tree` of `Element`s. Pure XML lexer + recursive
/// descent — no Wayland-specific knowledge yet (that lives in
/// `extractProtocol`).
pub fn parse(gpa: std.mem.Allocator, source: []const u8) ParseError!Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p: Parser = .{ .src = source, .pos = 0, .arena = arena.allocator() };
    try p.skipProlog();
    if (!p.match('<')) return error.UnexpectedChar;
    const root = try p.parseElement();
    return .{ .arena = arena, .root = root };
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,

    fn peek(s: Parser) ?u8 {
        return if (s.pos < s.src.len) s.src[s.pos] else null;
    }
    fn match(s: *Parser, c: u8) bool {
        if (s.peek() != c) return false;
        s.pos += 1;
        return true;
    }
    fn matchSlice(s: *Parser, str: []const u8) bool {
        if (s.pos + str.len > s.src.len) return false;
        if (!std.mem.eql(u8, s.src[s.pos .. s.pos + str.len], str)) return false;
        s.pos += str.len;
        return true;
    }
    fn advance(s: *Parser) ?u8 {
        if (s.pos >= s.src.len) return null;
        defer s.pos += 1;
        return s.src[s.pos];
    }
    fn skipWs(s: *Parser) void {
        while (s.peek()) |c| switch (c) {
            ' ', '\t', '\r', '\n' => s.pos += 1,
            else => break,
        };
    }

    fn skipProlog(s: *Parser) ParseError!void {
        while (true) {
            s.skipWs();
            if (s.matchSlice("<?")) {
                while (s.advance()) |c| if (c == '?' and s.peek() == '>') {
                    s.pos += 1;
                    break;
                };
                continue;
            }
            if (s.matchSlice("<!--")) {
                while (s.pos + 3 <= s.src.len) : (s.pos += 1) {
                    if (std.mem.eql(u8, s.src[s.pos .. s.pos + 3], "-->")) {
                        s.pos += 3;
                        break;
                    }
                }
                continue;
            }
            return;
        }
    }

    fn parseElement(s: *Parser) ParseError!Element {
        const start = s.pos;
        while (s.peek()) |c| switch (c) {
            ' ', '\t', '\r', '\n', '/', '>' => break,
            else => s.pos += 1,
        };
        if (s.pos == start) return error.UnexpectedChar;
        const tag = s.src[start..s.pos];

        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            s.skipWs();
            const c = s.peek() orelse return error.UnterminatedTag;
            if (c == '/' or c == '>') break;
            const a = try s.parseAttr();
            try attrs.append(s.arena, a);
        }
        const self_closing = s.match('/');
        if (!s.match('>')) return error.UnterminatedTag;
        if (self_closing) return .{
            .tag = try s.arena.dupe(u8, tag),
            .attrs = try attrs.toOwnedSlice(s.arena),
            .children = &.{},
        };

        var children: std.ArrayList(Child) = .empty;
        var text_buf: std.ArrayList(u8) = .empty;
        while (true) {
            const c = s.peek() orelse return error.UnexpectedEof;
            if (c == '<') {
                if (text_buf.items.len > 0) {
                    try children.append(s.arena, .{ .text = try s.arena.dupe(u8, text_buf.items) });
                    text_buf.clearRetainingCapacity();
                }
                s.pos += 1;
                if (s.peek() == '/') {
                    s.pos += 1;
                    const cs = s.pos;
                    while (s.peek()) |cc| {
                        if (cc == '>' or cc == ' ' or cc == '\t' or cc == '\r' or cc == '\n') break;
                        s.pos += 1;
                    }
                    const ct = s.src[cs..s.pos];
                    if (!std.mem.eql(u8, ct, tag)) return error.MismatchedClose;
                    s.skipWs();
                    if (!s.match('>')) return error.UnterminatedTag;
                    return .{
                        .tag = try s.arena.dupe(u8, tag),
                        .attrs = try attrs.toOwnedSlice(s.arena),
                        .children = try children.toOwnedSlice(s.arena),
                    };
                }
                if (s.matchSlice("!--")) {
                    while (s.pos + 3 <= s.src.len) : (s.pos += 1) {
                        if (std.mem.eql(u8, s.src[s.pos .. s.pos + 3], "-->")) {
                            s.pos += 3;
                            break;
                        }
                    }
                    continue;
                }
                const child = try s.parseElement();
                try children.append(s.arena, .{ .elem = child });
            } else if (c == '&') {
                s.pos += 1;
                try text_buf.append(s.arena, try s.parseEntity());
            } else {
                try text_buf.append(s.arena, c);
                s.pos += 1;
            }
        }
    }

    fn parseAttr(s: *Parser) ParseError!Attr {
        const ns = s.pos;
        while (s.peek()) |c| switch (c) {
            '=', ' ', '\t', '\r', '\n', '/', '>' => break,
            else => s.pos += 1,
        };
        if (s.pos == ns) return error.BadAttribute;
        const name = s.src[ns..s.pos];
        s.skipWs();
        if (!s.match('=')) return error.BadAttribute;
        s.skipWs();
        const q = s.advance() orelse return error.BadAttribute;
        if (q != '"' and q != '\'') return error.BadAttribute;
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            const c = s.peek() orelse return error.UnterminatedString;
            if (c == q) {
                s.pos += 1;
                break;
            }
            if (c == '&') {
                s.pos += 1;
                try buf.append(s.arena, try s.parseEntity());
                continue;
            }
            try buf.append(s.arena, c);
            s.pos += 1;
        }
        return .{
            .name = try s.arena.dupe(u8, name),
            .value = try s.arena.dupe(u8, buf.items),
        };
    }

    fn parseEntity(s: *Parser) ParseError!u8 {
        if (s.matchSlice("lt;")) return '<';
        if (s.matchSlice("gt;")) return '>';
        if (s.matchSlice("amp;")) return '&';
        if (s.matchSlice("quot;")) return '"';
        if (s.matchSlice("apos;")) return '\'';
        return error.UnknownEntity;
    }
};

// =================================================== Wayland protocol model =

/// Top-level Wayland protocol entry consumed by `emit.zig`. Holds
/// the protocol name plus its full interface list, all string slices
/// borrowing the parent `Tree`'s arena.
pub const Protocol = struct {
    /// `<protocol name="X">`
    name: []const u8,
    interfaces: []const Interface,
};

/// One Wayland interface — requests, events, and locally-scoped
/// enums. Consumed by `emit.zig` to render the proxy struct, the
/// request methods, and the event listener vtable.
pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message,
    events: []const Message,
    enums: []const Enum,
};

const MessageKind = enum { request, event };

/// One request or event entry. `opcode` is the position inside the
/// owning interface's `requests` / `events` list (wire-protocol
/// dispatch index). `destructor=true` marks requests that finalise
/// the proxy — `emit.zig` ties them to the wrapper's deinit.
pub const Message = struct {
    name: []const u8,
    /// 0-based opcode within its kind (request or event).
    opcode: u32,
    /// `type="destructor"` flag for requests that destroy the proxy.
    destructor: bool = false,
    args: []const Arg,
    since: u32 = 1,
};

/// One message argument. The `enum_ref` field links back to a
/// scoped `Enum` so `emit.zig` can render typed parameters instead
/// of raw `u32`s where the protocol declares an enum.
pub const Arg = struct {
    name: []const u8,
    type: ArgType,
    /// Interface name for `object` / `new_id` args. `null` for `new_id`
    /// without explicit interface — that's the wl_registry.bind pattern
    /// where the type is determined by the runtime version negotiation.
    interface: ?[]const u8 = null,
    allow_null: bool = false,
    /// Enum reference: `enum="error"` or `enum="<iface>.<name>"`.
    enum_ref: ?[]const u8 = null,
};

const ArgType = enum {
    int,
    uint,
    fixed,
    string,
    object,
    new_id,
    array,
    fd,
};

const Enum = struct {
    name: []const u8,
    bitfield: bool = false,
    entries: []const EnumEntry,
};

const EnumEntry = struct {
    name: []const u8,
    value: u32,
};

/// Second stage of the wayland_gen pipeline: lift the raw XML `Tree`
/// into a typed `Protocol`. The returned slices reuse `tree.arena`
/// — the protocol must not outlive its source `Tree`.
pub fn extractProtocol(gpa: std.mem.Allocator, tree: *Tree) !Protocol {
    const A = tree.arena.allocator();
    _ = gpa;
    const r = tree.root;
    if (!std.mem.eql(u8, r.tag, "protocol")) return error.NotAProtocol;
    const name = r.attr("name") orelse return error.MissingProtocolName;

    var interfaces: std.ArrayList(Interface) = .empty;
    for (r.children) |c| {
        if (c != .elem) continue;
        if (!std.mem.eql(u8, c.elem.tag, "interface")) continue;
        try interfaces.append(A, try parseInterface(A, &c.elem));
    }
    return .{
        .name = try A.dupe(u8, name),
        .interfaces = try interfaces.toOwnedSlice(A),
    };
}

fn parseInterface(A: std.mem.Allocator, e: *const Element) !Interface {
    const name = e.attr("name") orelse return error.MissingInterfaceName;
    const version: u32 = if (e.attr("version")) |v| std.fmt.parseInt(u32, v, 10) catch 1 else 1;

    var requests: std.ArrayList(Message) = .empty;
    var events: std.ArrayList(Message) = .empty;
    var enums: std.ArrayList(Enum) = .empty;

    var req_idx: u32 = 0;
    var ev_idx: u32 = 0;
    for (e.children) |c| {
        if (c != .elem) continue;
        const tag = c.elem.tag;
        if (std.mem.eql(u8, tag, "request")) {
            try requests.append(A, try parseMessage(A, &c.elem, req_idx));
            req_idx += 1;
        } else if (std.mem.eql(u8, tag, "event")) {
            try events.append(A, try parseMessage(A, &c.elem, ev_idx));
            ev_idx += 1;
        } else if (std.mem.eql(u8, tag, "enum")) {
            try enums.append(A, try parseEnum(A, &c.elem));
        }
    }

    return .{
        .name = try A.dupe(u8, name),
        .version = version,
        .requests = try requests.toOwnedSlice(A),
        .events = try events.toOwnedSlice(A),
        .enums = try enums.toOwnedSlice(A),
    };
}

fn parseMessage(A: std.mem.Allocator, e: *const Element, opcode: u32) !Message {
    const name = e.attr("name") orelse return error.MissingMessageName;
    const destructor = if (e.attr("type")) |t| std.mem.eql(u8, t, "destructor") else false;
    const since: u32 = if (e.attr("since")) |s| std.fmt.parseInt(u32, s, 10) catch 1 else 1;

    var args: std.ArrayList(Arg) = .empty;
    for (e.children) |c| {
        if (c != .elem) continue;
        if (!std.mem.eql(u8, c.elem.tag, "arg")) continue;
        try args.append(A, try parseArg(A, &c.elem));
    }
    return .{
        .name = try A.dupe(u8, name),
        .opcode = opcode,
        .destructor = destructor,
        .args = try args.toOwnedSlice(A),
        .since = since,
    };
}

fn parseArg(A: std.mem.Allocator, e: *const Element) !Arg {
    const name = e.attr("name") orelse return error.MissingArgName;
    const type_str = e.attr("type") orelse return error.MissingArgType;

    const arg_type: ArgType = if (std.mem.eql(u8, type_str, "int"))
        .int
    else if (std.mem.eql(u8, type_str, "uint"))
        .uint
    else if (std.mem.eql(u8, type_str, "fixed"))
        .fixed
    else if (std.mem.eql(u8, type_str, "string"))
        .string
    else if (std.mem.eql(u8, type_str, "object"))
        .object
    else if (std.mem.eql(u8, type_str, "new_id"))
        .new_id
    else if (std.mem.eql(u8, type_str, "array"))
        .array
    else if (std.mem.eql(u8, type_str, "fd"))
        .fd
    else
        return error.UnknownArgType;

    return .{
        .name = try A.dupe(u8, name),
        .type = arg_type,
        .interface = if (e.attr("interface")) |i| try A.dupe(u8, i) else null,
        .allow_null = if (e.attr("allow-null")) |an| std.mem.eql(u8, an, "true") else false,
        .enum_ref = if (e.attr("enum")) |en| try A.dupe(u8, en) else null,
    };
}

fn parseEnum(A: std.mem.Allocator, e: *const Element) !Enum {
    const name = e.attr("name") orelse return error.MissingEnumName;
    const bitfield = if (e.attr("bitfield")) |b| std.mem.eql(u8, b, "true") else false;

    var entries: std.ArrayList(EnumEntry) = .empty;
    for (e.children) |c| {
        if (c != .elem) continue;
        if (!std.mem.eql(u8, c.elem.tag, "entry")) continue;
        const en = c.elem.attr("name") orelse continue;
        const ev = c.elem.attr("value") orelse continue;
        // Wayland values can be hex (`0x1`), decimal, or empty for aliases.
        const val: u32 = if (std.mem.startsWith(u8, ev, "0x"))
            std.fmt.parseInt(u32, ev[2..], 16) catch continue
        else
            std.fmt.parseInt(u32, ev, 10) catch continue;
        try entries.append(A, .{
            .name = try A.dupe(u8, en),
            .value = val,
        });
    }
    return .{
        .name = try A.dupe(u8, name),
        .bitfield = bitfield,
        .entries = try entries.toOwnedSlice(A),
    };
}
