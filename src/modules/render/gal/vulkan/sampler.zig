//! Sampler Vulkan — Phase 0 / M0.4.
//!
//! Sampler n'a pas de state additionnel : le `vk.Sampler` natif suffit
//! comme identité. La création/destruction est inlinée dans `device.zig`
//! (méthodes `createSampler`/`destroySampler`) pour éviter le coût de
//! dispatch d'un fichier dédié à 0 helper.
//!
//! Ce fichier reste présent pour suivre le plan de découpe brief §Fichiers
//! et exposer un futur point d'extension (Phase 1+ : presets de samplers
//! courants — anisotropic, point, linear — accessibles par nom).

const std = @import("std");
const types = @import("../types.zig");
const Device = @import("device.zig").Device;

/// Phase 0 : delegated to `device.createSampler`. Ce wrapper rest réservé
/// pour les Phase 1+ presets (cf. doc en tête de fichier).
pub fn create(device: *Device, descriptor: types.SamplerDescriptor) types.Error!types.SamplerHandle {
    return device.createSampler(descriptor);
}

/// Libère un Sampler (delegated à `device.destroySampler`).
pub fn destroy(device: *Device, handle: types.SamplerHandle) void {
    device.destroySampler(handle);
}
