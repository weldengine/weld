//! Types a dispatched job body must never receive — declared BY the type,
//! tested by a tier-agnostic comptime predicate. Declaring the marker makes the
//! guard available, not called: an entry that never calls it is still open.

const std = @import("std");

/// The declaration a type adds to refuse reaching a dispatched job body. Its
/// VALUE is the reason, a `[]const u8`; declaring this name with any other type
/// is a contract breach and fails loudly where the reason is read.
pub const marker_decl_name = "weld_no_job_body";

/// Whether `T` itself carries the marker. False for every non-container type,
/// since `@hasDecl` is only defined on containers.
pub inline fn declaresMarker(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, marker_decl_name),
        else => false,
    };
}

/// Whether `T` reaches a marked type: itself, or through any pointer, slice,
/// optional, array, vector, error union, or struct/union field. Carries no
/// `comptime {}` block — one would force every CALL into a comptime context.
pub fn carriesMarked(comptime T: type) bool {
    return carriesMarkedIn(T, &[_]type{});
}

/// The walk, carrying the types already on the stack so a self-referential type
/// terminates. The `switch` is exhaustive with NO `else`, so a form Zig adds
/// later is a compile error here rather than a silent `false` — an `else` once
/// let `anyerror!*CommandBuffer` through.
///
/// `.@"fn" => false` is not an oversight: receiving `fn (*CommandBuffer) void`
/// hands the body no buffer. It would need one to call it, and that one arrives
/// through a field this walk does see.
///
/// The branch quota is raised rather than the walk depth-bounded — a depth
/// bound is a rule applied to a subset of what it must cover.
fn carriesMarkedIn(comptime T: type, comptime seen: []const type) bool {
    @setEvalBranchQuota(100_000);
    inline for (seen) |s| {
        if (s == T) return false;
    }
    if (declaresMarker(T)) return true;
    const next = seen ++ [_]type{T};
    return switch (@typeInfo(T)) {
        .pointer => |p| carriesMarkedIn(p.child, next),
        .optional => |o| carriesMarkedIn(o.child, next),
        .array => |a| carriesMarkedIn(a.child, next),
        .error_union => |eu| carriesMarkedIn(eu.payload, next),
        .vector => |v| carriesMarkedIn(v.child, next),
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (carriesMarkedIn(f.type, next)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |un| blk: {
            inline for (un.fields) |f| {
                if (carriesMarkedIn(f.type, next)) break :blk true;
            }
            break :blk false;
        },

        .type, .void, .noreturn, .bool, .int, .float => false,
        .comptime_float, .comptime_int, .undefined, .null, .enum_literal => false,

        .error_set => false,
        .@"enum" => false,
        .@"fn" => false,
        .@"opaque" => false,
        .frame, .@"anyframe" => false,
    };
}

/// Fail to compile if any field of the argument tuple `ArgsType` carries a
/// marked type. Every entry handing an argument tuple to a body a worker pool
/// runs must call it.
pub fn refuseMarkedArgs(comptime ArgsType: type) void {
    comptime {
        const info = @typeInfo(ArgsType);
        const fields = switch (info) {
            .@"struct" => |st| st.fields,
            else => return,
        };
        for (fields) |f| {
            if (carriesMarked(f.type)) @compileError(
                "argument of type `" ++ @typeName(f.type) ++
                    "` reaches a dispatched body, and its type refuses that: " ++
                    reasonOf(f.type),
            );
        }
    }
}

/// The reason a marked type gives for its own refusal. Walks in step with
/// `carriesMarkedIn` — widening either means widening both. `pub` because its
/// only other consumer raises a `@compileError` no test can read.
pub fn reasonOf(comptime T: type) []const u8 {
    return reasonOfIn(T, &[_]type{});
}

fn reasonOfIn(comptime T: type, comptime seen: []const type) []const u8 {
    @setEvalBranchQuota(100_000);
    inline for (seen) |s| {
        if (s == T) return no_reason;
    }
    if (declaresMarker(T)) return @field(T, marker_decl_name);
    const next = seen ++ [_]type{T};
    return switch (@typeInfo(T)) {
        .pointer => |p| reasonOfIn(p.child, next),
        .optional => |o| reasonOfIn(o.child, next),
        .array => |a| reasonOfIn(a.child, next),
        .error_union => |eu| reasonOfIn(eu.payload, next),
        .vector => |v| reasonOfIn(v.child, next),
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (carriesMarked(f.type)) break :blk reasonOfIn(f.type, next);
            }
            break :blk no_reason;
        },
        .@"union" => |un| blk: {
            inline for (un.fields) |f| {
                if (carriesMarked(f.type)) break :blk reasonOfIn(f.type, next);
            }
            break :blk no_reason;
        },
        else => no_reason,
    };
}

/// What `reasonOf` answers when no marker is reachable.
pub const no_reason = "no reason declared";

/// Test probe. Its reason is unique in this file, so a test reading it cannot
/// be satisfied by an accidental match.
const MarkedProbe = struct {
    pub const weld_no_job_body: []const u8 = "the probe refuses, and says so";
    x: u32 = 0,
};

test "the reason survives every composite the refusal walks" {
    const cases = .{
        MarkedProbe,
        *MarkedProbe,
        **MarkedProbe,
        ?*MarkedProbe,
        [3]MarkedProbe,
        @Vector(4, *MarkedProbe),
        anyerror!*MarkedProbe,
        struct { m: *MarkedProbe, stride: usize },
        union(enum) { a: usize, m: *MarkedProbe },
        struct { inner: struct { m: MarkedProbe } },
        [2]?*MarkedProbe,
    };
    inline for (cases) |T| {
        try std.testing.expect(carriesMarked(T));
        try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(T));
    }
}

test "a type that refuses nothing reports no reason, and the two agree" {
    const clean = .{
        u32,
        *u32,
        struct { stride: usize, name: []const u8 },
        union(enum) { a: usize, b: bool },
        [4]f32,
        anyerror!void,
    };
    inline for (clean) |T| {
        try std.testing.expect(!carriesMarked(T));
        try std.testing.expectEqualStrings(no_reason, reasonOf(T));
    }
}

test "a marked field is not shadowed by a silent sibling declared before it" {
    const Shadowed = struct { quiet: struct { n: usize }, m: *MarkedProbe };
    try std.testing.expect(carriesMarked(Shadowed));
    try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(Shadowed));
}

test "the production shape is the one that used to be blank" {
    const Ctx = struct { cmd: *MarkedProbe, tick: u64, frame: ?*anyopaque };
    try std.testing.expect(carriesMarked(Ctx));
    try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(Ctx));
}
