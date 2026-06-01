//! CommandEncoder + RenderPassEncoder + ComputePassEncoder Vulkan — Phase 0 / M0.4.
//!
//! The GAL CommandEncoder wraps a `*vk.CommandBuffer` allocated from the
//! Device's shared command pool. The semantics:
//! - `createCommandEncoder` allocates + `beginCommandBuffer`
//! - `finish` calls `endCommandBuffer`
//! - `destroy` frees the buffer and the encoder itself
//!
//! The RenderPassEncoder/ComputePassEncoder are flat structs that hold a
//! pointer to the `CommandBuffer` and call the corresponding `cmd*`.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const escape = @import("../escape_hatches.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const buffer_mod = @import("buffer.zig");
const texture_mod = @import("texture.zig");
const bind_mod = @import("bind_group.zig");
const pipeline_mod = @import("pipeline.zig");
const render_pass_mod = @import("render_pass.zig");

/// Vulkan CommandEncoder — wraps a `*vk.CommandBuffer` allocated from the
/// shared command pool. The GAL semantics are consistent with WebGPU:
/// `create` opens recording, `finish` closes it, `destroy` frees the
/// buffer on the CPU side (the GPU may still be executing it).
pub const CommandEncoder = struct {
    device: *Device,
    cb: *vk.CommandBuffer,
    label: ?[]const u8 = null,
    finished: bool = false,
    /// Transient resources (render pass + framebuffer) to free in
    /// `destroy`. Phase 0 simple: we keep only one at a time — the
    /// limitation corresponds to 1 begin/end render pass per encoder.
    active_pass: ?render_pass_mod.Transient = null,
    /// Tracks whether `vkCmdBeginRenderPass` has been issued without a
    /// matching `vkCmdEndRenderPass`. Separate from `active_pass` (which
    /// owns the render pass + framebuffer resources for cleanup) — once
    /// `RenderPassEncoder.end()` fires the Vulkan side closes
    /// immediately so cmdCopy* / blit / barrier after the pass do not
    /// land inside an active render pass (Bug 4 of the stabilization).
    pass_active: bool = false,

    pub fn beginRenderPass(self: *CommandEncoder, descriptor: types.RenderPassDescriptor) types.Error!RenderPassEncoder {
        if (self.finished) return error.InvalidArgument;
        var t = try render_pass_mod.begin(self.device, descriptor);
        const begin_info: vk.RenderPassBeginInfo = .{
            .render_pass = t.render_pass,
            .framebuffer = t.framebuffer,
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = t.extent },
            .clear_value_count = t.clear_count,
            .p_clear_values = if (t.clear_count > 0) @ptrCast(&t.clear_values) else undefined,
        };
        self.cb.cmdBeginRenderPass(&begin_info, .@"inline");
        self.active_pass = t;
        self.pass_active = true;
        return .{ .parent = self, .device = self.device, .cb = self.cb };
    }

    pub fn beginComputePass(self: *CommandEncoder, descriptor: types.ComputePassDescriptor) ComputePassEncoder {
        _ = descriptor;
        return .{ .device = self.device, .cb = self.cb };
    }

    pub fn copyBufferToBuffer(
        self: *CommandEncoder,
        src: types.BufferHandle,
        src_offset: u64,
        dst: types.BufferHandle,
        dst_offset: u64,
        size: u64,
    ) void {
        const src_buf = buffer_mod.lookup(self.device, src) orelse return;
        const dst_buf = buffer_mod.lookup(self.device, dst) orelse return;
        const region: vk.BufferCopy = .{
            .src_offset = src_offset,
            .dst_offset = dst_offset,
            .size = size,
        };
        self.cb.cmdCopyBuffer(src_buf, dst_buf, &.{region});
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
        // Phase 0: not implemented on the Vulkan side, silent no-op. Phase 1+
        // via `vkCmdCopyBufferToImage` + layout transitions.
    }

    /// Copy a texture region into a host-visible buffer. WebGPU canonical
    /// shape (source/dest/copy_size triple). Phase 0 contract: the source
    /// texture is assumed to already be in `.transfer_src_optimal` layout
    /// when the GPU executes the copy — render-pass `finalLayout` or a
    /// caller-emitted barrier must put it there. `dest.bytes_per_row` is
    /// honored when non-zero; otherwise Vulkan tight-packs the row stride
    /// from the image extent.
    pub fn copyTextureToBuffer(
        self: *CommandEncoder,
        source: types.ImageCopyTexture,
        dest: types.ImageCopyBuffer,
        copy_size: types.Extent3D,
    ) void {
        const src_img = texture_mod.lookupImage(self.device, source.texture) orelse return;
        const dst_buf = buffer_mod.lookup(self.device, dest.buffer) orelse return;

        const aspect_mask: vk.ImageAspectFlags = switch (source.aspect) {
            .all, .color => .{ .color = true },
            .depth => .{ .depth = true },
            .stencil => .{ .stencil = true },
        };

        // WebGPU `bytesPerRow` is bytes; Vulkan `buffer_row_length` is
        // pixels. Phase 0 assumes RGBA8 (4 bpp) for the capture path; if
        // the caller passes 0 we let Vulkan tight-pack.
        const row_length: u32 = if (dest.bytes_per_row == 0) 0 else dest.bytes_per_row / 4;

        const region: vk.BufferImageCopy = .{
            .buffer_offset = dest.offset,
            .buffer_row_length = row_length,
            .buffer_image_height = dest.rows_per_image,
            .image_subresource = .{
                .aspect_mask = aspect_mask,
                .mip_level = source.mip_level,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{
                .x = @intCast(source.origin.x),
                .y = @intCast(source.origin.y),
                .z = @intCast(source.origin.z),
            },
            .image_extent = .{
                .width = copy_size.width,
                .height = copy_size.height,
                .depth = copy_size.depth_or_array_layers,
            },
        };

        self.cb.cmdCopyImageToBuffer(
            src_img,
            .transfer_src_optimal,
            dst_buf,
            &.{region},
        );
    }

    pub fn finish(self: *CommandEncoder) void {
        if (self.finished) return;
        // Safety net: if the caller forgot `pass.end()`, close the
        // render pass here. The recommended call site is
        // `RenderPassEncoder.end()` which fires immediately so subsequent
        // copy / blit commands stay outside the pass scope.
        if (self.pass_active) {
            self.cb.cmdEndRenderPass();
            self.pass_active = false;
        }
        self.cb.endCommandBuffer() catch {};
        self.finished = true;
    }
};

/// Vulkan RenderPassEncoder — delegated by `CommandEncoder.beginRenderPass`.
/// Flat struct, not allocated separately from the CommandEncoder. Carries
/// a back-pointer to the parent so `end()` can mark the encoder's render
/// pass slot as closed — without this, callers issuing `cmdCopy*` after a
/// nominal `pass.end()` would fall inside the still-active Vulkan render
/// pass (Bug 4 of the M0.4 stabilization session).
pub const RenderPassEncoder = struct {
    parent: *CommandEncoder,
    device: *Device,
    cb: *vk.CommandBuffer,

    pub fn setPipeline(self: *RenderPassEncoder, pipeline: types.RenderPipelineHandle) void {
        const entry = pipeline_mod.lookup(self.device, pipeline) orelse return;
        self.cb.cmdBindPipeline(.graphics, entry.pipeline);
    }

    pub fn setBindGroup(self: *RenderPassEncoder, slot: u32, group: types.BindGroupHandle) void {
        const set = bind_mod.lookupSet(self.device, group) orelse return;
        // To bind correctly we need the pipeline_layout — Phase 0
        // pattern: the caller called setPipeline just before, we assume
        // the last bound pipeline is still current. Phase 1+:
        // track the current layout via a state machine.
        _ = .{ slot, set };
        // Phase 0: no effective binding without a tracker — call site no-op.
    }

    pub fn setVertexBuffer(self: *RenderPassEncoder, slot: u32, buffer: types.BufferHandle, offset: u64) void {
        const buf = buffer_mod.lookup(self.device, buffer) orelse return;
        const offsets: [1]vk.DeviceSize = .{offset};
        self.cb.cmdBindVertexBuffers(slot, &.{buf}, &offsets);
    }

    pub fn setIndexBuffer(
        self: *RenderPassEncoder,
        buffer: types.BufferHandle,
        offset: u64,
        index_type: enum { u16, u32 },
    ) void {
        const buf = buffer_mod.lookup(self.device, buffer) orelse return;
        const it: vk.IndexType = switch (index_type) {
            .u16 => .uint16,
            .u32 => .uint32,
        };
        self.cb.cmdBindIndexBuffer(buf, offset, it);
    }

    pub fn draw(
        self: *RenderPassEncoder,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        self.cb.cmdDraw(vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexed(
        self: *RenderPassEncoder,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        vertex_offset: i32,
        first_instance: u32,
    ) void {
        self.cb.cmdDrawIndexed(index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    pub fn setViewport(
        self: *RenderPassEncoder,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        min_depth: f32,
        max_depth: f32,
    ) void {
        const vp: vk.Viewport = .{
            .x = x,
            .y = y,
            .width = w,
            .height = h,
            .min_depth = min_depth,
            .max_depth = max_depth,
        };
        self.cb.cmdSetViewport(0, &.{vp});
    }

    pub fn setScissor(self: *RenderPassEncoder, x: i32, y: i32, w: u32, h: u32) void {
        const r: vk.Rect2D = .{
            .offset = .{ .x = x, .y = y },
            .extent = .{ .width = w, .height = h },
        };
        self.cb.cmdSetScissor(0, &.{r});
    }

    pub fn barrier(self: *RenderPassEncoder, barrier_desc: escape.ExplicitBarrier) void {
        _ = .{ self, barrier_desc };
        // Phase 0: explicit barriers not wired (auto-tracking by default).
        // First use Phase 1+ (cf. brief §Notes decision 2).
    }

    pub fn end(self: *RenderPassEncoder) void {
        // Close the Vulkan render pass immediately so the caller can
        // issue post-pass commands (cmdCopyImageToBuffer, blits, …) on
        // the same encoder. `CommandEncoder.finish` keys off
        // `pass_active` to avoid a double `cmdEndRenderPass`. The
        // `active_pass` Transient itself stays populated so the
        // CommandEncoder destroy can free the render pass + framebuffer
        // GPU resources after the submission completes.
        if (self.parent.pass_active) {
            self.cb.cmdEndRenderPass();
            self.parent.pass_active = false;
        }
    }
};

/// Vulkan ComputePassEncoder — delegated by `CommandEncoder.beginComputePass`.
/// Phase 0 — used in Phase 1+ (GI compute, V-Buffer culling).
pub const ComputePassEncoder = struct {
    device: *Device,
    cb: *vk.CommandBuffer,

    pub fn setPipeline(self: *ComputePassEncoder, pipeline: types.ComputePipelineHandle) void {
        const entry = pipeline_mod.lookup(self.device, .{ .inner = pipeline.inner }) orelse return;
        self.cb.cmdBindPipeline(.compute, entry.pipeline);
    }

    pub fn setBindGroup(self: *ComputePassEncoder, slot: u32, group: types.BindGroupHandle) void {
        _ = .{ self, slot, group };
    }

    pub fn dispatch(self: *ComputePassEncoder, x: u32, y: u32, z: u32) void {
        self.cb.cmdDispatch(x, y, z);
    }

    pub fn barrier(self: *ComputePassEncoder, barrier_desc: escape.ExplicitBarrier) void {
        _ = .{ self, barrier_desc };
    }

    pub fn end(self: *ComputePassEncoder) void {
        _ = self;
    }
};

/// Allocates + initializes a CommandEncoder from the Device's shared
/// command pool. Calls `beginCommandBuffer` immediately.
pub fn create(device: *Device, label: ?[]const u8) types.Error!*CommandEncoder {
    const alloc_ci: vk.CommandBufferAllocateInfo = .{
        .command_pool = device.command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var bufs: [1]*vk.CommandBuffer = undefined;
    device.vk_device.allocateCommandBuffers(&alloc_ci, &bufs) catch return error.BackendInternal;

    const begin: vk.CommandBufferBeginInfo = .{
        .flags = .empty,
        .p_inheritance_info = null,
    };
    bufs[0].beginCommandBuffer(&begin) catch return error.BackendInternal;

    const enc = device.allocator.create(CommandEncoder) catch return error.OutOfMemory;
    enc.* = .{
        .device = device,
        .cb = bufs[0],
        .label = label,
    };
    return enc;
}

/// Frees a CommandEncoder. Destroys the transient pass if still active.
/// The `vk.CommandBuffer` is not explicitly freed — the pool will be reset
/// on the caller's next `resetCommandBuffer`.
///
/// Phase 0 safety net: when destroying a CommandEncoder that owned an
/// `active_pass` (= a render pass + framebuffer Transient), we wait on
/// `vkDeviceWaitIdle` before tearing the GPU resources down. Without
/// the wait, callers who `defer destroyCommandEncoder` immediately
/// after `device.submit` (the common pattern) trigger Vulkan's
/// `Framebuffer is currently in use by VkCommandBuffer` warning
/// because the GPU may still be executing the pass. The wait is
/// over-cautious — Phase 1+ a per-encoder fence + retire queue will
/// scope this more tightly — but it matches the S2 pattern
/// (`/tmp/s2-ref/src/spike/vk_setup.zig:recreateSwapchain` calls
/// `waitIdle` before destroying its framebuffers) and keeps Phase 0
/// callers honest by default.
pub fn destroy(device: *Device, encoder: *CommandEncoder) void {
    if (encoder.active_pass) |*t| {
        device.vk_device.waitIdle() catch {};
        t.destroy(device.vk_device);
        encoder.active_pass = null;
    }
    // The command buffer is freed when the pool is reset/destroyed — we
    // don't need to call `freeCommandBuffers` in Phase 0 (the pool is
    // created with the `reset_command_buffer` flag, the caller can do
    // `cmd.resetCommandBuffer` before the next use).
    device.allocator.destroy(encoder);
}
