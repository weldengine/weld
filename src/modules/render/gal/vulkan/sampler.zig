//! Sampler Vulkan — Phase 0 / M0.4.
//!
//! Sampler has no additional state: the native `vk.Sampler` is enough
//! as identity. Creation/destruction is inlined in `device.zig`
//! (`createSampler`/`destroySampler` methods) to avoid the dispatch cost
//! of a dedicated file with 0 helpers.
//!
//! This file stays present to follow the brief §Files split plan
//! and to expose a future extension point (Phase 1+: presets of common
//! samplers — anisotropic, point, linear — accessible by name).

const std = @import("std");
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Phase 0: delegated to `device.createSampler`. This wrapper stays reserved
/// for the Phase 1+ presets (cf. the doc at the top of the file).
pub fn create(device: *Device, descriptor: types.SamplerDescriptor) types.Error!types.SamplerHandle {
    return device.createSampler(descriptor);
}

/// Frees a Sampler (delegated to `device.destroySampler`).
pub fn destroy(device: *Device, handle: types.SamplerHandle) void {
    device.destroySampler(handle);
}
