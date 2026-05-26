//! Buffer Vulkan — Phase 0 / M0.4.
//!
//! Buffer GPU = `vk.Buffer` + `vk.DeviceMemory` liés. La GAL ne sépare
//! pas les deux (la sémantique WebGPU-like considère un Buffer comme une
//! unité indissociable mémoire + handle). On stocke les deux dans une
//! `Entry` indexée par un compteur monotone côté Device.
//!
//! Allocation Phase 0 : un allocateur par buffer (`vkAllocateMemory` /
//! `vkFreeMemory` directs). Sub-allocation + pooling = Phase 1+ (cf.
//! brief §Notes). Inefficace pour des milliers de buffers, suffisant pour
//! le triangle Phase 0 + les instance buffers du benchmark.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;

/// Slot interne associé à un GAL `BufferHandle`. Stocké dans le registry
/// `Device.buffers` keyé par un u64 monotone.
pub const Entry = struct {
    vk_buffer: vk.Buffer,
    vk_memory: vk.DeviceMemory,
    size: u64,
    host_visible: bool,
    mapped_ptr: ?*anyopaque = null,

    pub fn destroy(self: *Entry, device: *vk.Device) void {
        if (self.mapped_ptr != null and self.vk_memory != .null) {
            device.unmapMemory(self.vk_memory);
            self.mapped_ptr = null;
        }
        if (self.vk_buffer != .null) device.destroyBuffer(self.vk_buffer, null);
        if (self.vk_memory != .null) device.freeMemory(self.vk_memory, null);
        self.* = undefined;
    }
};

/// Alloue un buffer Vulkan + sa DeviceMemory backing, enregistre le couple
/// dans le registry `device.buffers`. Retourne un `BufferHandle` GAL.
pub fn create(device: *Device, descriptor: types.BufferDescriptor) types.Error!types.BufferHandle {
    if (descriptor.size == 0) return error.InvalidArgument;

    const ci: vk.BufferCreateInfo = .{
        .flags = .empty,
        .size = descriptor.size,
        .usage = conv.bufferUsage(descriptor.usage),
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    const buf = device.vk_device.createBuffer(&ci, null) catch return error.BackendInternal;
    errdefer device.vk_device.destroyBuffer(buf, null);

    const reqs = device.vk_device.getBufferMemoryRequirements(buf);

    var want: vk.MemoryPropertyFlags = .empty;
    if (descriptor.host_visible) {
        want.host_visible = true;
        want.host_coherent = true;
    } else {
        want.device_local = true;
    }

    const mem_props = device.physical_device.getPhysicalDeviceMemoryProperties();
    const type_index = pickMemoryType(mem_props, reqs.memory_type_bits, want) orelse return error.Unsupported;

    const ai: vk.MemoryAllocateInfo = .{
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    };
    const mem = device.vk_device.allocateMemory(&ai, null) catch return error.OutOfMemory;
    errdefer device.vk_device.freeMemory(mem, null);

    device.vk_device.bindBufferMemory(buf, mem, 0) catch return error.BackendInternal;

    const id = device.nextHandle();
    try device.buffers.put(device.allocator, id, .{
        .vk_buffer = buf,
        .vk_memory = mem,
        .size = descriptor.size,
        .host_visible = descriptor.host_visible,
    });
    return .{ .inner = id };
}

/// Libère un buffer + sa memory. No-op si handle invalide.
pub fn destroy(device: *Device, handle: types.BufferHandle) void {
    if (handle.inner == 0) return;
    if (device.buffers.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Helper interne — récupère le `vk.Buffer` associé à un GAL handle.
/// Utilisé par `command_encoder.zig` lors de l'enregistrement des draws.
pub fn lookup(device: *Device, handle: types.BufferHandle) ?vk.Buffer {
    if (handle.inner == 0) return null;
    return if (device.buffers.get(handle.inner)) |e| e.vk_buffer else null;
}

/// Helper — map / unmap pour les buffers `host_visible`. Phase 0 : simple
/// passthrough. Phase 1+ : intégration avec persistent mapping.
pub fn map(device: *Device, handle: types.BufferHandle) types.Error![]u8 {
    if (handle.inner == 0) return error.InvalidArgument;
    const entry_ptr = device.buffers.getPtr(handle.inner) orelse return error.InvalidArgument;
    if (!entry_ptr.host_visible) return error.Unsupported;
    if (entry_ptr.mapped_ptr) |p| {
        return @as([*]u8, @ptrCast(p))[0..entry_ptr.size];
    }
    const p = device.vk_device.mapMemory(entry_ptr.vk_memory, 0, entry_ptr.size, .empty) catch return error.BackendInternal;
    const non_null = p orelse return error.BackendInternal;
    entry_ptr.mapped_ptr = non_null;
    return @as([*]u8, @ptrCast(non_null))[0..entry_ptr.size];
}

/// Démappe un buffer (l'inverse de `map`). No-op si non mappé.
pub fn unmap(device: *Device, handle: types.BufferHandle) void {
    if (handle.inner == 0) return;
    const entry_ptr = device.buffers.getPtr(handle.inner) orelse return;
    if (entry_ptr.mapped_ptr) |_| {
        device.vk_device.unmapMemory(entry_ptr.vk_memory);
        entry_ptr.mapped_ptr = null;
    }
}

fn pickMemoryType(
    props: vk.PhysicalDeviceMemoryProperties,
    type_bits: u32,
    want: vk.MemoryPropertyFlags,
) ?u32 {
    var i: u32 = 0;
    while (i < props.memory_type_count) : (i += 1) {
        const candidate = props.memory_types[i];
        const want_bits: u32 = @bitCast(want);
        const have_bits: u32 = @bitCast(candidate.property_flags);
        if ((type_bits & (@as(u32, 1) << @intCast(i))) != 0 and (have_bits & want_bits) == want_bits) {
            return i;
        }
    }
    return null;
}
