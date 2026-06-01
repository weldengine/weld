//! Barrier tracker — Phase 0 / M0.4.
//!
//! Maintains the layout/access-mask state of each texture/buffer to
//! automatically insert Vulkan/Metal/D3D12 barriers between passes that
//! share a resource. Consistent with brief §Notes decision 2:
//! auto-tracking by default, `BarrierMode.explicit` opt-in.
//!
//! Phase 0: minimalist implementation — one `std.AutoHashMap` per resource
//! type mapping handle → last (layout, stage, access). On each usage
//! declaration by a pass, the tracker compares the current state to the
//! required state and emits a `RecordedBarrier` if a transition is needed.
//!
//! Phase 1+: enriched for pass merging (merging compatible passes that
//! share a barrier), resource aliasing (reuse of a transient texture by
//! several non-overlapping passes), and multi-queue support (cross-queue
//! barriers with timeline semaphores).
//!
//! The tracker is internal to the render graph — not exported on the caller
//! side. The caller consumes only the `BarrierMode` via the pass descriptor
//! (cf. `escape_hatches.BarrierMode`).

const std = @import("std");
const types = @import("types.zig");
const escape = @import("escape_hatches.zig");

/// Access direction to a resource by a pass.
pub const Access = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    /// If the pass writes to this texture as a color attachment.
    color_attachment: bool = false,
    /// If the pass writes to this texture as a depth attachment.
    depth_attachment: bool = false,
    /// If the pass reads this texture as a sampled input.
    sampled: bool = false,
    _padding: u27 = 0,

    pub fn isWrite(self: Access) bool {
        return self.write or self.color_attachment or self.depth_attachment;
    }
};

/// Usage of a resource by a given pass.
pub const ResourceUsage = struct {
    stage: types.ShaderStage,
    access: Access,
    /// Required layout (textures only). Null for buffers.
    layout: ?escape.TextureLayout = null,
};

/// Current state of a texture in the tracker.
const TextureState = struct {
    layout: escape.TextureLayout,
    last_stage: types.ShaderStage,
    last_access: Access,
};

/// Current state of a buffer in the tracker.
const BufferState = struct {
    last_stage: types.ShaderStage,
    last_access: Access,
};

/// Barrier to insert between two passes (produced by the tracker, consumed
/// by the backend when recording the command buffers).
pub const RecordedBarrier = struct {
    resource: union(enum) {
        buffer: types.BufferHandle,
        texture: types.TextureHandle,
    },
    src_stage: types.ShaderStage,
    dst_stage: types.ShaderStage,
    src_access: Access,
    dst_access: Access,
    /// Layout transition (textures only).
    old_layout: ?escape.TextureLayout = null,
    new_layout: ?escape.TextureLayout = null,
};

/// Per-frame tracker of resource transitions. Reset at the start of each
/// frame (the render graph's transient resources are born and die within
/// the frame).
pub const BarrierTracker = struct {
    allocator: std.mem.Allocator,
    textures: std.AutoHashMapUnmanaged(u64, TextureState) = .empty,
    buffers: std.AutoHashMapUnmanaged(u64, BufferState) = .empty,
    /// Barriers accumulated in insertion order, consumed by the backend.
    recorded: std.ArrayListUnmanaged(RecordedBarrier) = .empty,

    pub fn init(allocator: std.mem.Allocator) BarrierTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BarrierTracker) void {
        self.textures.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.recorded.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reset the tracker for a new frame. Preserves the allocated buckets
    /// (capacity) to avoid frame-to-frame reallocations.
    pub fn reset(self: *BarrierTracker) void {
        self.textures.clearRetainingCapacity();
        self.buffers.clearRetainingCapacity();
        self.recorded.clearRetainingCapacity();
    }

    /// Declares the usage of a texture by the current pass. If a transition
    /// is needed vs the previous state, a `RecordedBarrier` is added to
    /// `self.recorded`. The texture's state is updated to the new
    /// post-pass state.
    ///
    /// `initial_layout` is used only the first time a texture appears
    /// (typically `.undefined` for transients).
    pub fn trackTexture(
        self: *BarrierTracker,
        texture: types.TextureHandle,
        usage: ResourceUsage,
        initial_layout: escape.TextureLayout,
    ) std.mem.Allocator.Error!void {
        const new_layout = usage.layout orelse initial_layout;
        const gop = try self.textures.getOrPut(self.allocator, texture.inner);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .layout = initial_layout,
                .last_stage = .{},
                .last_access = .{},
            };
        }
        const prev = gop.value_ptr.*;
        // Insert a barrier if a transition is needed.
        const needs_barrier = needsBarrierForTransition(
            prev.last_access,
            prev.last_stage,
            usage.access,
            usage.stage,
            prev.layout,
            new_layout,
        );
        if (needs_barrier) {
            try self.recorded.append(self.allocator, .{
                .resource = .{ .texture = texture },
                .src_stage = prev.last_stage,
                .dst_stage = usage.stage,
                .src_access = prev.last_access,
                .dst_access = usage.access,
                .old_layout = prev.layout,
                .new_layout = new_layout,
            });
        }
        gop.value_ptr.* = .{
            .layout = new_layout,
            .last_stage = usage.stage,
            .last_access = usage.access,
        };
    }

    /// Same for a buffer (no layout).
    pub fn trackBuffer(
        self: *BarrierTracker,
        buffer: types.BufferHandle,
        usage: ResourceUsage,
    ) std.mem.Allocator.Error!void {
        const gop = try self.buffers.getOrPut(self.allocator, buffer.inner);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .last_stage = .{},
                .last_access = .{},
            };
        }
        const prev = gop.value_ptr.*;
        const needs_barrier = needsBarrierForTransition(
            prev.last_access,
            prev.last_stage,
            usage.access,
            usage.stage,
            null,
            null,
        );
        if (needs_barrier) {
            try self.recorded.append(self.allocator, .{
                .resource = .{ .buffer = buffer },
                .src_stage = prev.last_stage,
                .dst_stage = usage.stage,
                .src_access = prev.last_access,
                .dst_access = usage.access,
            });
        }
        gop.value_ptr.* = .{
            .last_stage = usage.stage,
            .last_access = usage.access,
        };
    }

    /// Snapshot of the barriers accumulated since the last `reset` or `consumeRecorded`.
    pub fn consumeRecorded(self: *BarrierTracker) []const RecordedBarrier {
        return self.recorded.items;
    }
};

/// Determines whether a barrier is needed between two successive usages
/// of a resource. Phase 0 rule (simplified but correct):
///   - first occurrence (last_access empty) → no barrier, but a layout
///     transition if needed (handled by the caller via the initial state)
///   - write → read = mandatory barrier (read-after-write)
///   - read → write = mandatory barrier (write-after-read)
///   - write → write = mandatory barrier (write-after-write)
///   - read → read = no barrier (concurrent reads OK)
///   - layout change = mandatory barrier regardless of the access masks
fn needsBarrierForTransition(
    prev_access: Access,
    prev_stage: types.ShaderStage,
    new_access: Access,
    new_stage: types.ShaderStage,
    old_layout: ?escape.TextureLayout,
    new_layout: ?escape.TextureLayout,
) bool {
    _ = prev_stage;
    _ = new_stage;
    const prev_is_init = !prev_access.read and !prev_access.isWrite();
    if (prev_is_init) {
        // First usage: no hazard barrier, but a layout transition is possible.
        if (old_layout != null and new_layout != null) {
            return @intFromEnum(old_layout.?) != @intFromEnum(new_layout.?);
        }
        return false;
    }
    if (prev_access.isWrite()) return true; // WAW or RAW
    if (new_access.isWrite()) return true; // WAR
    // R→R: only a layout transition justifies a barrier.
    if (old_layout != null and new_layout != null) {
        return @intFromEnum(old_layout.?) != @intFromEnum(new_layout.?);
    }
    return false;
}

test "barriers: first usage produces no barrier when layout matches initial" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 1 };
    try tracker.trackTexture(tex, .{
        .stage = .{ .vertex = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .shader_read_only);
    try t.expectEqual(@as(usize, 0), tracker.consumeRecorded().len);
}

test "barriers: write then read inserts barrier" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 2 };
    // Pass A: color attachment write
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .write = true, .color_attachment = true },
        .layout = .color_attachment,
    }, .undefined);
    // Pass B: sampled read
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .undefined);
    const barriers = tracker.consumeRecorded();
    try t.expect(barriers.len >= 1);
    try t.expectEqual(escape.TextureLayout.color_attachment, barriers[barriers.len - 1].old_layout.?);
    try t.expectEqual(escape.TextureLayout.shader_read_only, barriers[barriers.len - 1].new_layout.?);
}

test "barriers: read after read does not insert barrier when layout stable" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 3 };
    try tracker.trackTexture(tex, .{
        .stage = .{ .vertex = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .shader_read_only);
    // First pass produces 0 barriers.
    try t.expectEqual(@as(usize, 0), tracker.recorded.items.len);
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .shader_read_only);
    // R→R same layout: still 0 barriers.
    try t.expectEqual(@as(usize, 0), tracker.recorded.items.len);
}

test "barriers: buffer write then read inserts barrier" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const buf = types.BufferHandle{ .inner = 100 };
    try tracker.trackBuffer(buf, .{
        .stage = .{ .compute = true },
        .access = .{ .write = true },
    });
    try tracker.trackBuffer(buf, .{
        .stage = .{ .vertex = true },
        .access = .{ .read = true },
    });
    const barriers = tracker.consumeRecorded();
    try t.expect(barriers.len >= 1);
}

test "barriers: reset clears recorded but preserves capacity" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 4 };
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .write = true, .color_attachment = true },
        .layout = .color_attachment,
    }, .undefined);
    tracker.reset();
    try t.expectEqual(@as(usize, 0), tracker.consumeRecorded().len);
    try t.expectEqual(@as(u32, 0), tracker.textures.count());
}
