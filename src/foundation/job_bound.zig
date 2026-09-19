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
        // NO PRE-TEST, AND THE LOOP DOES NOT STOP ON A SILENT FIELD. These two
        // arms used to gate on `carriesMarked(f.type)`, which walks with a FRESH
        // visited set, and then answer `reasonOfIn(f.type, next)`, which walks
        // with the CURRENT one. On a self-referential field the predicate said
        // yes through the cycle while the reason walk stopped ON the cycle and
        // answered `no_reason` — and the `break` abandoned every field after it,
        // so a marked sibling declared behind the recursive one was never read.
        // The refusal fired and explained nothing.
        //
        // Recursing per field with `next` and continuing past a field that has no
        // reason makes this arm the exact mirror of `carriesMarkedIn`'s, which is
        // what the contract two doc comments up demands: the two walk in step.
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                const r = reasonOfIn(f.type, next);
                if (!std.mem.eql(u8, r, no_reason)) break :blk r;
            }
            break :blk no_reason;
        },
        .@"union" => |un| blk: {
            inline for (un.fields) |f| {
                const r = reasonOfIn(f.type, next);
                if (!std.mem.eql(u8, r, no_reason)) break :blk r;
            }
            break :blk no_reason;
        },

        // EXHAUSTIVE, with no `else`, because `carriesMarkedIn` is — and the two
        // are required to walk in step. An `else` here would let a future kind be
        // given a decision in the predicate while this walk silently kept
        // answering `no_reason`: the divergence would compile, and a refusal that
        // explains nothing is what that costs. The compiler is what holds the
        // contract the doc states; leaving it to the doc is how the two parted
        // company the first time.
        .type, .void, .noreturn, .bool, .int, .float => no_reason,
        .comptime_float, .comptime_int, .undefined, .null, .enum_literal => no_reason,

        .error_set => no_reason,
        .@"enum" => no_reason,
        .@"fn" => no_reason,
        .@"opaque" => no_reason,
        .frame, .@"anyframe" => no_reason,
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

test "a cyclic field does not swallow a marked sibling behind it" {
    // `carriesMarked` walked with a FRESH visited set and `reasonOfIn` with the
    // CURRENT one, so on `link` the predicate said yes while the reason walk
    // stopped on the cycle and answered `no_reason` — and the `break` then
    // abandoned `m` entirely. The refusal fired and explained nothing.
    const Node = struct {
        link: ?*@This(),
        m: *MarkedProbe,
    };
    try std.testing.expect(carriesMarked(Node));
    try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(Node));

    // THE UNION ARM, carrying the identical defect and swept with it. Asserted
    // rather than assumed: the two arms are separate code, so a fix applied to
    // one only would pass the struct case above and leave this one blank.
    const Cyclic = union(enum) {
        link: ?*@This(),
        m: *MarkedProbe,
    };
    try std.testing.expect(carriesMarked(Cyclic));
    try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(Cyclic));

    // NOT COVERED, AND HARMLESS BY CONSTRUCTION. `no_reason` is a plain string,
    // so a marker whose declared reason is literally "no reason declared" reads
    // as absence and the walk keeps looking. The answer is still that string —
    // the marker's own text, verbatim — so nothing is misreported; only a later
    // field's reason may be preferred to it. Closing it would mean a sentinel the
    // public `no_reason` is not, for a collision that costs nothing.
}
