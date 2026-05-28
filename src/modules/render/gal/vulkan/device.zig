//! Vulkan backend Device — Phase 0 / M0.4.
//!
//! Root du backend Vulkan GAL. Implémente les 33 méthodes requises par
//! `interface.checkBackend` (cf. `gal/interface.zig`). Port progressif du
//! code spike S2 (`src/spike/vk_setup.zig` + `src/spike/vk_frame.zig`)
//! vers la surface GAL.
//!
//! **Sélection multi-GPU + multi-driver** (brief §Scope + §Notes décision 11) :
//! - `--gpu-prefer=<discrete|integrated|index:N>` inchangé vs S2.
//! - `--vulkan-driver=<auto|hardware|software>` nouveau M0.4 : `auto` =
//!   énumère tous les devices et applique `--gpu-prefer` ; `hardware` =
//!   filtre les `device_type = CPU` avant `--gpu-prefer` ; `software` =
//!   force lavapipe (filtre sur `device_type = CPU`), ignore `--gpu-prefer`.
//! - Combinaison conflictuelle `software + gpu-prefer=discrete` : log warn,
//!   driver gagne, continue.
//!
//! **Mapping handles GAL → Vulkan natif** :
//! - Handles simples (Sampler, ShaderModule, Fence, Semaphore, RenderPass,
//!   Pipeline, PipelineLayout, DescriptorSetLayout, DescriptorSet,
//!   SwapchainKHR) : `inner = @intFromEnum(vk_handle)`. Pas de stockage
//!   interne. La destruction utilise `@enumFromInt(handle.inner)`.
//! - Handles avec state additionnel (Buffer, Texture, TextureView,
//!   BindGroup, RenderPipeline) : registry interne `std.AutoHashMapUnmanaged`
//!   indexé par un compteur monotone.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const window_mod = weld_core.platform.window;
const types = @import("../types.zig");
const escape = @import("../escape_hatches.zig");
const conv = @import("conv.zig");
const swap = @import("swapchain.zig");
const surface_mod = @import("surface.zig");
const buffer_mod = @import("buffer.zig");
const texture_mod = @import("texture.zig");
const pipeline_mod = @import("pipeline.zig");
const bind_mod = @import("bind_group.zig");
const cmd_mod = @import("command_encoder.zig");
const sync_mod = @import("sync.zig");
const queue_mod = @import("queue.zig");
const frame_mod = @import("frame.zig");

const log = std.log.scoped(.gal_vk);

/// Statistiques de sélection device — exposées pour debug.
pub const DeviceSelection = struct {
    physical_device_name: [vk.MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    device_type: enum { other, integrated, discrete, virtual, cpu },
    queue_family_index: u32,
};

/// Device Vulkan — implémente l'interface GAL.
pub const Device = struct {
    allocator: std.mem.Allocator,
    descriptor: types.DeviceDescriptor,

    // Vulkan natif.
    vk_instance: *vk.Instance,
    debug_messenger: ?vk.DebugUtilsMessengerEXT = null,
    physical_device: *vk.PhysicalDevice,
    vk_device: *vk.Device,
    surface: vk.SurfaceKHR = .null,
    vk_queue: *vk.Queue,
    queue_family_index: u32,

    selection: DeviceSelection,

    // Compteur monotone pour les handles GAL qui ont besoin d'un registry.
    next_handle_id: u64 = 1,

    // Registries internes (resources avec state additionnel).
    buffers: std.AutoHashMapUnmanaged(u64, buffer_mod.Entry) = .empty,
    textures: std.AutoHashMapUnmanaged(u64, texture_mod.TextureEntry) = .empty,
    texture_views: std.AutoHashMapUnmanaged(u64, texture_mod.ViewEntry) = .empty,
    bind_groups: std.AutoHashMapUnmanaged(u64, bind_mod.Entry) = .empty,
    render_pipelines: std.AutoHashMapUnmanaged(u64, pipeline_mod.RenderEntry) = .empty,
    swapchains: std.AutoHashMapUnmanaged(u64, swap.Entry) = .empty,

    // Command pool partagée — créée à l'init, sert à allouer les
    // CommandBuffers pour les encoders.
    command_pool: vk.CommandPool = .null,

    pub fn init(allocator: std.mem.Allocator, descriptor: types.DeviceDescriptor) types.Error!Device {
        vk.loadLoader() catch return error.NotInitialized;

        var device: Device = .{
            .allocator = allocator,
            .descriptor = descriptor,
            .vk_instance = undefined,
            .physical_device = undefined,
            .vk_device = undefined,
            .vk_queue = undefined,
            .queue_family_index = 0,
            .selection = std.mem.zeroes(DeviceSelection),
        };

        const instance_result = createInstance(allocator, descriptor) catch |e| {
            // log.debug : ce path est exercé en CI Linux qui n'a pas de
            // device Vulkan utilisable — le caller (typiquement un test)
            // catch l'erreur et skip. log.err déclencherait un faux
            // positif de test failure en Zig 0.16.
            log.debug("vk: createInstance failed: {t}", .{e});
            return error.NotInitialized;
        };
        device.vk_instance = instance_result.instance;
        errdefer device.vk_instance.destroyInstance(null);
        vk.loadInstance(device.vk_instance) catch return error.NotInitialized;

        // VK_EXT_debug_utils activation is conditional to the validation
        // layer being present at vkCreateInstance time. If the layer is
        // absent (e.g. Fedora 44 without vulkan-validation-layers), the
        // extension is not activated, the function pointer is NULL, and
        // a raw call would SIGSEGV. `catch null` does not catch hardware
        // faults. We gate on the bool tracked by createInstance.
        device.debug_messenger = if (instance_result.debug_utils_enabled)
            createDebugMessenger(device.vk_instance) catch null
        else
            null;

        try pickPhysicalDevice(&device, allocator, descriptor);

        createLogicalDevice(&device) catch |e| {
            log.debug("vk: createLogicalDevice failed: {t}", .{e});
            return error.NotInitialized;
        };
        errdefer device.vk_device.destroyDevice(null);
        vk.loadDevice(device.vk_device) catch return error.NotInitialized;

        device.vk_queue = device.vk_device.getDeviceQueue(device.queue_family_index, 0);

        // Command pool partagée.
        const pool_ci: vk.CommandPoolCreateInfo = .{
            .flags = .{ .reset_command_buffer = true },
            .queue_family_index = device.queue_family_index,
        };
        device.command_pool = device.vk_device.createCommandPool(&pool_ci, null) catch return error.BackendInternal;

        return device;
    }

    pub fn deinit(self: *Device) void {
        self.vk_device.waitIdle() catch {};

        // Vide les registries (libère les vk handles).
        var bit = self.buffers.valueIterator();
        while (bit.next()) |entry| entry.destroy(self.vk_device);
        self.buffers.deinit(self.allocator);

        var tit = self.textures.valueIterator();
        while (tit.next()) |entry| entry.destroy(self.vk_device);
        self.textures.deinit(self.allocator);

        var vit = self.texture_views.valueIterator();
        while (vit.next()) |entry| entry.destroy(self.vk_device);
        self.texture_views.deinit(self.allocator);

        var git = self.bind_groups.valueIterator();
        while (git.next()) |entry| entry.destroy(self.vk_device);
        self.bind_groups.deinit(self.allocator);

        var pit = self.render_pipelines.valueIterator();
        while (pit.next()) |entry| entry.destroy(self.vk_device);
        self.render_pipelines.deinit(self.allocator);

        var sit = self.swapchains.valueIterator();
        while (sit.next()) |entry| entry.destroy(self.vk_device, self.allocator);
        self.swapchains.deinit(self.allocator);

        if (self.command_pool != .null) self.vk_device.destroyCommandPool(self.command_pool, null);

        self.vk_device.destroyDevice(null);
        if (self.debug_messenger) |m| self.vk_instance.destroyDebugUtilsMessengerEXT(m, null);
        if (self.surface != .null) self.vk_instance.destroySurfaceKHR(self.surface, null);
        self.vk_instance.destroyInstance(null);

        self.* = undefined;
    }

    pub fn supports(self: *Device, feature: escape.Feature) bool {
        _ = self;
        // Phase 0 : aucune feature optionnelle exposée par défaut côté Vulkan.
        // Phase 1+ : query au load et expose `timeline_semaphore`, etc.
        return switch (feature) {
            else => false,
        };
    }

    /// Helper interne — alloue un nouveau handle id monotone.
    pub fn nextHandle(self: *Device) u64 {
        const id = self.next_handle_id;
        self.next_handle_id += 1;
        return id;
    }

    // ====================================================================
    // Surface (M0.4 § Scope — Complément Post-Review)
    // ====================================================================

    /// Build a `SurfaceHandle` from an already-open Tier 0 window. The
    /// resulting `vk.SurfaceKHR` is owned by the device and destroyed
    /// by `deinit`. Calling twice on the same device returns the
    /// existing handle as a courtesy rather than leaking the first
    /// surface.
    pub fn createSurfaceFromWindow(
        self: *Device,
        window: *const window_mod.Window,
    ) types.Error!types.SurfaceHandle {
        if (self.surface != .null) {
            return .{ .inner = @intFromEnum(self.surface) };
        }
        const native = try surface_mod.createFromWindow(self.vk_instance, window);
        self.surface = native;
        return .{ .inner = @intFromEnum(native) };
    }

    // ====================================================================
    // Buffer
    // ====================================================================

    pub fn createBuffer(self: *Device, descriptor: types.BufferDescriptor) types.Error!types.BufferHandle {
        return buffer_mod.create(self, descriptor);
    }

    pub fn destroyBuffer(self: *Device, handle: types.BufferHandle) void {
        buffer_mod.destroy(self, handle);
    }

    /// Map a host-visible buffer for CPU read/write. The returned slice is
    /// invalidated by `unmapBuffer`. Returns `error.Unsupported` if the
    /// buffer was created with `host_visible = false`.
    pub fn mapBuffer(self: *Device, handle: types.BufferHandle) types.Error![]u8 {
        return buffer_mod.map(self, handle);
    }

    /// Unmap a buffer previously mapped via `mapBuffer`. No-op if not mapped.
    pub fn unmapBuffer(self: *Device, handle: types.BufferHandle) void {
        buffer_mod.unmap(self, handle);
    }

    // ====================================================================
    // Texture / TextureView
    // ====================================================================

    pub fn createTexture(self: *Device, descriptor: types.TextureDescriptor) types.Error!types.TextureHandle {
        return texture_mod.createTexture(self, descriptor);
    }

    pub fn destroyTexture(self: *Device, handle: types.TextureHandle) void {
        texture_mod.destroyTexture(self, handle);
    }

    pub fn createTextureView(
        self: *Device,
        parent: types.TextureHandle,
        descriptor: types.TextureViewDescriptor,
    ) types.Error!types.TextureViewHandle {
        return texture_mod.createView(self, parent, descriptor);
    }

    pub fn destroyTextureView(self: *Device, handle: types.TextureViewHandle) void {
        texture_mod.destroyView(self, handle);
    }

    // ====================================================================
    // Sampler (mapping direct via @intFromEnum)
    // ====================================================================

    pub fn createSampler(self: *Device, descriptor: types.SamplerDescriptor) types.Error!types.SamplerHandle {
        const filterOf = struct {
            fn of(f: anytype) vk.Filter {
                return switch (f) {
                    .nearest => .nearest,
                    .linear => .linear,
                };
            }
        }.of;
        const mipmapOf = struct {
            fn of(m: anytype) vk.SamplerMipmapMode {
                return switch (m) {
                    .nearest => .nearest,
                    .linear => .linear,
                };
            }
        }.of;
        const addrOf = struct {
            fn of(a: anytype) vk.SamplerAddressMode {
                return switch (a) {
                    .repeat => .repeat,
                    .clamp => .clamp_to_edge,
                    .mirror => .mirrored_repeat,
                };
            }
        }.of;
        const ci: vk.SamplerCreateInfo = .{
            .flags = .empty,
            .mag_filter = filterOf(descriptor.mag_filter),
            .min_filter = filterOf(descriptor.min_filter),
            .mipmap_mode = mipmapOf(descriptor.mipmap_filter),
            .address_mode_u = addrOf(descriptor.address_mode_u),
            .address_mode_v = addrOf(descriptor.address_mode_v),
            .address_mode_w = addrOf(descriptor.address_mode_w),
            .mip_lod_bias = 0,
            .anisotropy_enable = if (descriptor.anisotropy > 1) 1 else 0,
            .max_anisotropy = @floatFromInt(descriptor.anisotropy),
            .compare_enable = 0,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = vk.LOD_CLAMP_NONE,
            .border_color = .float_opaque_black,
            .unnormalized_coordinates = 0,
        };
        const s = self.vk_device.createSampler(&ci, null) catch return error.BackendInternal;
        return .{ .inner = @intFromEnum(s) };
    }

    pub fn destroySampler(self: *Device, handle: types.SamplerHandle) void {
        if (handle.inner == 0) return;
        self.vk_device.destroySampler(@enumFromInt(handle.inner), null);
    }

    // ====================================================================
    // ShaderModule (mapping direct)
    // ====================================================================

    pub fn createShaderModule(self: *Device, descriptor: types.ShaderModuleDescriptor) types.Error!types.ShaderModuleHandle {
        if (descriptor.code.len == 0) return error.InvalidArgument;
        if (descriptor.code.len % 4 != 0) return error.InvalidArgument;

        // Vulkan requires `pCode` to be `*const u32` — i.e. the SPIR-V
        // bytes must live at a u32-aligned address. `@embedFile` does
        // not guarantee alignment of the embedded slice, so callers that
        // pass an embedded `.spv` directly would otherwise fail
        // `InvalidArgument` here (observed on Fedora 44 + Intel UHD 630
        // during the M0.4 stabilization run). When the caller-provided
        // slice is misaligned we copy into a temporary aligned buffer;
        // Vulkan's spec lets us free the source after `vkCreateShaderModule`
        // returns since the driver owns its internal copy from that
        // point. The aligned path stays zero-copy.
        var owned_buf: ?[]align(4) u8 = null;
        defer if (owned_buf) |b| self.allocator.free(b);

        // Vulkan's `pCode` field is typed `*const u32` (a single
        // pointer used as the array base, with `code_size` providing
        // the element count). `@ptrCast(@alignCast(...))` casts a
        // `[*]const u8` many-pointer to that single-pointer form —
        // matching the S2 pattern in
        // /tmp/s2-ref/src/spike/vk_setup.zig.
        const code_ptr: *const u32 = blk: {
            if (std.mem.isAligned(@intFromPtr(descriptor.code.ptr), 4)) {
                break :blk @ptrCast(@alignCast(descriptor.code.ptr));
            }
            const buf = try self.allocator.alignedAlloc(u8, .@"4", descriptor.code.len);
            @memcpy(buf, descriptor.code);
            owned_buf = buf;
            break :blk @ptrCast(@alignCast(buf.ptr));
        };

        const ci: vk.ShaderModuleCreateInfo = .{
            .flags = .empty,
            .code_size = descriptor.code.len,
            .p_code = code_ptr,
        };
        const m = self.vk_device.createShaderModule(&ci, null) catch return error.ShaderCompilationFailed;
        return .{ .inner = @intFromEnum(m) };
    }

    pub fn destroyShaderModule(self: *Device, handle: types.ShaderModuleHandle) void {
        if (handle.inner == 0) return;
        self.vk_device.destroyShaderModule(@enumFromInt(handle.inner), null);
    }

    // ====================================================================
    // BindGroupLayout / BindGroup
    // ====================================================================

    pub fn createBindGroupLayout(
        self: *Device,
        descriptor: types.BindGroupLayoutDescriptor,
    ) types.Error!types.BindGroupLayoutHandle {
        return bind_mod.createLayout(self, descriptor);
    }

    pub fn destroyBindGroupLayout(self: *Device, handle: types.BindGroupLayoutHandle) void {
        bind_mod.destroyLayout(self, handle);
    }

    pub fn createBindGroup(self: *Device, descriptor: types.BindGroupDescriptor) types.Error!types.BindGroupHandle {
        return bind_mod.createGroup(self, descriptor);
    }

    pub fn destroyBindGroup(self: *Device, handle: types.BindGroupHandle) void {
        bind_mod.destroyGroup(self, handle);
    }

    // ====================================================================
    // RenderPipeline / ComputePipeline
    // ====================================================================

    pub fn createRenderPipeline(
        self: *Device,
        descriptor: types.RenderPipelineDescriptor,
    ) types.Error!types.RenderPipelineHandle {
        return pipeline_mod.createRender(self, descriptor);
    }

    pub fn destroyRenderPipeline(self: *Device, handle: types.RenderPipelineHandle) void {
        pipeline_mod.destroyRender(self, handle);
    }

    pub fn createComputePipeline(
        self: *Device,
        descriptor: types.ComputePipelineDescriptor,
    ) types.Error!types.ComputePipelineHandle {
        return pipeline_mod.createCompute(self, descriptor);
    }

    pub fn destroyComputePipeline(self: *Device, handle: types.ComputePipelineHandle) void {
        pipeline_mod.destroyCompute(self, handle);
    }

    // ====================================================================
    // Sync (Fence, Semaphore) — mapping direct
    // ====================================================================

    pub fn createFence(self: *Device, signaled: bool) types.Error!types.FenceHandle {
        return sync_mod.createFence(self, signaled);
    }

    pub fn destroyFence(self: *Device, handle: types.FenceHandle) void {
        sync_mod.destroyFence(self, handle);
    }

    pub fn waitFence(self: *Device, handle: types.FenceHandle, timeout_ns: u64) types.Error!void {
        return sync_mod.waitFence(self, handle, timeout_ns);
    }

    pub fn resetFence(self: *Device, handle: types.FenceHandle) types.Error!void {
        return sync_mod.resetFence(self, handle);
    }

    pub fn createSemaphore(self: *Device) types.Error!types.SemaphoreHandle {
        return sync_mod.createSemaphore(self);
    }

    pub fn destroySemaphore(self: *Device, handle: types.SemaphoreHandle) void {
        sync_mod.destroySemaphore(self, handle);
    }

    // ====================================================================
    // Swapchain
    // ====================================================================

    pub fn createSwapchain(self: *Device, descriptor: types.SwapchainDescriptor) types.Error!types.SwapchainHandle {
        return swap.create(self, descriptor);
    }

    pub fn destroySwapchain(self: *Device, handle: types.SwapchainHandle) void {
        swap.destroy(self, handle);
    }

    /// Return the pre-allocated `TextureViewHandle` for image `image_index`
    /// of the swapchain (cf. `swap.getImageView`). `image_index` must be a
    /// value previously returned by `acquireNextImage` — out of range is a
    /// caller bug and trips an assertion in debug builds.
    pub fn getSwapchainImageView(
        self: *Device,
        handle: types.SwapchainHandle,
        image_index: u32,
    ) types.TextureViewHandle {
        return swap.getImageView(self, handle, image_index);
    }

    pub fn acquireNextImage(
        self: *Device,
        handle: types.SwapchainHandle,
        signal_semaphore: ?types.SemaphoreHandle,
        timeout_ns: u64,
    ) types.Error!u32 {
        return swap.acquireNextImage(self, handle, signal_semaphore, timeout_ns);
    }

    pub fn present(
        self: *Device,
        handle: types.SwapchainHandle,
        image_index: u32,
        wait_semaphores: []const types.SemaphoreHandle,
    ) types.Error!void {
        return swap.present(self, handle, image_index, wait_semaphores);
    }

    // ====================================================================
    // Queue & command encoder
    // ====================================================================

    pub fn getQueue(self: *Device, queue_type: types.QueueType) types.Error!types.QueueHandle {
        return queue_mod.get(self, queue_type);
    }

    pub fn createCommandEncoder(self: *Device, label: ?[]const u8) types.Error!*cmd_mod.CommandEncoder {
        return cmd_mod.create(self, label);
    }

    /// Helper Vulkan-spécifique pour libérer un CommandEncoder.
    pub fn destroyCommandEncoder(self: *Device, encoder: *cmd_mod.CommandEncoder) void {
        cmd_mod.destroy(self, encoder);
    }

    /// Submit a finished CommandEncoder to the graphics queue. Mirrors
    /// the WebGPU `queue.submit` shape (extended with the explicit
    /// wait/signal/fence triple WebGPU hides behind its async runtime).
    /// The encoder must have had `finish()` called. Returns when the
    /// submission is recorded (not when the GPU completes) — pair with
    /// `waitFence` or `acquireNextImage(... wait_semaphore)` to gate
    /// downstream work.
    pub fn submit(
        self: *Device,
        encoder: *cmd_mod.CommandEncoder,
        descriptor: types.SubmitDescriptor,
    ) types.Error!void {
        return frame_mod.submit(self, encoder, .{
            .wait_semaphore = descriptor.wait_semaphore,
            .signal_semaphore = descriptor.signal_semaphore,
            .fence = descriptor.fence,
        });
    }
};

// ============================================================================
// Sélection multi-GPU + multi-driver (helpers internes)
// ============================================================================

/// Result of `createInstance`. `debug_utils_enabled` reflects whether
/// `VK_EXT_debug_utils` was effectively appended to the enabled
/// extension list at `vkCreateInstance` time — it is `true` only when
/// the validation layer was both requested and present on the system.
/// The caller must gate any `vkCreateDebugUtilsMessengerEXT` dispatch
/// on this flag: when the extension is absent the function pointer is
/// NULL and a raw call SIGSEGVs (cf. fix journal — Fedora 44 without
/// `vulkan-validation-layers` installed).
const InstanceResult = struct {
    instance: *vk.Instance,
    debug_utils_enabled: bool,
};

fn createInstance(allocator: std.mem.Allocator, descriptor: types.DeviceDescriptor) !InstanceResult {
    var ext_buf: std.ArrayList([*:0]const u8) = .empty;
    defer ext_buf.deinit(allocator);
    try ext_buf.append(allocator, "VK_KHR_surface");
    switch (builtin.os.tag) {
        .linux => try ext_buf.append(allocator, "VK_KHR_wayland_surface"),
        .windows => try ext_buf.append(allocator, "VK_KHR_win32_surface"),
        else => {},
    }

    var layer_buf: std.ArrayList([*:0]const u8) = .empty;
    defer layer_buf.deinit(allocator);
    var debug_utils_enabled = false;
    if (descriptor.enable_validation and builtin.mode != .ReleaseFast) {
        const available = vk.enumerateInstanceLayerProperties(allocator) catch &[_]vk.LayerProperties{};
        defer allocator.free(available);
        for (available) |lp| {
            if (std.mem.startsWith(u8, &lp.layer_name, "VK_LAYER_KHRONOS_validation")) {
                try layer_buf.append(allocator, "VK_LAYER_KHRONOS_validation");
                try ext_buf.append(allocator, "VK_EXT_debug_utils");
                debug_utils_enabled = true;
                break;
            }
        }
    }

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = "Weld GAL",
        .application_version = 1,
        .p_engine_name = "Weld",
        .engine_version = 1,
        .api_version = (@as(u32, 1) << 22) | (@as(u32, 3) << 12), // Vulkan 1.3
    };
    const ci: vk.InstanceCreateInfo = .{
        .flags = .empty,
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(layer_buf.items.len),
        .pp_enabled_layer_names = if (layer_buf.items.len > 0) layer_buf.items.ptr else undefined,
        .enabled_extension_count = @intCast(ext_buf.items.len),
        .pp_enabled_extension_names = ext_buf.items.ptr,
    };
    const instance = try vk.createInstance(&ci, null);
    return .{ .instance = instance, .debug_utils_enabled = debug_utils_enabled };
}

fn createDebugMessenger(instance: *vk.Instance) !vk.DebugUtilsMessengerEXT {
    const ci: vk.DebugUtilsMessengerCreateInfoEXT = .{
        .flags = .empty,
        .message_severity = .{ .warning = true, .@"error" = true },
        .message_type = .{ .general = true, .validation = true, .performance = true },
        .pfn_user_callback = @ptrCast(&debugCallback),
        .p_user_data = null,
    };
    return instance.createDebugUtilsMessengerEXT(&ci, null);
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_types: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = .{ severity, msg_types, user_data };
    if (data) |d| if (d.p_message) |msg| log.warn("vk: {s}", .{msg});
    return 0;
}

fn pickPhysicalDevice(
    device: *Device,
    allocator: std.mem.Allocator,
    descriptor: types.DeviceDescriptor,
) !void {
    const devices = device.vk_instance.enumeratePhysicalDevices(allocator) catch return error.NotInitialized;
    defer allocator.free(devices);
    if (devices.len == 0) return error.NotInitialized;

    // Détecte les combinaisons conflictuelles.
    if (descriptor.vulkan_driver == .software and descriptor.gpu_preference != .auto) {
        log.warn("--gpu-prefer ignored when --vulkan-driver=software", .{});
    }

    // `software` : ne garde que les devices de type CPU (lavapipe).
    // `hardware` : exclut les devices de type CPU.
    // `auto`     : tous.
    var filtered: std.ArrayList(*vk.PhysicalDevice) = .empty;
    defer filtered.deinit(allocator);
    for (devices) |pd| {
        const props = pd.getPhysicalDeviceProperties();
        const dt = props.device_type;
        const is_cpu = @intFromEnum(dt) == 4; // VK_PHYSICAL_DEVICE_TYPE_CPU
        const keep = switch (descriptor.vulkan_driver) {
            .software => is_cpu,
            .hardware => !is_cpu,
            .auto => true,
        };
        if (keep) try filtered.append(allocator, pd);
    }
    if (filtered.items.len == 0) return error.NotInitialized;

    // Override par index direct ?
    switch (descriptor.gpu_preference) {
        .index => |i| {
            if (i >= filtered.items.len) return error.NotInitialized;
            device.physical_device = filtered.items[i];
        },
        else => {
            // Score : préfère discrete > integrated > virtual > cpu > other,
            // sauf si --gpu-prefer infléchit.
            var best: ?*vk.PhysicalDevice = null;
            var best_score: i32 = -1;
            for (filtered.items) |pd| {
                const s = scoreDevice(pd, descriptor.gpu_preference);
                if (s > best_score) {
                    best = pd;
                    best_score = s;
                }
            }
            device.physical_device = best orelse return error.NotInitialized;
        },
    }

    const props = device.physical_device.getPhysicalDeviceProperties();
    @memcpy(&device.selection.physical_device_name, &props.device_name);
    device.selection.device_type = switch (@intFromEnum(props.device_type)) {
        1 => .integrated,
        2 => .discrete,
        3 => .virtual,
        4 => .cpu,
        else => .other,
    };

    // Trouve une queue family graphics (Phase 0 : une seule queue, fused
    // graphics + compute + transfer + present).
    const families = device.physical_device.getPhysicalDeviceQueueFamilyProperties(allocator) catch return error.NotInitialized;
    defer allocator.free(families);
    for (families, 0..) |f, i| {
        if (f.queue_flags.graphics) {
            device.queue_family_index = @intCast(i);
            device.selection.queue_family_index = device.queue_family_index;
            return;
        }
    }
    return error.NotInitialized;
}

fn scoreDevice(pd: *vk.PhysicalDevice, pref: types.GpuPreference) i32 {
    const props = pd.getPhysicalDeviceProperties();
    const dt = @intFromEnum(props.device_type);
    return switch (pref) {
        .auto => switch (dt) {
            2 => 100, // discrete
            1 => 80, // integrated
            3 => 60, // virtual
            4 => 20, // cpu (lavapipe)
            else => 1,
        },
        .discrete => if (dt == 2) 100 else if (dt == 1) 50 else 1,
        .integrated => if (dt == 1) 100 else if (dt == 2) 50 else 1,
        .index => 0, // déjà géré au-dessus
    };
}

fn createLogicalDevice(device: *Device) !void {
    const priorities: [1]f32 = .{1.0};
    const queue_ci: vk.DeviceQueueCreateInfo = .{
        .flags = .empty,
        .queue_family_index = device.queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priorities),
    };
    // VK_KHR_swapchain is requested unconditionally on platforms that
    // support a windowing backend. The GAL `createSurfaceFromWindow` +
    // `createSwapchain` flow creates the surface after the device, so
    // gating activation on `descriptor.surface != null` at device init
    // time produces a NULL `vkCreateSwapchainKHR` pointer and a SIGSEGV
    // on first use. The extension is harmless on a device that never
    // creates a swapchain (compute-only paths, future).
    const enabled_exts = [_][*:0]const u8{"VK_KHR_swapchain"};

    const features: vk.PhysicalDeviceFeatures = std.mem.zeroes(vk.PhysicalDeviceFeatures);
    const ci: vk.DeviceCreateInfo = .{
        .flags = .empty,
        .queue_create_info_count = 1,
        .p_queue_create_infos = &queue_ci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(enabled_exts.len),
        .pp_enabled_extension_names = &enabled_exts,
        .p_enabled_features = &features,
    };
    device.vk_device = try device.physical_device.createDevice(&ci, null);
}

// ============================================================================
// Tests (sans Vulkan réel — vérifient juste la shape struct)
// ============================================================================

test "device: struct shape compiles with all GAL methods" {
    // Le test compile-only ; vérifie que Device a bien toutes les méthodes
    // requises par interface.checkBackend. Vérification réelle déclenchée
    // par gal/main.zig.
    _ = Device;
}
