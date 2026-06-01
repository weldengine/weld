//! Comptime check of the GAL contract — Phase 0 / M0.4.
//!
//! Pattern inspired by Mach sysgpu (`engine-mach-reference.md` §2): no
//! runtime vtable, the backend is resolved at compile time and the interface
//! is checked by `comptime`. Every backend class (`Null`, `Vulkan`,
//! future `Metal`, `D3D12`, `WebGPU`) passes `checkBackend(Backend)` at
//! `comptime` — if a method is missing, the build breaks with a clear message.
//!
//! Phase 0: presence check + first-parameter signature
//! (`*Backend`). Phase 1+: extension to full signature checking
//! (parameters + return types) on the sysgpu model (~2,700
//! lines of assertions). Phase 0 stays pragmatic so as not to block
//! the Vulkan backend's progress.

const std = @import("std");
const types = @import("types.zig");

/// Required method on a backend. Presence is checked at comptime;
/// the full signature remains to be extended Phase 1+.
const RequiredMethod = struct {
    name: []const u8,
    /// Doc message shown on error — guides the reader toward the
    /// corresponding spec section.
    purpose: []const u8,
};

/// List of methods required for any Phase 0 GAL backend. Logical order
/// (device lifecycle → resources → pipeline → frame).
pub const required_methods = [_]RequiredMethod{
    // Lifecycle
    .{ .name = "init", .purpose = "Builds the Device from a DeviceDescriptor" },
    .{ .name = "deinit", .purpose = "Frees all the Device's GPU resources" },
    .{ .name = "supports", .purpose = "Query of an optional Feature (cf. escape_hatches.Feature)" },

    // Buffer ops
    .{ .name = "createBuffer", .purpose = "Allocates a GPU Buffer" },
    .{ .name = "destroyBuffer", .purpose = "Frees a GPU Buffer" },
    .{ .name = "mapBuffer", .purpose = "Maps a host-visible Buffer for CPU read/write" },
    .{ .name = "unmapBuffer", .purpose = "Unmaps a Buffer mapped via mapBuffer" },

    // Texture ops
    .{ .name = "createTexture", .purpose = "Allocates a GPU Texture" },
    .{ .name = "destroyTexture", .purpose = "Frees a GPU Texture" },
    .{ .name = "createTextureView", .purpose = "Creates a view on a Texture" },
    .{ .name = "destroyTextureView", .purpose = "Frees a TextureView" },

    // Sampler
    .{ .name = "createSampler", .purpose = "Creates a Sampler" },
    .{ .name = "destroySampler", .purpose = "Frees a Sampler" },

    // Shader / pipeline
    .{ .name = "createShaderModule", .purpose = "Loads a SPIR-V module on the device" },
    .{ .name = "destroyShaderModule", .purpose = "Frees a ShaderModule" },
    .{ .name = "createBindGroupLayout", .purpose = "Creates a BindGroupLayout" },
    .{ .name = "destroyBindGroupLayout", .purpose = "Frees a BindGroupLayout" },
    .{ .name = "createBindGroup", .purpose = "Creates a BindGroup from a layout + entries" },
    .{ .name = "destroyBindGroup", .purpose = "Frees a BindGroup" },
    .{ .name = "createRenderPipeline", .purpose = "Creates a RenderPipeline (graphics PSO)" },
    .{ .name = "destroyRenderPipeline", .purpose = "Frees a RenderPipeline" },
    .{ .name = "createComputePipeline", .purpose = "Creates a ComputePipeline" },
    .{ .name = "destroyComputePipeline", .purpose = "Frees a ComputePipeline" },

    // Sync primitives
    .{ .name = "createFence", .purpose = "Creates a Fence (CPU↔GPU sync)" },
    .{ .name = "destroyFence", .purpose = "Frees a Fence" },
    .{ .name = "waitFence", .purpose = "Blocks until a Fence is signaled (timeout ns)" },
    .{ .name = "resetFence", .purpose = "Resets a Fence for reuse" },
    .{ .name = "createSemaphore", .purpose = "Creates a binary Semaphore (GPU↔GPU sync)" },
    .{ .name = "destroySemaphore", .purpose = "Frees a Semaphore" },

    // Swapchain
    .{ .name = "createSwapchain", .purpose = "Creates the swapchain for a surface" },
    .{ .name = "destroySwapchain", .purpose = "Frees the swapchain" },
    .{ .name = "acquireNextImage", .purpose = "Acquires the swapchain's next image index" },
    .{ .name = "getSwapchainImageView", .purpose = "Returns the stable TextureViewHandle for a swapchain image (pre-allocated at init)" },
    .{ .name = "present", .purpose = "Presents the current image" },

    // Queue & command recording
    .{ .name = "getQueue", .purpose = "Gets a Queue (graphics/compute/transfer)" },
    .{ .name = "createCommandEncoder", .purpose = "Starts recording a command buffer" },
    .{ .name = "submit", .purpose = "Submits a finished CommandEncoder to the graphics queue (cf. SubmitDescriptor)" },
};

/// Comptime check that `Backend` declares all the required methods.
/// Called as `comptime interface.checkBackend(Backend)` during the
/// instantiation of the `gal.main.Device` wrapper. Returns `void` on
/// success, triggers a `@compileError` on a missing method.
pub fn checkBackend(comptime Backend: type) void {
    comptime {
        for (required_methods) |m| {
            if (!@hasDecl(Backend, m.name)) {
                @compileError(std.fmt.comptimePrint(
                    "GAL backend `{s}` missing required method `{s}` ({s}). " ++
                        "See src/modules/render/gal/interface.zig for the full list.",
                    .{ @typeName(Backend), m.name, m.purpose },
                ));
            }
        }
    }
}

/// Lists the required methods as text (debug / docgen).
pub fn listRequiredMethods(writer: anytype) !void {
    inline for (required_methods) |m| {
        try writer.print("- {s}: {s}\n", .{ m.name, m.purpose });
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Minimal backend "shape" for the tests — declares all the required
/// methods with bodyless stubs (never called). Do not use outside
/// interface tests.
const TestShape = struct {
    pub fn init(allocator: std.mem.Allocator, descriptor: types.DeviceDescriptor) types.Error!TestShape {
        _ = .{ allocator, descriptor };
        return .{};
    }
    pub fn deinit(self: *TestShape) void {
        _ = self;
    }
    pub fn supports(self: *TestShape, feature: @import("escape_hatches.zig").Feature) bool {
        _ = .{ self, feature };
        return false;
    }
    pub fn createBuffer(self: *TestShape, d: types.BufferDescriptor) types.Error!types.BufferHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyBuffer(self: *TestShape, h: types.BufferHandle) void {
        _ = .{ self, h };
    }
    pub fn mapBuffer(self: *TestShape, h: types.BufferHandle) types.Error![]u8 {
        _ = .{ self, h };
        return &[_]u8{};
    }
    pub fn unmapBuffer(self: *TestShape, h: types.BufferHandle) void {
        _ = .{ self, h };
    }
    pub fn createTexture(self: *TestShape, d: types.TextureDescriptor) types.Error!types.TextureHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyTexture(self: *TestShape, h: types.TextureHandle) void {
        _ = .{ self, h };
    }
    pub fn createTextureView(self: *TestShape, parent: types.TextureHandle, d: types.TextureViewDescriptor) types.Error!types.TextureViewHandle {
        _ = .{ self, parent, d };
        return .{};
    }
    pub fn destroyTextureView(self: *TestShape, h: types.TextureViewHandle) void {
        _ = .{ self, h };
    }
    pub fn createSampler(self: *TestShape, d: types.SamplerDescriptor) types.Error!types.SamplerHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroySampler(self: *TestShape, h: types.SamplerHandle) void {
        _ = .{ self, h };
    }
    pub fn createShaderModule(self: *TestShape, d: types.ShaderModuleDescriptor) types.Error!types.ShaderModuleHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyShaderModule(self: *TestShape, h: types.ShaderModuleHandle) void {
        _ = .{ self, h };
    }
    pub fn createBindGroupLayout(self: *TestShape, d: types.BindGroupLayoutDescriptor) types.Error!types.BindGroupLayoutHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyBindGroupLayout(self: *TestShape, h: types.BindGroupLayoutHandle) void {
        _ = .{ self, h };
    }
    pub fn createBindGroup(self: *TestShape, d: types.BindGroupDescriptor) types.Error!types.BindGroupHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyBindGroup(self: *TestShape, h: types.BindGroupHandle) void {
        _ = .{ self, h };
    }
    pub fn createRenderPipeline(self: *TestShape, d: types.RenderPipelineDescriptor) types.Error!types.RenderPipelineHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyRenderPipeline(self: *TestShape, h: types.RenderPipelineHandle) void {
        _ = .{ self, h };
    }
    pub fn createComputePipeline(self: *TestShape, d: types.ComputePipelineDescriptor) types.Error!types.ComputePipelineHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroyComputePipeline(self: *TestShape, h: types.ComputePipelineHandle) void {
        _ = .{ self, h };
    }
    pub fn createFence(self: *TestShape, signaled: bool) types.Error!types.FenceHandle {
        _ = .{ self, signaled };
        return .{};
    }
    pub fn destroyFence(self: *TestShape, h: types.FenceHandle) void {
        _ = .{ self, h };
    }
    pub fn waitFence(self: *TestShape, h: types.FenceHandle, timeout_ns: u64) types.Error!void {
        _ = .{ self, h, timeout_ns };
    }
    pub fn resetFence(self: *TestShape, h: types.FenceHandle) types.Error!void {
        _ = .{ self, h };
    }
    pub fn createSemaphore(self: *TestShape) types.Error!types.SemaphoreHandle {
        _ = self;
        return .{};
    }
    pub fn destroySemaphore(self: *TestShape, h: types.SemaphoreHandle) void {
        _ = .{ self, h };
    }
    pub fn createSwapchain(self: *TestShape, d: types.SwapchainDescriptor) types.Error!types.SwapchainHandle {
        _ = .{ self, d };
        return .{};
    }
    pub fn destroySwapchain(self: *TestShape, h: types.SwapchainHandle) void {
        _ = .{ self, h };
    }
    pub fn acquireNextImage(self: *TestShape, h: types.SwapchainHandle, signal_semaphore: ?types.SemaphoreHandle, timeout_ns: u64) types.Error!u32 {
        _ = .{ self, h, signal_semaphore, timeout_ns };
        return 0;
    }
    pub fn getSwapchainImageView(self: *TestShape, h: types.SwapchainHandle, image_index: u32) types.TextureViewHandle {
        _ = .{ self, h, image_index };
        return .{};
    }
    pub fn present(self: *TestShape, h: types.SwapchainHandle, image_index: u32, wait_semaphores: []const types.SemaphoreHandle) types.Error!void {
        _ = .{ self, h, image_index, wait_semaphores };
    }
    pub fn getQueue(self: *TestShape, queue_type: types.QueueType) types.Error!types.QueueHandle {
        _ = .{ self, queue_type };
        return @ptrFromInt(@as(usize, 0xDEAD));
    }
    pub fn createCommandEncoder(self: *TestShape, label: ?[]const u8) types.Error!*CommandEncoderStub {
        _ = .{ self, label };
        return undefined;
    }
    pub fn submit(self: *TestShape, encoder: *CommandEncoderStub, descriptor: types.SubmitDescriptor) types.Error!void {
        _ = .{ self, encoder, descriptor };
    }
};

const CommandEncoderStub = struct {};

test "interface: TestShape passes checkBackend" {
    comptime checkBackend(TestShape);
}

test "interface: required_methods is non-empty" {
    try std.testing.expect(required_methods.len > 0);
}
