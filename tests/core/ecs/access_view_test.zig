//! Acceptance tests for the declared-access view (`ARCH-030`).
//!
//! **These are the POSITIVE half, and without them the three counter-proofs in
//! `access_counterproof/` prove nothing.** A view that refused every access
//! would satisfy all three refusals and fail nothing — so what has to be
//! established first is that legitimate code reaches what it declared, reads
//! through a write declaration, and keeps `World`'s change-detection contract.
//!
//! The pure membership predicate is tested where it lives, inline in
//! `src/core/ecs/view.zig`: it needs no world. What is here needs one.
//!
//! The instruction-for-instruction comparison the zero-cost claim rests on is
//! NOT here, and cannot be: `@compileError` and code generation both happen
//! while this file is being built. It is `zig build ecs-access-zero-cost`,
//! which emits the assembly of a witness pair and compares the two bodies —
//! the shape `zig build forge-asm-inventory` established for reading a claim in
//! emitted code. What this file can pin is the STRUCTURAL precondition that
//! claim rests on, and it does, below.

const std = @import("std");
const weld_core = @import("weld_core");
const ecs = weld_core.ecs;

const World = ecs.World;
const EntityId = ecs.EntityId;
const Transform = ecs.Transform;
const Velocity = ecs.Velocity;
const Access = ecs.Access;
const View = ecs.View;

const testing = std.testing;

test "a declared read is reachable and a declared write is mutable" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const eid = try world.spawn(gpa, Transform{}, Velocity{});

    const spec = [_]Access{
        Access.reads(Velocity),
        Access.writes(Transform),
    };
    const v = View(&spec).fromErased(@ptrCast(&world));

    // The declared read.
    try testing.expectEqual(@as(f32, 0), v.get(Velocity, eid).?.linear[0]);

    // The declared write, and the read that reaches THROUGH it. A write
    // declaration granting a read is not a convenience: the one registered
    // production system declares four writes and no read at all, and every one
    // of its publication paths reads before it writes.
    v.getMut(Transform, eid).?.pos[0] = 4;
    try testing.expectEqual(@as(f32, 4), v.get(Transform, eid).?.pos[0]);
}

test "a view forwards to World rather than reimplementing it" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const eid = try world.spawn(gpa, Transform{}, Velocity{});
    const spec = [_]Access{Access.writes(Transform)};
    const v = View(&spec).fromErased(@ptrCast(&world));

    v.getMut(Transform, eid).?.pos[2] = 9;

    // Read back through the WORLD, not through the view: a view that wrote to
    // its own copy of anything would pass a view-only round-trip and fail here.
    try testing.expectEqual(@as(f32, 9), world.get(Transform, eid).?.pos[2]);
    try testing.expectEqual(world.entityCount(), v.entityCount());
    try testing.expectEqual(world.isLive(eid), v.isLive(eid));
    try testing.expectEqual(world.current_tick, v.currentTick());
}

test "a view's getMut stamps the changed tick its read side then observes" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const eid = try world.spawn(gpa, Transform{}, Velocity{});

    const spec = [_]Access{Access.writes(Transform)};
    const v = View(&spec).fromErased(@ptrCast(&world));

    world.beginFrame();
    const before = v.changedTick(Transform, eid).?;
    world.beginFrame();
    v.getMut(Transform, eid).?.pos[1] = 1;
    const after = v.changedTick(Transform, eid).?;

    // The forward is not a rename: `getMut` carries `World`'s auto-mark, and a
    // view that routed a write anywhere else would break every `Changed<T>`
    // filter with nothing naming the view as the cause.
    try testing.expect(after > before);
    try testing.expectEqual(world.current_tick, after);
}

test "a view reaches a resource by its declared type" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const Published = extern struct { v: u32 = 0 };
    const zero = [_]u8{0} ** 4;
    const rid = try world.registry.registerComponentRaw(gpa, .{
        .name = @typeName(Published),
        .size = 4,
        .alignment = 4,
        .default_bytes = &zero,
        .fields = &.{},
    });
    try world.addResource(gpa, rid, std.mem.asBytes(&Published{ .v = 7 }));

    const spec = [_]Access{Access.writesResource(Published)};
    const v = View(&spec).fromErased(@ptrCast(&world));

    try testing.expectEqual(@as(u8, 7), v.resourceBytes(Published).?[0]);
    v.resourceBytesMut(Published).?[0] = 9;
    try testing.expectEqual(@as(u8, 9), world.resourceBytes(Published).?[0]);
}

test "a view is one pointer wide and carries no runtime declaration" {
    const spec = [_]Access{ Access.reads(Velocity), Access.writes(Transform) };
    const V = View(&spec);

    // THE STRUCTURAL PRECONDITION of the zero-cost claim, and the whole of what
    // a run-time test can say about it. A view is the pointer it wraps and
    // nothing else: no declared-set slice, no length, no kind tag. The
    // declaration lives on the TYPE, which is why it can be checked at compile
    // time and why it can weigh nothing at run time.
    //
    // The claim itself — that the emitted instructions are the same — is
    // `zig build ecs-access-zero-cost`, which reads the listing. This test
    // would still pass if the view were one pointer wide AND did extra work, so
    // it is a precondition and never the proof.
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(V));
    try testing.expectEqual(@as(usize, 1), @typeInfo(V).@"struct".fields.len);

    // And the declaration IS on the type, reachable without an instance.
    try testing.expectEqual(@as(usize, 2), V.declared.len);
}

test "a view refuses to enter a dispatched body" {
    // The world is reachable from a view by an explicit cast, so a view handed
    // to a worker would carry per-entity access across the whole world while
    // that worker owns one range. The marker `foundation.job_bound` reads is
    // what closes it, and erasing the world's TYPE is what would otherwise have
    // opened it: `carriesMarked` finds nothing behind a `*anyopaque`.
    const spec = [_]Access{Access.writes(Transform)};
    const V = View(&spec);
    try testing.expect(weld_core.ecs.command_buffer.carriesMarked(V));
    try testing.expect(weld_core.ecs.command_buffer.carriesMarked(ecs.SystemContextOf(&spec)));
}
