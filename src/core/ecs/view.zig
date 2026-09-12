//! Declared-access view over a `World`.
//!
//! A system declares the components and resources it touches, and that
//! declaration becomes the TYPE of what it receives. An access the declaration
//! does not name is a compile error; a mutable access to a component the
//! declaration names read-only is a compile error. Nothing here is checked at
//! run time and nothing is left to a reviewer.
//!
//! **The view withholds the world's TYPE, because Zig cannot withhold a field.**
//! Every accessor needs a `*World` and there is no way to hide one behind a
//! private field. What the view does instead is store the pointer erased, so
//! recovering a `*World` from a view costs an explicit `@ptrCast(@alignCast(…))`
//! at the call site — a deliberate, greppable act rather than a field access
//! anyone reaches by accident. The escape is not closed; it is made loud.
//!
//! **A view refuses to enter a dispatched body**, and declares so on its own
//! type the way `CommandBuffer` does. The erasure above would otherwise open a
//! hole the marker already closes for the command buffer: a view carries
//! per-entity access across the whole world, and a worker owns one range.
//!
//! The membership test and the refusal are two functions on purpose. `grants`
//! carries no `comptime` block so an ordinary test can assert it at run time;
//! `require` is where the compile error is raised. Fusing them makes the
//! predicate unassertable by any passing test.

const std = @import("std");
const world_mod = @import("world.zig");
const registry_mod = @import("registry.zig");
const tick_mod = @import("tick.zig");

const World = world_mod.World;
const EntityId = world_mod.EntityId;
const ComponentId = registry_mod.ComponentId;
const Tick = tick_mod.Tick;

/// What an access names and how the declaring system may use it.
///
/// Shared with `scheduler.zig`, which turns each variant into the runtime
/// `AccessDescriptor` the dependency graph reads. Declared here rather than
/// there so the dependency runs one way: the scheduler imports the view.
pub const AccessKind = enum { reads, writes, reads_resource, writes_resource };

/// One entry of a declared access set, carrying the type itself and not its
/// name — which is what lets the membership test run at compile time.
///
/// The runtime twin, `scheduler.AccessDescriptor`, keeps only `@typeName(T)`
/// and a resolve closure; `T` is unrecoverable from it. That is why the
/// declaration a system writes is a set of these and the descriptors are
/// DERIVED from it, never maintained beside it.
pub const Access = struct {
    kind: AccessKind,
    T: type,

    /// Read access to component `T`.
    pub fn reads(comptime T: type) Access {
        return .{ .kind = .reads, .T = T };
    }

    /// Exclusive write access to component `T`. Subsumes reading it.
    pub fn writes(comptime T: type) Access {
        return .{ .kind = .writes, .T = T };
    }

    /// Read access to resource `R`.
    pub fn readsResource(comptime R: type) Access {
        return .{ .kind = .reads_resource, .T = R };
    }

    /// Exclusive write access to resource `R`. Subsumes reading it.
    pub fn writesResource(comptime R: type) Access {
        return .{ .kind = .writes_resource, .T = R };
    }
};

/// The four questions a declared set is asked. Reads and writes are separate
/// questions on purpose: a write is observable as a mutation even when the
/// caller never stores through the returned pointer, since `World.getMut`
/// stamps `changed_tick` on the way out.
pub const Use = enum { component_read, component_write, resource_read, resource_write };

/// Prefix every refusal from this file carries.
///
/// A counter-proof harness attributes a compile failure by MATCHING this in the
/// compiler's output, never by reading an exit code: a build that dies before
/// the refusal fires exits the same way one the refusal stops does.
pub const refusal_marker = "weld-access-refused";

/// Whether `spec` grants `T` the use `want`.
///
/// A write grants a read of the same type; a read never grants a write. Carries
/// no `comptime` block so a run-time test can assert it — the compile error
/// lives in `require` below.
pub fn grants(comptime spec: []const Access, comptime T: type, comptime want: Use) bool {
    // `inline`, because `Access` carries a `type` field and is therefore
    // comptime-only: a runtime loop cannot hold one. The function still has no
    // `comptime` block, so a run-time test can call it — the split this file's
    // header states.
    inline for (spec) |a| {
        if (a.T != T) continue;
        const granted = switch (want) {
            .component_read => a.kind == .reads or a.kind == .writes,
            .component_write => a.kind == .writes,
            .resource_read => a.kind == .reads_resource or a.kind == .writes_resource,
            .resource_write => a.kind == .writes_resource,
        };
        if (granted) return true;
    }
    return false;
}

/// Render `spec` as declared, for a refusal message.
///
/// A refusal that names only what was refused leaves the reader to guess what
/// was declared, which is the shape `job_bound.reasonOf` degenerated into: a
/// structurally correct refusal that explains nothing.
fn renderSpec(comptime spec: []const Access) []const u8 {
    comptime {
        if (spec.len == 0) return "{ } (an explicitly empty declaration)";
        var out: []const u8 = "{ ";
        for (spec, 0..) |a, i| {
            if (i != 0) out = out ++ ", ";
            out = out ++ switch (a.kind) {
                .reads => "reads",
                .writes => "writes",
                .reads_resource => "readsResource",
                .writes_resource => "writesResource",
            } ++ "(" ++ @typeName(a.T) ++ ")";
        }
        return out ++ " }";
    }
}

fn useName(comptime want: Use) []const u8 {
    return switch (want) {
        .component_read => "a read of component",
        .component_write => "a write to component",
        .resource_read => "a read of resource",
        .resource_write => "a write to resource",
    };
}

/// Refuse, at compile time, a use the declared set does not grant.
fn require(comptime spec: []const Access, comptime T: type, comptime want: Use) void {
    comptime {
        if (grants(spec, T, want)) return;
        @compileError(refusal_marker ++ ": this system attempts " ++ useName(want) ++
            " `" ++ @typeName(T) ++ "`, which its declared access set does not grant. Declared: " ++
            renderSpec(spec) ++ ". Add the access to the declaration, or stop reaching for the type.");
    }
}

/// The restricted handle a system receives in place of a `*World`.
///
/// Instantiated once per declared set. Every accessor is a thin forward to the
/// `World` entry of the same name, preceded by a `comptime` membership test
/// that compiles to nothing — so the restriction costs the same pointer
/// arithmetic a direct access costs.
pub fn View(comptime spec: []const Access) type {
    return struct {
        const Self = @This();

        /// Read at comptime by `foundation.job_bound`. A view reaches every
        /// entity of the world by handle, and a worker owns one range: the two
        /// cannot both be true of the same value.
        pub const weld_no_job_body: []const u8 =
            "a view reaches any entity of the world by handle, while a worker owns " ++
            "one range and nothing else. Read through the view on the system's own " ++
            "thread, or dispatch a body that takes the chunk it was given.";

        /// The declared set this view was built from, reachable for a test that
        /// wants to assert the type carries its declaration.
        pub const declared: []const Access = spec;

        /// The world, with its type erased. Not a `*World` field: see the file
        /// header — Zig has no private field, so what is withheld is the type.
        world_erased: *anyopaque,

        /// Build a view over an erased world pointer. Called by the generated
        /// trampoline; `p` must point at a live `World`.
        pub fn fromErased(p: *anyopaque) Self {
            return .{ .world_erased = p };
        }

        fn unrestricted(self: Self) *World {
            return @ptrCast(@alignCast(self.world_erased));
        }

        /// Borrow `T` on `entity`, or null when the entity is dead or lacks it.
        pub fn get(self: Self, comptime T: type, entity: EntityId) ?*const T {
            comptime require(spec, T, .component_read);
            return self.unrestricted().get(T, entity);
        }

        /// Borrow `T` on `entity` mutably, stamping its `changed_tick`.
        pub fn getMut(self: Self, comptime T: type, entity: EntityId) ?*T {
            comptime require(spec, T, .component_write);
            return self.unrestricted().getMut(T, entity);
        }

        /// The tick at which `T` on `entity` last changed, or null when the
        /// type is unregistered or the entity does not carry it.
        ///
        /// A read, so a read declaration grants it: observing that a component
        /// changed is not mutating it.
        pub fn changedTick(self: Self, comptime T: type, entity: EntityId) ?Tick {
            comptime require(spec, T, .component_read);
            const w = self.unrestricted();
            const cid = w.componentId(@typeName(T)) orelse return null;
            return w.changedTickOf(entity, cid);
        }

        /// The stored bytes of resource `R`, or null when no such resource is
        /// published.
        ///
        /// Bytes rather than a typed pointer because the byte-keyed store is
        /// what the resource path actually uses; the type is here to be checked
        /// against the declaration, not to reinterpret the slice.
        pub fn resourceBytes(self: Self, comptime R: type) ?[]const u8 {
            comptime require(spec, R, .resource_read);
            const w = self.unrestricted();
            const id = w.componentId(@typeName(R)) orelse return null;
            return w.resources.getResource(id);
        }

        /// The stored bytes of resource `R`, mutably.
        pub fn resourceBytesMut(self: Self, comptime R: type) ?[]u8 {
            comptime require(spec, R, .resource_write);
            const w = self.unrestricted();
            const id = w.componentId(@typeName(R)) orelse return null;
            return w.resources.getMutResource(id);
        }

        /// Whether `entity` is still live.
        ///
        /// Names no component, so no declaration gates it — a liveness test
        /// reads identity, not entity data.
        pub fn isLive(self: Self, entity: EntityId) bool {
            return self.unrestricted().isLive(entity);
        }

        /// How many entities the world holds.
        ///
        /// A cardinality is neither a component nor a resource, so the declared
        /// set has nothing to say about it.
        pub fn entityCount(self: Self) usize {
            return self.unrestricted().entityCount();
        }

        /// The world's current tick.
        pub fn currentTick(self: Self) Tick {
            return self.unrestricted().current_tick;
        }
    };
}

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const A = extern struct { v: u32 = 0 };
const B = extern struct { v: u32 = 0 };
const C = extern struct { v: u32 = 0 };
const R1 = extern struct { v: u32 = 0 };
const R2 = extern struct { v: u32 = 0 };

const mixed_spec = [_]Access{
    Access.reads(A),
    Access.writes(B),
    Access.readsResource(R1),
    Access.writesResource(R2),
};

test "a write grants a read of the same component, and a read never grants a write" {
    const spec: []const Access = &mixed_spec;

    // Declared read: readable, not writable.
    try testing.expect(grants(spec, A, .component_read));
    try testing.expect(!grants(spec, A, .component_write));

    // Declared write: writable AND readable — the asymmetry the one production
    // system depends on, since every publication path reads before it writes.
    try testing.expect(grants(spec, B, .component_write));
    try testing.expect(grants(spec, B, .component_read));

    // Undeclared: neither.
    try testing.expect(!grants(spec, C, .component_read));
    try testing.expect(!grants(spec, C, .component_write));
}

test "resource uses answer on their own axis, never on the component one" {
    const spec: []const Access = &mixed_spec;

    try testing.expect(grants(spec, R1, .resource_read));
    try testing.expect(!grants(spec, R1, .resource_write));
    try testing.expect(grants(spec, R2, .resource_write));
    try testing.expect(grants(spec, R2, .resource_read));

    // A resource declaration grants NOTHING on the component axis, and a
    // component declaration nothing on the resource axis. Without this the two
    // namespaces would silently merge — they already share the id pool.
    try testing.expect(!grants(spec, R1, .component_read));
    try testing.expect(!grants(spec, B, .resource_read));
}

test "an empty declaration grants nothing" {
    const spec: []const Access = &.{};
    try testing.expect(!grants(spec, A, .component_read));
    try testing.expect(!grants(spec, A, .component_write));
    try testing.expect(!grants(spec, R1, .resource_read));
}

test "a view carries its declaration on its type" {
    const spec = [_]Access{ Access.reads(A), Access.writes(B) };
    const V = View(&spec);
    try testing.expectEqual(@as(usize, 2), V.declared.len);
    try testing.expect(V.declared[0].T == A);
    try testing.expect(V.declared[1].kind == .writes);
}

test "two views over different declarations are different types" {
    const s1 = [_]Access{Access.reads(A)};
    const s2 = [_]Access{Access.writes(A)};
    // The restriction lives in the type, so two declarations that differ must
    // not collapse to one instantiation — if they did, a read-only system would
    // silently inherit a writer's surface.
    try testing.expect(View(&s1) != View(&s2));
}

test "the refusal marker is what a counter-proof harness matches on" {
    // The harness greps the compiler's output for this exact string. An exit
    // code cannot tell a refused build from one that died earlier, so the
    // marker is load-bearing and pinned here rather than left to a fixture.
    try testing.expectEqualStrings("weld-access-refused", refusal_marker);
}
