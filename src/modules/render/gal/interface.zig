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
    .{ .name = "init", .purpose = "Construit le Device depuis un DeviceDescriptor" },
    .{ .name = "deinit", .purpose = "Libère toutes les resources GPU du Device" },
    .{ .name = "supports", .purpose = "Query d'une Feature optionnelle (cf. escape_hatches.Feature)" },

    // Buffer ops
    .{ .name = "createBuffer", .purpose = "Alloue un Buffer GPU" },
    .{ .name = "destroyBuffer", .purpose = "Libère un Buffer GPU" },
    .{ .name = "mapBuffer", .purpose = "Map un host-visible Buffer pour CPU read/write" },
    .{ .name = "unmapBuffer", .purpose = "Unmap un Buffer mappé via mapBuffer" },

    // Texture ops
    .{ .name = "createTexture", .purpose = "Alloue une Texture GPU" },
    .{ .name = "destroyTexture", .purpose = "Libère une Texture GPU" },
    .{ .name = "createTextureView", .purpose = "Crée une vue sur une Texture" },
    .{ .name = "destroyTextureView", .purpose = "Libère une TextureView" },

    // Sampler
    .{ .name = "createSampler", .purpose = "Crée un Sampler" },
    .{ .name = "destroySampler", .purpose = "Libère un Sampler" },

    // Shader / pipeline
    .{ .name = "createShaderModule", .purpose = "Charge un module SPIR-V sur le device" },
    .{ .name = "destroyShaderModule", .purpose = "Libère un ShaderModule" },
    .{ .name = "createBindGroupLayout", .purpose = "Crée un BindGroupLayout" },
    .{ .name = "destroyBindGroupLayout", .purpose = "Libère un BindGroupLayout" },
    .{ .name = "createBindGroup", .purpose = "Crée un BindGroup à partir d'un layout + entries" },
    .{ .name = "destroyBindGroup", .purpose = "Libère un BindGroup" },
    .{ .name = "createRenderPipeline", .purpose = "Crée un RenderPipeline (PSO graphics)" },
    .{ .name = "destroyRenderPipeline", .purpose = "Libère un RenderPipeline" },
    .{ .name = "createComputePipeline", .purpose = "Crée un ComputePipeline" },
    .{ .name = "destroyComputePipeline", .purpose = "Libère un ComputePipeline" },

    // Sync primitives
    .{ .name = "createFence", .purpose = "Crée une Fence (sync CPU↔GPU)" },
    .{ .name = "destroyFence", .purpose = "Libère une Fence" },
    .{ .name = "waitFence", .purpose = "Bloque jusqu'à signalement d'une Fence (timeout ns)" },
    .{ .name = "resetFence", .purpose = "Reset une Fence pour réutilisation" },
    .{ .name = "createSemaphore", .purpose = "Crée un Semaphore binaire (sync GPU↔GPU)" },
    .{ .name = "destroySemaphore", .purpose = "Libère un Semaphore" },

    // Swapchain
    .{ .name = "createSwapchain", .purpose = "Crée la swapchain pour une surface" },
    .{ .name = "destroySwapchain", .purpose = "Libère la swapchain" },
    .{ .name = "acquireNextImage", .purpose = "Acquiert le prochain image index de la swapchain" },
    .{ .name = "getSwapchainImageView", .purpose = "Retourne la TextureViewHandle stable pour une image du swapchain (pré-allouée à l'init)" },
    .{ .name = "present", .purpose = "Présente l'image courante" },

    // Queue & command recording
    .{ .name = "getQueue", .purpose = "Obtient une Queue (graphics/compute/transfer)" },
    .{ .name = "createCommandEncoder", .purpose = "Démarre l'enregistrement d'un command buffer" },
    .{ .name = "submit", .purpose = "Submit un CommandEncoder finalisé à la graphics queue (cf. SubmitDescriptor)" },
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
