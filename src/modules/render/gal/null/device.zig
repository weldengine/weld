//! Backend Null GAL — Phase 0 / M0.4.
//!
//! Implémentation no-op des concepts GAL Phase 0 — utilisée pour les tests
//! headless en CI et pour valider que le contrat d'interface est satisfait
//! au comptime (cf. `interface.checkBackend`).
//!
//! Tous les `create*` retournent un handle valide avec un `inner` issu d'un
//! compteur monotone. Tous les `destroy*` sont no-op. `acquireNextImage`
//! retourne 0 ; `present` est no-op ; `waitFence` retourne immédiatement.
//!
//! Le backend ne touche jamais le hardware GPU. Aucune dépendance sur
//! Vulkan, Metal, D3D12. Compile sur toute plateforme cible Zig 0.16.x.

const std = @import("std");
const types = @import("../types.zig");
const escape = @import("../escape_hatches.zig");
const stubs = @import("stubs.zig");

/// Device Null. Stocke uniquement l'allocateur, un compteur de handles et
/// une queue unique (graphics+compute+transfer fused). Ne fait aucune
/// allocation système sauf au `init` (struct lui-même) et pour les command
/// encoders alloués via l'allocateur passé.
pub const Device = struct {
    allocator: std.mem.Allocator,
    descriptor: types.DeviceDescriptor,
    handles: stubs.HandleCounter = .{},
    /// Slot fictif pour la queue unique (graphics). `getQueue` retourne ce
    /// pointeur cast en `QueueHandle`. Inoffensif puisque Null ne déréférence
    /// jamais le QueueHandle.
    queue_slot: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, descriptor: types.DeviceDescriptor) types.Error!Device {
        return .{
            .allocator = allocator,
            .descriptor = descriptor,
        };
    }

    pub fn deinit(self: *Device) void {
        self.* = undefined;
    }

    pub fn supports(self: *Device, feature: escape.Feature) bool {
        _ = self;
        // Aucune feature optionnelle déclarée par le Null backend Phase 0.
        // Phase 1+ on pourrait simuler `timeline_semaphore = true` pour valider
        // les tests d'escape hatches sans Vulkan.
        return switch (feature) {
            else => false,
        };
    }

    // ---------------- Buffer / Texture / Sampler --------------------------

    pub fn createBuffer(self: *Device, descriptor: types.BufferDescriptor) types.Error!types.BufferHandle {
        _ = descriptor;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyBuffer(self: *Device, handle: types.BufferHandle) void {
        _ = .{ self, handle };
    }

    pub fn createTexture(self: *Device, descriptor: types.TextureDescriptor) types.Error!types.TextureHandle {
        // Phase 0 : sample_count > 1 non supporté (cohérent avec brief
        // §Out-of-scope MSAA).
        if (descriptor.sample_count > 1) return error.Unsupported;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyTexture(self: *Device, handle: types.TextureHandle) void {
        _ = .{ self, handle };
    }

    pub fn createTextureView(
        self: *Device,
        parent: types.TextureHandle,
        descriptor: types.TextureViewDescriptor,
    ) types.Error!types.TextureViewHandle {
        _ = .{ parent, descriptor };
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyTextureView(self: *Device, handle: types.TextureViewHandle) void {
        _ = .{ self, handle };
    }

    pub fn createSampler(self: *Device, descriptor: types.SamplerDescriptor) types.Error!types.SamplerHandle {
        _ = descriptor;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroySampler(self: *Device, handle: types.SamplerHandle) void {
        _ = .{ self, handle };
    }

    // ---------------- Shaders / pipelines ---------------------------------

    pub fn createShaderModule(self: *Device, descriptor: types.ShaderModuleDescriptor) types.Error!types.ShaderModuleHandle {
        if (descriptor.code.len == 0) return error.InvalidArgument;
        if (descriptor.code.len % 4 != 0) return error.InvalidArgument;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyShaderModule(self: *Device, handle: types.ShaderModuleHandle) void {
        _ = .{ self, handle };
    }

    pub fn createBindGroupLayout(self: *Device, descriptor: types.BindGroupLayoutDescriptor) types.Error!types.BindGroupLayoutHandle {
        _ = descriptor;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyBindGroupLayout(self: *Device, handle: types.BindGroupLayoutHandle) void {
        _ = .{ self, handle };
    }

    pub fn createBindGroup(self: *Device, descriptor: types.BindGroupDescriptor) types.Error!types.BindGroupHandle {
        if (!descriptor.layout.isValid()) return error.InvalidArgument;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyBindGroup(self: *Device, handle: types.BindGroupHandle) void {
        _ = .{ self, handle };
    }

    pub fn createRenderPipeline(self: *Device, descriptor: types.RenderPipelineDescriptor) types.Error!types.RenderPipelineHandle {
        if (!descriptor.vertex_module.isValid()) return error.InvalidArgument;
        if (descriptor.sample_count > 1) return error.Unsupported;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyRenderPipeline(self: *Device, handle: types.RenderPipelineHandle) void {
        _ = .{ self, handle };
    }

    pub fn createComputePipeline(self: *Device, descriptor: types.ComputePipelineDescriptor) types.Error!types.ComputePipelineHandle {
        if (!descriptor.module.isValid()) return error.InvalidArgument;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyComputePipeline(self: *Device, handle: types.ComputePipelineHandle) void {
        _ = .{ self, handle };
    }

    // ---------------- Sync primitives -------------------------------------

    pub fn createFence(self: *Device, signaled: bool) types.Error!types.FenceHandle {
        _ = signaled;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroyFence(self: *Device, handle: types.FenceHandle) void {
        _ = .{ self, handle };
    }

    pub fn waitFence(self: *Device, handle: types.FenceHandle, timeout_ns: u64) types.Error!void {
        _ = .{ self, handle, timeout_ns };
        // Null = jamais d'attente, signalement instantané.
    }

    pub fn resetFence(self: *Device, handle: types.FenceHandle) types.Error!void {
        _ = .{ self, handle };
    }

    pub fn createSemaphore(self: *Device) types.Error!types.SemaphoreHandle {
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroySemaphore(self: *Device, handle: types.SemaphoreHandle) void {
        _ = .{ self, handle };
    }

    // ---------------- Swapchain -------------------------------------------

    pub fn createSwapchain(self: *Device, descriptor: types.SwapchainDescriptor) types.Error!types.SwapchainHandle {
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidArgument;
        return .{ .inner = self.handles.next_id() };
    }

    pub fn destroySwapchain(self: *Device, handle: types.SwapchainHandle) void {
        _ = .{ self, handle };
    }

    pub fn acquireNextImage(
        self: *Device,
        handle: types.SwapchainHandle,
        signal_semaphore: ?types.SemaphoreHandle,
        timeout_ns: u64,
    ) types.Error!u32 {
        _ = .{ self, handle, signal_semaphore, timeout_ns };
        return 0;
    }

    pub fn present(
        self: *Device,
        handle: types.SwapchainHandle,
        image_index: u32,
        wait_semaphores: []const types.SemaphoreHandle,
    ) types.Error!void {
        _ = .{ self, handle, image_index, wait_semaphores };
    }

    // ---------------- Queue & command recording ---------------------------

    pub fn getQueue(self: *Device, queue_type: types.QueueType) types.Error!types.QueueHandle {
        _ = queue_type;
        return @ptrCast(&self.queue_slot);
    }

    pub fn createCommandEncoder(self: *Device, label: ?[]const u8) types.Error!*stubs.CommandEncoder {
        const enc = try self.allocator.create(stubs.CommandEncoder);
        enc.* = .{ .label = label };
        return enc;
    }

    /// Helper Null-spécifique pour libérer un CommandEncoder alloué par
    /// `createCommandEncoder`. N'est pas dans l'interface formelle Phase 0
    /// — le caller la connaît parce qu'il a passé l'allocateur au Device.
    pub fn destroyCommandEncoder(self: *Device, encoder: *stubs.CommandEncoder) void {
        self.allocator.destroy(encoder);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "null.Device: init / deinit cycle" {
    var device = try Device.init(testing.allocator, .{ .label = "test" });
    defer device.deinit();
    try testing.expectEqual(@as(u64, 1), device.handles.next);
}

test "null.Device: createBuffer returns monotone increasing handles" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();
    const b1 = try device.createBuffer(.{ .size = 1024, .usage = .{ .vertex = true } });
    const b2 = try device.createBuffer(.{ .size = 256, .usage = .{ .uniform = true } });
    try testing.expect(b1.inner > 0);
    try testing.expect(b2.inner > b1.inner);
    device.destroyBuffer(b1);
    device.destroyBuffer(b2);
}

test "null.Device: createTexture with sample_count > 1 returns Unsupported" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();
    const result = device.createTexture(.{
        .format = .rgba8_unorm,
        .width = 64,
        .height = 64,
        .sample_count = 4,
        .usage = .{ .color_attachment = true },
    });
    try testing.expectError(error.Unsupported, result);
}

test "null.Device: createShaderModule rejects non-aligned SPIR-V" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();
    const bad = device.createShaderModule(.{ .code = "abc" });
    try testing.expectError(error.InvalidArgument, bad);
    const empty = device.createShaderModule(.{ .code = &.{} });
    try testing.expectError(error.InvalidArgument, empty);
    const ok = try device.createShaderModule(.{ .code = "abcd" });
    try testing.expect(ok.isValid());
}

test "null.Device: createBindGroup rejects invalid layout" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();
    const bad = device.createBindGroup(.{ .layout = .{}, .entries = &.{} });
    try testing.expectError(error.InvalidArgument, bad);
}

test "null.Device: full lifecycle smoke — create / present / destroy" {
    var device = try Device.init(testing.allocator, .{ .label = "smoke" });
    defer device.deinit();

    const swap = try device.createSwapchain(.{ .width = 1280, .height = 720 });
    defer device.destroySwapchain(swap);

    const fence = try device.createFence(false);
    defer device.destroyFence(fence);
    try device.waitFence(fence, std.math.maxInt(u64));
    try device.resetFence(fence);

    const sem = try device.createSemaphore();
    defer device.destroySemaphore(sem);

    const image_index = try device.acquireNextImage(swap, sem, std.math.maxInt(u64));
    try testing.expectEqual(@as(u32, 0), image_index);
    try device.present(swap, image_index, &.{sem});

    const queue = try device.getQueue(.graphics);
    try testing.expect(@intFromPtr(queue) != 0);

    const enc = try device.createCommandEncoder("smoke-pass");
    defer device.destroyCommandEncoder(enc);
    var pass = enc.beginRenderPass(.{ .label = "pass" });
    pass.draw(3, 1, 0, 0);
    pass.end();
    enc.finish();
}

test "null.Device: createSwapchain rejects zero dimensions" {
    var device = try Device.init(testing.allocator, .{});
    defer device.deinit();
    try testing.expectError(error.InvalidArgument, device.createSwapchain(.{ .width = 0, .height = 720 }));
    try testing.expectError(error.InvalidArgument, device.createSwapchain(.{ .width = 1280, .height = 0 }));
}
