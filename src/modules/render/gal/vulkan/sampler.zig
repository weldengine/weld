//! Sampler Vulkan.
//!
//! Sampler has no additional state: the native `vk.Sampler` is enough
//! as identity. Creation/destruction is inlined in `device.zig`
//! (`createSampler`/`destroySampler` methods) to avoid the dispatch cost
//! of a dedicated file with 0 helpers.
//!
//! This file stays present to follow the file split plan
//! and to expose an extension point for presets of common
//! samplers — anisotropic, point, linear — accessible by name.

const std = @import("std");
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Delegated to `device.createSampler`. The wrapper stays reserved for the
/// presets named at the top of the file — do NOT inline it away.
pub fn create(device: *Device, descriptor: types.SamplerDescriptor) types.Error!types.SamplerHandle {
    return device.createSampler(descriptor);
}

/// Frees a Sampler (delegated to `device.destroySampler`).
pub fn destroy(device: *Device, handle: types.SamplerHandle) void {
    device.destroySampler(handle);
}
