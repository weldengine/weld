//! BindGroupLayout + BindGroup Vulkan — Phase 0 / M0.4.
//!
//! Mapping:
//! - `BindGroupLayoutHandle` ↔ `vk.DescriptorSetLayout` (direct mapping, no registry)
//! - `BindGroupHandle` ↔ `vk.DescriptorSet` (internal registry to
//!   keep the parent `vk.DescriptorPool` at destruction time)
//!
//! Phase 0: one descriptor pool per BindGroup (overkill but simple).
//! Phase 1+: shared multi-frame pool + reset at the frame boundary.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const buffer_mod = @import("buffer.zig");
const texture_mod = @import("texture.zig");

/// Internal slot of a BindGroup — bundles DescriptorPool + DescriptorSet.
/// Phase 0: one pool per bind group (cf. the doc at the top of the file).
pub const Entry = struct {
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,

    pub fn destroy(self: *Entry, device: *vk.Device) void {
        // Destroying the pool implicitly frees the sets allocated in it.
        if (self.descriptor_pool != .null) device.destroyDescriptorPool(self.descriptor_pool, null);
        self.* = undefined;
    }
};

/// Creates a `vk.DescriptorSetLayout` from a GAL descriptor. Direct
/// mapping: handle.inner = @intFromEnum(layout).
pub fn createLayout(
    device: *Device,
    descriptor: types.BindGroupLayoutDescriptor,
) types.Error!types.BindGroupLayoutHandle {
    if (descriptor.entries.len == 0) {
        // Empty layout accepted — equivalent to an empty descriptor set.
        const ci: vk.DescriptorSetLayoutCreateInfo = .{
            .flags = .empty,
            .binding_count = 0,
            .p_bindings = undefined,
        };
        const l = device.vk_device.createDescriptorSetLayout(&ci, null) catch return error.BackendInternal;
        return .{ .inner = @intFromEnum(l) };
    }

    var vk_bindings = std.ArrayList(vk.DescriptorSetLayoutBinding).empty;
    defer vk_bindings.deinit(device.allocator);
    try vk_bindings.ensureTotalCapacity(device.allocator, descriptor.entries.len);
    for (descriptor.entries) |e| {
        try vk_bindings.append(device.allocator, .{
            .binding = e.binding,
            .descriptor_type = conv.descriptorType(e.binding_type),
            .descriptor_count = 1,
            .stage_flags = conv.shaderStageFlags(e.visibility),
            .p_immutable_samplers = null,
        });
    }
    const ci: vk.DescriptorSetLayoutCreateInfo = .{
        .flags = .empty,
        .binding_count = @intCast(vk_bindings.items.len),
        .p_bindings = if (vk_bindings.items.len > 0) @ptrCast(vk_bindings.items.ptr) else undefined,
    };
    const l = device.vk_device.createDescriptorSetLayout(&ci, null) catch return error.BackendInternal;
    return .{ .inner = @intFromEnum(l) };
}

/// Frees a `vk.DescriptorSetLayout`. No-op if handle invalid.
pub fn destroyLayout(device: *Device, handle: types.BindGroupLayoutHandle) void {
    if (handle.inner == 0) return;
    device.vk_device.destroyDescriptorSetLayout(@enumFromInt(handle.inner), null);
}

/// Creates a BindGroup — allocates a dedicated DescriptorPool, allocates a
/// DescriptorSet from the pool, writes the bindings via
/// `vkUpdateDescriptorSets`. Phase 0: one pool per group (cf. doc).
pub fn createGroup(
    device: *Device,
    descriptor: types.BindGroupDescriptor,
) types.Error!types.BindGroupHandle {
    if (!descriptor.layout.isValid()) return error.InvalidArgument;

    // 1. Build the pool sizes by counting the types present in entries.
    var counts = std.AutoHashMap(vk.DescriptorType, u32).init(device.allocator);
    defer counts.deinit();
    for (descriptor.entries) |e| {
        const t: vk.DescriptorType = switch (e.resource) {
            .buffer => .uniform_buffer, // Phase 0: uniform by default. storage if flag, to extend Phase 1.
            .texture_view => .sampled_image,
            .sampler => .sampler,
        };
        const gop = try counts.getOrPut(t);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var pool_sizes = std.ArrayList(vk.DescriptorPoolSize).empty;
    defer pool_sizes.deinit(device.allocator);
    var it = counts.iterator();
    while (it.next()) |kv| {
        try pool_sizes.append(device.allocator, .{
            .type = kv.key_ptr.*,
            .descriptor_count = kv.value_ptr.*,
        });
    }
    // Minimal fallback for empty layouts.
    if (pool_sizes.items.len == 0) {
        try pool_sizes.append(device.allocator, .{ .type = .uniform_buffer, .descriptor_count = 1 });
    }

    const pool_ci: vk.DescriptorPoolCreateInfo = .{
        .flags = .empty,
        .max_sets = 1,
        .pool_size_count = @intCast(pool_sizes.items.len),
        // `items.ptr` is a `[*]T` many-pointer; the vk field is `*const T`
        // (pointer to the first of `pool_size_count` contiguous entries).
        .p_pool_sizes = @ptrCast(pool_sizes.items.ptr),
    };
    const pool = device.vk_device.createDescriptorPool(&pool_ci, null) catch return error.BackendInternal;
    errdefer device.vk_device.destroyDescriptorPool(pool, null);

    const layout_vk: vk.DescriptorSetLayout = @enumFromInt(descriptor.layout.inner);
    const alloc_ci: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&layout_vk),
    };
    var sets: [1]vk.DescriptorSet = .{.null};
    device.vk_device.allocateDescriptorSets(&alloc_ci, &sets) catch return error.BackendInternal;
    const set = sets[0];

    // 2. Write the effective bindings.
    if (descriptor.entries.len > 0) {
        var writes = std.ArrayList(vk.WriteDescriptorSet).empty;
        defer writes.deinit(device.allocator);
        try writes.ensureTotalCapacity(device.allocator, descriptor.entries.len);

        // Buffers / images storage backing (lifetime: tied to the function — no
        // dangling pointers because Vulkan copies the descriptors at update time).
        var buffer_infos = std.ArrayList(vk.DescriptorBufferInfo).empty;
        defer buffer_infos.deinit(device.allocator);
        var image_infos = std.ArrayList(vk.DescriptorImageInfo).empty;
        defer image_infos.deinit(device.allocator);

        try buffer_infos.ensureTotalCapacity(device.allocator, descriptor.entries.len);
        try image_infos.ensureTotalCapacity(device.allocator, descriptor.entries.len);

        // Valid zero-initialized dummies for the WriteDescriptorSet union
        // members NOT selected by each write's `descriptor_type`.
        // `vkUpdateDescriptorSets` reads only the member matching the type, but
        // some validation layers defensively inspect ALL union pointers — so
        // the unused ones point at real (ignored) structs rather than
        // `undefined` garbage. Lifetime: function scope, outliving the
        // `updateDescriptorSets` call below.
        const dummy_image: vk.DescriptorImageInfo = .{ .sampler = .null, .image_view = .null, .image_layout = .undefined };
        const dummy_buffer: vk.DescriptorBufferInfo = .{ .buffer = .null, .offset = 0, .range = 0 };
        const dummy_texel: vk.BufferView = .null;

        for (descriptor.entries) |e| {
            switch (e.resource) {
                .buffer => |b| {
                    const buf = buffer_mod.lookup(device, b.handle) orelse return error.InvalidArgument;
                    const bi: vk.DescriptorBufferInfo = .{
                        .buffer = buf,
                        .offset = b.offset,
                        .range = if (b.size) |s| s else vk.WHOLE_SIZE,
                    };
                    try buffer_infos.append(device.allocator, bi);
                    try writes.append(device.allocator, .{
                        .dst_set = set,
                        .dst_binding = e.binding,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .uniform_buffer,
                        .p_image_info = &dummy_image,
                        .p_buffer_info = @ptrCast(&buffer_infos.items[buffer_infos.items.len - 1]),
                        .p_texel_buffer_view = &dummy_texel,
                    });
                },
                .texture_view => |v| {
                    const view = texture_mod.lookupView(device, v) orelse return error.InvalidArgument;
                    const ii: vk.DescriptorImageInfo = .{
                        .sampler = .null,
                        .image_view = view,
                        .image_layout = .shader_read_only_optimal,
                    };
                    try image_infos.append(device.allocator, ii);
                    try writes.append(device.allocator, .{
                        .dst_set = set,
                        .dst_binding = e.binding,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .sampled_image,
                        .p_image_info = @ptrCast(&image_infos.items[image_infos.items.len - 1]),
                        .p_buffer_info = &dummy_buffer,
                        .p_texel_buffer_view = &dummy_texel,
                    });
                },
                .sampler => |s| {
                    const ii: vk.DescriptorImageInfo = .{
                        .sampler = @enumFromInt(s.inner),
                        .image_view = .null,
                        .image_layout = .undefined,
                    };
                    try image_infos.append(device.allocator, ii);
                    try writes.append(device.allocator, .{
                        .dst_set = set,
                        .dst_binding = e.binding,
                        .dst_array_element = 0,
                        .descriptor_count = 1,
                        .descriptor_type = .sampler,
                        .p_image_info = @ptrCast(&image_infos.items[image_infos.items.len - 1]),
                        .p_buffer_info = &dummy_buffer,
                        .p_texel_buffer_view = &dummy_texel,
                    });
                },
            }
        }

        device.vk_device.updateDescriptorSets(writes.items, &.{});
    }

    const id = device.nextHandle();
    try device.bind_groups.put(device.allocator, id, .{
        .descriptor_pool = pool,
        .descriptor_set = set,
    });
    return .{ .inner = id };
}

/// Frees a BindGroup (and its dedicated pool, which implicitly frees
/// the set). No-op if handle invalid.
pub fn destroyGroup(device: *Device, handle: types.BindGroupHandle) void {
    if (handle.inner == 0) return;
    if (device.bind_groups.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Helper — retrieves the native `vk.DescriptorSet` (for the bind).
pub fn lookupSet(device: *Device, handle: types.BindGroupHandle) ?vk.DescriptorSet {
    if (handle.inner == 0) return null;
    return if (device.bind_groups.get(handle.inner)) |e| e.descriptor_set else null;
}
