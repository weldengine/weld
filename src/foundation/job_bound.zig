//! Types a dispatched job body must never receive — declared BY the type,
//! tested by a tier-agnostic comptime predicate.
//!
//! **Why this lives in `foundation` and not beside the type it refuses.**
//! `engine-ecs-internals.md` §7 states an absolute: no job body receives a
//! command buffer. The refusal sits on the TYPE rather than beside one dispatch
//! entry, because a guard at one entry leaves every other entry open. But
//! placement on the type only makes the guard AVAILABLE; it does not make an
//! entry CALL it, and a dispatch entry added without that call has the hole
//! back.
//!
//! Closing that by importing `ecs/command_buffer.zig` from `src/core/jobs/`
//! is refused: `command_buffer.zig` imports `world.zig`, so
//! the job tier would acquire the whole World in its graph to guard an entry no
//! production path uses. The existing `jobs/scheduler.zig` -> `ecs/archetype.zig`
//! import is NOT a precedent for that — `archetype.zig` imports `chunk`,
//! `registry`, `entity`, `tick` and `change_detection`, and no `world.zig`.
//!
//! So the dependency inverts one notch further: the type
//! declares its own refusal and the predicate interrogates the type it is
//! handed. `src/core/jobs/` imports nothing from the ECS for this — it already
//! imports `foundation` for the float environment — and the guard becomes
//! reachable from any tier without moving a single import edge.
//!
//! The walk follows EVERY composite — pointer, array, vector, optional, error
//! union, and each field of a struct or union — so `**T`, `[3]T` and a marked
//! type buried in a caller's own struct are all caught. Anything narrower is a
//! rule applied to a subset of what it must cover, which is the shape
//! `carriesMarkedIn` states at its own site.

const std = @import("std");

/// The declaration a type adds to refuse reaching a dispatched job body.
///
/// Its VALUE is the reason, a `[]const u8`, so a type that refuses also says
/// why. A type declaring this name with any other type is a contract breach and
/// fails loudly where the reason is read.
///
/// **The reason travels exactly as far as the refusal**, and that is a property
/// to preserve rather than a happy state: the two walks answer two halves of one
/// question, and for a whole milestone they disagreed — `reasonOf` followed only
/// pointers and optionals while `carriesMarkedIn` entered every composite, so a
/// marker reached through a struct field refused correctly and reported
/// `"no reason declared"`, `SystemContext` included. Widening one without the
/// other is what produced it, and the shared form is what prevents it
/// returning.
pub const marker_decl_name = "weld_no_job_body";

/// Whether `T` itself carries the marker. False for every non-container type,
/// since `@hasDecl` is only defined on containers.
pub inline fn declaresMarker(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, marker_decl_name),
        else => false,
    };
}

/// Whether `T` reaches a marked type at all: itself, or through any number of
/// pointers, slices, optionals, arrays, vectors, error unions, and struct or
/// union fields. A marked type buried inside a caller's own struct IS caught —
/// the shape is not hypothetical, `SystemContext` carries `cmd: *CommandBuffer`
/// as a field — and the walk's own doc below carries the reason.
/// The `comptime T: type` parameter is what makes this comptime-decidable; the
/// body deliberately carries NO `comptime {}` block, because such a block
/// forces every CALL into a comptime return context and a test asserting the
/// predicate at runtime then fails to compile. `refuseMarkedArgs` below keeps
/// its own block, where the compile error is actually raised.
pub fn carriesMarked(comptime T: type) bool {
    return carriesMarkedIn(T, &[_]type{});
}

/// The walk, carrying the types already on the stack so a self-referential type
/// terminates.
///
/// **Fully recursive, and that is the point rather than an extra.** The earlier
/// form stopped at one pointer level and never entered a struct, and its doc
/// justified the omission "for a shape no call site has" — while
/// `src/core/ecs/scheduler.zig:223` carries `cmd: *CommandBuffer` as a FIELD of
/// `SystemContext`, in the very file the bound guards. A justification that is
/// false inside what it protects is the costliest kind: it survives review by
/// resembling an argument. Widening only to struct fields would have repeated
/// the class this reprise exists to close — a rule applied to a subset of what
/// it must cover — so every composite is followed.
///
/// The widening is a widening of a REFUSAL, so its direction is safe; the
/// 21-case differential B2 measured is re-run and every case that flips is
/// named in the milestone's journal rather than discovered later.
fn carriesMarkedIn(comptime T: type, comptime seen: []const type) bool {
    // A real argument type reaches deep graphs — `*World` alone is hundreds of
    // fields — and the walk runs at EVERY guarded call site, so the default
    // 1000-branch quota is not enough. Raised rather than depth-bounded: a
    // depth bound would reintroduce the class this fix closes, a rule applied
    // to a subset of what it must cover.
    @setEvalBranchQuota(100_000);
    inline for (seen) |s| {
        if (s == T) return false; // already on the stack: a cycle, not a hit
    }
    if (declaresMarker(T)) return true;
    const next = seen ++ [_]type{T};
    // EXHAUSTIVE OVER `std.builtin.Type`, WITH NO `else`. An `else => false`
    // over an enumeration of forms is the same signature as the one-level
    // predicate P1-5 closed, and it cost one: `.error_union` fell through it, so
    // `anyerror!*CommandBuffer` passed the bound and a worker recovered the
    // pointer with a `catch`. Derived rather than extended — the day Zig adds a
    // form, this switch is a compile error here instead of a silent `false`.
    //
    // Seven forms carry a nested type and are FOLLOWED; the other seventeen
    // state their reason at the prong.
    return switch (@typeInfo(T)) {
        // Followed.
        .pointer => |p| carriesMarkedIn(p.child, next),
        .optional => |o| carriesMarkedIn(o.child, next),
        .array => |a| carriesMarkedIn(a.child, next),
        .error_union => |eu| carriesMarkedIn(eu.payload, next),
        // A vector element may be a POINTER, so `@Vector(4, *CommandBuffer)` is
        // expressible and reaches a body as data.
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

        // Carry no nested type at all: there is nothing to follow.
        .type, .void, .noreturn, .bool, .int, .float => false,
        .comptime_float, .comptime_int, .undefined, .null, .enum_literal => false,

        // A set of error NAMES, no payload.
        .error_set => false,
        // The tag type is an integer; no user type is reachable as data.
        .@"enum" => false,
        // A function TYPE and not data: receiving `fn (*CommandBuffer) void`
        // gives a body no buffer to record into. It would need one to call it,
        // and that one reaches it through a field this walk does see.
        .@"fn" => false,
        // Declares no fields by definition — nothing to traverse.
        .@"opaque" => false,
        // Zig's async surface is unused in this language version and neither
        // form appears in the repository. If one ever does, the absence of an
        // `else` above is what will say so.
        .frame, .@"anyframe" => false,
    };
}

/// Fail to compile if any field of the argument tuple `ArgsType` carries a
/// marked type.
///
/// Called by every entry that hands an argument tuple to a body a worker pool
/// runs. A tokenizer cannot see a type — it would flag a NAME — so a lint rule
/// would carry a heuristic's false positives and, worse, its false negatives.
/// Here the check is exact.
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

/// The reason a marked type gives for its own refusal, read off the marker.
///
/// **Its walk is the SAME walk as `carriesMarkedIn`'s, and keeping the two in
/// step is the whole contract.** They answer two halves of one question — does
/// this type refuse, and why — so a form followed by one and not the other
/// produces a refusal that explains nothing. That is what this used to be: it
/// followed pointers and optionals while the predicate entered every composite,
/// so a marker reached through a struct FIELD refused correctly and reported
/// `"no reason declared"` — including `SystemContext`, whose
/// `cmd: *CommandBuffer` is the exact shape the predicate's walk was widened
/// for. The diagnostic was blank in the one case the guard exists to serve.
///
/// A branch is entered only when `carriesMarked` says the marker is down it, so
/// the FIRST reason reached is returned and a sibling field's silence never
/// shadows it. The two walks are therefore not merely similar in shape: this one
/// is driven by the other's answer.
///
/// `pub` because a reason no one can read is not a reason. Its only other
/// consumer raises a `@compileError`, which no test can assert at runtime, so
/// without this the diagnostic's CONTENT would be unverifiable — and an
/// unverifiable diagnostic is how this one came to be blank for a whole
/// milestone without a test noticing.
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
    // The SEVEN forms `carriesMarkedIn` follows, and no others. Written as the
    // same list rather than as a catch-all: a form this misses is a blank
    // diagnostic, which reads as "the type declared no reason" and not as "the
    // walk stopped" — the two are indistinguishable at the call site, which is
    // why they were allowed to diverge in the first place.
    return switch (@typeInfo(T)) {
        .pointer => |p| reasonOfIn(p.child, next),
        .optional => |o| reasonOfIn(o.child, next),
        .array => |a| reasonOfIn(a.child, next),
        .error_union => |eu| reasonOfIn(eu.payload, next),
        .vector => |v| reasonOfIn(v.child, next),
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                // Gated on the PREDICATE, not attempted and discarded: entering
                // the first field regardless would return its `no_reason` and
                // shadow a marked field behind it.
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

/// What `reasonOf` answers when no marker is reachable. Named rather than
/// repeated, so a test can pin the negative against the same bytes the
/// production path emits.
pub const no_reason = "no reason declared";

// ─── The reason travels as far as the refusal ──────────────────────────────

/// A marked probe carrying a reason distinguishable from every other string
/// here, so a test that reads it cannot be satisfied by an accident.
const MarkedProbe = struct {
    pub const weld_no_job_body: []const u8 = "the probe refuses, and says so";
    x: u32 = 0,
};

test "the reason survives every composite the refusal walks" {
    // FORM BY FORM, and the list is the switch's own. The predicate followed
    // seven forms and the reason followed two, so five of these answered
    // `no_reason` while refusing correctly — a refusal that explains nothing in
    // the one case the guard exists to serve.
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
        // Nested one more level, so the answer cannot come from a single hop.
        struct { inner: struct { m: MarkedProbe } },
        [2]?*MarkedProbe,
    };
    inline for (cases) |T| {
        // The two halves asserted TOGETHER: a reason on a type that does not
        // refuse would be as wrong as a refusal with no reason.
        try std.testing.expect(carriesMarked(T));
        try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(T));
    }
}

test "a type that refuses nothing reports no reason, and the two agree" {
    // THE NEGATIVE HALF. Without it, "the reason is found" would pass a
    // `reasonOf` that returned the probe's string unconditionally — a guard has
    // two ways of being wrong and only one is usually tested.
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
    // The struct arm enters a field only when the PREDICATE says the marker is
    // down it. Entering the first field regardless would answer `no_reason`
    // here — the marked field sits second, behind one that carries nothing, and
    // that ordering is the whole case.
    const Shadowed = struct { quiet: struct { n: usize }, m: *MarkedProbe };
    try std.testing.expect(carriesMarked(Shadowed));
    try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(Shadowed));
}

test "the production shape is the one that used to be blank" {
    // `SystemContext` carries `cmd: *CommandBuffer` as a FIELD, which is the
    // shape the predicate's walk was widened for and the one whose diagnostic
    // stayed empty. Reproduced structurally rather than imported: `foundation`
    // sits below the ECS and cannot reach `SystemContext`, and a probe of the
    // same SHAPE is what the walk actually decides on.
    const Ctx = struct { cmd: *MarkedProbe, tick: u64, frame: ?*anyopaque };
    try std.testing.expect(carriesMarked(Ctx));
    try std.testing.expectEqualStrings(MarkedProbe.weld_no_job_body, reasonOf(Ctx));
}
