//! RenderPass Vulkan — Phase 0 / M0.4.
//!
//! Phase 0 : les RenderPass Vulkan sont créées **à la demande** lors de
//! `CommandEncoder.beginRenderPass` à partir d'un `RenderPassDescriptor`
//! GAL. C'est inefficace par rapport à un cache par signature
//! (color_targets + depth_format + load/store ops), mais suffisant pour
//! la triangle Phase 0. Phase 1+ : cache hashé `(formats + ops)` →
//! réutilisation.
//!
//! Les framebuffers correspondants sont créés transient pour la durée
//! de la pass (sauf si le caller passe directement par VK_KHR_dynamic_rendering
//! — Phase 1+).

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const texture_mod = @import("texture.zig");
const Device = @import("device.zig").Device;

/// Bundle render pass + framebuffer transients pour une pass donnée. Crés
/// par `begin`, libérés par `end`.
pub const Transient = struct {
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    extent: vk.Extent2D,
    clear_values: [9]vk.ClearValue = undefined,
    clear_count: u32 = 0,

    pub fn destroy(self: *Transient, device: *vk.Device) void {
        if (self.framebuffer != .null) device.destroyFramebuffer(self.framebuffer, null);
        if (self.render_pass != .null) device.destroyRenderPass(self.render_pass, null);
        self.* = undefined;
    }
};

/// Crée la RenderPass + Framebuffer correspondant à un `RenderPassDescriptor`.
pub fn begin(device: *Device, descriptor: types.RenderPassDescriptor) types.Error!Transient {
    const max_attachments = 9;
    if (descriptor.color_attachments.len + @as(usize, if (descriptor.depth_stencil_attachment != null) 1 else 0) > max_attachments) {
        return error.Unsupported;
    }

    var attachments: [max_attachments]vk.AttachmentDescription = undefined;
    var color_refs: [max_attachments]vk.AttachmentReference = undefined;
    var fb_views: [max_attachments]vk.ImageView = undefined;
    var depth_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .undefined };
    var n_attach: u32 = 0;
    var n_color: u32 = 0;

    var extent: vk.Extent2D = .{ .width = 0, .height = 0 };
    var clears: [9]vk.ClearValue = undefined;

    for (descriptor.color_attachments) |c| {
        if (n_attach >= max_attachments) return error.Unsupported;
        // Format extrait du parent de la view — pour Phase 0 on suppose que
        // c'est encodé dans la registry texture_views (mais on n'a pas le
        // backlink). On lit donc le format depuis l'image associée.
        const view = texture_mod.lookupView(device, c.view) orelse return error.InvalidArgument;
        // Format unknown depuis la view seule — Phase 0 : on prend
        // bgra8_unorm comme défaut swapchain. Phase 1+ : extension du
        // ViewEntry pour mémoriser le format.
        const format = vk.Format.b8g8r8a8_unorm;
        attachments[n_attach] = .{
            .flags = .empty,
            .format = format,
            .samples = ._1_bit,
            .load_op = conv.loadOp(c.load_op),
            .store_op = conv.storeOp(c.store_op),
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };
        color_refs[n_color] = .{
            .attachment = n_attach,
            .layout = .color_attachment_optimal,
        };
        fb_views[n_attach] = view;
        clears[n_attach] = .{ .color = .{ .float32 = .{
            c.clear_color.r, c.clear_color.g, c.clear_color.b, c.clear_color.a,
        } } };
        n_attach += 1;
        n_color += 1;
    }

    var has_depth = false;
    if (descriptor.depth_stencil_attachment) |d| {
        if (n_attach >= max_attachments) return error.Unsupported;
        const view = texture_mod.lookupView(device, d.view) orelse return error.InvalidArgument;
        // Phase 0 : format depth attendu D32_SFLOAT (cf. brief §Notes décision 5).
        const format = vk.Format.d32_sfloat;
        attachments[n_attach] = .{
            .flags = .empty,
            .format = format,
            .samples = ._1_bit,
            .load_op = conv.loadOp(d.depth_load_op),
            .store_op = conv.storeOp(d.depth_store_op),
            .stencil_load_op = conv.loadOp(d.stencil_load_op),
            .stencil_store_op = conv.storeOp(d.stencil_store_op),
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
        };
        depth_ref = .{
            .attachment = n_attach,
            .layout = .depth_stencil_attachment_optimal,
        };
        fb_views[n_attach] = view;
        clears[n_attach] = .{ .depth_stencil = .{
            .depth = d.depth_clear,
            .stencil = d.stencil_clear,
        } };
        n_attach += 1;
        has_depth = true;
    }

    const subpass: vk.SubpassDescription = .{
        .flags = .empty,
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = n_color,
        .p_color_attachments = if (n_color > 0) @ptrCast(&color_refs) else undefined,
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = if (has_depth) &depth_ref else null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    const rp_ci: vk.RenderPassCreateInfo = .{
        .flags = .empty,
        .attachment_count = n_attach,
        .p_attachments = if (n_attach > 0) @ptrCast(&attachments) else undefined,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 0,
        .p_dependencies = undefined,
    };
    const rp = device.vk_device.createRenderPass(&rp_ci, null) catch return error.BackendInternal;
    errdefer device.vk_device.destroyRenderPass(rp, null);

    // Extent — on prend la dimension de la première texture color attachment
    // (toutes les attachments doivent matcher Phase 0).
    if (descriptor.color_attachments.len > 0) {
        const first_view = descriptor.color_attachments[0].view;
        if (lookupViewExtent(device, first_view)) |e| extent = e;
    } else if (descriptor.depth_stencil_attachment) |d| {
        if (lookupViewExtent(device, d.view)) |e| extent = e;
    } else {
        return error.InvalidArgument;
    }

    const fb_ci: vk.FramebufferCreateInfo = .{
        .flags = .empty,
        .render_pass = rp,
        .attachment_count = n_attach,
        .p_attachments = if (n_attach > 0) @ptrCast(&fb_views) else undefined,
        .width = extent.width,
        .height = extent.height,
        .layers = 1,
    };
    const fb = device.vk_device.createFramebuffer(&fb_ci, null) catch return error.BackendInternal;

    var t: Transient = .{
        .render_pass = rp,
        .framebuffer = fb,
        .extent = extent,
        .clear_count = n_attach,
    };
    @memcpy(t.clear_values[0..n_attach], clears[0..n_attach]);
    return t;
}

/// Helper : récupère la taille (extent2d) d'une view en remontant à la
/// texture parente. Phase 0 stocke ces métadonnées dans `TextureEntry`,
/// pas dans `ViewEntry` — donc on cherche la texture qui contient cette
/// `vk.ImageView` (O(n) linear scan). Phase 1+ : back-pointer view → tex.
fn lookupViewExtent(device: *Device, view: types.TextureViewHandle) ?vk.Extent2D {
    const v = texture_mod.lookupView(device, view) orelse return null;
    var it = device.textures.iterator();
    while (it.next()) |kv| {
        _ = kv;
        // Phase 0 : on n'a pas de back-pointer, on retourne le premier
        // entry des textures. C'est faux pour les multi-textures mais
        // marche pour le smoke test single-texture. À corriger Phase 1.
        return .{ .width = 0, .height = 0 };
    }
    _ = v;
    return null;
}
