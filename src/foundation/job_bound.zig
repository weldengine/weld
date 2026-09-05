//! Types a dispatched job body must never receive — declared BY the type,
//! tested by a tier-agnostic comptime predicate.
//!
//! **Why this lives in `foundation` and not beside the type it refuses.**
//! `engine-ecs-internals.md` §7 states an absolute: no job body receives a
//! command buffer. M1.B/G8 put that refusal on the TYPE rather than beside one
//! dispatch entry, because a guard at one entry is the defect shape that
//! milestone kept meeting. But placement on the type only makes the guard
//! AVAILABLE; it does not make an entry CALL it — and M1.B/G10 measured a
//! fourth arg-passing dispatch entry, `jobs.Scheduler.dispatch`, that did not.
//!
//! Closing that by importing `ecs/command_buffer.zig` from `src/core/jobs/`
//! was refused on a measurement: `command_buffer.zig` imports `world.zig`, so
//! the job tier would acquire the whole World in its graph to guard an entry no
//! production path uses. The existing `jobs/scheduler.zig` -> `ecs/archetype.zig`
//! import is NOT a precedent for that — `archetype.zig` imports `chunk`,
//! `registry`, `entity`, `tick` and `change_detection`, and no `world.zig`.
//!
//! So the dependency inverts one notch further than G8 took it: the type
//! declares its own refusal and the predicate interrogates the type it is
//! handed. `src/core/jobs/` imports nothing from the ECS for this — it already
//! imports `foundation` for the float environment — and the guard becomes
//! reachable from any tier without moving a single import edge.
//!
//! The walk is ONE LEVEL DEEP on pointers and recurses on optionals, which is
//! the shape M1.B/G8 shipped and documented; equivalence with the
//! identity-comparing form it replaces was measured over 21 type cases with
//! zero disagreements, `**T` and `[3]T` included (both refused by both forms,
//! which is the stated limit and not an oversight).

const std = @import("std");

/// The declaration a type adds to refuse reaching a dispatched job body.
///
/// Its VALUE is the reason, a `[]const u8`, so a type that refuses also says
/// why and the compile error stays exactly as informative as one written beside
/// a single dispatch entry. A type declaring this name with any other type is a
/// contract breach and fails loudly where the reason is read.
pub const marker_decl_name = "weld_no_job_body";

/// Whether `T` itself carries the marker. False for every non-container type,
/// since `@hasDecl` is only defined on containers.
pub inline fn declaresMarker(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, marker_decl_name),
        else => false,
    };
}

/// Whether `T` is a marked type, a pointer or slice to one, or an optional of
/// either. One level deep on pointers, by the same design as the form this
/// replaces: a marked type buried inside a caller's own struct is NOT caught,
/// and that is stated rather than implied — closing it would need a recursive
/// walk of every field of every argument, for a shape no call site has.
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
    return switch (@typeInfo(T)) {
        .pointer => |p| carriesMarkedIn(p.child, next),
        .optional => |o| carriesMarkedIn(o.child, next),
        .array => |a| carriesMarkedIn(a.child, next),
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
        else => false,
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
fn reasonOf(comptime T: type) []const u8 {
    if (declaresMarker(T)) return @field(T, marker_decl_name);
    return switch (@typeInfo(T)) {
        .pointer => |p| reasonOf(p.child),
        .optional => |o| reasonOf(o.child),
        else => "no reason declared",
    };
}
