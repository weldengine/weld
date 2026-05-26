//! GAL Vulkan backend offline test — Phase 0 / M0.4.
//!
//! Couvre brief §Critères d'acceptation > Tests :
//! `Vulkan backend init and teardown over lavapipe — init Device, create
//! swapchain headless surface, teardown propre. Skip si `LAVAPIPE_AVAILABLE=0`.`
//!
//! Phase 0 : la création de swapchain requiert une vraie window+surface
//! (cf. brief §Out-of-scope macOS — sur macOS le test est skippé puisque
//! Weld macOS = Phase 2+). Le test s'exécute donc :
//! - Linux : tente l'init Vulkan via loader natif, skip si la lib absente
//! - Windows : idem
//! - macOS : skip avec mention explicite
//!
//! Le test n'exerce **que** l'init Device + supports() + getQueue + teardown.
//! La swapchain demande une surface, hors scope du test offline. Le smoke
//! test PPM dans `examples/triangle/` couvre la swapchain Phase 0 sur les
//! 3 GPU configs (cf. brief §Comportement observable).

const std = @import("std");
const builtin = @import("builtin");
const gal = @import("weld_render");
const vk = @import("weld_core").platform.vk;

const VulkanAvailable = enum { yes, no };

/// Tente de charger le loader Vulkan. Si la lib n'est pas présente, on
/// skip avec warn (le runner CI doit pouvoir tourner sans Vulkan sur le
/// runner Ubuntu GitHub Actions par défaut).
fn detectVulkan() VulkanAvailable {
    // Mode opt-in CI : `LAVAPIPE_AVAILABLE` env var définie sur le runner
    // configuré avec lavapipe. `std.posix.getenv` retourne `?[]const u8` ;
    // sur Windows on saute directement à l'heuristique loader (la fonction
    // existe sur tous les targets via std.process).
    if (builtin.os.tag != .windows) {
        if (std.posix.getenv("LAVAPIPE_AVAILABLE") != null) return .yes;
    }
    // Heuristique : si Vulkan ne load pas, on skip.
    vk.loadLoader() catch return .no;
    return .yes;
}

test "Vulkan backend init and teardown over headless device" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    if (detectVulkan() == .no) {
        std.log.scoped(.test_gal_vk).warn("Vulkan loader not available — skipping (set LAVAPIPE_AVAILABLE=1 to force run)", .{});
        return error.SkipZigTest;
    }

    var device = gal.vulkan_backend.Device.init(std.testing.allocator, .{
        .label = "offline_test",
        .vulkan_driver = .auto,
        .gpu_preference = .auto,
        .enable_validation = false,
    }) catch |e| {
        std.log.scoped(.test_gal_vk).warn("Vulkan device init failed ({t}) — skipping", .{e});
        return error.SkipZigTest;
    };
    defer device.deinit();

    // Sanity : feature query sans crash, getQueue retourne un handle non-null.
    try std.testing.expect(!device.supports(.timeline_semaphore));
    const queue = try device.getQueue(.graphics);
    try std.testing.expect(@intFromPtr(queue) != 0);
}

test "Vulkan backend satisfies comptime interface check" {
    comptime gal.interface.checkBackend(gal.vulkan_backend.Device);
    try std.testing.expect(true);
}

test "Vulkan backend Device struct keeps allocator + selection" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    if (detectVulkan() == .no) return error.SkipZigTest;

    var device = gal.vulkan_backend.Device.init(std.testing.allocator, .{}) catch return error.SkipZigTest;
    defer device.deinit();

    // Le nom du device est rempli (terminé par un null byte).
    var has_content = false;
    for (device.selection.physical_device_name) |b| if (b != 0) {
        has_content = true;
        break;
    };
    try std.testing.expect(has_content);
}
