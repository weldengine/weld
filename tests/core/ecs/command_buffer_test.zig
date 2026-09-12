//! What the command buffer no longer holds, and when it resolves what it does.
//!
//! A declared-access view restricts what a system reaches. A command buffer
//! carrying a `*World` reopens that by a neighbouring field — `ctx.cmd.world`,
//! no cast and no diagnostic — and Zig has no private field to close it with.
//! The datum is therefore REMOVED, and these two tests are what say so rather
//! than a comment claiming it.

const std = @import("std");
const weld_core = @import("weld_core");
const ecs = weld_core.ecs;

const World = ecs.World;
const EntityId = ecs.EntityId;
const CommandBuffer = ecs.CommandBuffer;
const Transform = ecs.Transform;
const Velocity = ecs.Velocity;

const testing = std.testing;

/// Whether `T` reaches `Target` through its fields, at any depth.
///
/// **It deliberately does NOT enter function types**, and that exclusion is the
/// whole precision of the test. A recorded command carries a resolver whose
/// SIGNATURE is `fn (*World, Allocator) anyerror!ComponentId` — the type
/// `*World` appears there, and a walk that followed parameter types would
/// report a world the buffer does not hold. Naming a type in a signature is not
/// holding a value of it; what this predicate answers is whether a holder of a
/// `CommandBuffer` can reach a `*World` by dereferencing fields, which is the
/// only reach that matters.
fn reachesType(comptime T: type, comptime Target: type, comptime seen: []const type) bool {
    @setEvalBranchQuota(100_000);
    inline for (seen) |s| {
        if (s == T) return false; // a cycle, not a hit
    }
    if (T == Target) return true;
    const next = seen ++ [_]type{T};
    return switch (@typeInfo(T)) {
        .pointer => |p| reachesType(p.child, Target, next),
        .optional => |o| reachesType(o.child, Target, next),
        .array => |a| reachesType(a.child, Target, next),
        .error_union => |e| reachesType(e.payload, Target, next),
        .vector => |v| reachesType(v.child, Target, next),
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (reachesType(f.type, Target, next)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |un| blk: {
            inline for (un.fields) |f| {
                if (reachesType(f.type, Target, next)) break :blk true;
            }
            break :blk false;
        },
        // A function type NAMES its parameters; it does not hold them.
        .@"fn" => false,
        else => false,
    };
}

test "a system reaches no world through its command buffer" {
    // STRUCTURAL, not by field name. A test asserting `!@hasField(CommandBuffer,
    // "world")` would pass the day the field came back under another name, or
    // came back one level down inside a struct the buffer holds. What is
    // asserted is that no path of field dereferences from a `CommandBuffer`
    // arrives at a `*World`.
    try testing.expect(!reachesType(CommandBuffer, *World, &.{}));

    // NON-VACUITY. The predicate has to be able to say yes, or the assertion
    // above is the assertion of a walk that finds nothing anywhere. `*World`
    // trivially reaches itself, and a struct holding one reaches it at depth.
    try testing.expect(reachesType(*World, *World, &.{}));
    const Holder = struct { inner: struct { w: *World } };
    try testing.expect(reachesType(Holder, *World, &.{}));

    // And the exclusion that makes the first assertion precise: the buffer DOES
    // carry resolvers, whose signature names `*World`. If the walk entered
    // function types, the first assertion would be false — so this pins the
    // reason it is true.
    try testing.expect(!reachesType(ecs.command_buffer.ComponentResolveFn, *World, &.{}));
}

test "no system entry point reaches a world at all" {
    // `ARCH-030`'s FIRST conformance test — "aucun point d'entrée de système ne
    // reçoit `*World` ni aucun équivalent non restreint" — read mechanically on
    // the type rather than by inspecting the fields one reader at a time.
    //
    // It belongs beside the command buffer's own assertion because the two are
    // one claim: the view withholds the world, and a buffer holding one would
    // hand it straight back. Removing the field is what makes THIS pass.
    try testing.expect(!reachesType(ecs.SystemContext, *World, &.{}));

    // And the typed form a declared system actually receives.
    const spec = [_]ecs.Access{ecs.Access.writes(Transform)};
    try testing.expect(!reachesType(ecs.SystemContextOf(&spec), *World, &.{}));

    // NON-VACUITY on the subject itself, not on a toy: the context still
    // carries its command buffer, its job scheduler and its frame context, so
    // the walk really did traverse a live type graph and come back empty.
    try testing.expect(@typeInfo(ecs.SystemContext).@"struct".fields.len >= 6);
    try testing.expect(reachesType(ecs.SystemContext, *ecs.CommandBuffer, &.{}));
}

/// A component type no other test registers, so its absence from a world's
/// registry is a fact about THIS test and not about the suite's ordering.
const LateBound = extern struct { v: u32 = 0 };

test "a deferred add resolves its component id at flush and not at record" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const eid = try world.spawn(gpa, Transform{}, Velocity{});

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();

    // Before anything, the world has never heard of the type.
    try testing.expect(world.componentId(@typeName(LateBound)) == null);

    try cmd.addComponent(eid, LateBound, .{ .v = 3 });
    try testing.expectEqual(@as(usize, 1), cmd.commandCount());

    // THE COUNTER-FACTUAL, and it is structural rather than staged: resolving
    // at record time is UNREACHABLE, because resolving means registering and
    // registering means holding a world — which `CommandBuffer.init(gpa)` does
    // not take and the type does not carry (asserted above). The observable
    // consequence is here: the registry still does not know the type, although
    // a command naming it has been recorded.
    try testing.expect(world.componentId(@typeName(LateBound)) == null);

    // The flush is where the world arrives, so the flush is where the type is
    // registered and the id assigned.
    try cmd.flush(&world);
    const cid = world.componentId(@typeName(LateBound));
    try testing.expect(cid != null);
    try testing.expect(world.hasComponentDyn(eid, cid.?));
    try testing.expectEqual(@as(u8, 3), world.componentBytes(eid, cid.?).?[0]);
}

test "a deferred spawn resolves every one of its component ids at flush" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const A = extern struct { v: u32 = 0 };
    const B = extern struct { v: u32 = 0 };

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();

    try cmd.spawn(.{ A{ .v = 1 }, B{ .v = 2 } });
    try testing.expect(world.componentId(@typeName(A)) == null);
    try testing.expect(world.componentId(@typeName(B)) == null);
    try testing.expectEqual(@as(usize, 0), world.entityCount());

    try cmd.flush(&world);

    // Both, not just the first: a resolution loop that stopped early would
    // spawn with one id and whatever `undefined` left in the other slot.
    const a = world.componentId(@typeName(A));
    const b = world.componentId(@typeName(B));
    try testing.expect(a != null and b != null);
    try testing.expectEqual(@as(usize, 1), world.entityCount());

    var it = world.entity_locations.keyIterator();
    const e = it.next().?.*;
    try testing.expectEqual(@as(u8, 1), world.componentBytes(e, a.?).?[0]);
    try testing.expectEqual(@as(u8, 2), world.componentBytes(e, b.?).?[0]);
}

test "a command applied WITHOUT a flush resolves all the same" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Drained = extern struct { v: u32 = 0 };

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();
    try cmd.spawn(.{Drained{ .v = 5 }});

    // **THE DEFECT THIS PINS.** Resolution was first written as a pre-pass over
    // a BUFFER, which covers the buffers a caller remembered to hand it. The
    // Etch tick-boundary drain reads `observer_registry.deferred` through
    // neither `flush` nor `flushWithObservers`: it takes the commands BY VALUE
    // and passes them straight to `applyWithObservers`. The pre-pass never ran
    // there, and `spawnDynamicWithValues` received a slice of `undefined` ids —
    // an out-of-range `ComponentId` into the registry, which is a panic under
    // safety and an out-of-bounds read without it.
    //
    // So the resolution moved to the APPLY boundary, and this is the shape that
    // reaches it: one command, taken out of its buffer, applied on its own.
    const taken = cmd.commands.items[0];
    try weld_core.ecs.observers.applyWithObservers(taken, &world.observer_registry, &world, gpa);

    const cid = world.componentId(@typeName(Drained));
    try testing.expect(cid != null);
    try testing.expectEqual(@as(usize, 1), world.entityCount());
    var it = world.entity_locations.keyIterator();
    const e = it.next().?.*;
    try testing.expectEqual(@as(u8, 5), world.componentBytes(e, cid.?).?[0]);
}

test "a command recorded with an id already in hand is left alone at flush" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The second recorder the buffer serves: the Etch interpreter and the
    // observer flush hold the id before they record, and have a world. Their
    // commands carry no resolver, and the flush must not overwrite what they
    // put there.
    const zero = [_]u8{0} ** 4;
    const cid = try world.registry.registerComponentRaw(gpa, .{
        .name = "Preresolved",
        .size = 4,
        .alignment = 4,
        .default_bytes = &zero,
        .fields = &.{},
    });
    const eid = try world.spawn(gpa, Transform{}, Velocity{});

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();

    const bytes = [_]u8{ 7, 0, 0, 0 };
    try cmd.commands.append(gpa, .{ .add_component = .{
        .entity = eid,
        .component_id = cid,
        .bytes = &bytes,
    } });
    try cmd.flush(&world);

    try testing.expect(world.hasComponentDyn(eid, cid));
    try testing.expectEqual(@as(u8, 7), world.componentBytes(eid, cid).?[0]);
}
