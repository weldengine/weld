//! RenderPipeline + ComputePipeline Vulkan — Phase 0 / M0.4.
//!
//! Phase 0:
//! - One PipelineLayout per pipeline (no sharing). Phase 1+: layout cache.
//! - No disk PipelineCache (inter-run load/save). Phase 1+:
//!   serialization in `.weld-cache/pipelines/`.
//! - Forced dynamic states: viewport + scissor (cf. S2 spike).
//! - Ephemeral render pass created just-in-time at draw — for
//!   PipelineCreateInfo compatibility which requires a VkRenderPass, we
//!   create a "template" render pass from the descriptor's color/depth
//!   targets and keep it in the entry for the pipeline's lifetime.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;

/// Internal slot of a RenderPipeline — bundles Pipeline + PipelineLayout +
/// the template RenderPass (Vulkan requires a VkRenderPass when creating
/// a graphics PSO, we keep this one for the pipeline's lifetime).
pub const RenderEntry = struct {
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    /// Template render pass created from the descriptor's color/depth targets.
    /// Vulkan requires a VkRenderPass for the graphics PSO; we keep this one
    /// for the PSO's lifetime.
    render_pass: vk.RenderPass,

    pub fn destroy(self: *RenderEntry, device: *vk.Device) void {
        if (self.pipeline != .null) device.destroyPipeline(self.pipeline, null);
        if (self.pipeline_layout != .null) device.destroyPipelineLayout(self.pipeline_layout, null);
        if (self.render_pass != .null) device.destroyRenderPass(self.render_pass, null);
        self.* = undefined;
    }
};

/// Creates a RenderPipeline (graphics PSO) — pipeline layout + template
/// render pass + graphics pipeline. Phase 0: dynamic viewport/scissor,
/// no tessellation, no MSAA.
pub fn createRender(
    device: *Device,
    descriptor: types.RenderPipelineDescriptor,
) types.Error!types.RenderPipelineHandle {
    if (!descriptor.vertex_module.isValid()) return error.InvalidArgument;
    if (descriptor.sample_count > 1) return error.Unsupported;

    // R8 (M1.1.1-HF3): bound the fixed [9] attachment arrays below (mirror of the
    // `render_pass.begin` guard) AND honor the device's color-attachment limit —
    // an over-long `color_targets` would otherwise write past `attachments` /
    // `color_refs`, and one exceeding `maxColorAttachments` is invalid.
    const max_attachments = 9;
    if (descriptor.color_targets.len + @as(usize, if (descriptor.depth_format != null) 1 else 0) > max_attachments) {
        return error.Unsupported;
    }
    const dev_limits = device.physical_device.getPhysicalDeviceProperties().limits;
    if (descriptor.color_targets.len > @as(usize, dev_limits.max_color_attachments)) return error.Unsupported;

    // PipelineLayout
    var set_layouts: std.ArrayList(vk.DescriptorSetLayout) = .empty;
    defer set_layouts.deinit(device.allocator);
    try set_layouts.ensureTotalCapacity(device.allocator, descriptor.layout.len);
    for (descriptor.layout) |l| {
        try set_layouts.append(device.allocator, @enumFromInt(l.inner));
    }
    const layout_ci: vk.PipelineLayoutCreateInfo = .{
        .flags = .empty,
        .set_layout_count = @intCast(set_layouts.items.len),
        .p_set_layouts = if (set_layouts.items.len > 0) @ptrCast(set_layouts.items.ptr) else undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    };
    const pl_layout = device.vk_device.createPipelineLayout(&layout_ci, null) catch return error.PipelineCreationFailed;
    errdefer device.vk_device.destroyPipelineLayout(pl_layout, null);

    // Template render pass (color attachments + optional depth). Sized by the
    // R8 guard above (`max_attachments`), so the loops below cannot overflow.
    var attachments: [max_attachments]vk.AttachmentDescription = undefined;
    var color_refs: [max_attachments]vk.AttachmentReference = undefined;
    var depth_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .undefined };
    var n_attach: u32 = 0;
    var n_color: u32 = 0;
    for (descriptor.color_targets) |c| {
        attachments[n_attach] = .{
            .flags = .empty,
            .format = conv.textureFormat(c.format),
            .samples = ._1_bit,
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };
        color_refs[n_color] = .{ .attachment = n_attach, .layout = .color_attachment_optimal };
        n_attach += 1;
        n_color += 1;
    }
    var has_depth = false;
    if (descriptor.depth_format) |df| {
        attachments[n_attach] = .{
            .flags = .empty,
            .format = conv.textureFormat(df),
            .samples = ._1_bit,
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
        };
        depth_ref = .{ .attachment = n_attach, .layout = .depth_stencil_attachment_optimal };
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
    // External subpass dependency — MUST match the executing render pass
    // built by `render_pass.zig` (same SUBPASS_EXTERNAL→0 color-attachment-output
    // dependency). This template render pass is used only for pipeline
    // compatibility; if its `dependencyCount` differs from the executing pass,
    // the draw trips VUID-vkCmdDrawIndexed-renderPass-02684 (render passes
    // incompatible). Kept identical to render_pass.zig. Frozen by E7 (C0.5).
    const external_dep: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output = true },
        .dst_stage_mask = .{ .color_attachment_output = true },
        .src_access_mask = .empty,
        .dst_access_mask = .{ .color_attachment_write = true },
        .dependency_flags = .empty,
    };
    const rp_ci: vk.RenderPassCreateInfo = .{
        .flags = .empty,
        .attachment_count = n_attach,
        .p_attachments = if (n_attach > 0) @ptrCast(&attachments) else undefined,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&external_dep),
    };
    const rp = device.vk_device.createRenderPass(&rp_ci, null) catch return error.PipelineCreationFailed;
    errdefer device.vk_device.destroyRenderPass(rp, null);

    // Shader stages
    // Build both stages as a single array literal so the bindgen-emitted
    // `s_type = .pipeline_shader_stage_create_info` default is applied
    // to every element. The previous `var stages = undefined;` followed
    // by per-element `stages[N] = .{ ... }` assignment left `s_type` at
    // an indeterminate value on Linux (Fedora 44 + Intel UHD 630
    // surfaced a `pStages[N].sType must be ...` validation warning
    // followed by a SIGSEGV inside the validation layer's logging
    // path). S2 reference (/tmp/s2-ref/src/spike/vk_setup.zig
    // createGraphicsPipeline) uses the same array-literal pattern.
    //
    // The fragment slot is always populated so the array literal stays
    // canonical; when `descriptor.fragment_module` is null the slot is
    // ignored downstream via `stage_count = 1`.
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .empty,
            .stage = .vertex_bit,
            .module = @enumFromInt(descriptor.vertex_module.inner),
            .p_name = descriptor.vertex_entry_point.ptr,
            .p_specialization_info = null,
        },
        .{
            .flags = .empty,
            .stage = .fragment_bit,
            .module = if (descriptor.fragment_module) |fs| @enumFromInt(fs.inner) else .null,
            .p_name = descriptor.fragment_entry_point.ptr,
            .p_specialization_info = null,
        },
    };
    const stage_count: u32 = if (descriptor.fragment_module != null) 2 else 1;

    // Vertex input
    var bindings: std.ArrayList(vk.VertexInputBindingDescription) = .empty;
    defer bindings.deinit(device.allocator);
    var attrs: std.ArrayList(vk.VertexInputAttributeDescription) = .empty;
    defer attrs.deinit(device.allocator);
    for (descriptor.vertex_buffers, 0..) |vb, i| {
        try bindings.append(device.allocator, .{
            .binding = @intCast(i),
            .stride = vb.stride,
            .input_rate = if (vb.step_mode == .instance) .instance else .vertex,
        });
        for (vb.attributes) |a| {
            try attrs.append(device.allocator, .{
                .location = a.location,
                .binding = @intCast(i),
                .format = conv.textureFormat(a.format),
                .offset = a.offset,
            });
        }
    }
    const vi: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .empty,
        .vertex_binding_description_count = @intCast(bindings.items.len),
        .p_vertex_binding_descriptions = if (bindings.items.len > 0) @ptrCast(bindings.items.ptr) else undefined,
        .vertex_attribute_description_count = @intCast(attrs.items.len),
        .p_vertex_attribute_descriptions = if (attrs.items.len > 0) @ptrCast(attrs.items.ptr) else undefined,
    };
    const ia: vk.PipelineInputAssemblyStateCreateInfo = .{
        .flags = .empty,
        .topology = conv.primitiveTopology(descriptor.primitive_topology),
        .primitive_restart_enable = 0,
    };
    const viewport: vk.Viewport = .{ .x = 0, .y = 0, .width = 1, .height = 1, .min_depth = 0, .max_depth = 1 };
    const scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 1, .height = 1 } };
    const vp: vk.PipelineViewportStateCreateInfo = .{
        .flags = .empty,
        .viewport_count = 1,
        .p_viewports = @ptrCast(&viewport),
        .scissor_count = 1,
        .p_scissors = @ptrCast(&scissor),
    };
    const dyn = [_]vk.DynamicState{ .viewport, .scissor };
    const dyn_state: vk.PipelineDynamicStateCreateInfo = .{
        .flags = .empty,
        .dynamic_state_count = dyn.len,
        .p_dynamic_states = @ptrCast(&dyn),
    };
    const rs: vk.PipelineRasterizationStateCreateInfo = .{
        .flags = .empty,
        .depth_clamp_enable = 0,
        .rasterizer_discard_enable = 0,
        .polygon_mode = .fill,
        .cull_mode = conv.cullMode(descriptor.cull_mode),
        .front_face = .counter_clockwise,
        .depth_bias_enable = 0,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1.0,
    };
    const ms: vk.PipelineMultisampleStateCreateInfo = .{
        .flags = .empty,
        .rasterization_samples = ._1_bit,
        .sample_shading_enable = 0,
        .min_sample_shading = 0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = 0,
        .alpha_to_one_enable = 0,
    };
    const depth_stencil: vk.PipelineDepthStencilStateCreateInfo = .{
        .flags = .empty,
        .depth_test_enable = if (descriptor.depth_test_enabled) 1 else 0,
        .depth_write_enable = if (descriptor.depth_write_enabled) 1 else 0,
        .depth_compare_op = conv.compareOp(descriptor.depth_compare),
        .depth_bounds_test_enable = 0,
        .stencil_test_enable = 0,
        .front = std.mem.zeroes(vk.StencilOpState),
        .back = std.mem.zeroes(vk.StencilOpState),
        .min_depth_bounds = 0,
        .max_depth_bounds = 1,
    };

    var blend_states: std.ArrayList(vk.PipelineColorBlendAttachmentState) = .empty;
    defer blend_states.deinit(device.allocator);
    for (descriptor.color_targets) |_| {
        try blend_states.append(device.allocator, .{
            .blend_enable = 0,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
        });
    }
    const cb: vk.PipelineColorBlendStateCreateInfo = .{
        .flags = .empty,
        .logic_op_enable = 0,
        .logic_op = .copy,
        .attachment_count = @intCast(blend_states.items.len),
        .p_attachments = if (blend_states.items.len > 0) @ptrCast(blend_states.items.ptr) else undefined,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const pipe_ci = [_]vk.GraphicsPipelineCreateInfo{
        .{
            .flags = .empty,
            .stage_count = stage_count,
            .p_stages = @ptrCast(&stages),
            .p_vertex_input_state = &vi,
            .p_input_assembly_state = &ia,
            .p_tessellation_state = null,
            .p_viewport_state = &vp,
            .p_rasterization_state = &rs,
            .p_multisample_state = &ms,
            .p_depth_stencil_state = if (has_depth) &depth_stencil else null,
            .p_color_blend_state = &cb,
            .p_dynamic_state = &dyn_state,
            .layout = pl_layout,
            .render_pass = rp,
            .subpass = 0,
            .base_pipeline_handle = .null,
            .base_pipeline_index = -1,
        },
    };
    var pipelines: [1]vk.Pipeline = .{.null};
    device.vk_device.createGraphicsPipelines(.null, &pipe_ci, null, &pipelines) catch return error.PipelineCreationFailed;
    // R5c (M1.1.1-HF3): destroy the just-created pipeline if the registry `put`
    // below fails — the layout + render-pass errdefers already cover their halves
    // of the tail, but the pipeline itself would otherwise leak.
    errdefer device.vk_device.destroyPipeline(pipelines[0], null);

    const id = device.nextHandle();
    try device.render_pipelines.put(device.allocator, id, .{
        .pipeline = pipelines[0],
        .pipeline_layout = pl_layout,
        .render_pass = rp,
    });
    return .{ .inner = id };
}

/// Frees a RenderPipeline + its layout + its template render pass.
pub fn destroyRender(device: *Device, handle: types.RenderPipelineHandle) void {
    if (handle.inner == 0) return;
    if (device.render_pipelines.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Phase 0: ComputePipeline is in the GAL day-1 (escape hatch Phase 1+
/// V-Buffer / GI compute). Unused in Phase 0, but must be creatable.
pub fn createCompute(
    device: *Device,
    descriptor: types.ComputePipelineDescriptor,
) types.Error!types.ComputePipelineHandle {
    if (!descriptor.module.isValid()) return error.InvalidArgument;

    var set_layouts: std.ArrayList(vk.DescriptorSetLayout) = .empty;
    defer set_layouts.deinit(device.allocator);
    try set_layouts.ensureTotalCapacity(device.allocator, descriptor.layout.len);
    for (descriptor.layout) |l| try set_layouts.append(device.allocator, @enumFromInt(l.inner));
    const layout_ci: vk.PipelineLayoutCreateInfo = .{
        .flags = .empty,
        .set_layout_count = @intCast(set_layouts.items.len),
        .p_set_layouts = if (set_layouts.items.len > 0) @ptrCast(set_layouts.items.ptr) else undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    };
    const pl_layout = device.vk_device.createPipelineLayout(&layout_ci, null) catch return error.PipelineCreationFailed;
    errdefer device.vk_device.destroyPipelineLayout(pl_layout, null);

    const stage: vk.PipelineShaderStageCreateInfo = .{
        .flags = .empty,
        .stage = .compute_bit,
        .module = @enumFromInt(descriptor.module.inner),
        .p_name = descriptor.entry_point.ptr,
        .p_specialization_info = null,
    };
    const ci = [_]vk.ComputePipelineCreateInfo{.{
        .flags = .empty,
        .stage = stage,
        .layout = pl_layout,
        .base_pipeline_handle = .null,
        .base_pipeline_index = -1,
    }};
    var pipelines: [1]vk.Pipeline = .{.null};
    device.vk_device.createComputePipelines(.null, &ci, null, &pipelines) catch return error.PipelineCreationFailed;
    // R5c (M1.1.1-HF3): destroy the pipeline if the registry `put` below fails
    // (the layout errdefer covers the layout; the pipeline would otherwise leak).
    errdefer device.vk_device.destroyPipeline(pipelines[0], null);

    // Phase 0: we store in render_pipelines for simplicity — Phase 1+
    // a dedicated compute_pipelines registry. The `render_pass` is `.null`
    // for compute pipelines.
    const id = device.nextHandle();
    try device.render_pipelines.put(device.allocator, id, .{
        .pipeline = pipelines[0],
        .pipeline_layout = pl_layout,
        .render_pass = .null,
    });
    return .{ .inner = id };
}

/// Frees a ComputePipeline + its layout. Phase 0 shares the
/// `render_pipelines` map with the RenderPipelines (unified registry).
pub fn destroyCompute(device: *Device, handle: types.ComputePipelineHandle) void {
    if (handle.inner == 0) return;
    if (device.render_pipelines.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Helper: retrieves the native `(pipeline, layout, render_pass)` from a handle.
pub fn lookup(device: *Device, handle: types.RenderPipelineHandle) ?RenderEntry {
    if (handle.inner == 0) return null;
    return device.render_pipelines.get(handle.inner);
}
