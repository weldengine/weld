//! No-op stubs shared by the Null GAL backend — Phase 0 / M0.4.
//!
//! The Null backend serves two purposes:
//!
//! 1. **Headless CI** — `tests/render/gal_null_smoke.zig` can run
//!    Device + Queue + BindGroup + RenderPipeline + 1 frame without a real GPU.
//! 2. **API discipline** — forces the GAL contract to materialize day 1.
//!    The Null backend's existence makes impossible the drift "I implement
//!    Vulkan first, I'll abstract later" which is the explicit anti-pattern
//!    listed in the brief §Notes known pitfalls.
//!
//! The no-op methods return handles whose `inner` is a simple monotonic
//! counter (incremented on each allocation). No ownership tracking on the
//! Null side — the caller can destroy a non-existent handle without a
//! crash. This laxity is intentional: the Null backend validates API
//! coherence, not object-management rigor.

const std = @import("std");
const types = @import("../types.zig");
const escape = @import("../escape_hatches.zig");

/// Monotonic handle counter. Shared by all resource types (a single
/// numeric space suffices in Phase 0; each type has its own tag via the
/// `extern struct` wrapping).
pub const HandleCounter = struct {
    next: u64 = 1,

    pub fn next_id(self: *HandleCounter) u64 {
        const id = self.next;
        self.next += 1;
        return id;
    }
};

/// CommandEncoder stub for the Null backend. All methods are no-ops.
/// Kept as a flat struct to match the `*CommandEncoder` signature on the
/// caller side.
pub const CommandEncoder = struct {
    label: ?[]const u8 = null,
    finished: bool = false,

    pub fn beginRenderPass(self: *CommandEncoder, descriptor: types.RenderPassDescriptor) RenderPassEncoder {
        _ = .{ self, descriptor };
        return .{};
    }

    pub fn beginComputePass(self: *CommandEncoder, descriptor: types.ComputePassDescriptor) ComputePassEncoder {
        _ = .{ self, descriptor };
        return .{};
    }

    pub fn copyBufferToBuffer(
        self: *CommandEncoder,
        src: types.BufferHandle,
        src_offset: u64,
        dst: types.BufferHandle,
        dst_offset: u64,
        size: u64,
    ) void {
        _ = .{ self, src, src_offset, dst, dst_offset, size };
    }

    pub fn copyBufferToTexture(
        self: *CommandEncoder,
        src: types.BufferHandle,
        src_offset: u64,
        dst: types.TextureHandle,
        mip: u32,
        layer: u32,
        size: [3]u32,
    ) void {
        _ = .{ self, src, src_offset, dst, mip, layer, size };
    }

    pub fn copyTextureToBuffer(
        self: *CommandEncoder,
        source: types.ImageCopyTexture,
        dest: types.ImageCopyBuffer,
        copy_size: types.Extent3D,
    ) void {
        _ = .{ self, source, dest, copy_size };
    }

    pub fn finish(self: *CommandEncoder) void {
        self.finished = true;
    }
};

/// RenderPassEncoder stub for the Null backend.
pub const RenderPassEncoder = struct {
    pub fn setPipeline(self: *RenderPassEncoder, pipeline: types.RenderPipelineHandle) void {
        _ = .{ self, pipeline };
    }
    pub fn setBindGroup(self: *RenderPassEncoder, slot: u32, group: types.BindGroupHandle) void {
        _ = .{ self, slot, group };
    }
    pub fn setVertexBuffer(self: *RenderPassEncoder, slot: u32, buffer: types.BufferHandle, offset: u64) void {
        _ = .{ self, slot, buffer, offset };
    }
    pub fn setIndexBuffer(self: *RenderPassEncoder, buffer: types.BufferHandle, offset: u64, index_type: enum { u16, u32 }) void {
        _ = .{ self, buffer, offset, index_type };
    }
    pub fn draw(self: *RenderPassEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        _ = .{ self, vertex_count, instance_count, first_vertex, first_instance };
    }
    pub fn drawIndexed(self: *RenderPassEncoder, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        _ = .{ self, index_count, instance_count, first_index, vertex_offset, first_instance };
    }
    pub fn setViewport(self: *RenderPassEncoder, x: f32, y: f32, w: f32, h: f32, min_depth: f32, max_depth: f32) void {
        _ = .{ self, x, y, w, h, min_depth, max_depth };
    }
    pub fn setScissor(self: *RenderPassEncoder, x: i32, y: i32, w: u32, h: u32) void {
        _ = .{ self, x, y, w, h };
    }
    pub fn barrier(self: *RenderPassEncoder, barrier_desc: escape.ExplicitBarrier) void {
        _ = .{ self, barrier_desc };
    }
    pub fn end(self: *RenderPassEncoder) void {
        _ = self;
    }
};

/// ComputePassEncoder stub for the Null backend.
pub const ComputePassEncoder = struct {
    pub fn setPipeline(self: *ComputePassEncoder, pipeline: types.ComputePipelineHandle) void {
        _ = .{ self, pipeline };
    }
    pub fn setBindGroup(self: *ComputePassEncoder, slot: u32, group: types.BindGroupHandle) void {
        _ = .{ self, slot, group };
    }
    pub fn dispatch(self: *ComputePassEncoder, x: u32, y: u32, z: u32) void {
        _ = .{ self, x, y, z };
    }
    pub fn barrier(self: *ComputePassEncoder, barrier_desc: escape.ExplicitBarrier) void {
        _ = .{ self, barrier_desc };
    }
    pub fn end(self: *ComputePassEncoder) void {
        _ = self;
    }
};

test "stubs: HandleCounter is monotone" {
    const t = std.testing;
    var c: HandleCounter = .{};
    try t.expectEqual(@as(u64, 1), c.next_id());
    try t.expectEqual(@as(u64, 2), c.next_id());
    try t.expectEqual(@as(u64, 3), c.next_id());
}

test "stubs: CommandEncoder finish flips finished flag" {
    const t = std.testing;
    var enc: CommandEncoder = .{};
    try t.expect(!enc.finished);
    enc.finish();
    try t.expect(enc.finished);
}
