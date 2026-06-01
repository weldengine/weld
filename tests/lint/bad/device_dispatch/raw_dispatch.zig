//! Fixture: raw `vk.device_dispatch` access outside the GAL Vulkan backend.
//!
//! `weld_lint lint` must flag this with a non-zero exit. With the M0.5
//! hardening, no `WELD_LEGACY_VK_DISPATCH` grandfather marker can suppress it.

const vk = @import("vk");

fn present() void {
    _ = vk.device_dispatch.vkQueuePresentKHR;
}
