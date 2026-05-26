//! vk_gen Raw variants tests — Phase 0 / M0.4.
//!
//! Couvre brief §Critères d'acceptation > Tests :
//! - `vkAcquireNextImageKHR emits Raw variant` — vérifie présence dans
//!   la sortie générée
//! - `vkCreateBuffer does not emit Raw variant` — vérifie absence (cas
//!   négatif — la fonction est dans raw_targets liste, vkCreateBuffer
//!   ne l'est pas)
//!
//! Strategy : grep sur le `src/core/platform/vk.zig` post-bindgen, vérifie
//! la présence de `acquireNextImageKHRRaw` (sur Device) et l'absence de
//! `createBufferRaw`. Le test compile au niveau Zig type system —
//! @hasDecl ne suffit pas car les wrappers sont des méthodes sur Device
//! (opaque), pas des declarations au scope module.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;

test "vkAcquireNextImageKHR emits Raw variant" {
    const t = std.testing;

    // Le wrapper Raw est une méthode sur Device : on vérifie son type
    // via @TypeOf — si la méthode n'existait pas, ce test ne compilerait
    // pas (Zig type-check les références à des fns).
    const fn_type = @TypeOf(vk.Device.acquireNextImageKHRRaw);
    const info = @typeInfo(fn_type);
    try t.expectEqual(@typeInfo(@TypeOf(vk.Device.acquireNextImageKHRRaw)).@"fn".return_type.?, vk.Result);
    _ = info;
}

test "Queue.presentKHR Raw variant exists" {
    const t = std.testing;
    const fn_type = @TypeOf(vk.Queue.presentKHRRaw);
    try t.expectEqual(@typeInfo(fn_type).@"fn".return_type.?, vk.Result);
}

test "vkAcquireNextImage2KHR emits Raw variant" {
    const t = std.testing;
    const fn_type = @TypeOf(vk.Device.acquireNextImage2KHRRaw);
    try t.expectEqual(@typeInfo(fn_type).@"fn".return_type.?, vk.Result);
}

test "vkCreateBuffer does not emit Raw variant" {
    // Si Device.createBufferRaw existait, @hasDecl le rapporterait. La
    // liste raw_targets de l'emitter ne contient que les 3 cibles brief.
    try std.testing.expect(!@hasDecl(vk.Device, "createBufferRaw"));
}

test "createImage does not emit Raw variant" {
    try std.testing.expect(!@hasDecl(vk.Device, "createImageRaw"));
}
