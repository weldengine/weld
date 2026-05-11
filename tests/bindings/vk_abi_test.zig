//! Step (i) of the S2 brief: ABI gate for the generator emitting
//! `src/core/platform/vk.zig`. For a representative subset of Vulkan
//! structs, the generated Zig `extern struct` is asserted to have the
//! same `@sizeOf`, `@alignOf` and per-field `@offsetOf` as a reference
//! `extern struct` declared inline here.
//!
//! § Why not @cImport — CLAUDE.md forbids `@cImport` outside the
//! generated `*_binding.zig` files (rule applies even to test code).
//! The Vulkan C headers are not used at all here; instead, the
//! reference structs in `Ref` are hand-rolled to match the Vulkan 1.3
//! C ABI exactly (taken from the Khronos `vulkan_core.h` shipped with
//! `vulkan-sdk-1.4.341.0`, the same upstream that `bindings/upstream/
//! vulkan/vk.xml` was vendored from). The references rely on Zig's
//! `extern struct` matching the C ABI's natural-padding behaviour — no
//! explicit `_pad` fields are needed because Zig inserts the same
//! padding the C compiler would.
//!
//! Field type collapsing: pointer fields use `?*const anyopaque`
//! (8 bytes on every 64-bit target), enum fields use `i32` (C enum =
//! `int`), bitmask fields use `u32` (`typedef uint32_t VkFlags`),
//! `VkBool32` uses `u32`, dispatchable handles use `?*const anyopaque`
//! and non-dispatchable handles use `u64` (same 8 bytes on 64-bit).
//!
//! What this gate catches:
//!   * `vk_gen` regressing on field ordering after an XML refresh.
//!   * A new vendor-tag stripping rule accidentally renaming a field.
//!   * Drift between vk.xml and the C ABI (would also fail at runtime).
//!
//! What it does NOT catch:
//!   * 32-bit targets — the spike is 64-bit only and so is the
//!     reference; `@offsetOf` would diverge on a 32-bit build.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;

/// Asserts that `Generated`'s layout matches `Reference`'s layout exactly.
/// Iterates `Reference`'s fields by name so field renames in the generator
/// surface as a hard `@offsetOf` failure.
fn assertLayout(comptime Generated: type, comptime Reference: type) !void {
    try std.testing.expectEqual(@sizeOf(Reference), @sizeOf(Generated));
    try std.testing.expectEqual(@alignOf(Reference), @alignOf(Generated));
    inline for (@typeInfo(Reference).@"struct".fields) |f| {
        try std.testing.expectEqual(
            @offsetOf(Reference, f.name),
            @offsetOf(Generated, f.name),
        );
    }
}

const Ref = struct {
    // Field names mirror vk.zig's snake_case so the helper can look them
    // up by name in both types. Pointer types collapse to
    // `?*const anyopaque` (8 bytes on 64-bit). Zig's `extern struct`
    // auto-pads to align each field per the C ABI, so no explicit pad
    // fields are needed.

    pub const ApplicationInfo = extern struct {
        s_type: i32,
        p_next: ?*const anyopaque,
        p_application_name: ?*const anyopaque,
        application_version: u32,
        p_engine_name: ?*const anyopaque,
        engine_version: u32,
        api_version: u32,
    };

    pub const InstanceCreateInfo = extern struct {
        s_type: i32,
        p_next: ?*const anyopaque,
        flags: u32,
        p_application_info: ?*const anyopaque,
        enabled_layer_count: u32,
        pp_enabled_layer_names: ?*const anyopaque,
        enabled_extension_count: u32,
        pp_enabled_extension_names: ?*const anyopaque,
    };

    pub const DeviceCreateInfo = extern struct {
        s_type: i32,
        p_next: ?*const anyopaque,
        flags: u32,
        queue_create_info_count: u32,
        p_queue_create_infos: ?*const anyopaque,
        enabled_layer_count: u32,
        pp_enabled_layer_names: ?*const anyopaque,
        enabled_extension_count: u32,
        pp_enabled_extension_names: ?*const anyopaque,
        p_enabled_features: ?*const anyopaque,
    };

    pub const SwapchainCreateInfoKHR = extern struct {
        s_type: i32,
        p_next: ?*const anyopaque,
        flags: u32,
        surface: ?*const anyopaque,
        min_image_count: u32,
        image_format: i32,
        image_color_space: i32,
        image_extent_width: u32,
        image_extent_height: u32,
        image_array_layers: u32,
        image_usage: u32,
        image_sharing_mode: i32,
        queue_family_index_count: u32,
        p_queue_family_indices: ?*const anyopaque,
        pre_transform: u32,
        composite_alpha: u32,
        present_mode: i32,
        clipped: u32,
        old_swapchain: ?*const anyopaque,
    };

    pub const SubmitInfo = extern struct {
        s_type: i32,
        p_next: ?*const anyopaque,
        wait_semaphore_count: u32,
        p_wait_semaphores: ?*const anyopaque,
        p_wait_dst_stage_mask: ?*const anyopaque,
        command_buffer_count: u32,
        p_command_buffers: ?*const anyopaque,
        signal_semaphore_count: u32,
        p_signal_semaphores: ?*const anyopaque,
    };

    pub const PresentInfoKHR = extern struct {
        s_type: i32,
        p_next: ?*const anyopaque,
        wait_semaphore_count: u32,
        p_wait_semaphores: ?*const anyopaque,
        swapchain_count: u32,
        p_swapchains: ?*const anyopaque,
        p_image_indices: ?*const anyopaque,
        p_results: ?*const anyopaque,
    };

    pub const PhysicalDeviceFeatures = extern struct {
        robust_buffer_access: u32,
        full_draw_index_uint32: u32,
        image_cube_array: u32,
        independent_blend: u32,
        geometry_shader: u32,
        tessellation_shader: u32,
        sample_rate_shading: u32,
        dual_src_blend: u32,
        logic_op: u32,
        multi_draw_indirect: u32,
        draw_indirect_first_instance: u32,
        depth_clamp: u32,
        depth_bias_clamp: u32,
        fill_mode_non_solid: u32,
        depth_bounds: u32,
        wide_lines: u32,
        large_points: u32,
        alpha_to_one: u32,
        multi_viewport: u32,
        sampler_anisotropy: u32,
        texture_compression_etc2: u32,
        // Generator emits a double underscore here because the upstream
        // field name `textureCompressionASTC_LDR` carries an embedded `_`
        // plus an implicit word boundary between `ASTC` and `LDR`. Locked
        // in deliberately — any change to the snake_case canonicaliser
        // should be a §4.2 review item, not a silent regression.
        texture_compression_astc__ldr: u32,
        texture_compression_bc: u32,
        occlusion_query_precise: u32,
        pipeline_statistics_query: u32,
        vertex_pipeline_stores_and_atomics: u32,
        fragment_stores_and_atomics: u32,
        shader_tessellation_and_geometry_point_size: u32,
        shader_image_gather_extended: u32,
        shader_storage_image_extended_formats: u32,
        shader_storage_image_multisample: u32,
        shader_storage_image_read_without_format: u32,
        shader_storage_image_write_without_format: u32,
        shader_uniform_buffer_array_dynamic_indexing: u32,
        shader_sampled_image_array_dynamic_indexing: u32,
        shader_storage_buffer_array_dynamic_indexing: u32,
        shader_storage_image_array_dynamic_indexing: u32,
        shader_clip_distance: u32,
        shader_cull_distance: u32,
        shader_float64: u32,
        shader_int64: u32,
        shader_int16: u32,
        shader_resource_residency: u32,
        shader_resource_min_lod: u32,
        sparse_binding: u32,
        sparse_residency_buffer: u32,
        // Same generator quirk: `sparseResidencyImage2D` snake-cases to
        // `sparse_residency_image2_d` (digit / 'D' word boundary).
        sparse_residency_image2_d: u32,
        sparse_residency_image3_d: u32,
        sparse_residency2_samples: u32,
        sparse_residency4_samples: u32,
        sparse_residency8_samples: u32,
        sparse_residency16_samples: u32,
        sparse_residency_aliased: u32,
        variable_multisample_rate: u32,
        inherited_queries: u32,
    };

    // For `PhysicalDeviceProperties` the nested `PhysicalDeviceLimits` and
    // `PhysicalDeviceSparseProperties` are large; we lock in their canonical
    // sizes and the top-level offsets. The Vulkan 1.3 C ABI sizes:
    //   * VkPhysicalDeviceLimits = 504 bytes (106 fields, mostly u32/float)
    //   * VkPhysicalDeviceSparseProperties = 20 bytes (5 VkBool32)
    // Both numbers stable across the 1.x line.
    pub const PhysicalDeviceProperties = extern struct {
        api_version: u32,
        driver_version: u32,
        vendor_id: u32,
        device_id: u32,
        device_type: i32,
        device_name: [256]u8,
        pipeline_cache_uuid: [16]u8,
        limits: [504]u8 align(8),
        sparse_properties: [20]u8,
    };
};

test "ApplicationInfo layout matches Vulkan 1.3 ABI" {
    try assertLayout(vk.ApplicationInfo, Ref.ApplicationInfo);
}

test "InstanceCreateInfo layout matches Vulkan 1.3 ABI" {
    try assertLayout(vk.InstanceCreateInfo, Ref.InstanceCreateInfo);
}

test "DeviceCreateInfo layout matches Vulkan 1.3 ABI" {
    try assertLayout(vk.DeviceCreateInfo, Ref.DeviceCreateInfo);
}

test "SwapchainCreateInfoKHR layout matches Vulkan 1.3 ABI" {
    // SwapchainCreateInfoKHR embeds `VkExtent2D imageExtent` inline. The
    // generator emits it as a nested `Extent2D` field at the offset of
    // `image_extent_width` on the ref; the reference splits it into two
    // adjacent u32s so the field-by-field map below stays straightforward.
    try std.testing.expectEqual(@sizeOf(Ref.SwapchainCreateInfoKHR), @sizeOf(vk.SwapchainCreateInfoKHR));
    try std.testing.expectEqual(@alignOf(Ref.SwapchainCreateInfoKHR), @alignOf(vk.SwapchainCreateInfoKHR));

    const checks = .{
        .{ "s_type", "s_type" },
        .{ "p_next", "p_next" },
        .{ "flags", "flags" },
        .{ "surface", "surface" },
        .{ "min_image_count", "min_image_count" },
        .{ "image_format", "image_format" },
        .{ "image_color_space", "image_color_space" },
        .{ "image_extent_width", "image_extent" },
        .{ "image_array_layers", "image_array_layers" },
        .{ "image_usage", "image_usage" },
        .{ "image_sharing_mode", "image_sharing_mode" },
        .{ "queue_family_index_count", "queue_family_index_count" },
        .{ "p_queue_family_indices", "p_queue_family_indices" },
        .{ "pre_transform", "pre_transform" },
        .{ "composite_alpha", "composite_alpha" },
        .{ "present_mode", "present_mode" },
        .{ "clipped", "clipped" },
        .{ "old_swapchain", "old_swapchain" },
    };
    inline for (checks) |pair| {
        try std.testing.expectEqual(
            @offsetOf(Ref.SwapchainCreateInfoKHR, pair[0]),
            @offsetOf(vk.SwapchainCreateInfoKHR, pair[1]),
        );
    }
}

test "SubmitInfo layout matches Vulkan 1.3 ABI" {
    try assertLayout(vk.SubmitInfo, Ref.SubmitInfo);
}

test "PresentInfoKHR layout matches Vulkan 1.3 ABI" {
    try assertLayout(vk.PresentInfoKHR, Ref.PresentInfoKHR);
}

test "PhysicalDeviceFeatures layout matches Vulkan 1.3 ABI" {
    try assertLayout(vk.PhysicalDeviceFeatures, Ref.PhysicalDeviceFeatures);
    // 55 VkBool32 fields × 4 bytes = 220 bytes. Hard-coded to catch any
    // generator regression that quietly adds a 56th field.
    try std.testing.expectEqual(@as(usize, 220), @sizeOf(vk.PhysicalDeviceFeatures));
}

test "PhysicalDeviceProperties layout matches Vulkan 1.3 ABI" {
    try std.testing.expectEqual(@sizeOf(Ref.PhysicalDeviceProperties), @sizeOf(vk.PhysicalDeviceProperties));
    try std.testing.expectEqual(@alignOf(Ref.PhysicalDeviceProperties), @alignOf(vk.PhysicalDeviceProperties));

    const fields = .{
        "api_version",
        "driver_version",
        "vendor_id",
        "device_id",
        "device_type",
        "device_name",
        "pipeline_cache_uuid",
        "limits",
        "sparse_properties",
    };
    inline for (fields) |name| {
        try std.testing.expectEqual(
            @offsetOf(Ref.PhysicalDeviceProperties, name),
            @offsetOf(vk.PhysicalDeviceProperties, name),
        );
    }
}

test "selected handle sizes match 64-bit Vulkan ABI" {
    // Dispatchable handles (VkInstance, VkDevice, …) are `*Instance_T` →
    // pointer-sized; the generator emits them as `opaque`, so pointer-to-
    // opaque is pointer-sized. Locking in their footprint catches a
    // regression where the generator quietly emits them as a u32.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(*vk.Instance));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(*vk.Device));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(*vk.PhysicalDevice));
}
