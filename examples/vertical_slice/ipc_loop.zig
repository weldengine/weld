//! M0.9 vertical slice — IPC component-edit loop (E5 / C0.8).
//!
//! Closes C0.8 end-to-end *inside the slice* (the slice IS the C0.8 runtime —
//! it owns the live World from E3 and the world→viewport renderer from E4; this
//! is NOT the C0.4 IPC-test runtime in `src/runtime`, whose `renderMire`/echo-
//! ack are legitimate transport stubs). An editor-stub thread sends a REAL
//! `ModifyComponent` over the REAL M0.7 transport (AF_UNIX socket + framing);
//! the slice's runtime-side client receives it, decodes it, and applies it to
//! the live World via the canonical `diff_runner`/`sim.setF32` write path
//! (`field_offset` + `new_value` → memcpy into the component slot). The E4
//! renderer then reflects the edit. No `src/` touched, no shim — host-glue over
//! the existing engine, like E3/E4.
//!
//! Only the socket message path is exercised here (not the shm viewport): the
//! slice renders through its own GAL viewport (`render.zig`), so this loop runs
//! headlessly on every platform incl. macOS — the C0.8 SEMANTIC loop is fully
//! assertable in `zig build test`; the VISUAL reflection is the lavapipe smoke
//! + hardware.

const std = @import("std");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const messages = ipc.messages;
const framing = ipc.framing;
const transport = ipc.transport;

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;

extern "c" fn getpid() i32;

/// Resolve the byte size of the field located at `offset` within component
/// `cid` (the value width to copy). `null` if no field starts there.
fn fieldSizeAt(registry: *const Registry, cid: ComponentId, offset: u32) ?usize {
    for (registry.componentFields(cid)) |f| {
        if (f.offset == offset) return f.kind.sizeBytes();
    }
    return null;
}

/// Apply a decoded `ModifyComponent` to the live World — the canonical
/// `diff_runner` write path: locate the entity's component slot via the
/// registry + archetype, then memcpy `new_value` (the field's bytes) at
/// `field_offset`. Silently ignores a stale entity / unknown component / bad
/// offset (a malformed edit must not crash the runtime).
pub fn applyModify(world: *World, msg: messages.ModifyComponent) bool {
    const eid = EntityId{ .index = @intCast(msg.entity), .generation = 0 };
    const loc = world.dynamicLocation(eid) orelse return false;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid: ComponentId = msg.component_type;
    const cidx = arch.componentIndex(cid) orelse return false;
    const slot = arch.componentSlot(chunk, cidx, loc.slot);
    const size = fieldSizeAt(&world.registry, cid, msg.field_offset) orelse return false;
    if (@as(usize, msg.field_offset) + size > slot.len or size > msg.new_value.len) return false;
    @memcpy(slot[msg.field_offset..][0..size], msg.new_value[0..size]);
    return true;
}

/// Build a `ModifyComponent` that sets one `f32` field of `component`.`field`
/// on `entity` to `value`, resolving the component id + field offset from the
/// live registry (the editor and runtime share it in-process — `idOf`/
/// `findField` are the public registry API).
pub fn buildF32Edit(world: *World, entity: u32, component: []const u8, field: []const u8, value: f32) ?messages.ModifyComponent {
    const cid = world.registry.idOf(component) orelse return null;
    const fd = world.registry.findField(cid, field) orelse return null;
    var msg = messages.ModifyComponent{
        .entity = entity,
        .component_type = cid,
        .field_offset = fd.offset,
        .new_value = std.mem.zeroes([40]u8),
    };
    @memcpy(msg.new_value[0..4], std.mem.asBytes(&value));
    return msg;
}

const RuntimeCtx = struct {
    gpa: std.mem.Allocator,
    world: *World,
    path: []const u8,
    applied: bool = false,
    err: ?anyerror = null,
};

/// The slice's runtime-side client: connect, handshake, receive ONE
/// `ModifyComponent`, apply it to the World, reply `ModifyAck`. Runs on a
/// spawned thread so the editor-stub (server, on the caller's thread) can drive
/// the same real socket.
fn runtimeClientThread(ctx: *RuntimeCtx) void {
    var client = ipc.client.IpcClient.init(ctx.gpa);
    defer client.deinit();
    client.connect(ctx.path) catch |e| {
        ctx.err = e;
        return;
    };
    client.sendHello("0.0.7-S6", "deadbee", 0) catch |e| {
        ctx.err = e;
        return;
    };
    var ack_buf: [framing.frameSizeOf(messages.ProtocolHelloAck)]u8 = undefined;
    _ = client.recvHelloAck(&ack_buf) catch |e| {
        ctx.err = e;
        return;
    };
    var scratch: [framing.frameSizeOf(messages.ModifyComponent)]u8 = undefined;
    const fr = client.connection().recvFrame(&scratch) catch |e| {
        ctx.err = e;
        return;
    };
    const m = framing.decode(messages.ModifyComponent, fr.header, fr.payload_bytes) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.applied = applyModify(ctx.world, m);
    const ack = messages.ModifyAck{ .success = if (ctx.applied) 1 else 0 };
    client.connection().sendMessage(messages.ModifyAck, fr.header.seq_id, &ack) catch |e| {
        ctx.err = e;
        return;
    };
}

/// Run one editor→runtime component edit over the real M0.7 transport and
/// apply it to `world`. The caller's thread is the editor-stub (server); a
/// spawned thread is the runtime-side client that owns the apply. Returns once
/// the round-trip completes (edit applied + `ModifyAck` received).
pub fn runOneEdit(gpa: std.mem.Allocator, world: *World, msg: messages.ModifyComponent) !void {
    var name_buf: [64]u8 = undefined;
    const ep_name = try std.fmt.bufPrint(&name_buf, "weld-slice-c08-{d}", .{getpid()});
    var path_buf: [128]u8 = undefined;
    const path = try transport.buildSocketPath(&path_buf, ep_name);

    // Reap any orphan socket from a previously-crashed run so `listen` is clean.
    ipc.cleanup.reapOrphans();

    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(path); // socket is listening before the client thread connects

    var ctx = RuntimeCtx{ .gpa = gpa, .world = world, .path = path };
    const thread = try std.Thread.spawn(.{}, runtimeClientThread, .{&ctx});

    // Drive the editor (server) side, CAPTURING any error rather than
    // early-returning, so the client thread is always joined exactly once
    // before we read the shared `ctx`. A mid-protocol failure closes the
    // socket, so the peer's blocking recv returns an error (no deadlock).
    var acked = false;
    const editor_err: ?anyerror = blk: {
        server.acceptOne() catch |e| break :blk e;
        var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
        const hello = server.recvHello(&hello_buf) catch |e| break :blk e;
        ipc.server.IpcServer.validateHello(hello) catch |e| break :blk e;
        server.sendHelloAck(true, "") catch |e| break :blk e;
        server.connection().sendMessage(messages.ModifyComponent, 1, &msg) catch |e| break :blk e;
        var ack_buf: [framing.frameSizeOf(messages.ModifyAck)]u8 = undefined;
        const ack = server.connection().recvMessage(messages.ModifyAck, &ack_buf) catch |e| break :blk e;
        acked = ack.success != 0;
        break :blk null;
    };

    thread.join();
    if (editor_err) |e| return e;
    if (ctx.err) |e| return e;
    if (!acked or !ctx.applied) return error.EditNotApplied;
}
