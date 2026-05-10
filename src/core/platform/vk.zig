//! AUTO-GENERATED — do not edit. Regenerate via `zig build bindgen-vk`.
//!
//! Vulkan binding emitted from `bindings/upstream/vulkan/vk.xml`
//! (Vulkan-Headers vulkan-sdk-1.4.341.0).
//! Whitelist: Vulkan 1.3 core + VK_KHR_surface + VK_KHR_swapchain
//! + VK_KHR_wayland_surface + VK_KHR_win32_surface + VK_EXT_debug_utils.
//!
//! Throwaway in the strict sense — refactored in S3 by the unified
//! bindgen system (cf. `engine-c-bindings.md` §10.1). The public
//! Zig surface (handle types, struct layouts, method names) is a
//! conformance target of `engine-c-bindings.md` §4.2 idioms so the
//! S3 regeneration produces zero diff at call sites.

const std = @import("std");
const builtin = @import("builtin");

// ---- C basetype aliases ----

pub const SampleMask = u32;
pub const Bool32 = u32;
pub const Flags = u32;
pub const Flags64 = u64;
pub const DeviceSize = u64;
pub const DeviceAddress = u64;

// ---- Platform forward declarations ----

pub const wl_display = opaque {};
pub const wl_surface = opaque {};
pub const HINSTANCE = *opaque {};
pub const HWND = *opaque {};

// ---- API Constants ----

pub const MAX_PHYSICAL_DEVICE_NAME_SIZE: u32 = 256;
pub const UUID_SIZE: u32 = 16;
pub const LUID_SIZE: u32 = 8;
pub const MAX_EXTENSION_NAME_SIZE: u32 = 256;
pub const MAX_DESCRIPTION_SIZE: u32 = 256;
pub const MAX_MEMORY_TYPES: u32 = 32;
pub const MAX_MEMORY_HEAPS: u32 = 16;
pub const LOD_CLAMP_NONE: f32 = 1000.0;
pub const REMAINING_MIP_LEVELS: u32 = 0xFFFFFFFF;
pub const REMAINING_ARRAY_LAYERS: u32 = 0xFFFFFFFF;
pub const REMAINING_3D_SLICES_EXT: u32 = 0xFFFFFFFF;
pub const WHOLE_SIZE: u64 = 0xFFFFFFFFFFFFFFFF;
pub const ATTACHMENT_UNUSED: u32 = 0xFFFFFFFF;
pub const TRUE: u32 = 1;
pub const FALSE: u32 = 0;
pub const QUEUE_FAMILY_IGNORED: u32 = 0xFFFFFFFF;
pub const QUEUE_FAMILY_EXTERNAL: u32 = 0xFFFFFFFE;
pub const QUEUE_FAMILY_FOREIGN_EXT: u32 = 0xFFFFFFFD;
pub const SUBPASS_EXTERNAL: u32 = 0xFFFFFFFF;
pub const MAX_DEVICE_GROUP_SIZE: u32 = 32;
pub const MAX_DRIVER_NAME_SIZE: u32 = 256;
pub const MAX_DRIVER_INFO_SIZE: u32 = 256;
pub const SHADER_UNUSED_KHR: u32 = 0xFFFFFFFF;
pub const MAX_GLOBAL_PRIORITY_SIZE: u32 = 16;
pub const MAX_SHADER_MODULE_IDENTIFIER_SIZE_EXT: u32 = 32;
pub const MAX_PIPELINE_BINARY_KEY_SIZE_KHR: u32 = 32;
pub const MAX_VIDEO_AV1_REFERENCES_PER_FRAME_KHR: u32 = 7;
pub const MAX_VIDEO_VP9_REFERENCES_PER_FRAME_KHR: u32 = 3;
pub const SHADER_INDEX_UNUSED_AMDX: u32 = 0xFFFFFFFF;
pub const PARTITIONED_ACCELERATION_STRUCTURE_PARTITION_INDEX_GLOBAL_NV: u32 = 0xFFFFFFFF;
pub const COMPRESSED_TRIANGLE_FORMAT_DGF1_BYTE_ALIGNMENT_AMDX: u32 = 128;
pub const COMPRESSED_TRIANGLE_FORMAT_DGF1_BYTE_STRIDE_AMDX: u32 = 128;
pub const MAX_PHYSICAL_DEVICE_DATA_GRAPH_OPERATION_SET_NAME_SIZE_ARM: u32 = 128;
pub const DATA_GRAPH_MODEL_TOOLCHAIN_VERSION_LENGTH_QCOM: u32 = 3;
pub const COMPUTE_OCCUPANCY_PRIORITY_LOW_NV: f32 = 0.25;
pub const COMPUTE_OCCUPANCY_PRIORITY_NORMAL_NV: f32 = 0.50;
pub const COMPUTE_OCCUPANCY_PRIORITY_HIGH_NV: f32 = 0.75;

// ---- Enums (and bitmask FlagBits enums) ----

pub const ImageLayout = enum(i32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    depth_stencil_attachment_optimal = 3,
    depth_stencil_read_only_optimal = 4,
    shader_read_only_optimal = 5,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    preinitialized = 8,
    depth_read_only_stencil_attachment_optimal = 1000117000,
    depth_attachment_stencil_read_only_optimal = 1000117001,
    depth_attachment_optimal = 1000241000,
    depth_read_only_optimal = 1000241001,
    stencil_attachment_optimal = 1000241002,
    stencil_read_only_optimal = 1000241003,
    read_only_optimal = 1000314000,
    attachment_optimal = 1000314001,
    rendering_local_read = 1000232000,
    present_src_khr = 1000001002,
    video_decode_dst_khr = 1000024000,
    video_decode_src_khr = 1000024001,
    video_decode_dpb_khr = 1000024002,
    shared_present_khr = 1000111000,
    fragment_density_map_optimal_ext = 1000218000,
    fragment_shading_rate_attachment_optimal_khr = 1000164003,
    video_encode_dst_khr = 1000299000,
    video_encode_src_khr = 1000299001,
    video_encode_dpb_khr = 1000299002,
    attachment_feedback_loop_optimal_ext = 1000339000,
    tensor_aliasing_arm = 1000460000,
    video_encode_quantization_map_khr = 1000553000,
    zero_initialized_ext = 1000620000,
    _,
};
pub const ImageLayout_depth_read_only_stencil_attachment_optimal_khr: ImageLayout = .depth_read_only_stencil_attachment_optimal;
pub const ImageLayout_depth_attachment_stencil_read_only_optimal_khr: ImageLayout = .depth_attachment_stencil_read_only_optimal;
pub const ImageLayout_shading_rate_optimal_nv: ImageLayout = .fragment_shading_rate_attachment_optimal_khr;
pub const ImageLayout_rendering_local_read_khr: ImageLayout = .rendering_local_read;
pub const ImageLayout_depth_attachment_optimal_khr: ImageLayout = .depth_attachment_optimal;
pub const ImageLayout_depth_read_only_optimal_khr: ImageLayout = .depth_read_only_optimal;
pub const ImageLayout_stencil_attachment_optimal_khr: ImageLayout = .stencil_attachment_optimal;
pub const ImageLayout_stencil_read_only_optimal_khr: ImageLayout = .stencil_read_only_optimal;
pub const ImageLayout_read_only_optimal_khr: ImageLayout = .read_only_optimal;
pub const ImageLayout_attachment_optimal_khr: ImageLayout = .attachment_optimal;

pub const AttachmentLoadOp = enum(i32) {
    load = 0,
    clear = 1,
    dont_care = 2,
    none = 1000400000,
    _,
};
pub const AttachmentLoadOp_none_ext: AttachmentLoadOp = .none;
pub const AttachmentLoadOp_none_khr: AttachmentLoadOp = .none;

pub const AttachmentStoreOp = enum(i32) {
    store = 0,
    dont_care = 1,
    none = 1000301000,
    _,
};
pub const AttachmentStoreOp_none_khr: AttachmentStoreOp = .none;
pub const AttachmentStoreOp_none_qcom: AttachmentStoreOp = .none;
pub const AttachmentStoreOp_none_ext: AttachmentStoreOp = .none;

pub const ImageType = enum(i32) {
    _1d = 0,
    _2d = 1,
    _3d = 2,
    _,
};

pub const ImageTiling = enum(i32) {
    optimal = 0,
    linear = 1,
    drm_format_modifier_ext = 1000158000,
    _,
};

pub const ImageViewType = enum(i32) {
    _1d = 0,
    _2d = 1,
    _3d = 2,
    cube = 3,
    _1d_array = 4,
    _2d_array = 5,
    cube_array = 6,
    _,
};

pub const CommandBufferLevel = enum(i32) {
    primary = 0,
    secondary = 1,
    _,
};

pub const ComponentSwizzle = enum(i32) {
    identity = 0,
    zero = 1,
    one = 2,
    r = 3,
    g = 4,
    b = 5,
    a = 6,
    _,
};

pub const DescriptorType = enum(i32) {
    sampler = 0,
    combined_image_sampler = 1,
    sampled_image = 2,
    storage_image = 3,
    uniform_texel_buffer = 4,
    storage_texel_buffer = 5,
    uniform_buffer = 6,
    storage_buffer = 7,
    uniform_buffer_dynamic = 8,
    storage_buffer_dynamic = 9,
    input_attachment = 10,
    inline_uniform_block = 1000138000,
    acceleration_structure_khr = 1000150000,
    acceleration_structure_nv = 1000165000,
    sample_weight_image_qcom = 1000440000,
    block_match_image_qcom = 1000440001,
    tensor_arm = 1000460000,
    mutable_ext = 1000351000,
    partitioned_acceleration_structure_nv = 1000570000,
    _,
};
pub const DescriptorType_inline_uniform_block_ext: DescriptorType = .inline_uniform_block;
pub const DescriptorType_mutable_valve: DescriptorType = .mutable_ext;

pub const QueryType = enum(i32) {
    occlusion = 0,
    pipeline_statistics = 1,
    timestamp = 2,
    result_status_only_khr = 1000023000,
    transform_feedback_stream_ext = 1000028004,
    performance_query_khr = 1000116000,
    acceleration_structure_compacted_size_khr = 1000150000,
    acceleration_structure_serialization_size_khr = 1000150001,
    acceleration_structure_compacted_size_nv = 1000165000,
    performance_query_intel = 1000210000,
    video_encode_feedback_khr = 1000299000,
    mesh_primitives_generated_ext = 1000328000,
    primitives_generated_ext = 1000382000,
    acceleration_structure_serialization_bottom_level_pointers_khr = 1000386000,
    acceleration_structure_size_khr = 1000386001,
    micromap_serialization_size_ext = 1000396000,
    micromap_compacted_size_ext = 1000396001,
    _,
};

pub const BorderColor = enum(i32) {
    float_transparent_black = 0,
    int_transparent_black = 1,
    float_opaque_black = 2,
    int_opaque_black = 3,
    float_opaque_white = 4,
    int_opaque_white = 5,
    float_custom_ext = 1000287003,
    int_custom_ext = 1000287004,
    _,
};

pub const PipelineBindPoint = enum(i32) {
    graphics = 0,
    compute = 1,
    execution_graph_amdx = 1000134000,
    ray_tracing_khr = 1000165000,
    subpass_shading_huawei = 1000369003,
    data_graph_arm = 1000507000,
    _,
};
pub const PipelineBindPoint_ray_tracing_nv: PipelineBindPoint = .ray_tracing_khr;

pub const PipelineCacheHeaderVersion = enum(i32) {
    one = 1,
    safety_critical_one = 1000298001,
    data_graph_qcom = 1000629000,
    _,
};

pub const PipelineCacheCreateFlagBits = enum(i32) {
    _,
};
pub const PipelineCacheCreateFlagBits_externally_synchronized_bit_ext: PipelineCacheCreateFlagBits = .externally_synchronized_bit;

pub const PrimitiveTopology = enum(i32) {
    point_list = 0,
    line_list = 1,
    line_strip = 2,
    triangle_list = 3,
    triangle_strip = 4,
    triangle_fan = 5,
    line_list_with_adjacency = 6,
    line_strip_with_adjacency = 7,
    triangle_list_with_adjacency = 8,
    triangle_strip_with_adjacency = 9,
    patch_list = 10,
    _,
};

pub const SharingMode = enum(i32) {
    exclusive = 0,
    concurrent = 1,
    _,
};

pub const IndexType = enum(i32) {
    uint16 = 0,
    uint32 = 1,
    uint8 = 1000265000,
    none_khr = 1000165000,
    _,
};
pub const IndexType_none_nv: IndexType = .none_khr;
pub const IndexType_uint8_ext: IndexType = .uint8;
pub const IndexType_uint8_khr: IndexType = .uint8;

pub const Filter = enum(i32) {
    nearest = 0,
    linear = 1,
    cubic_ext = 1000015000,
    _,
};
pub const Filter_cubic_img: Filter = .cubic_ext;

pub const SamplerMipmapMode = enum(i32) {
    nearest = 0,
    linear = 1,
    _,
};

pub const SamplerAddressMode = enum(i32) {
    repeat = 0,
    mirrored_repeat = 1,
    clamp_to_edge = 2,
    clamp_to_border = 3,
    mirror_clamp_to_edge = 4,
    _,
};
pub const SamplerAddressMode_mirror_clamp_to_edge_khr: SamplerAddressMode = .mirror_clamp_to_edge;

pub const CompareOp = enum(i32) {
    never = 0,
    less = 1,
    equal = 2,
    less_or_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_or_equal = 6,
    always = 7,
    _,
};

pub const PolygonMode = enum(i32) {
    fill = 0,
    line = 1,
    point = 2,
    fill_rectangle_nv = 1000153000,
    _,
};

pub const FrontFace = enum(i32) {
    counter_clockwise = 0,
    clockwise = 1,
    _,
};

pub const BlendFactor = enum(i32) {
    zero = 0,
    one = 1,
    src_color = 2,
    one_minus_src_color = 3,
    dst_color = 4,
    one_minus_dst_color = 5,
    src_alpha = 6,
    one_minus_src_alpha = 7,
    dst_alpha = 8,
    one_minus_dst_alpha = 9,
    constant_color = 10,
    one_minus_constant_color = 11,
    constant_alpha = 12,
    one_minus_constant_alpha = 13,
    src_alpha_saturate = 14,
    src1_color = 15,
    one_minus_src1_color = 16,
    src1_alpha = 17,
    one_minus_src1_alpha = 18,
    _,
};

pub const BlendOp = enum(i32) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
    zero_ext = 1000148000,
    src_ext = 1000148001,
    dst_ext = 1000148002,
    src_over_ext = 1000148003,
    dst_over_ext = 1000148004,
    src_in_ext = 1000148005,
    dst_in_ext = 1000148006,
    src_out_ext = 1000148007,
    dst_out_ext = 1000148008,
    src_atop_ext = 1000148009,
    dst_atop_ext = 1000148010,
    xor_ext = 1000148011,
    multiply_ext = 1000148012,
    screen_ext = 1000148013,
    overlay_ext = 1000148014,
    darken_ext = 1000148015,
    lighten_ext = 1000148016,
    colordodge_ext = 1000148017,
    colorburn_ext = 1000148018,
    hardlight_ext = 1000148019,
    softlight_ext = 1000148020,
    difference_ext = 1000148021,
    exclusion_ext = 1000148022,
    invert_ext = 1000148023,
    invert_rgb_ext = 1000148024,
    lineardodge_ext = 1000148025,
    linearburn_ext = 1000148026,
    vividlight_ext = 1000148027,
    linearlight_ext = 1000148028,
    pinlight_ext = 1000148029,
    hardmix_ext = 1000148030,
    hsl_hue_ext = 1000148031,
    hsl_saturation_ext = 1000148032,
    hsl_color_ext = 1000148033,
    hsl_luminosity_ext = 1000148034,
    plus_ext = 1000148035,
    plus_clamped_ext = 1000148036,
    plus_clamped_alpha_ext = 1000148037,
    plus_darker_ext = 1000148038,
    minus_ext = 1000148039,
    minus_clamped_ext = 1000148040,
    contrast_ext = 1000148041,
    invert_ovg_ext = 1000148042,
    red_ext = 1000148043,
    green_ext = 1000148044,
    blue_ext = 1000148045,
    _,
};

pub const StencilOp = enum(i32) {
    keep = 0,
    zero = 1,
    replace = 2,
    increment_and_clamp = 3,
    decrement_and_clamp = 4,
    invert = 5,
    increment_and_wrap = 6,
    decrement_and_wrap = 7,
    _,
};

pub const LogicOp = enum(i32) {
    clear = 0,
    @"and" = 1,
    and_reverse = 2,
    copy = 3,
    and_inverted = 4,
    no_op = 5,
    xor = 6,
    @"or" = 7,
    nor = 8,
    equivalent = 9,
    invert = 10,
    or_reverse = 11,
    copy_inverted = 12,
    or_inverted = 13,
    nand = 14,
    set = 15,
    _,
};

pub const InternalAllocationType = enum(i32) {
    executable = 0,
    _,
};

pub const SystemAllocationScope = enum(i32) {
    command = 0,
    object = 1,
    cache = 2,
    device = 3,
    instance = 4,
    _,
};

pub const PhysicalDeviceType = enum(i32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
    _,
};

pub const VertexInputRate = enum(i32) {
    vertex = 0,
    instance = 1,
    _,
};

pub const Format = enum(i32) {
    undefined = 0,
    r4g4_unorm_pack8 = 1,
    r4g4b4a4_unorm_pack16 = 2,
    b4g4r4a4_unorm_pack16 = 3,
    r5g6b5_unorm_pack16 = 4,
    b5g6r5_unorm_pack16 = 5,
    r5g5b5a1_unorm_pack16 = 6,
    b5g5r5a1_unorm_pack16 = 7,
    a1r5g5b5_unorm_pack16 = 8,
    r8_unorm = 9,
    r8_snorm = 10,
    r8_uscaled = 11,
    r8_sscaled = 12,
    r8_uint = 13,
    r8_sint = 14,
    r8_srgb = 15,
    r8g8_unorm = 16,
    r8g8_snorm = 17,
    r8g8_uscaled = 18,
    r8g8_sscaled = 19,
    r8g8_uint = 20,
    r8g8_sint = 21,
    r8g8_srgb = 22,
    r8g8b8_unorm = 23,
    r8g8b8_snorm = 24,
    r8g8b8_uscaled = 25,
    r8g8b8_sscaled = 26,
    r8g8b8_uint = 27,
    r8g8b8_sint = 28,
    r8g8b8_srgb = 29,
    b8g8r8_unorm = 30,
    b8g8r8_snorm = 31,
    b8g8r8_uscaled = 32,
    b8g8r8_sscaled = 33,
    b8g8r8_uint = 34,
    b8g8r8_sint = 35,
    b8g8r8_srgb = 36,
    r8g8b8a8_unorm = 37,
    r8g8b8a8_snorm = 38,
    r8g8b8a8_uscaled = 39,
    r8g8b8a8_sscaled = 40,
    r8g8b8a8_uint = 41,
    r8g8b8a8_sint = 42,
    r8g8b8a8_srgb = 43,
    b8g8r8a8_unorm = 44,
    b8g8r8a8_snorm = 45,
    b8g8r8a8_uscaled = 46,
    b8g8r8a8_sscaled = 47,
    b8g8r8a8_uint = 48,
    b8g8r8a8_sint = 49,
    b8g8r8a8_srgb = 50,
    a8b8g8r8_unorm_pack32 = 51,
    a8b8g8r8_snorm_pack32 = 52,
    a8b8g8r8_uscaled_pack32 = 53,
    a8b8g8r8_sscaled_pack32 = 54,
    a8b8g8r8_uint_pack32 = 55,
    a8b8g8r8_sint_pack32 = 56,
    a8b8g8r8_srgb_pack32 = 57,
    a2r10g10b10_unorm_pack32 = 58,
    a2r10g10b10_snorm_pack32 = 59,
    a2r10g10b10_uscaled_pack32 = 60,
    a2r10g10b10_sscaled_pack32 = 61,
    a2r10g10b10_uint_pack32 = 62,
    a2r10g10b10_sint_pack32 = 63,
    a2b10g10r10_unorm_pack32 = 64,
    a2b10g10r10_snorm_pack32 = 65,
    a2b10g10r10_uscaled_pack32 = 66,
    a2b10g10r10_sscaled_pack32 = 67,
    a2b10g10r10_uint_pack32 = 68,
    a2b10g10r10_sint_pack32 = 69,
    r16_unorm = 70,
    r16_snorm = 71,
    r16_uscaled = 72,
    r16_sscaled = 73,
    r16_uint = 74,
    r16_sint = 75,
    r16_sfloat = 76,
    r16g16_unorm = 77,
    r16g16_snorm = 78,
    r16g16_uscaled = 79,
    r16g16_sscaled = 80,
    r16g16_uint = 81,
    r16g16_sint = 82,
    r16g16_sfloat = 83,
    r16g16b16_unorm = 84,
    r16g16b16_snorm = 85,
    r16g16b16_uscaled = 86,
    r16g16b16_sscaled = 87,
    r16g16b16_uint = 88,
    r16g16b16_sint = 89,
    r16g16b16_sfloat = 90,
    r16g16b16a16_unorm = 91,
    r16g16b16a16_snorm = 92,
    r16g16b16a16_uscaled = 93,
    r16g16b16a16_sscaled = 94,
    r16g16b16a16_uint = 95,
    r16g16b16a16_sint = 96,
    r16g16b16a16_sfloat = 97,
    r32_uint = 98,
    r32_sint = 99,
    r32_sfloat = 100,
    r32g32_uint = 101,
    r32g32_sint = 102,
    r32g32_sfloat = 103,
    r32g32b32_uint = 104,
    r32g32b32_sint = 105,
    r32g32b32_sfloat = 106,
    r32g32b32a32_uint = 107,
    r32g32b32a32_sint = 108,
    r32g32b32a32_sfloat = 109,
    r64_uint = 110,
    r64_sint = 111,
    r64_sfloat = 112,
    r64g64_uint = 113,
    r64g64_sint = 114,
    r64g64_sfloat = 115,
    r64g64b64_uint = 116,
    r64g64b64_sint = 117,
    r64g64b64_sfloat = 118,
    r64g64b64a64_uint = 119,
    r64g64b64a64_sint = 120,
    r64g64b64a64_sfloat = 121,
    b10g11r11_ufloat_pack32 = 122,
    e5b9g9r9_ufloat_pack32 = 123,
    d16_unorm = 124,
    x8_d24_unorm_pack32 = 125,
    d32_sfloat = 126,
    s8_uint = 127,
    d16_unorm_s8_uint = 128,
    d24_unorm_s8_uint = 129,
    d32_sfloat_s8_uint = 130,
    bc1_rgb_unorm_block = 131,
    bc1_rgb_srgb_block = 132,
    bc1_rgba_unorm_block = 133,
    bc1_rgba_srgb_block = 134,
    bc2_unorm_block = 135,
    bc2_srgb_block = 136,
    bc3_unorm_block = 137,
    bc3_srgb_block = 138,
    bc4_unorm_block = 139,
    bc4_snorm_block = 140,
    bc5_unorm_block = 141,
    bc5_snorm_block = 142,
    bc6h_ufloat_block = 143,
    bc6h_sfloat_block = 144,
    bc7_unorm_block = 145,
    bc7_srgb_block = 146,
    etc2_r8g8b8_unorm_block = 147,
    etc2_r8g8b8_srgb_block = 148,
    etc2_r8g8b8a1_unorm_block = 149,
    etc2_r8g8b8a1_srgb_block = 150,
    etc2_r8g8b8a8_unorm_block = 151,
    etc2_r8g8b8a8_srgb_block = 152,
    eac_r11_unorm_block = 153,
    eac_r11_snorm_block = 154,
    eac_r11g11_unorm_block = 155,
    eac_r11g11_snorm_block = 156,
    astc_4x4_unorm_block = 157,
    astc_4x4_srgb_block = 158,
    astc_5x4_unorm_block = 159,
    astc_5x4_srgb_block = 160,
    astc_5x5_unorm_block = 161,
    astc_5x5_srgb_block = 162,
    astc_6x5_unorm_block = 163,
    astc_6x5_srgb_block = 164,
    astc_6x6_unorm_block = 165,
    astc_6x6_srgb_block = 166,
    astc_8x5_unorm_block = 167,
    astc_8x5_srgb_block = 168,
    astc_8x6_unorm_block = 169,
    astc_8x6_srgb_block = 170,
    astc_8x8_unorm_block = 171,
    astc_8x8_srgb_block = 172,
    astc_10x5_unorm_block = 173,
    astc_10x5_srgb_block = 174,
    astc_10x6_unorm_block = 175,
    astc_10x6_srgb_block = 176,
    astc_10x8_unorm_block = 177,
    astc_10x8_srgb_block = 178,
    astc_10x10_unorm_block = 179,
    astc_10x10_srgb_block = 180,
    astc_12x10_unorm_block = 181,
    astc_12x10_srgb_block = 182,
    astc_12x12_unorm_block = 183,
    astc_12x12_srgb_block = 184,
    g8b8g8r8_422_unorm = 1000156000,
    b8g8r8g8_422_unorm = 1000156001,
    g8_b8_r8_3plane_420_unorm = 1000156002,
    g8_b8r8_2plane_420_unorm = 1000156003,
    g8_b8_r8_3plane_422_unorm = 1000156004,
    g8_b8r8_2plane_422_unorm = 1000156005,
    g8_b8_r8_3plane_444_unorm = 1000156006,
    r10x6_unorm_pack16 = 1000156007,
    r10x6g10x6_unorm_2pack16 = 1000156008,
    r10x6g10x6b10x6a10x6_unorm_4pack16 = 1000156009,
    g10x6b10x6g10x6r10x6_422_unorm_4pack16 = 1000156010,
    b10x6g10x6r10x6g10x6_422_unorm_4pack16 = 1000156011,
    g10x6_b10x6_r10x6_3plane_420_unorm_3pack16 = 1000156012,
    g10x6_b10x6r10x6_2plane_420_unorm_3pack16 = 1000156013,
    g10x6_b10x6_r10x6_3plane_422_unorm_3pack16 = 1000156014,
    g10x6_b10x6r10x6_2plane_422_unorm_3pack16 = 1000156015,
    g10x6_b10x6_r10x6_3plane_444_unorm_3pack16 = 1000156016,
    r12x4_unorm_pack16 = 1000156017,
    r12x4g12x4_unorm_2pack16 = 1000156018,
    r12x4g12x4b12x4a12x4_unorm_4pack16 = 1000156019,
    g12x4b12x4g12x4r12x4_422_unorm_4pack16 = 1000156020,
    b12x4g12x4r12x4g12x4_422_unorm_4pack16 = 1000156021,
    g12x4_b12x4_r12x4_3plane_420_unorm_3pack16 = 1000156022,
    g12x4_b12x4r12x4_2plane_420_unorm_3pack16 = 1000156023,
    g12x4_b12x4_r12x4_3plane_422_unorm_3pack16 = 1000156024,
    g12x4_b12x4r12x4_2plane_422_unorm_3pack16 = 1000156025,
    g12x4_b12x4_r12x4_3plane_444_unorm_3pack16 = 1000156026,
    g16b16g16r16_422_unorm = 1000156027,
    b16g16r16g16_422_unorm = 1000156028,
    g16_b16_r16_3plane_420_unorm = 1000156029,
    g16_b16r16_2plane_420_unorm = 1000156030,
    g16_b16_r16_3plane_422_unorm = 1000156031,
    g16_b16r16_2plane_422_unorm = 1000156032,
    g16_b16_r16_3plane_444_unorm = 1000156033,
    g8_b8r8_2plane_444_unorm = 1000330000,
    g10x6_b10x6r10x6_2plane_444_unorm_3pack16 = 1000330001,
    g12x4_b12x4r12x4_2plane_444_unorm_3pack16 = 1000330002,
    g16_b16r16_2plane_444_unorm = 1000330003,
    a4r4g4b4_unorm_pack16 = 1000340000,
    a4b4g4r4_unorm_pack16 = 1000340001,
    astc_4x4_sfloat_block = 1000066000,
    astc_5x4_sfloat_block = 1000066001,
    astc_5x5_sfloat_block = 1000066002,
    astc_6x5_sfloat_block = 1000066003,
    astc_6x6_sfloat_block = 1000066004,
    astc_8x5_sfloat_block = 1000066005,
    astc_8x6_sfloat_block = 1000066006,
    astc_8x8_sfloat_block = 1000066007,
    astc_10x5_sfloat_block = 1000066008,
    astc_10x6_sfloat_block = 1000066009,
    astc_10x8_sfloat_block = 1000066010,
    astc_10x10_sfloat_block = 1000066011,
    astc_12x10_sfloat_block = 1000066012,
    astc_12x12_sfloat_block = 1000066013,
    a1b5g5r5_unorm_pack16 = 1000470000,
    a8_unorm = 1000470001,
    pvrtc1_2bpp_unorm_block_img = 1000054000,
    pvrtc1_4bpp_unorm_block_img = 1000054001,
    pvrtc2_2bpp_unorm_block_img = 1000054002,
    pvrtc2_4bpp_unorm_block_img = 1000054003,
    pvrtc1_2bpp_srgb_block_img = 1000054004,
    pvrtc1_4bpp_srgb_block_img = 1000054005,
    pvrtc2_2bpp_srgb_block_img = 1000054006,
    pvrtc2_4bpp_srgb_block_img = 1000054007,
    astc_3x3x3_unorm_block_ext = 1000288000,
    astc_3x3x3_srgb_block_ext = 1000288001,
    astc_3x3x3_sfloat_block_ext = 1000288002,
    astc_4x3x3_unorm_block_ext = 1000288003,
    astc_4x3x3_srgb_block_ext = 1000288004,
    astc_4x3x3_sfloat_block_ext = 1000288005,
    astc_4x4x3_unorm_block_ext = 1000288006,
    astc_4x4x3_srgb_block_ext = 1000288007,
    astc_4x4x3_sfloat_block_ext = 1000288008,
    astc_4x4x4_unorm_block_ext = 1000288009,
    astc_4x4x4_srgb_block_ext = 1000288010,
    astc_4x4x4_sfloat_block_ext = 1000288011,
    astc_5x4x4_unorm_block_ext = 1000288012,
    astc_5x4x4_srgb_block_ext = 1000288013,
    astc_5x4x4_sfloat_block_ext = 1000288014,
    astc_5x5x4_unorm_block_ext = 1000288015,
    astc_5x5x4_srgb_block_ext = 1000288016,
    astc_5x5x4_sfloat_block_ext = 1000288017,
    astc_5x5x5_unorm_block_ext = 1000288018,
    astc_5x5x5_srgb_block_ext = 1000288019,
    astc_5x5x5_sfloat_block_ext = 1000288020,
    astc_6x5x5_unorm_block_ext = 1000288021,
    astc_6x5x5_srgb_block_ext = 1000288022,
    astc_6x5x5_sfloat_block_ext = 1000288023,
    astc_6x6x5_unorm_block_ext = 1000288024,
    astc_6x6x5_srgb_block_ext = 1000288025,
    astc_6x6x5_sfloat_block_ext = 1000288026,
    astc_6x6x6_unorm_block_ext = 1000288027,
    astc_6x6x6_srgb_block_ext = 1000288028,
    astc_6x6x6_sfloat_block_ext = 1000288029,
    r8_bool_arm = 1000460000,
    r16g16_sfixed5_nv = 1000464000,
    r10x6_uint_pack16_arm = 1000609000,
    r10x6g10x6_uint_2pack16_arm = 1000609001,
    r10x6g10x6b10x6a10x6_uint_4pack16_arm = 1000609002,
    r12x4_uint_pack16_arm = 1000609003,
    r12x4g12x4_uint_2pack16_arm = 1000609004,
    r12x4g12x4b12x4a12x4_uint_4pack16_arm = 1000609005,
    r14x2_uint_pack16_arm = 1000609006,
    r14x2g14x2_uint_2pack16_arm = 1000609007,
    r14x2g14x2b14x2a14x2_uint_4pack16_arm = 1000609008,
    r14x2_unorm_pack16_arm = 1000609009,
    r14x2g14x2_unorm_2pack16_arm = 1000609010,
    r14x2g14x2b14x2a14x2_unorm_4pack16_arm = 1000609011,
    g14x2_b14x2r14x2_2plane_420_unorm_3pack16_arm = 1000609012,
    g14x2_b14x2r14x2_2plane_422_unorm_3pack16_arm = 1000609013,
    _,
};
pub const Format_astc_4x4_sfloat_block_ext: Format = .astc_4x4_sfloat_block;
pub const Format_astc_5x4_sfloat_block_ext: Format = .astc_5x4_sfloat_block;
pub const Format_astc_5x5_sfloat_block_ext: Format = .astc_5x5_sfloat_block;
pub const Format_astc_6x5_sfloat_block_ext: Format = .astc_6x5_sfloat_block;
pub const Format_astc_6x6_sfloat_block_ext: Format = .astc_6x6_sfloat_block;
pub const Format_astc_8x5_sfloat_block_ext: Format = .astc_8x5_sfloat_block;
pub const Format_astc_8x6_sfloat_block_ext: Format = .astc_8x6_sfloat_block;
pub const Format_astc_8x8_sfloat_block_ext: Format = .astc_8x8_sfloat_block;
pub const Format_astc_10x5_sfloat_block_ext: Format = .astc_10x5_sfloat_block;
pub const Format_astc_10x6_sfloat_block_ext: Format = .astc_10x6_sfloat_block;
pub const Format_astc_10x8_sfloat_block_ext: Format = .astc_10x8_sfloat_block;
pub const Format_astc_10x10_sfloat_block_ext: Format = .astc_10x10_sfloat_block;
pub const Format_astc_12x10_sfloat_block_ext: Format = .astc_12x10_sfloat_block;
pub const Format_astc_12x12_sfloat_block_ext: Format = .astc_12x12_sfloat_block;
pub const Format_g8b8g8r8_422_unorm_khr: Format = .g8b8g8r8_422_unorm;
pub const Format_b8g8r8g8_422_unorm_khr: Format = .b8g8r8g8_422_unorm;
pub const Format_g8_b8_r8_3plane_420_unorm_khr: Format = .g8_b8_r8_3plane_420_unorm;
pub const Format_g8_b8r8_2plane_420_unorm_khr: Format = .g8_b8r8_2plane_420_unorm;
pub const Format_g8_b8_r8_3plane_422_unorm_khr: Format = .g8_b8_r8_3plane_422_unorm;
pub const Format_g8_b8r8_2plane_422_unorm_khr: Format = .g8_b8r8_2plane_422_unorm;
pub const Format_g8_b8_r8_3plane_444_unorm_khr: Format = .g8_b8_r8_3plane_444_unorm;
pub const Format_r10x6_unorm_pack16_khr: Format = .r10x6_unorm_pack16;
pub const Format_r10x6g10x6_unorm_2pack16_khr: Format = .r10x6g10x6_unorm_2pack16;
pub const Format_r10x6g10x6b10x6a10x6_unorm_4pack16_khr: Format = .r10x6g10x6b10x6a10x6_unorm_4pack16;
pub const Format_g10x6b10x6g10x6r10x6_422_unorm_4pack16_khr: Format = .g10x6b10x6g10x6r10x6_422_unorm_4pack16;
pub const Format_b10x6g10x6r10x6g10x6_422_unorm_4pack16_khr: Format = .b10x6g10x6r10x6g10x6_422_unorm_4pack16;
pub const Format_g10x6_b10x6_r10x6_3plane_420_unorm_3pack16_khr: Format = .g10x6_b10x6_r10x6_3plane_420_unorm_3pack16;
pub const Format_g10x6_b10x6r10x6_2plane_420_unorm_3pack16_khr: Format = .g10x6_b10x6r10x6_2plane_420_unorm_3pack16;
pub const Format_g10x6_b10x6_r10x6_3plane_422_unorm_3pack16_khr: Format = .g10x6_b10x6_r10x6_3plane_422_unorm_3pack16;
pub const Format_g10x6_b10x6r10x6_2plane_422_unorm_3pack16_khr: Format = .g10x6_b10x6r10x6_2plane_422_unorm_3pack16;
pub const Format_g10x6_b10x6_r10x6_3plane_444_unorm_3pack16_khr: Format = .g10x6_b10x6_r10x6_3plane_444_unorm_3pack16;
pub const Format_r12x4_unorm_pack16_khr: Format = .r12x4_unorm_pack16;
pub const Format_r12x4g12x4_unorm_2pack16_khr: Format = .r12x4g12x4_unorm_2pack16;
pub const Format_r12x4g12x4b12x4a12x4_unorm_4pack16_khr: Format = .r12x4g12x4b12x4a12x4_unorm_4pack16;
pub const Format_g12x4b12x4g12x4r12x4_422_unorm_4pack16_khr: Format = .g12x4b12x4g12x4r12x4_422_unorm_4pack16;
pub const Format_b12x4g12x4r12x4g12x4_422_unorm_4pack16_khr: Format = .b12x4g12x4r12x4g12x4_422_unorm_4pack16;
pub const Format_g12x4_b12x4_r12x4_3plane_420_unorm_3pack16_khr: Format = .g12x4_b12x4_r12x4_3plane_420_unorm_3pack16;
pub const Format_g12x4_b12x4r12x4_2plane_420_unorm_3pack16_khr: Format = .g12x4_b12x4r12x4_2plane_420_unorm_3pack16;
pub const Format_g12x4_b12x4_r12x4_3plane_422_unorm_3pack16_khr: Format = .g12x4_b12x4_r12x4_3plane_422_unorm_3pack16;
pub const Format_g12x4_b12x4r12x4_2plane_422_unorm_3pack16_khr: Format = .g12x4_b12x4r12x4_2plane_422_unorm_3pack16;
pub const Format_g12x4_b12x4_r12x4_3plane_444_unorm_3pack16_khr: Format = .g12x4_b12x4_r12x4_3plane_444_unorm_3pack16;
pub const Format_g16b16g16r16_422_unorm_khr: Format = .g16b16g16r16_422_unorm;
pub const Format_b16g16r16g16_422_unorm_khr: Format = .b16g16r16g16_422_unorm;
pub const Format_g16_b16_r16_3plane_420_unorm_khr: Format = .g16_b16_r16_3plane_420_unorm;
pub const Format_g16_b16r16_2plane_420_unorm_khr: Format = .g16_b16r16_2plane_420_unorm;
pub const Format_g16_b16_r16_3plane_422_unorm_khr: Format = .g16_b16_r16_3plane_422_unorm;
pub const Format_g16_b16r16_2plane_422_unorm_khr: Format = .g16_b16r16_2plane_422_unorm;
pub const Format_g16_b16_r16_3plane_444_unorm_khr: Format = .g16_b16_r16_3plane_444_unorm;
pub const Format_g8_b8r8_2plane_444_unorm_ext: Format = .g8_b8r8_2plane_444_unorm;
pub const Format_g10x6_b10x6r10x6_2plane_444_unorm_3pack16_ext: Format = .g10x6_b10x6r10x6_2plane_444_unorm_3pack16;
pub const Format_g12x4_b12x4r12x4_2plane_444_unorm_3pack16_ext: Format = .g12x4_b12x4r12x4_2plane_444_unorm_3pack16;
pub const Format_g16_b16r16_2plane_444_unorm_ext: Format = .g16_b16r16_2plane_444_unorm;
pub const Format_a4r4g4b4_unorm_pack16_ext: Format = .a4r4g4b4_unorm_pack16;
pub const Format_a4b4g4r4_unorm_pack16_ext: Format = .a4b4g4r4_unorm_pack16;
pub const Format_r16g16_s10_5_nv: Format = .r16g16_sfixed5_nv;
pub const Format_a1b5g5r5_unorm_pack16_khr: Format = .a1b5g5r5_unorm_pack16;
pub const Format_a8_unorm_khr: Format = .a8_unorm;

pub const StructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    device_queue_create_info = 2,
    device_create_info = 3,
    submit_info = 4,
    memory_allocate_info = 5,
    mapped_memory_range = 6,
    bind_sparse_info = 7,
    fence_create_info = 8,
    semaphore_create_info = 9,
    event_create_info = 10,
    query_pool_create_info = 11,
    buffer_create_info = 12,
    buffer_view_create_info = 13,
    image_create_info = 14,
    image_view_create_info = 15,
    shader_module_create_info = 16,
    pipeline_cache_create_info = 17,
    pipeline_shader_stage_create_info = 18,
    pipeline_vertex_input_state_create_info = 19,
    pipeline_input_assembly_state_create_info = 20,
    pipeline_tessellation_state_create_info = 21,
    pipeline_viewport_state_create_info = 22,
    pipeline_rasterization_state_create_info = 23,
    pipeline_multisample_state_create_info = 24,
    pipeline_depth_stencil_state_create_info = 25,
    pipeline_color_blend_state_create_info = 26,
    pipeline_dynamic_state_create_info = 27,
    graphics_pipeline_create_info = 28,
    compute_pipeline_create_info = 29,
    pipeline_layout_create_info = 30,
    sampler_create_info = 31,
    descriptor_set_layout_create_info = 32,
    descriptor_pool_create_info = 33,
    descriptor_set_allocate_info = 34,
    write_descriptor_set = 35,
    copy_descriptor_set = 36,
    framebuffer_create_info = 37,
    render_pass_create_info = 38,
    command_pool_create_info = 39,
    command_buffer_allocate_info = 40,
    command_buffer_inheritance_info = 41,
    command_buffer_begin_info = 42,
    render_pass_begin_info = 43,
    buffer_memory_barrier = 44,
    image_memory_barrier = 45,
    memory_barrier = 46,
    loader_instance_create_info = 47,
    loader_device_create_info = 48,
    bind_buffer_memory_info = 1000157000,
    bind_image_memory_info = 1000157001,
    memory_dedicated_requirements = 1000127000,
    memory_dedicated_allocate_info = 1000127001,
    memory_allocate_flags_info = 1000060000,
    device_group_command_buffer_begin_info = 1000060004,
    device_group_submit_info = 1000060005,
    device_group_bind_sparse_info = 1000060006,
    bind_buffer_memory_device_group_info = 1000060013,
    bind_image_memory_device_group_info = 1000060014,
    physical_device_group_properties = 1000070000,
    device_group_device_create_info = 1000070001,
    buffer_memory_requirements_info_2 = 1000146000,
    image_memory_requirements_info_2 = 1000146001,
    image_sparse_memory_requirements_info_2 = 1000146002,
    memory_requirements_2 = 1000146003,
    sparse_image_memory_requirements_2 = 1000146004,
    physical_device_features_2 = 1000059000,
    physical_device_properties_2 = 1000059001,
    format_properties_2 = 1000059002,
    image_format_properties_2 = 1000059003,
    physical_device_image_format_info_2 = 1000059004,
    queue_family_properties_2 = 1000059005,
    physical_device_memory_properties_2 = 1000059006,
    sparse_image_format_properties_2 = 1000059007,
    physical_device_sparse_image_format_info_2 = 1000059008,
    image_view_usage_create_info = 1000117002,
    protected_submit_info = 1000145000,
    physical_device_protected_memory_features = 1000145001,
    physical_device_protected_memory_properties = 1000145002,
    device_queue_info_2 = 1000145003,
    physical_device_external_image_format_info = 1000071000,
    external_image_format_properties = 1000071001,
    physical_device_external_buffer_info = 1000071002,
    external_buffer_properties = 1000071003,
    physical_device_id_properties = 1000071004,
    external_memory_buffer_create_info = 1000072000,
    external_memory_image_create_info = 1000072001,
    export_memory_allocate_info = 1000072002,
    physical_device_external_fence_info = 1000112000,
    external_fence_properties = 1000112001,
    export_fence_create_info = 1000113000,
    export_semaphore_create_info = 1000077000,
    physical_device_external_semaphore_info = 1000076000,
    external_semaphore_properties = 1000076001,
    physical_device_subgroup_properties = 1000094000,
    physical_device_16bit_storage_features = 1000083000,
    physical_device_variable_pointers_features = 1000120000,
    descriptor_update_template_create_info = 1000085000,
    physical_device_maintenance_3_properties = 1000168000,
    descriptor_set_layout_support = 1000168001,
    sampler_ycbcr_conversion_create_info = 1000156000,
    sampler_ycbcr_conversion_info = 1000156001,
    bind_image_plane_memory_info = 1000156002,
    image_plane_memory_requirements_info = 1000156003,
    physical_device_sampler_ycbcr_conversion_features = 1000156004,
    sampler_ycbcr_conversion_image_format_properties = 1000156005,
    device_group_render_pass_begin_info = 1000060003,
    physical_device_point_clipping_properties = 1000117000,
    render_pass_input_attachment_aspect_create_info = 1000117001,
    pipeline_tessellation_domain_origin_state_create_info = 1000117003,
    render_pass_multiview_create_info = 1000053000,
    physical_device_multiview_features = 1000053001,
    physical_device_multiview_properties = 1000053002,
    physical_device_shader_draw_parameters_features = 1000063000,
    physical_device_vulkan_1_1_features = 49,
    physical_device_vulkan_1_1_properties = 50,
    physical_device_vulkan_1_2_features = 51,
    physical_device_vulkan_1_2_properties = 52,
    image_format_list_create_info = 1000147000,
    physical_device_driver_properties = 1000196000,
    physical_device_vulkan_memory_model_features = 1000211000,
    physical_device_host_query_reset_features = 1000261000,
    physical_device_timeline_semaphore_features = 1000207000,
    physical_device_timeline_semaphore_properties = 1000207001,
    semaphore_type_create_info = 1000207002,
    timeline_semaphore_submit_info = 1000207003,
    semaphore_wait_info = 1000207004,
    semaphore_signal_info = 1000207005,
    physical_device_buffer_device_address_features = 1000257000,
    buffer_device_address_info = 1000244001,
    buffer_opaque_capture_address_create_info = 1000257002,
    memory_opaque_capture_address_allocate_info = 1000257003,
    device_memory_opaque_capture_address_info = 1000257004,
    physical_device_8bit_storage_features = 1000177000,
    physical_device_shader_atomic_int64_features = 1000180000,
    physical_device_shader_float16_int8_features = 1000082000,
    physical_device_float_controls_properties = 1000197000,
    descriptor_set_layout_binding_flags_create_info = 1000161000,
    physical_device_descriptor_indexing_features = 1000161001,
    physical_device_descriptor_indexing_properties = 1000161002,
    descriptor_set_variable_descriptor_count_allocate_info = 1000161003,
    descriptor_set_variable_descriptor_count_layout_support = 1000161004,
    physical_device_scalar_block_layout_features = 1000221000,
    physical_device_sampler_filter_minmax_properties = 1000130000,
    sampler_reduction_mode_create_info = 1000130001,
    physical_device_uniform_buffer_standard_layout_features = 1000253000,
    physical_device_shader_subgroup_extended_types_features = 1000175000,
    attachment_description_2 = 1000109000,
    attachment_reference_2 = 1000109001,
    subpass_description_2 = 1000109002,
    subpass_dependency_2 = 1000109003,
    render_pass_create_info_2 = 1000109004,
    subpass_begin_info = 1000109005,
    subpass_end_info = 1000109006,
    physical_device_depth_stencil_resolve_properties = 1000199000,
    subpass_description_depth_stencil_resolve = 1000199001,
    image_stencil_usage_create_info = 1000246000,
    physical_device_imageless_framebuffer_features = 1000108000,
    framebuffer_attachments_create_info = 1000108001,
    framebuffer_attachment_image_info = 1000108002,
    render_pass_attachment_begin_info = 1000108003,
    physical_device_separate_depth_stencil_layouts_features = 1000241000,
    attachment_reference_stencil_layout = 1000241001,
    attachment_description_stencil_layout = 1000241002,
    physical_device_vulkan_1_3_features = 53,
    physical_device_vulkan_1_3_properties = 54,
    physical_device_tool_properties = 1000245000,
    physical_device_private_data_features = 1000295000,
    device_private_data_create_info = 1000295001,
    private_data_slot_create_info = 1000295002,
    memory_barrier_2 = 1000314000,
    buffer_memory_barrier_2 = 1000314001,
    image_memory_barrier_2 = 1000314002,
    dependency_info = 1000314003,
    submit_info_2 = 1000314004,
    semaphore_submit_info = 1000314005,
    command_buffer_submit_info = 1000314006,
    physical_device_synchronization_2_features = 1000314007,
    copy_buffer_info_2 = 1000337000,
    copy_image_info_2 = 1000337001,
    copy_buffer_to_image_info_2 = 1000337002,
    copy_image_to_buffer_info_2 = 1000337003,
    buffer_copy_2 = 1000337006,
    image_copy_2 = 1000337007,
    buffer_image_copy_2 = 1000337009,
    physical_device_texture_compression_astc_hdr_features = 1000066000,
    format_properties_3 = 1000360000,
    physical_device_maintenance_4_features = 1000413000,
    physical_device_maintenance_4_properties = 1000413001,
    device_buffer_memory_requirements = 1000413002,
    device_image_memory_requirements = 1000413003,
    pipeline_creation_feedback_create_info = 1000192000,
    physical_device_shader_terminate_invocation_features = 1000215000,
    physical_device_shader_demote_to_helper_invocation_features = 1000276000,
    physical_device_pipeline_creation_cache_control_features = 1000297000,
    physical_device_zero_initialize_workgroup_memory_features = 1000325000,
    physical_device_image_robustness_features = 1000335000,
    physical_device_subgroup_size_control_properties = 1000225000,
    pipeline_shader_stage_required_subgroup_size_create_info = 1000225001,
    physical_device_subgroup_size_control_features = 1000225002,
    physical_device_inline_uniform_block_features = 1000138000,
    physical_device_inline_uniform_block_properties = 1000138001,
    write_descriptor_set_inline_uniform_block = 1000138002,
    descriptor_pool_inline_uniform_block_create_info = 1000138003,
    physical_device_shader_integer_dot_product_features = 1000280000,
    physical_device_shader_integer_dot_product_properties = 1000280001,
    physical_device_texel_buffer_alignment_properties = 1000281001,
    blit_image_info_2 = 1000337004,
    resolve_image_info_2 = 1000337005,
    image_blit_2 = 1000337008,
    image_resolve_2 = 1000337010,
    rendering_info = 1000044000,
    rendering_attachment_info = 1000044001,
    pipeline_rendering_create_info = 1000044002,
    physical_device_dynamic_rendering_features = 1000044003,
    command_buffer_inheritance_rendering_info = 1000044004,
    physical_device_vulkan_1_4_features = 55,
    physical_device_vulkan_1_4_properties = 56,
    device_queue_global_priority_create_info = 1000174000,
    physical_device_global_priority_query_features = 1000388000,
    queue_family_global_priority_properties = 1000388001,
    physical_device_index_type_uint8_features = 1000265000,
    memory_map_info = 1000271000,
    memory_unmap_info = 1000271001,
    physical_device_maintenance_5_features = 1000470000,
    physical_device_maintenance_5_properties = 1000470001,
    device_image_subresource_info = 1000470004,
    subresource_layout_2 = 1000338002,
    image_subresource_2 = 1000338003,
    buffer_usage_flags_2_create_info = 1000470006,
    physical_device_maintenance_6_features = 1000545000,
    physical_device_maintenance_6_properties = 1000545001,
    bind_memory_status = 1000545002,
    physical_device_host_image_copy_features = 1000270000,
    physical_device_host_image_copy_properties = 1000270001,
    memory_to_image_copy = 1000270002,
    image_to_memory_copy = 1000270003,
    copy_image_to_memory_info = 1000270004,
    copy_memory_to_image_info = 1000270005,
    host_image_layout_transition_info = 1000270006,
    copy_image_to_image_info = 1000270007,
    subresource_host_memcpy_size = 1000270008,
    host_image_copy_device_performance_query = 1000270009,
    physical_device_shader_subgroup_rotate_features = 1000416000,
    physical_device_shader_float_controls_2_features = 1000528000,
    physical_device_shader_expect_assume_features = 1000544000,
    pipeline_create_flags_2_create_info = 1000470005,
    physical_device_push_descriptor_properties = 1000080000,
    bind_descriptor_sets_info = 1000545003,
    push_constants_info = 1000545004,
    push_descriptor_set_info = 1000545005,
    push_descriptor_set_with_template_info = 1000545006,
    physical_device_pipeline_protected_access_features = 1000466000,
    pipeline_robustness_create_info = 1000068000,
    physical_device_pipeline_robustness_features = 1000068001,
    physical_device_pipeline_robustness_properties = 1000068002,
    physical_device_line_rasterization_features = 1000259000,
    pipeline_rasterization_line_state_create_info = 1000259001,
    physical_device_line_rasterization_properties = 1000259002,
    physical_device_vertex_attribute_divisor_properties = 1000525000,
    pipeline_vertex_input_divisor_state_create_info = 1000190001,
    physical_device_vertex_attribute_divisor_features = 1000190002,
    rendering_area_info = 1000470003,
    physical_device_dynamic_rendering_local_read_features = 1000232000,
    rendering_attachment_location_info = 1000232001,
    rendering_input_attachment_index_info = 1000232002,
    physical_device_vulkan_sc_1_0_features = 1000298000,
    physical_device_vulkan_sc_1_0_properties = 1000298001,
    device_object_reservation_create_info = 1000298002,
    command_pool_memory_reservation_create_info = 1000298003,
    command_pool_memory_consumption = 1000298004,
    pipeline_pool_size = 1000298005,
    fault_data = 1000298007,
    fault_callback_info = 1000298008,
    pipeline_offline_create_info = 1000298010,
    swapchain_create_info_khr = 1000001000,
    present_info_khr = 1000001001,
    device_group_present_capabilities_khr = 1000060007,
    image_swapchain_create_info_khr = 1000060008,
    bind_image_memory_swapchain_info_khr = 1000060009,
    acquire_next_image_info_khr = 1000060010,
    device_group_present_info_khr = 1000060011,
    device_group_swapchain_create_info_khr = 1000060012,
    display_mode_create_info_khr = 1000002000,
    display_surface_create_info_khr = 1000002001,
    display_present_info_khr = 1000003000,
    xlib_surface_create_info_khr = 1000004000,
    xcb_surface_create_info_khr = 1000005000,
    wayland_surface_create_info_khr = 1000006000,
    android_surface_create_info_khr = 1000008000,
    win32_surface_create_info_khr = 1000009000,
    native_buffer_android = 1000010000,
    swapchain_image_create_info_android = 1000010001,
    physical_device_presentation_properties_android = 1000010002,
    debug_report_callback_create_info_ext = 1000011000,
    pipeline_rasterization_state_rasterization_order_amd = 1000018000,
    debug_marker_object_name_info_ext = 1000022000,
    debug_marker_object_tag_info_ext = 1000022001,
    debug_marker_marker_info_ext = 1000022002,
    video_profile_info_khr = 1000023000,
    video_capabilities_khr = 1000023001,
    video_picture_resource_info_khr = 1000023002,
    video_session_memory_requirements_khr = 1000023003,
    bind_video_session_memory_info_khr = 1000023004,
    video_session_create_info_khr = 1000023005,
    video_session_parameters_create_info_khr = 1000023006,
    video_session_parameters_update_info_khr = 1000023007,
    video_begin_coding_info_khr = 1000023008,
    video_end_coding_info_khr = 1000023009,
    video_coding_control_info_khr = 1000023010,
    video_reference_slot_info_khr = 1000023011,
    queue_family_video_properties_khr = 1000023012,
    video_profile_list_info_khr = 1000023013,
    physical_device_video_format_info_khr = 1000023014,
    video_format_properties_khr = 1000023015,
    queue_family_query_result_status_properties_khr = 1000023016,
    video_decode_info_khr = 1000024000,
    video_decode_capabilities_khr = 1000024001,
    video_decode_usage_info_khr = 1000024002,
    dedicated_allocation_image_create_info_nv = 1000026000,
    dedicated_allocation_buffer_create_info_nv = 1000026001,
    dedicated_allocation_memory_allocate_info_nv = 1000026002,
    physical_device_transform_feedback_features_ext = 1000028000,
    physical_device_transform_feedback_properties_ext = 1000028001,
    pipeline_rasterization_state_stream_create_info_ext = 1000028002,
    cu_module_create_info_nvx = 1000029000,
    cu_function_create_info_nvx = 1000029001,
    cu_launch_info_nvx = 1000029002,
    cu_module_texturing_mode_create_info_nvx = 1000029004,
    image_view_handle_info_nvx = 1000030000,
    image_view_address_properties_nvx = 1000030001,
    video_encode_h264_capabilities_khr = 1000038000,
    video_encode_h264_session_parameters_create_info_khr = 1000038001,
    video_encode_h264_session_parameters_add_info_khr = 1000038002,
    video_encode_h264_picture_info_khr = 1000038003,
    video_encode_h264_dpb_slot_info_khr = 1000038004,
    video_encode_h264_nalu_slice_info_khr = 1000038005,
    video_encode_h264_gop_remaining_frame_info_khr = 1000038006,
    video_encode_h264_profile_info_khr = 1000038007,
    video_encode_h264_rate_control_info_khr = 1000038008,
    video_encode_h264_rate_control_layer_info_khr = 1000038009,
    video_encode_h264_session_create_info_khr = 1000038010,
    video_encode_h264_quality_level_properties_khr = 1000038011,
    video_encode_h264_session_parameters_get_info_khr = 1000038012,
    video_encode_h264_session_parameters_feedback_info_khr = 1000038013,
    video_encode_h265_capabilities_khr = 1000039000,
    video_encode_h265_session_parameters_create_info_khr = 1000039001,
    video_encode_h265_session_parameters_add_info_khr = 1000039002,
    video_encode_h265_picture_info_khr = 1000039003,
    video_encode_h265_dpb_slot_info_khr = 1000039004,
    video_encode_h265_nalu_slice_segment_info_khr = 1000039005,
    video_encode_h265_gop_remaining_frame_info_khr = 1000039006,
    video_encode_h265_profile_info_khr = 1000039007,
    video_encode_h265_rate_control_info_khr = 1000039009,
    video_encode_h265_rate_control_layer_info_khr = 1000039010,
    video_encode_h265_session_create_info_khr = 1000039011,
    video_encode_h265_quality_level_properties_khr = 1000039012,
    video_encode_h265_session_parameters_get_info_khr = 1000039013,
    video_encode_h265_session_parameters_feedback_info_khr = 1000039014,
    video_decode_h264_capabilities_khr = 1000040000,
    video_decode_h264_picture_info_khr = 1000040001,
    video_decode_h264_profile_info_khr = 1000040003,
    video_decode_h264_session_parameters_create_info_khr = 1000040004,
    video_decode_h264_session_parameters_add_info_khr = 1000040005,
    video_decode_h264_dpb_slot_info_khr = 1000040006,
    texture_lod_gather_format_properties_amd = 1000041000,
    stream_descriptor_surface_create_info_ggp = 1000049000,
    physical_device_corner_sampled_image_features_nv = 1000050000,
    private_vendor_info_placeholder_offset_0_nv = 1000051000,
    external_memory_image_create_info_nv = 1000056000,
    export_memory_allocate_info_nv = 1000056001,
    import_memory_win32_handle_info_nv = 1000057000,
    export_memory_win32_handle_info_nv = 1000057001,
    win32_keyed_mutex_acquire_release_info_nv = 1000058000,
    validation_flags_ext = 1000061000,
    vi_surface_create_info_nn = 1000062000,
    image_view_astc_decode_mode_ext = 1000067000,
    physical_device_astc_decode_features_ext = 1000067001,
    import_memory_win32_handle_info_khr = 1000073000,
    export_memory_win32_handle_info_khr = 1000073001,
    memory_win32_handle_properties_khr = 1000073002,
    memory_get_win32_handle_info_khr = 1000073003,
    import_memory_fd_info_khr = 1000074000,
    memory_fd_properties_khr = 1000074001,
    memory_get_fd_info_khr = 1000074002,
    win32_keyed_mutex_acquire_release_info_khr = 1000075000,
    import_semaphore_win32_handle_info_khr = 1000078000,
    export_semaphore_win32_handle_info_khr = 1000078001,
    d3d12_fence_submit_info_khr = 1000078002,
    semaphore_get_win32_handle_info_khr = 1000078003,
    import_semaphore_fd_info_khr = 1000079000,
    semaphore_get_fd_info_khr = 1000079001,
    command_buffer_inheritance_conditional_rendering_info_ext = 1000081000,
    physical_device_conditional_rendering_features_ext = 1000081001,
    conditional_rendering_begin_info_ext = 1000081002,
    present_regions_khr = 1000084000,
    pipeline_viewport_w_scaling_state_create_info_nv = 1000087000,
    surface_capabilities_2_ext = 1000090000,
    display_power_info_ext = 1000091000,
    device_event_info_ext = 1000091001,
    display_event_info_ext = 1000091002,
    swapchain_counter_create_info_ext = 1000091003,
    present_times_info_google = 1000092000,
    physical_device_multiview_per_view_attributes_properties_nvx = 1000097000,
    multiview_per_view_attributes_info_nvx = 1000044009,
    pipeline_viewport_swizzle_state_create_info_nv = 1000098000,
    physical_device_discard_rectangle_properties_ext = 1000099000,
    pipeline_discard_rectangle_state_create_info_ext = 1000099001,
    physical_device_conservative_rasterization_properties_ext = 1000101000,
    pipeline_rasterization_conservative_state_create_info_ext = 1000101001,
    physical_device_depth_clip_enable_features_ext = 1000102000,
    pipeline_rasterization_depth_clip_state_create_info_ext = 1000102001,
    hdr_metadata_ext = 1000105000,
    physical_device_relaxed_line_rasterization_features_img = 1000110000,
    shared_present_surface_capabilities_khr = 1000111000,
    import_fence_win32_handle_info_khr = 1000114000,
    export_fence_win32_handle_info_khr = 1000114001,
    fence_get_win32_handle_info_khr = 1000114002,
    import_fence_fd_info_khr = 1000115000,
    fence_get_fd_info_khr = 1000115001,
    physical_device_performance_query_features_khr = 1000116000,
    physical_device_performance_query_properties_khr = 1000116001,
    query_pool_performance_create_info_khr = 1000116002,
    performance_query_submit_info_khr = 1000116003,
    acquire_profiling_lock_info_khr = 1000116004,
    performance_counter_khr = 1000116005,
    performance_counter_description_khr = 1000116006,
    performance_query_reservation_info_khr = 1000116007,
    physical_device_surface_info_2_khr = 1000119000,
    surface_capabilities_2_khr = 1000119001,
    surface_format_2_khr = 1000119002,
    display_properties_2_khr = 1000121000,
    display_plane_properties_2_khr = 1000121001,
    display_mode_properties_2_khr = 1000121002,
    display_plane_info_2_khr = 1000121003,
    display_plane_capabilities_2_khr = 1000121004,
    ios_surface_create_info_mvk = 1000122000,
    macos_surface_create_info_mvk = 1000123000,
    debug_utils_object_name_info_ext = 1000128000,
    debug_utils_object_tag_info_ext = 1000128001,
    debug_utils_label_ext = 1000128002,
    debug_utils_messenger_callback_data_ext = 1000128003,
    debug_utils_messenger_create_info_ext = 1000128004,
    android_hardware_buffer_usage_android = 1000129000,
    android_hardware_buffer_properties_android = 1000129001,
    android_hardware_buffer_format_properties_android = 1000129002,
    import_android_hardware_buffer_info_android = 1000129003,
    memory_get_android_hardware_buffer_info_android = 1000129004,
    external_format_android = 1000129005,
    android_hardware_buffer_format_properties_2_android = 1000129006,
    physical_device_shader_enqueue_features_amdx = 1000134000,
    physical_device_shader_enqueue_properties_amdx = 1000134001,
    execution_graph_pipeline_scratch_size_amdx = 1000134002,
    execution_graph_pipeline_create_info_amdx = 1000134003,
    pipeline_shader_stage_node_create_info_amdx = 1000134004,
    texel_buffer_descriptor_info_ext = 1000135000,
    image_descriptor_info_ext = 1000135001,
    resource_descriptor_info_ext = 1000135002,
    bind_heap_info_ext = 1000135003,
    push_data_info_ext = 1000135004,
    descriptor_set_and_binding_mapping_ext = 1000135005,
    shader_descriptor_set_and_binding_mapping_info_ext = 1000135006,
    opaque_capture_data_create_info_ext = 1000135007,
    physical_device_descriptor_heap_properties_ext = 1000135008,
    physical_device_descriptor_heap_features_ext = 1000135009,
    command_buffer_inheritance_descriptor_heap_info_ext = 1000135010,
    sampler_custom_border_color_index_create_info_ext = 1000135011,
    indirect_commands_layout_push_data_token_nv = 1000135012,
    subsampled_image_format_properties_ext = 1000135013,
    physical_device_descriptor_heap_tensor_properties_arm = 1000135014,
    attachment_sample_count_info_amd = 1000044008,
    physical_device_shader_bfloat16_features_khr = 1000141000,
    sample_locations_info_ext = 1000143000,
    render_pass_sample_locations_begin_info_ext = 1000143001,
    pipeline_sample_locations_state_create_info_ext = 1000143002,
    physical_device_sample_locations_properties_ext = 1000143003,
    multisample_properties_ext = 1000143004,
    physical_device_blend_operation_advanced_features_ext = 1000148000,
    physical_device_blend_operation_advanced_properties_ext = 1000148001,
    pipeline_color_blend_advanced_state_create_info_ext = 1000148002,
    pipeline_coverage_to_color_state_create_info_nv = 1000149000,
    write_descriptor_set_acceleration_structure_khr = 1000150007,
    acceleration_structure_build_geometry_info_khr = 1000150000,
    acceleration_structure_device_address_info_khr = 1000150002,
    acceleration_structure_geometry_aabbs_data_khr = 1000150003,
    acceleration_structure_geometry_instances_data_khr = 1000150004,
    acceleration_structure_geometry_triangles_data_khr = 1000150005,
    acceleration_structure_geometry_khr = 1000150006,
    acceleration_structure_version_info_khr = 1000150009,
    copy_acceleration_structure_info_khr = 1000150010,
    copy_acceleration_structure_to_memory_info_khr = 1000150011,
    copy_memory_to_acceleration_structure_info_khr = 1000150012,
    physical_device_acceleration_structure_features_khr = 1000150013,
    physical_device_acceleration_structure_properties_khr = 1000150014,
    acceleration_structure_create_info_khr = 1000150017,
    acceleration_structure_build_sizes_info_khr = 1000150020,
    physical_device_ray_tracing_pipeline_features_khr = 1000347000,
    physical_device_ray_tracing_pipeline_properties_khr = 1000347001,
    ray_tracing_pipeline_create_info_khr = 1000150015,
    ray_tracing_shader_group_create_info_khr = 1000150016,
    ray_tracing_pipeline_interface_create_info_khr = 1000150018,
    physical_device_ray_query_features_khr = 1000348013,
    pipeline_coverage_modulation_state_create_info_nv = 1000152000,
    physical_device_shader_sm_builtins_features_nv = 1000154000,
    physical_device_shader_sm_builtins_properties_nv = 1000154001,
    drm_format_modifier_properties_list_ext = 1000158000,
    physical_device_image_drm_format_modifier_info_ext = 1000158002,
    image_drm_format_modifier_list_create_info_ext = 1000158003,
    image_drm_format_modifier_explicit_create_info_ext = 1000158004,
    image_drm_format_modifier_properties_ext = 1000158005,
    drm_format_modifier_properties_list_2_ext = 1000158006,
    validation_cache_create_info_ext = 1000160000,
    shader_module_validation_cache_create_info_ext = 1000160001,
    physical_device_portability_subset_features_khr = 1000163000,
    physical_device_portability_subset_properties_khr = 1000163001,
    pipeline_viewport_shading_rate_image_state_create_info_nv = 1000164000,
    physical_device_shading_rate_image_features_nv = 1000164001,
    physical_device_shading_rate_image_properties_nv = 1000164002,
    pipeline_viewport_coarse_sample_order_state_create_info_nv = 1000164005,
    ray_tracing_pipeline_create_info_nv = 1000165000,
    acceleration_structure_create_info_nv = 1000165001,
    geometry_nv = 1000165003,
    geometry_triangles_nv = 1000165004,
    geometry_aabb_nv = 1000165005,
    bind_acceleration_structure_memory_info_nv = 1000165006,
    write_descriptor_set_acceleration_structure_nv = 1000165007,
    acceleration_structure_memory_requirements_info_nv = 1000165008,
    physical_device_ray_tracing_properties_nv = 1000165009,
    ray_tracing_shader_group_create_info_nv = 1000165011,
    acceleration_structure_info_nv = 1000165012,
    physical_device_representative_fragment_test_features_nv = 1000166000,
    pipeline_representative_fragment_test_state_create_info_nv = 1000166001,
    physical_device_image_view_image_format_info_ext = 1000170000,
    filter_cubic_image_view_image_format_properties_ext = 1000170001,
    import_memory_host_pointer_info_ext = 1000178000,
    memory_host_pointer_properties_ext = 1000178001,
    physical_device_external_memory_host_properties_ext = 1000178002,
    physical_device_shader_clock_features_khr = 1000181000,
    pipeline_compiler_control_create_info_amd = 1000183000,
    physical_device_shader_core_properties_amd = 1000185000,
    video_decode_h265_capabilities_khr = 1000187000,
    video_decode_h265_session_parameters_create_info_khr = 1000187001,
    video_decode_h265_session_parameters_add_info_khr = 1000187002,
    video_decode_h265_profile_info_khr = 1000187003,
    video_decode_h265_picture_info_khr = 1000187004,
    video_decode_h265_dpb_slot_info_khr = 1000187005,
    device_memory_overallocation_create_info_amd = 1000189000,
    physical_device_vertex_attribute_divisor_properties_ext = 1000190000,
    present_frame_token_ggp = 1000191000,
    physical_device_mesh_shader_features_nv = 1000202000,
    physical_device_mesh_shader_properties_nv = 1000202001,
    physical_device_shader_image_footprint_features_nv = 1000204000,
    pipeline_viewport_exclusive_scissor_state_create_info_nv = 1000205000,
    physical_device_exclusive_scissor_features_nv = 1000205002,
    checkpoint_data_nv = 1000206000,
    queue_family_checkpoint_properties_nv = 1000206001,
    queue_family_checkpoint_properties_2_nv = 1000314008,
    checkpoint_data_2_nv = 1000314009,
    physical_device_present_timing_features_ext = 1000208000,
    swapchain_timing_properties_ext = 1000208001,
    swapchain_time_domain_properties_ext = 1000208002,
    present_timings_info_ext = 1000208003,
    present_timing_info_ext = 1000208004,
    past_presentation_timing_info_ext = 1000208005,
    past_presentation_timing_properties_ext = 1000208006,
    past_presentation_timing_ext = 1000208007,
    present_timing_surface_capabilities_ext = 1000208008,
    swapchain_calibrated_timestamp_info_ext = 1000208009,
    physical_device_shader_integer_functions_2_features_intel = 1000209000,
    query_pool_performance_query_create_info_intel = 1000210000,
    initialize_performance_api_info_intel = 1000210001,
    performance_marker_info_intel = 1000210002,
    performance_stream_marker_info_intel = 1000210003,
    performance_override_info_intel = 1000210004,
    performance_configuration_acquire_info_intel = 1000210005,
    physical_device_pci_bus_info_properties_ext = 1000212000,
    display_native_hdr_surface_capabilities_amd = 1000213000,
    swapchain_display_native_hdr_create_info_amd = 1000213001,
    imagepipe_surface_create_info_fuchsia = 1000214000,
    metal_surface_create_info_ext = 1000217000,
    physical_device_fragment_density_map_features_ext = 1000218000,
    physical_device_fragment_density_map_properties_ext = 1000218001,
    render_pass_fragment_density_map_create_info_ext = 1000218002,
    rendering_fragment_density_map_attachment_info_ext = 1000044007,
    fragment_shading_rate_attachment_info_khr = 1000226000,
    pipeline_fragment_shading_rate_state_create_info_khr = 1000226001,
    physical_device_fragment_shading_rate_properties_khr = 1000226002,
    physical_device_fragment_shading_rate_features_khr = 1000226003,
    physical_device_fragment_shading_rate_khr = 1000226004,
    rendering_fragment_shading_rate_attachment_info_khr = 1000044006,
    physical_device_shader_core_properties_2_amd = 1000227000,
    physical_device_coherent_memory_features_amd = 1000229000,
    physical_device_shader_image_atomic_int64_features_ext = 1000234000,
    physical_device_shader_quad_control_features_khr = 1000235000,
    physical_device_memory_budget_properties_ext = 1000237000,
    physical_device_memory_priority_features_ext = 1000238000,
    memory_priority_allocate_info_ext = 1000238001,
    surface_protected_capabilities_khr = 1000239000,
    physical_device_dedicated_allocation_image_aliasing_features_nv = 1000240000,
    physical_device_buffer_device_address_features_ext = 1000244000,
    buffer_device_address_create_info_ext = 1000244002,
    validation_features_ext = 1000247000,
    physical_device_present_wait_features_khr = 1000248000,
    physical_device_cooperative_matrix_features_nv = 1000249000,
    cooperative_matrix_properties_nv = 1000249001,
    physical_device_cooperative_matrix_properties_nv = 1000249002,
    physical_device_coverage_reduction_mode_features_nv = 1000250000,
    pipeline_coverage_reduction_state_create_info_nv = 1000250001,
    framebuffer_mixed_samples_combination_nv = 1000250002,
    physical_device_fragment_shader_interlock_features_ext = 1000251000,
    physical_device_ycbcr_image_arrays_features_ext = 1000252000,
    physical_device_provoking_vertex_features_ext = 1000254000,
    pipeline_rasterization_provoking_vertex_state_create_info_ext = 1000254001,
    physical_device_provoking_vertex_properties_ext = 1000254002,
    surface_full_screen_exclusive_info_ext = 1000255000,
    surface_capabilities_full_screen_exclusive_ext = 1000255002,
    surface_full_screen_exclusive_win32_info_ext = 1000255001,
    headless_surface_create_info_ext = 1000256000,
    physical_device_shader_atomic_float_features_ext = 1000260000,
    physical_device_extended_dynamic_state_features_ext = 1000267000,
    physical_device_pipeline_executable_properties_features_khr = 1000269000,
    pipeline_info_khr = 1000269001,
    pipeline_executable_properties_khr = 1000269002,
    pipeline_executable_info_khr = 1000269003,
    pipeline_executable_statistic_khr = 1000269004,
    pipeline_executable_internal_representation_khr = 1000269005,
    physical_device_map_memory_placed_features_ext = 1000272000,
    physical_device_map_memory_placed_properties_ext = 1000272001,
    memory_map_placed_info_ext = 1000272002,
    physical_device_shader_atomic_float_2_features_ext = 1000273000,
    physical_device_device_generated_commands_properties_nv = 1000277000,
    graphics_shader_group_create_info_nv = 1000277001,
    graphics_pipeline_shader_groups_create_info_nv = 1000277002,
    indirect_commands_layout_token_nv = 1000277003,
    indirect_commands_layout_create_info_nv = 1000277004,
    generated_commands_info_nv = 1000277005,
    generated_commands_memory_requirements_info_nv = 1000277006,
    physical_device_device_generated_commands_features_nv = 1000277007,
    physical_device_inherited_viewport_scissor_features_nv = 1000278000,
    command_buffer_inheritance_viewport_scissor_info_nv = 1000278001,
    physical_device_texel_buffer_alignment_features_ext = 1000281000,
    command_buffer_inheritance_render_pass_transform_info_qcom = 1000282000,
    render_pass_transform_begin_info_qcom = 1000282001,
    physical_device_depth_bias_control_features_ext = 1000283000,
    depth_bias_info_ext = 1000283001,
    depth_bias_representation_info_ext = 1000283002,
    physical_device_device_memory_report_features_ext = 1000284000,
    device_device_memory_report_create_info_ext = 1000284001,
    device_memory_report_callback_data_ext = 1000284002,
    sampler_custom_border_color_create_info_ext = 1000287000,
    physical_device_custom_border_color_properties_ext = 1000287001,
    physical_device_custom_border_color_features_ext = 1000287002,
    physical_device_texture_compression_astc_3d_features_ext = 1000288000,
    pipeline_library_create_info_khr = 1000290000,
    physical_device_present_barrier_features_nv = 1000292000,
    surface_capabilities_present_barrier_nv = 1000292001,
    swapchain_present_barrier_create_info_nv = 1000292002,
    present_id_khr = 1000294000,
    physical_device_present_id_features_khr = 1000294001,
    video_encode_info_khr = 1000299000,
    video_encode_rate_control_info_khr = 1000299001,
    video_encode_rate_control_layer_info_khr = 1000299002,
    video_encode_capabilities_khr = 1000299003,
    video_encode_usage_info_khr = 1000299004,
    query_pool_video_encode_feedback_create_info_khr = 1000299005,
    physical_device_video_encode_quality_level_info_khr = 1000299006,
    video_encode_quality_level_properties_khr = 1000299007,
    video_encode_quality_level_info_khr = 1000299008,
    video_encode_session_parameters_get_info_khr = 1000299009,
    video_encode_session_parameters_feedback_info_khr = 1000299010,
    physical_device_diagnostics_config_features_nv = 1000300000,
    device_diagnostics_config_create_info_nv = 1000300001,
    cuda_module_create_info_nv = 1000307000,
    cuda_function_create_info_nv = 1000307001,
    cuda_launch_info_nv = 1000307002,
    physical_device_cuda_kernel_launch_features_nv = 1000307003,
    physical_device_cuda_kernel_launch_properties_nv = 1000307004,
    refresh_object_list_khr = 1000308000,
    physical_device_tile_shading_features_qcom = 1000309000,
    physical_device_tile_shading_properties_qcom = 1000309001,
    render_pass_tile_shading_create_info_qcom = 1000309002,
    per_tile_begin_info_qcom = 1000309003,
    per_tile_end_info_qcom = 1000309004,
    dispatch_tile_info_qcom = 1000309005,
    query_low_latency_support_nv = 1000310000,
    export_metal_object_create_info_ext = 1000311000,
    export_metal_objects_info_ext = 1000311001,
    export_metal_device_info_ext = 1000311002,
    export_metal_command_queue_info_ext = 1000311003,
    export_metal_buffer_info_ext = 1000311004,
    import_metal_buffer_info_ext = 1000311005,
    export_metal_texture_info_ext = 1000311006,
    import_metal_texture_info_ext = 1000311007,
    export_metal_io_surface_info_ext = 1000311008,
    import_metal_io_surface_info_ext = 1000311009,
    export_metal_shared_event_info_ext = 1000311010,
    import_metal_shared_event_info_ext = 1000311011,
    physical_device_descriptor_buffer_properties_ext = 1000316000,
    physical_device_descriptor_buffer_density_map_properties_ext = 1000316001,
    physical_device_descriptor_buffer_features_ext = 1000316002,
    descriptor_address_info_ext = 1000316003,
    descriptor_get_info_ext = 1000316004,
    buffer_capture_descriptor_data_info_ext = 1000316005,
    image_capture_descriptor_data_info_ext = 1000316006,
    image_view_capture_descriptor_data_info_ext = 1000316007,
    sampler_capture_descriptor_data_info_ext = 1000316008,
    opaque_capture_descriptor_data_create_info_ext = 1000316010,
    descriptor_buffer_binding_info_ext = 1000316011,
    descriptor_buffer_binding_push_descriptor_buffer_handle_ext = 1000316012,
    acceleration_structure_capture_descriptor_data_info_ext = 1000316009,
    physical_device_graphics_pipeline_library_features_ext = 1000320000,
    physical_device_graphics_pipeline_library_properties_ext = 1000320001,
    graphics_pipeline_library_create_info_ext = 1000320002,
    physical_device_shader_early_and_late_fragment_tests_features_amd = 1000321000,
    physical_device_fragment_shader_barycentric_features_khr = 1000203000,
    physical_device_fragment_shader_barycentric_properties_khr = 1000322000,
    physical_device_shader_subgroup_uniform_control_flow_features_khr = 1000323000,
    physical_device_fragment_shading_rate_enums_properties_nv = 1000326000,
    physical_device_fragment_shading_rate_enums_features_nv = 1000326001,
    pipeline_fragment_shading_rate_enum_state_create_info_nv = 1000326002,
    acceleration_structure_geometry_motion_triangles_data_nv = 1000327000,
    physical_device_ray_tracing_motion_blur_features_nv = 1000327001,
    acceleration_structure_motion_info_nv = 1000327002,
    physical_device_mesh_shader_features_ext = 1000328000,
    physical_device_mesh_shader_properties_ext = 1000328001,
    physical_device_ycbcr_2_plane_444_formats_features_ext = 1000330000,
    physical_device_fragment_density_map_2_features_ext = 1000332000,
    physical_device_fragment_density_map_2_properties_ext = 1000332001,
    copy_command_transform_info_qcom = 1000333000,
    physical_device_workgroup_memory_explicit_layout_features_khr = 1000336000,
    physical_device_image_compression_control_features_ext = 1000338000,
    image_compression_control_ext = 1000338001,
    image_compression_properties_ext = 1000338004,
    physical_device_attachment_feedback_loop_layout_features_ext = 1000339000,
    physical_device_4444_formats_features_ext = 1000340000,
    physical_device_fault_features_ext = 1000341000,
    device_fault_counts_ext = 1000341001,
    device_fault_info_ext = 1000341002,
    physical_device_rgba10x6_formats_features_ext = 1000344000,
    directfb_surface_create_info_ext = 1000346000,
    physical_device_vertex_input_dynamic_state_features_ext = 1000352000,
    vertex_input_binding_description_2_ext = 1000352001,
    vertex_input_attribute_description_2_ext = 1000352002,
    physical_device_drm_properties_ext = 1000353000,
    physical_device_address_binding_report_features_ext = 1000354000,
    device_address_binding_callback_data_ext = 1000354001,
    physical_device_depth_clip_control_features_ext = 1000355000,
    pipeline_viewport_depth_clip_control_create_info_ext = 1000355001,
    physical_device_primitive_topology_list_restart_features_ext = 1000356000,
    import_memory_zircon_handle_info_fuchsia = 1000364000,
    memory_zircon_handle_properties_fuchsia = 1000364001,
    memory_get_zircon_handle_info_fuchsia = 1000364002,
    import_semaphore_zircon_handle_info_fuchsia = 1000365000,
    semaphore_get_zircon_handle_info_fuchsia = 1000365001,
    buffer_collection_create_info_fuchsia = 1000366000,
    import_memory_buffer_collection_fuchsia = 1000366001,
    buffer_collection_image_create_info_fuchsia = 1000366002,
    buffer_collection_properties_fuchsia = 1000366003,
    buffer_constraints_info_fuchsia = 1000366004,
    buffer_collection_buffer_create_info_fuchsia = 1000366005,
    image_constraints_info_fuchsia = 1000366006,
    image_format_constraints_info_fuchsia = 1000366007,
    sysmem_color_space_fuchsia = 1000366008,
    buffer_collection_constraints_info_fuchsia = 1000366009,
    subpass_shading_pipeline_create_info_huawei = 1000369000,
    physical_device_subpass_shading_features_huawei = 1000369001,
    physical_device_subpass_shading_properties_huawei = 1000369002,
    physical_device_invocation_mask_features_huawei = 1000370000,
    memory_get_remote_address_info_nv = 1000371000,
    physical_device_external_memory_rdma_features_nv = 1000371001,
    pipeline_properties_identifier_ext = 1000372000,
    physical_device_pipeline_properties_features_ext = 1000372001,
    import_fence_sci_sync_info_nv = 1000373000,
    export_fence_sci_sync_info_nv = 1000373001,
    fence_get_sci_sync_info_nv = 1000373002,
    sci_sync_attributes_info_nv = 1000373003,
    import_semaphore_sci_sync_info_nv = 1000373004,
    export_semaphore_sci_sync_info_nv = 1000373005,
    semaphore_get_sci_sync_info_nv = 1000373006,
    physical_device_external_sci_sync_features_nv = 1000373007,
    import_memory_sci_buf_info_nv = 1000374000,
    export_memory_sci_buf_info_nv = 1000374001,
    memory_get_sci_buf_info_nv = 1000374002,
    memory_sci_buf_properties_nv = 1000374003,
    physical_device_external_memory_sci_buf_features_nv = 1000374004,
    physical_device_frame_boundary_features_ext = 1000375000,
    frame_boundary_ext = 1000375001,
    physical_device_multisampled_render_to_single_sampled_features_ext = 1000376000,
    subpass_resolve_performance_query_ext = 1000376001,
    multisampled_render_to_single_sampled_info_ext = 1000376002,
    physical_device_extended_dynamic_state_2_features_ext = 1000377000,
    screen_surface_create_info_qnx = 1000378000,
    physical_device_color_write_enable_features_ext = 1000381000,
    pipeline_color_write_create_info_ext = 1000381001,
    physical_device_primitives_generated_query_features_ext = 1000382000,
    physical_device_ray_tracing_maintenance_1_features_khr = 1000386000,
    physical_device_shader_untyped_pointers_features_khr = 1000387000,
    physical_device_video_encode_rgb_conversion_features_valve = 1000390000,
    video_encode_rgb_conversion_capabilities_valve = 1000390001,
    video_encode_profile_rgb_conversion_info_valve = 1000390002,
    video_encode_session_rgb_conversion_create_info_valve = 1000390003,
    physical_device_image_view_min_lod_features_ext = 1000391000,
    image_view_min_lod_create_info_ext = 1000391001,
    physical_device_multi_draw_features_ext = 1000392000,
    physical_device_multi_draw_properties_ext = 1000392001,
    physical_device_image_2d_view_of_3d_features_ext = 1000393000,
    physical_device_shader_tile_image_features_ext = 1000395000,
    physical_device_shader_tile_image_properties_ext = 1000395001,
    micromap_build_info_ext = 1000396000,
    micromap_version_info_ext = 1000396001,
    copy_micromap_info_ext = 1000396002,
    copy_micromap_to_memory_info_ext = 1000396003,
    copy_memory_to_micromap_info_ext = 1000396004,
    physical_device_opacity_micromap_features_ext = 1000396005,
    physical_device_opacity_micromap_properties_ext = 1000396006,
    micromap_create_info_ext = 1000396007,
    micromap_build_sizes_info_ext = 1000396008,
    acceleration_structure_triangles_opacity_micromap_ext = 1000396009,
    physical_device_displacement_micromap_features_nv = 1000397000,
    physical_device_displacement_micromap_properties_nv = 1000397001,
    acceleration_structure_triangles_displacement_micromap_nv = 1000397002,
    physical_device_cluster_culling_shader_features_huawei = 1000404000,
    physical_device_cluster_culling_shader_properties_huawei = 1000404001,
    physical_device_cluster_culling_shader_vrs_features_huawei = 1000404002,
    physical_device_border_color_swizzle_features_ext = 1000411000,
    sampler_border_color_component_mapping_create_info_ext = 1000411001,
    physical_device_pageable_device_local_memory_features_ext = 1000412000,
    physical_device_shader_core_properties_arm = 1000415000,
    device_queue_shader_core_control_create_info_arm = 1000417000,
    physical_device_scheduling_controls_features_arm = 1000417001,
    physical_device_scheduling_controls_properties_arm = 1000417002,
    physical_device_image_sliced_view_of_3d_features_ext = 1000418000,
    image_view_sliced_create_info_ext = 1000418001,
    physical_device_descriptor_set_host_mapping_features_valve = 1000420000,
    descriptor_set_binding_reference_valve = 1000420001,
    descriptor_set_layout_host_mapping_info_valve = 1000420002,
    physical_device_non_seamless_cube_map_features_ext = 1000422000,
    physical_device_render_pass_striped_features_arm = 1000424000,
    physical_device_render_pass_striped_properties_arm = 1000424001,
    render_pass_stripe_begin_info_arm = 1000424002,
    render_pass_stripe_info_arm = 1000424003,
    render_pass_stripe_submit_info_arm = 1000424004,
    physical_device_copy_memory_indirect_features_nv = 1000426000,
    physical_device_device_generated_commands_compute_features_nv = 1000428000,
    compute_pipeline_indirect_buffer_info_nv = 1000428001,
    pipeline_indirect_device_address_info_nv = 1000428002,
    physical_device_ray_tracing_linear_swept_spheres_features_nv = 1000429008,
    acceleration_structure_geometry_linear_swept_spheres_data_nv = 1000429009,
    acceleration_structure_geometry_spheres_data_nv = 1000429010,
    physical_device_linear_color_attachment_features_nv = 1000430000,
    physical_device_shader_maximal_reconvergence_features_khr = 1000434000,
    application_parameters_ext = 1000435000,
    physical_device_image_compression_control_swapchain_features_ext = 1000437000,
    physical_device_image_processing_features_qcom = 1000440000,
    physical_device_image_processing_properties_qcom = 1000440001,
    image_view_sample_weight_create_info_qcom = 1000440002,
    physical_device_nested_command_buffer_features_ext = 1000451000,
    physical_device_nested_command_buffer_properties_ext = 1000451001,
    native_buffer_usage_ohos = 1000452000,
    native_buffer_properties_ohos = 1000452001,
    native_buffer_format_properties_ohos = 1000452002,
    import_native_buffer_info_ohos = 1000452003,
    memory_get_native_buffer_info_ohos = 1000452004,
    external_format_ohos = 1000452005,
    external_memory_acquire_unmodified_ext = 1000453000,
    physical_device_extended_dynamic_state_3_features_ext = 1000455000,
    physical_device_extended_dynamic_state_3_properties_ext = 1000455001,
    physical_device_subpass_merge_feedback_features_ext = 1000458000,
    render_pass_creation_control_ext = 1000458001,
    render_pass_creation_feedback_create_info_ext = 1000458002,
    render_pass_subpass_feedback_create_info_ext = 1000458003,
    direct_driver_loading_info_lunarg = 1000459000,
    direct_driver_loading_list_lunarg = 1000459001,
    tensor_create_info_arm = 1000460000,
    tensor_view_create_info_arm = 1000460001,
    bind_tensor_memory_info_arm = 1000460002,
    write_descriptor_set_tensor_arm = 1000460003,
    physical_device_tensor_properties_arm = 1000460004,
    tensor_format_properties_arm = 1000460005,
    tensor_description_arm = 1000460006,
    tensor_memory_requirements_info_arm = 1000460007,
    tensor_memory_barrier_arm = 1000460008,
    physical_device_tensor_features_arm = 1000460009,
    device_tensor_memory_requirements_arm = 1000460010,
    copy_tensor_info_arm = 1000460011,
    tensor_copy_arm = 1000460012,
    tensor_dependency_info_arm = 1000460013,
    memory_dedicated_allocate_info_tensor_arm = 1000460014,
    physical_device_external_tensor_info_arm = 1000460015,
    external_tensor_properties_arm = 1000460016,
    external_memory_tensor_create_info_arm = 1000460017,
    physical_device_descriptor_buffer_tensor_features_arm = 1000460018,
    physical_device_descriptor_buffer_tensor_properties_arm = 1000460019,
    descriptor_get_tensor_info_arm = 1000460020,
    tensor_capture_descriptor_data_info_arm = 1000460021,
    tensor_view_capture_descriptor_data_info_arm = 1000460022,
    frame_boundary_tensors_arm = 1000460023,
    physical_device_shader_module_identifier_features_ext = 1000462000,
    physical_device_shader_module_identifier_properties_ext = 1000462001,
    pipeline_shader_stage_module_identifier_create_info_ext = 1000462002,
    shader_module_identifier_ext = 1000462003,
    physical_device_rasterization_order_attachment_access_features_ext = 1000342000,
    physical_device_optical_flow_features_nv = 1000464000,
    physical_device_optical_flow_properties_nv = 1000464001,
    optical_flow_image_format_info_nv = 1000464002,
    optical_flow_image_format_properties_nv = 1000464003,
    optical_flow_session_create_info_nv = 1000464004,
    optical_flow_execute_info_nv = 1000464005,
    optical_flow_session_create_private_data_info_nv = 1000464010,
    physical_device_legacy_dithering_features_ext = 1000465000,
    physical_device_external_format_resolve_features_android = 1000468000,
    physical_device_external_format_resolve_properties_android = 1000468001,
    android_hardware_buffer_format_resolve_properties_android = 1000468002,
    physical_device_anti_lag_features_amd = 1000476000,
    anti_lag_data_amd = 1000476001,
    anti_lag_presentation_info_amd = 1000476002,
    physical_device_dense_geometry_format_features_amdx = 1000478000,
    acceleration_structure_dense_geometry_format_triangles_data_amdx = 1000478001,
    surface_capabilities_present_id_2_khr = 1000479000,
    present_id_2_khr = 1000479001,
    physical_device_present_id_2_features_khr = 1000479002,
    surface_capabilities_present_wait_2_khr = 1000480000,
    physical_device_present_wait_2_features_khr = 1000480001,
    present_wait_2_info_khr = 1000480002,
    physical_device_ray_tracing_position_fetch_features_khr = 1000481000,
    physical_device_shader_object_features_ext = 1000482000,
    physical_device_shader_object_properties_ext = 1000482001,
    shader_create_info_ext = 1000482002,
    physical_device_pipeline_binary_features_khr = 1000483000,
    pipeline_binary_create_info_khr = 1000483001,
    pipeline_binary_info_khr = 1000483002,
    pipeline_binary_key_khr = 1000483003,
    physical_device_pipeline_binary_properties_khr = 1000483004,
    release_captured_pipeline_data_info_khr = 1000483005,
    pipeline_binary_data_info_khr = 1000483006,
    pipeline_create_info_khr = 1000483007,
    device_pipeline_binary_internal_cache_control_khr = 1000483008,
    pipeline_binary_handles_info_khr = 1000483009,
    physical_device_tile_properties_features_qcom = 1000484000,
    tile_properties_qcom = 1000484001,
    physical_device_amigo_profiling_features_sec = 1000485000,
    amigo_profiling_submit_info_sec = 1000485001,
    surface_present_mode_khr = 1000274000,
    surface_present_scaling_capabilities_khr = 1000274001,
    surface_present_mode_compatibility_khr = 1000274002,
    physical_device_swapchain_maintenance_1_features_khr = 1000275000,
    swapchain_present_fence_info_khr = 1000275001,
    swapchain_present_modes_create_info_khr = 1000275002,
    swapchain_present_mode_info_khr = 1000275003,
    swapchain_present_scaling_create_info_khr = 1000275004,
    release_swapchain_images_info_khr = 1000275005,
    physical_device_multiview_per_view_viewports_features_qcom = 1000488000,
    semaphore_sci_sync_pool_create_info_nv = 1000489000,
    semaphore_sci_sync_create_info_nv = 1000489001,
    physical_device_external_sci_sync_2_features_nv = 1000489002,
    device_semaphore_sci_sync_pool_reservation_create_info_nv = 1000489003,
    physical_device_ray_tracing_invocation_reorder_features_nv = 1000490000,
    physical_device_ray_tracing_invocation_reorder_properties_nv = 1000490001,
    physical_device_cooperative_vector_features_nv = 1000491000,
    physical_device_cooperative_vector_properties_nv = 1000491001,
    cooperative_vector_properties_nv = 1000491002,
    convert_cooperative_vector_matrix_info_nv = 1000491004,
    physical_device_extended_sparse_address_space_features_nv = 1000492000,
    physical_device_extended_sparse_address_space_properties_nv = 1000492001,
    physical_device_mutable_descriptor_type_features_ext = 1000351000,
    mutable_descriptor_type_create_info_ext = 1000351002,
    physical_device_legacy_vertex_attributes_features_ext = 1000495000,
    physical_device_legacy_vertex_attributes_properties_ext = 1000495001,
    layer_settings_create_info_ext = 1000496000,
    physical_device_shader_core_builtins_features_arm = 1000497000,
    physical_device_shader_core_builtins_properties_arm = 1000497001,
    physical_device_pipeline_library_group_handles_features_ext = 1000498000,
    physical_device_dynamic_rendering_unused_attachments_features_ext = 1000499000,
    physical_device_internally_synchronized_queues_features_khr = 1000504000,
    latency_sleep_mode_info_nv = 1000505000,
    latency_sleep_info_nv = 1000505001,
    set_latency_marker_info_nv = 1000505002,
    get_latency_marker_info_nv = 1000505003,
    latency_timings_frame_report_nv = 1000505004,
    latency_submission_present_id_nv = 1000505005,
    out_of_band_queue_type_info_nv = 1000505006,
    swapchain_latency_create_info_nv = 1000505007,
    latency_surface_capabilities_nv = 1000505008,
    physical_device_cooperative_matrix_features_khr = 1000506000,
    cooperative_matrix_properties_khr = 1000506001,
    physical_device_cooperative_matrix_properties_khr = 1000506002,
    data_graph_pipeline_create_info_arm = 1000507000,
    data_graph_pipeline_session_create_info_arm = 1000507001,
    data_graph_pipeline_resource_info_arm = 1000507002,
    data_graph_pipeline_constant_arm = 1000507003,
    data_graph_pipeline_session_memory_requirements_info_arm = 1000507004,
    bind_data_graph_pipeline_session_memory_info_arm = 1000507005,
    physical_device_data_graph_features_arm = 1000507006,
    data_graph_pipeline_shader_module_create_info_arm = 1000507007,
    data_graph_pipeline_property_query_result_arm = 1000507008,
    data_graph_pipeline_info_arm = 1000507009,
    data_graph_pipeline_compiler_control_create_info_arm = 1000507010,
    data_graph_pipeline_session_bind_point_requirements_info_arm = 1000507011,
    data_graph_pipeline_session_bind_point_requirement_arm = 1000507012,
    data_graph_pipeline_identifier_create_info_arm = 1000507013,
    data_graph_pipeline_dispatch_info_arm = 1000507014,
    data_graph_processing_engine_create_info_arm = 1000507016,
    queue_family_data_graph_processing_engine_properties_arm = 1000507017,
    queue_family_data_graph_properties_arm = 1000507018,
    physical_device_queue_family_data_graph_processing_engine_info_arm = 1000507019,
    data_graph_pipeline_constant_tensor_semi_structured_sparsity_info_arm = 1000507015,
    physical_device_multiview_per_view_render_areas_features_qcom = 1000510000,
    multiview_per_view_render_areas_render_pass_begin_info_qcom = 1000510001,
    physical_device_compute_shader_derivatives_features_khr = 1000201000,
    physical_device_compute_shader_derivatives_properties_khr = 1000511000,
    video_decode_av1_capabilities_khr = 1000512000,
    video_decode_av1_picture_info_khr = 1000512001,
    video_decode_av1_profile_info_khr = 1000512003,
    video_decode_av1_session_parameters_create_info_khr = 1000512004,
    video_decode_av1_dpb_slot_info_khr = 1000512005,
    video_encode_av1_capabilities_khr = 1000513000,
    video_encode_av1_session_parameters_create_info_khr = 1000513001,
    video_encode_av1_picture_info_khr = 1000513002,
    video_encode_av1_dpb_slot_info_khr = 1000513003,
    physical_device_video_encode_av1_features_khr = 1000513004,
    video_encode_av1_profile_info_khr = 1000513005,
    video_encode_av1_rate_control_info_khr = 1000513006,
    video_encode_av1_rate_control_layer_info_khr = 1000513007,
    video_encode_av1_quality_level_properties_khr = 1000513008,
    video_encode_av1_session_create_info_khr = 1000513009,
    video_encode_av1_gop_remaining_frame_info_khr = 1000513010,
    physical_device_video_decode_vp9_features_khr = 1000514000,
    video_decode_vp9_capabilities_khr = 1000514001,
    video_decode_vp9_picture_info_khr = 1000514002,
    video_decode_vp9_profile_info_khr = 1000514003,
    physical_device_video_maintenance_1_features_khr = 1000515000,
    video_inline_query_info_khr = 1000515001,
    physical_device_per_stage_descriptor_set_features_nv = 1000516000,
    physical_device_image_processing_2_features_qcom = 1000518000,
    physical_device_image_processing_2_properties_qcom = 1000518001,
    sampler_block_match_window_create_info_qcom = 1000518002,
    sampler_cubic_weights_create_info_qcom = 1000519000,
    physical_device_cubic_weights_features_qcom = 1000519001,
    blit_image_cubic_weights_info_qcom = 1000519002,
    physical_device_ycbcr_degamma_features_qcom = 1000520000,
    sampler_ycbcr_conversion_ycbcr_degamma_create_info_qcom = 1000520001,
    physical_device_cubic_clamp_features_qcom = 1000521000,
    physical_device_attachment_feedback_loop_dynamic_state_features_ext = 1000524000,
    physical_device_unified_image_layouts_features_khr = 1000527000,
    attachment_feedback_loop_info_ext = 1000527001,
    screen_buffer_properties_qnx = 1000529000,
    screen_buffer_format_properties_qnx = 1000529001,
    import_screen_buffer_info_qnx = 1000529002,
    external_format_qnx = 1000529003,
    physical_device_external_memory_screen_buffer_features_qnx = 1000529004,
    physical_device_layered_driver_properties_msft = 1000530000,
    calibrated_timestamp_info_khr = 1000184000,
    set_descriptor_buffer_offsets_info_ext = 1000545007,
    bind_descriptor_buffer_embedded_samplers_info_ext = 1000545008,
    physical_device_descriptor_pool_overallocation_features_nv = 1000546000,
    physical_device_tile_memory_heap_features_qcom = 1000547000,
    physical_device_tile_memory_heap_properties_qcom = 1000547001,
    tile_memory_requirements_qcom = 1000547002,
    tile_memory_bind_info_qcom = 1000547003,
    tile_memory_size_info_qcom = 1000547004,
    physical_device_copy_memory_indirect_features_khr = 1000549000,
    physical_device_copy_memory_indirect_properties_khr = 1000426001,
    copy_memory_indirect_info_khr = 1000549002,
    copy_memory_to_image_indirect_info_khr = 1000549003,
    physical_device_memory_decompression_features_ext = 1000427000,
    physical_device_memory_decompression_properties_ext = 1000427001,
    decompress_memory_info_ext = 1000550002,
    display_surface_stereo_create_info_nv = 1000551000,
    display_mode_stereo_properties_nv = 1000551001,
    video_encode_intra_refresh_capabilities_khr = 1000552000,
    video_encode_session_intra_refresh_create_info_khr = 1000552001,
    video_encode_intra_refresh_info_khr = 1000552002,
    video_reference_intra_refresh_info_khr = 1000552003,
    physical_device_video_encode_intra_refresh_features_khr = 1000552004,
    video_encode_quantization_map_capabilities_khr = 1000553000,
    video_format_quantization_map_properties_khr = 1000553001,
    video_encode_quantization_map_info_khr = 1000553002,
    video_encode_quantization_map_session_parameters_create_info_khr = 1000553005,
    physical_device_video_encode_quantization_map_features_khr = 1000553009,
    video_encode_h264_quantization_map_capabilities_khr = 1000553003,
    video_encode_h265_quantization_map_capabilities_khr = 1000553004,
    video_format_h265_quantization_map_properties_khr = 1000553006,
    video_encode_av1_quantization_map_capabilities_khr = 1000553007,
    video_format_av1_quantization_map_properties_khr = 1000553008,
    physical_device_raw_access_chains_features_nv = 1000555000,
    external_compute_queue_device_create_info_nv = 1000556000,
    external_compute_queue_create_info_nv = 1000556001,
    external_compute_queue_data_params_nv = 1000556002,
    physical_device_external_compute_queue_properties_nv = 1000556003,
    physical_device_shader_relaxed_extended_instruction_features_khr = 1000558000,
    physical_device_command_buffer_inheritance_features_nv = 1000559000,
    physical_device_maintenance_7_features_khr = 1000562000,
    physical_device_maintenance_7_properties_khr = 1000562001,
    physical_device_layered_api_properties_list_khr = 1000562002,
    physical_device_layered_api_properties_khr = 1000562003,
    physical_device_layered_api_vulkan_properties_khr = 1000562004,
    physical_device_shader_atomic_float16_vector_features_nv = 1000563000,
    physical_device_shader_replicated_composites_features_ext = 1000564000,
    physical_device_shader_float8_features_ext = 1000567000,
    physical_device_ray_tracing_validation_features_nv = 1000568000,
    physical_device_cluster_acceleration_structure_features_nv = 1000569000,
    physical_device_cluster_acceleration_structure_properties_nv = 1000569001,
    cluster_acceleration_structure_clusters_bottom_level_input_nv = 1000569002,
    cluster_acceleration_structure_triangle_cluster_input_nv = 1000569003,
    cluster_acceleration_structure_move_objects_input_nv = 1000569004,
    cluster_acceleration_structure_input_info_nv = 1000569005,
    cluster_acceleration_structure_commands_info_nv = 1000569006,
    ray_tracing_pipeline_cluster_acceleration_structure_create_info_nv = 1000569007,
    physical_device_partitioned_acceleration_structure_features_nv = 1000570000,
    physical_device_partitioned_acceleration_structure_properties_nv = 1000570001,
    write_descriptor_set_partitioned_acceleration_structure_nv = 1000570002,
    partitioned_acceleration_structure_instances_input_nv = 1000570003,
    build_partitioned_acceleration_structure_info_nv = 1000570004,
    partitioned_acceleration_structure_flags_nv = 1000570005,
    physical_device_device_generated_commands_features_ext = 1000572000,
    physical_device_device_generated_commands_properties_ext = 1000572001,
    generated_commands_memory_requirements_info_ext = 1000572002,
    indirect_execution_set_create_info_ext = 1000572003,
    generated_commands_info_ext = 1000572004,
    indirect_commands_layout_create_info_ext = 1000572006,
    indirect_commands_layout_token_ext = 1000572007,
    write_indirect_execution_set_pipeline_ext = 1000572008,
    write_indirect_execution_set_shader_ext = 1000572009,
    indirect_execution_set_pipeline_info_ext = 1000572010,
    indirect_execution_set_shader_info_ext = 1000572011,
    indirect_execution_set_shader_layout_info_ext = 1000572012,
    generated_commands_pipeline_info_ext = 1000572013,
    generated_commands_shader_info_ext = 1000572014,
    physical_device_maintenance_8_features_khr = 1000574000,
    memory_barrier_access_flags_3_khr = 1000574002,
    physical_device_image_alignment_control_features_mesa = 1000575000,
    physical_device_image_alignment_control_properties_mesa = 1000575001,
    image_alignment_control_create_info_mesa = 1000575002,
    physical_device_shader_fma_features_khr = 1000579000,
    push_constant_bank_info_nv = 1000580000,
    physical_device_push_constant_bank_features_nv = 1000580001,
    physical_device_push_constant_bank_properties_nv = 1000580002,
    physical_device_ray_tracing_invocation_reorder_features_ext = 1000581000,
    physical_device_ray_tracing_invocation_reorder_properties_ext = 1000581001,
    physical_device_depth_clamp_control_features_ext = 1000582000,
    pipeline_viewport_depth_clamp_control_create_info_ext = 1000582001,
    physical_device_maintenance_9_features_khr = 1000584000,
    physical_device_maintenance_9_properties_khr = 1000584001,
    queue_family_ownership_transfer_properties_khr = 1000584002,
    physical_device_video_maintenance_2_features_khr = 1000586000,
    video_decode_h264_inline_session_parameters_info_khr = 1000586001,
    video_decode_h265_inline_session_parameters_info_khr = 1000586002,
    video_decode_av1_inline_session_parameters_info_khr = 1000586003,
    surface_create_info_ohos = 1000685000,
    native_buffer_ohos = 1000453001,
    swapchain_image_create_info_ohos = 1000453002,
    physical_device_presentation_properties_ohos = 1000453003,
    physical_device_hdr_vivid_features_huawei = 1000590000,
    hdr_vivid_dynamic_metadata_huawei = 1000590001,
    physical_device_cooperative_matrix_2_features_nv = 1000593000,
    cooperative_matrix_flexible_dimensions_properties_nv = 1000593001,
    physical_device_cooperative_matrix_2_properties_nv = 1000593002,
    physical_device_pipeline_opacity_micromap_features_arm = 1000596000,
    import_memory_metal_handle_info_ext = 1000602000,
    memory_metal_handle_properties_ext = 1000602001,
    memory_get_metal_handle_info_ext = 1000602002,
    physical_device_depth_clamp_zero_one_features_khr = 1000421000,
    physical_device_performance_counters_by_region_features_arm = 1000605000,
    physical_device_performance_counters_by_region_properties_arm = 1000605001,
    performance_counter_arm = 1000605002,
    performance_counter_description_arm = 1000605003,
    render_pass_performance_counters_by_region_begin_info_arm = 1000605004,
    physical_device_vertex_attribute_robustness_features_ext = 1000608000,
    physical_device_format_pack_features_arm = 1000609000,
    physical_device_fragment_density_map_layered_features_valve = 1000611000,
    physical_device_fragment_density_map_layered_properties_valve = 1000611001,
    pipeline_fragment_density_map_layered_create_info_valve = 1000611002,
    physical_device_robustness_2_features_khr = 1000286000,
    physical_device_robustness_2_properties_khr = 1000286001,
    set_present_config_nv = 1000613000,
    physical_device_present_metering_features_nv = 1000613001,
    physical_device_fragment_density_map_offset_features_ext = 1000425000,
    physical_device_fragment_density_map_offset_properties_ext = 1000425001,
    render_pass_fragment_density_map_offset_end_info_ext = 1000425002,
    physical_device_zero_initialize_device_memory_features_ext = 1000620000,
    physical_device_present_mode_fifo_latest_ready_features_khr = 1000361000,
    physical_device_shader_64_bit_indexing_features_ext = 1000627000,
    physical_device_custom_resolve_features_ext = 1000628000,
    begin_custom_resolve_info_ext = 1000628001,
    custom_resolve_create_info_ext = 1000628002,
    physical_device_data_graph_model_features_qcom = 1000629000,
    data_graph_pipeline_builtin_model_create_info_qcom = 1000629001,
    physical_device_maintenance_10_features_khr = 1000630000,
    physical_device_maintenance_10_properties_khr = 1000630001,
    rendering_attachment_flags_info_khr = 1000630002,
    rendering_end_info_khr = 1000619003,
    resolve_image_mode_info_khr = 1000630004,
    physical_device_shader_long_vector_features_ext = 1000635000,
    physical_device_shader_long_vector_properties_ext = 1000635001,
    physical_device_pipeline_cache_incremental_mode_features_sec = 1000637000,
    physical_device_shader_uniform_buffer_unsized_array_features_ext = 1000642000,
    compute_occupancy_priority_parameters_nv = 1000645000,
    physical_device_compute_occupancy_priority_features_nv = 1000645001,
    physical_device_shader_subgroup_partitioned_features_ext = 1000662000,
    _,
};
pub const StructureType_physical_device_variable_pointer_features: StructureType = .physical_device_variable_pointers_features;
pub const StructureType_physical_device_shader_draw_parameter_features: StructureType = .physical_device_shader_draw_parameters_features;
pub const StructureType_debug_report_create_info_ext: StructureType = .debug_report_callback_create_info_ext;
pub const StructureType_rendering_info_khr: StructureType = .rendering_info;
pub const StructureType_rendering_attachment_info_khr: StructureType = .rendering_attachment_info;
pub const StructureType_pipeline_rendering_create_info_khr: StructureType = .pipeline_rendering_create_info;
pub const StructureType_physical_device_dynamic_rendering_features_khr: StructureType = .physical_device_dynamic_rendering_features;
pub const StructureType_command_buffer_inheritance_rendering_info_khr: StructureType = .command_buffer_inheritance_rendering_info;
pub const StructureType_render_pass_multiview_create_info_khr: StructureType = .render_pass_multiview_create_info;
pub const StructureType_physical_device_multiview_features_khr: StructureType = .physical_device_multiview_features;
pub const StructureType_physical_device_multiview_properties_khr: StructureType = .physical_device_multiview_properties;
pub const StructureType_physical_device_features_2_khr: StructureType = .physical_device_features_2;
pub const StructureType_physical_device_properties_2_khr: StructureType = .physical_device_properties_2;
pub const StructureType_format_properties_2_khr: StructureType = .format_properties_2;
pub const StructureType_image_format_properties_2_khr: StructureType = .image_format_properties_2;
pub const StructureType_physical_device_image_format_info_2_khr: StructureType = .physical_device_image_format_info_2;
pub const StructureType_queue_family_properties_2_khr: StructureType = .queue_family_properties_2;
pub const StructureType_physical_device_memory_properties_2_khr: StructureType = .physical_device_memory_properties_2;
pub const StructureType_sparse_image_format_properties_2_khr: StructureType = .sparse_image_format_properties_2;
pub const StructureType_physical_device_sparse_image_format_info_2_khr: StructureType = .physical_device_sparse_image_format_info_2;
pub const StructureType_memory_allocate_flags_info_khr: StructureType = .memory_allocate_flags_info;
pub const StructureType_device_group_render_pass_begin_info_khr: StructureType = .device_group_render_pass_begin_info;
pub const StructureType_device_group_command_buffer_begin_info_khr: StructureType = .device_group_command_buffer_begin_info;
pub const StructureType_device_group_submit_info_khr: StructureType = .device_group_submit_info;
pub const StructureType_device_group_bind_sparse_info_khr: StructureType = .device_group_bind_sparse_info;
pub const StructureType_bind_buffer_memory_device_group_info_khr: StructureType = .bind_buffer_memory_device_group_info;
pub const StructureType_bind_image_memory_device_group_info_khr: StructureType = .bind_image_memory_device_group_info;
pub const StructureType_physical_device_texture_compression_astc_hdr_features_ext: StructureType = .physical_device_texture_compression_astc_hdr_features;
pub const StructureType_pipeline_robustness_create_info_ext: StructureType = .pipeline_robustness_create_info;
pub const StructureType_physical_device_pipeline_robustness_features_ext: StructureType = .physical_device_pipeline_robustness_features;
pub const StructureType_physical_device_pipeline_robustness_properties_ext: StructureType = .physical_device_pipeline_robustness_properties;
pub const StructureType_physical_device_group_properties_khr: StructureType = .physical_device_group_properties;
pub const StructureType_device_group_device_create_info_khr: StructureType = .device_group_device_create_info;
pub const StructureType_physical_device_external_image_format_info_khr: StructureType = .physical_device_external_image_format_info;
pub const StructureType_external_image_format_properties_khr: StructureType = .external_image_format_properties;
pub const StructureType_physical_device_external_buffer_info_khr: StructureType = .physical_device_external_buffer_info;
pub const StructureType_external_buffer_properties_khr: StructureType = .external_buffer_properties;
pub const StructureType_physical_device_id_properties_khr: StructureType = .physical_device_id_properties;
pub const StructureType_external_memory_buffer_create_info_khr: StructureType = .external_memory_buffer_create_info;
pub const StructureType_external_memory_image_create_info_khr: StructureType = .external_memory_image_create_info;
pub const StructureType_export_memory_allocate_info_khr: StructureType = .export_memory_allocate_info;
pub const StructureType_physical_device_external_semaphore_info_khr: StructureType = .physical_device_external_semaphore_info;
pub const StructureType_external_semaphore_properties_khr: StructureType = .external_semaphore_properties;
pub const StructureType_export_semaphore_create_info_khr: StructureType = .export_semaphore_create_info;
pub const StructureType_physical_device_push_descriptor_properties_khr: StructureType = .physical_device_push_descriptor_properties;
pub const StructureType_physical_device_shader_float16_int8_features_khr: StructureType = .physical_device_shader_float16_int8_features;
pub const StructureType_physical_device_float16_int8_features_khr: StructureType = .physical_device_shader_float16_int8_features;
pub const StructureType_physical_device_16bit_storage_features_khr: StructureType = .physical_device_16bit_storage_features;
pub const StructureType_descriptor_update_template_create_info_khr: StructureType = .descriptor_update_template_create_info;
pub const StructureType_surface_capabilities2_ext: StructureType = .surface_capabilities_2_ext;
pub const StructureType_physical_device_imageless_framebuffer_features_khr: StructureType = .physical_device_imageless_framebuffer_features;
pub const StructureType_framebuffer_attachments_create_info_khr: StructureType = .framebuffer_attachments_create_info;
pub const StructureType_framebuffer_attachment_image_info_khr: StructureType = .framebuffer_attachment_image_info;
pub const StructureType_render_pass_attachment_begin_info_khr: StructureType = .render_pass_attachment_begin_info;
pub const StructureType_attachment_description_2_khr: StructureType = .attachment_description_2;
pub const StructureType_attachment_reference_2_khr: StructureType = .attachment_reference_2;
pub const StructureType_subpass_description_2_khr: StructureType = .subpass_description_2;
pub const StructureType_subpass_dependency_2_khr: StructureType = .subpass_dependency_2;
pub const StructureType_render_pass_create_info_2_khr: StructureType = .render_pass_create_info_2;
pub const StructureType_subpass_begin_info_khr: StructureType = .subpass_begin_info;
pub const StructureType_subpass_end_info_khr: StructureType = .subpass_end_info;
pub const StructureType_physical_device_external_fence_info_khr: StructureType = .physical_device_external_fence_info;
pub const StructureType_external_fence_properties_khr: StructureType = .external_fence_properties;
pub const StructureType_export_fence_create_info_khr: StructureType = .export_fence_create_info;
pub const StructureType_physical_device_point_clipping_properties_khr: StructureType = .physical_device_point_clipping_properties;
pub const StructureType_render_pass_input_attachment_aspect_create_info_khr: StructureType = .render_pass_input_attachment_aspect_create_info;
pub const StructureType_image_view_usage_create_info_khr: StructureType = .image_view_usage_create_info;
pub const StructureType_pipeline_tessellation_domain_origin_state_create_info_khr: StructureType = .pipeline_tessellation_domain_origin_state_create_info;
pub const StructureType_physical_device_variable_pointers_features_khr: StructureType = .physical_device_variable_pointers_features;
pub const StructureType_physical_device_variable_pointer_features_khr: StructureType = .physical_device_variable_pointers_features_khr;
pub const StructureType_memory_dedicated_requirements_khr: StructureType = .memory_dedicated_requirements;
pub const StructureType_memory_dedicated_allocate_info_khr: StructureType = .memory_dedicated_allocate_info;
pub const StructureType_physical_device_sampler_filter_minmax_properties_ext: StructureType = .physical_device_sampler_filter_minmax_properties;
pub const StructureType_sampler_reduction_mode_create_info_ext: StructureType = .sampler_reduction_mode_create_info;
pub const StructureType_physical_device_inline_uniform_block_features_ext: StructureType = .physical_device_inline_uniform_block_features;
pub const StructureType_physical_device_inline_uniform_block_properties_ext: StructureType = .physical_device_inline_uniform_block_properties;
pub const StructureType_write_descriptor_set_inline_uniform_block_ext: StructureType = .write_descriptor_set_inline_uniform_block;
pub const StructureType_descriptor_pool_inline_uniform_block_create_info_ext: StructureType = .descriptor_pool_inline_uniform_block_create_info;
pub const StructureType_buffer_memory_requirements_info_2_khr: StructureType = .buffer_memory_requirements_info_2;
pub const StructureType_image_memory_requirements_info_2_khr: StructureType = .image_memory_requirements_info_2;
pub const StructureType_image_sparse_memory_requirements_info_2_khr: StructureType = .image_sparse_memory_requirements_info_2;
pub const StructureType_memory_requirements_2_khr: StructureType = .memory_requirements_2;
pub const StructureType_sparse_image_memory_requirements_2_khr: StructureType = .sparse_image_memory_requirements_2;
pub const StructureType_image_format_list_create_info_khr: StructureType = .image_format_list_create_info;
pub const StructureType_attachment_sample_count_info_nv: StructureType = .attachment_sample_count_info_amd;
pub const StructureType_sampler_ycbcr_conversion_create_info_khr: StructureType = .sampler_ycbcr_conversion_create_info;
pub const StructureType_sampler_ycbcr_conversion_info_khr: StructureType = .sampler_ycbcr_conversion_info;
pub const StructureType_bind_image_plane_memory_info_khr: StructureType = .bind_image_plane_memory_info;
pub const StructureType_image_plane_memory_requirements_info_khr: StructureType = .image_plane_memory_requirements_info;
pub const StructureType_physical_device_sampler_ycbcr_conversion_features_khr: StructureType = .physical_device_sampler_ycbcr_conversion_features;
pub const StructureType_sampler_ycbcr_conversion_image_format_properties_khr: StructureType = .sampler_ycbcr_conversion_image_format_properties;
pub const StructureType_bind_buffer_memory_info_khr: StructureType = .bind_buffer_memory_info;
pub const StructureType_bind_image_memory_info_khr: StructureType = .bind_image_memory_info;
pub const StructureType_descriptor_set_layout_binding_flags_create_info_ext: StructureType = .descriptor_set_layout_binding_flags_create_info;
pub const StructureType_physical_device_descriptor_indexing_features_ext: StructureType = .physical_device_descriptor_indexing_features;
pub const StructureType_physical_device_descriptor_indexing_properties_ext: StructureType = .physical_device_descriptor_indexing_properties;
pub const StructureType_descriptor_set_variable_descriptor_count_allocate_info_ext: StructureType = .descriptor_set_variable_descriptor_count_allocate_info;
pub const StructureType_descriptor_set_variable_descriptor_count_layout_support_ext: StructureType = .descriptor_set_variable_descriptor_count_layout_support;
pub const StructureType_physical_device_maintenance_3_properties_khr: StructureType = .physical_device_maintenance_3_properties;
pub const StructureType_descriptor_set_layout_support_khr: StructureType = .descriptor_set_layout_support;
pub const StructureType_device_queue_global_priority_create_info_ext: StructureType = .device_queue_global_priority_create_info;
pub const StructureType_physical_device_shader_subgroup_extended_types_features_khr: StructureType = .physical_device_shader_subgroup_extended_types_features;
pub const StructureType_physical_device_8bit_storage_features_khr: StructureType = .physical_device_8bit_storage_features;
pub const StructureType_physical_device_shader_atomic_int64_features_khr: StructureType = .physical_device_shader_atomic_int64_features;
pub const StructureType_calibrated_timestamp_info_ext: StructureType = .calibrated_timestamp_info_khr;
pub const StructureType_device_queue_global_priority_create_info_khr: StructureType = .device_queue_global_priority_create_info;
pub const StructureType_physical_device_global_priority_query_features_khr: StructureType = .physical_device_global_priority_query_features;
pub const StructureType_queue_family_global_priority_properties_khr: StructureType = .queue_family_global_priority_properties;
pub const StructureType_pipeline_vertex_input_divisor_state_create_info_ext: StructureType = .pipeline_vertex_input_divisor_state_create_info;
pub const StructureType_physical_device_vertex_attribute_divisor_features_ext: StructureType = .physical_device_vertex_attribute_divisor_features;
pub const StructureType_pipeline_creation_feedback_create_info_ext: StructureType = .pipeline_creation_feedback_create_info;
pub const StructureType_physical_device_driver_properties_khr: StructureType = .physical_device_driver_properties;
pub const StructureType_physical_device_float_controls_properties_khr: StructureType = .physical_device_float_controls_properties;
pub const StructureType_physical_device_depth_stencil_resolve_properties_khr: StructureType = .physical_device_depth_stencil_resolve_properties;
pub const StructureType_subpass_description_depth_stencil_resolve_khr: StructureType = .subpass_description_depth_stencil_resolve;
pub const StructureType_physical_device_compute_shader_derivatives_features_nv: StructureType = .physical_device_compute_shader_derivatives_features_khr;
pub const StructureType_physical_device_fragment_shader_barycentric_features_nv: StructureType = .physical_device_fragment_shader_barycentric_features_khr;
pub const StructureType_physical_device_timeline_semaphore_features_khr: StructureType = .physical_device_timeline_semaphore_features;
pub const StructureType_physical_device_timeline_semaphore_properties_khr: StructureType = .physical_device_timeline_semaphore_properties;
pub const StructureType_semaphore_type_create_info_khr: StructureType = .semaphore_type_create_info;
pub const StructureType_timeline_semaphore_submit_info_khr: StructureType = .timeline_semaphore_submit_info;
pub const StructureType_semaphore_wait_info_khr: StructureType = .semaphore_wait_info;
pub const StructureType_semaphore_signal_info_khr: StructureType = .semaphore_signal_info;
pub const StructureType_query_pool_create_info_intel: StructureType = .query_pool_performance_query_create_info_intel;
pub const StructureType_physical_device_vulkan_memory_model_features_khr: StructureType = .physical_device_vulkan_memory_model_features;
pub const StructureType_physical_device_shader_terminate_invocation_features_khr: StructureType = .physical_device_shader_terminate_invocation_features;
pub const StructureType_physical_device_scalar_block_layout_features_ext: StructureType = .physical_device_scalar_block_layout_features;
pub const StructureType_physical_device_subgroup_size_control_properties_ext: StructureType = .physical_device_subgroup_size_control_properties;
pub const StructureType_pipeline_shader_stage_required_subgroup_size_create_info_ext: StructureType = .pipeline_shader_stage_required_subgroup_size_create_info;
pub const StructureType_physical_device_subgroup_size_control_features_ext: StructureType = .physical_device_subgroup_size_control_features;
pub const StructureType_physical_device_dynamic_rendering_local_read_features_khr: StructureType = .physical_device_dynamic_rendering_local_read_features;
pub const StructureType_rendering_attachment_location_info_khr: StructureType = .rendering_attachment_location_info;
pub const StructureType_rendering_input_attachment_index_info_khr: StructureType = .rendering_input_attachment_index_info;
pub const StructureType_physical_device_separate_depth_stencil_layouts_features_khr: StructureType = .physical_device_separate_depth_stencil_layouts_features;
pub const StructureType_attachment_reference_stencil_layout_khr: StructureType = .attachment_reference_stencil_layout;
pub const StructureType_attachment_description_stencil_layout_khr: StructureType = .attachment_description_stencil_layout;
pub const StructureType_physical_device_buffer_address_features_ext: StructureType = .physical_device_buffer_device_address_features_ext;
pub const StructureType_buffer_device_address_info_ext: StructureType = .buffer_device_address_info;
pub const StructureType_physical_device_tool_properties_ext: StructureType = .physical_device_tool_properties;
pub const StructureType_image_stencil_usage_create_info_ext: StructureType = .image_stencil_usage_create_info;
pub const StructureType_physical_device_uniform_buffer_standard_layout_features_khr: StructureType = .physical_device_uniform_buffer_standard_layout_features;
pub const StructureType_physical_device_buffer_device_address_features_khr: StructureType = .physical_device_buffer_device_address_features;
pub const StructureType_buffer_device_address_info_khr: StructureType = .buffer_device_address_info;
pub const StructureType_buffer_opaque_capture_address_create_info_khr: StructureType = .buffer_opaque_capture_address_create_info;
pub const StructureType_memory_opaque_capture_address_allocate_info_khr: StructureType = .memory_opaque_capture_address_allocate_info;
pub const StructureType_device_memory_opaque_capture_address_info_khr: StructureType = .device_memory_opaque_capture_address_info;
pub const StructureType_physical_device_line_rasterization_features_ext: StructureType = .physical_device_line_rasterization_features;
pub const StructureType_pipeline_rasterization_line_state_create_info_ext: StructureType = .pipeline_rasterization_line_state_create_info;
pub const StructureType_physical_device_line_rasterization_properties_ext: StructureType = .physical_device_line_rasterization_properties;
pub const StructureType_physical_device_host_query_reset_features_ext: StructureType = .physical_device_host_query_reset_features;
pub const StructureType_physical_device_index_type_uint8_features_ext: StructureType = .physical_device_index_type_uint8_features;
pub const StructureType_physical_device_host_image_copy_features_ext: StructureType = .physical_device_host_image_copy_features;
pub const StructureType_physical_device_host_image_copy_properties_ext: StructureType = .physical_device_host_image_copy_properties;
pub const StructureType_memory_to_image_copy_ext: StructureType = .memory_to_image_copy;
pub const StructureType_image_to_memory_copy_ext: StructureType = .image_to_memory_copy;
pub const StructureType_copy_image_to_memory_info_ext: StructureType = .copy_image_to_memory_info;
pub const StructureType_copy_memory_to_image_info_ext: StructureType = .copy_memory_to_image_info;
pub const StructureType_host_image_layout_transition_info_ext: StructureType = .host_image_layout_transition_info;
pub const StructureType_copy_image_to_image_info_ext: StructureType = .copy_image_to_image_info;
pub const StructureType_subresource_host_memcpy_size_ext: StructureType = .subresource_host_memcpy_size;
pub const StructureType_host_image_copy_device_performance_query_ext: StructureType = .host_image_copy_device_performance_query;
pub const StructureType_memory_map_info_khr: StructureType = .memory_map_info;
pub const StructureType_memory_unmap_info_khr: StructureType = .memory_unmap_info;
pub const StructureType_surface_present_mode_ext: StructureType = .surface_present_mode_khr;
pub const StructureType_surface_present_scaling_capabilities_ext: StructureType = .surface_present_scaling_capabilities_khr;
pub const StructureType_surface_present_mode_compatibility_ext: StructureType = .surface_present_mode_compatibility_khr;
pub const StructureType_physical_device_swapchain_maintenance_1_features_ext: StructureType = .physical_device_swapchain_maintenance_1_features_khr;
pub const StructureType_swapchain_present_fence_info_ext: StructureType = .swapchain_present_fence_info_khr;
pub const StructureType_swapchain_present_modes_create_info_ext: StructureType = .swapchain_present_modes_create_info_khr;
pub const StructureType_swapchain_present_mode_info_ext: StructureType = .swapchain_present_mode_info_khr;
pub const StructureType_swapchain_present_scaling_create_info_ext: StructureType = .swapchain_present_scaling_create_info_khr;
pub const StructureType_release_swapchain_images_info_ext: StructureType = .release_swapchain_images_info_khr;
pub const StructureType_physical_device_shader_demote_to_helper_invocation_features_ext: StructureType = .physical_device_shader_demote_to_helper_invocation_features;
pub const StructureType_physical_device_shader_integer_dot_product_features_khr: StructureType = .physical_device_shader_integer_dot_product_features;
pub const StructureType_physical_device_shader_integer_dot_product_properties_khr: StructureType = .physical_device_shader_integer_dot_product_properties;
pub const StructureType_physical_device_texel_buffer_alignment_properties_ext: StructureType = .physical_device_texel_buffer_alignment_properties;
pub const StructureType_physical_device_robustness_2_features_ext: StructureType = .physical_device_robustness_2_features_khr;
pub const StructureType_physical_device_robustness_2_properties_ext: StructureType = .physical_device_robustness_2_properties_khr;
pub const StructureType_physical_device_private_data_features_ext: StructureType = .physical_device_private_data_features;
pub const StructureType_device_private_data_create_info_ext: StructureType = .device_private_data_create_info;
pub const StructureType_private_data_slot_create_info_ext: StructureType = .private_data_slot_create_info;
pub const StructureType_physical_device_pipeline_creation_cache_control_features_ext: StructureType = .physical_device_pipeline_creation_cache_control_features;
pub const StructureType_memory_barrier_2_khr: StructureType = .memory_barrier_2;
pub const StructureType_buffer_memory_barrier_2_khr: StructureType = .buffer_memory_barrier_2;
pub const StructureType_image_memory_barrier_2_khr: StructureType = .image_memory_barrier_2;
pub const StructureType_dependency_info_khr: StructureType = .dependency_info;
pub const StructureType_submit_info_2_khr: StructureType = .submit_info_2;
pub const StructureType_semaphore_submit_info_khr: StructureType = .semaphore_submit_info;
pub const StructureType_command_buffer_submit_info_khr: StructureType = .command_buffer_submit_info;
pub const StructureType_physical_device_synchronization_2_features_khr: StructureType = .physical_device_synchronization_2_features;
pub const StructureType_physical_device_zero_initialize_workgroup_memory_features_khr: StructureType = .physical_device_zero_initialize_workgroup_memory_features;
pub const StructureType_physical_device_image_robustness_features_ext: StructureType = .physical_device_image_robustness_features;
pub const StructureType_copy_buffer_info_2_khr: StructureType = .copy_buffer_info_2;
pub const StructureType_copy_image_info_2_khr: StructureType = .copy_image_info_2;
pub const StructureType_copy_buffer_to_image_info_2_khr: StructureType = .copy_buffer_to_image_info_2;
pub const StructureType_copy_image_to_buffer_info_2_khr: StructureType = .copy_image_to_buffer_info_2;
pub const StructureType_blit_image_info_2_khr: StructureType = .blit_image_info_2;
pub const StructureType_resolve_image_info_2_khr: StructureType = .resolve_image_info_2;
pub const StructureType_buffer_copy_2_khr: StructureType = .buffer_copy_2;
pub const StructureType_image_copy_2_khr: StructureType = .image_copy_2;
pub const StructureType_image_blit_2_khr: StructureType = .image_blit_2;
pub const StructureType_buffer_image_copy_2_khr: StructureType = .buffer_image_copy_2;
pub const StructureType_image_resolve_2_khr: StructureType = .image_resolve_2;
pub const StructureType_subresource_layout_2_ext: StructureType = .subresource_layout_2;
pub const StructureType_image_subresource_2_ext: StructureType = .image_subresource_2;
pub const StructureType_physical_device_rasterization_order_attachment_access_features_arm: StructureType = .physical_device_rasterization_order_attachment_access_features_ext;
pub const StructureType_physical_device_mutable_descriptor_type_features_valve: StructureType = .physical_device_mutable_descriptor_type_features_ext;
pub const StructureType_mutable_descriptor_type_create_info_valve: StructureType = .mutable_descriptor_type_create_info_ext;
pub const StructureType_format_properties_3_khr: StructureType = .format_properties_3;
pub const StructureType_physical_device_present_mode_fifo_latest_ready_features_ext: StructureType = .physical_device_present_mode_fifo_latest_ready_features_khr;
pub const StructureType_pipeline_info_ext: StructureType = .pipeline_info_khr;
pub const StructureType_physical_device_external_sci_buf_features_nv: StructureType = .physical_device_external_memory_sci_buf_features_nv;
pub const StructureType_physical_device_global_priority_query_features_ext: StructureType = .physical_device_global_priority_query_features;
pub const StructureType_queue_family_global_priority_properties_ext: StructureType = .queue_family_global_priority_properties;
pub const StructureType_physical_device_maintenance_4_features_khr: StructureType = .physical_device_maintenance_4_features;
pub const StructureType_physical_device_maintenance_4_properties_khr: StructureType = .physical_device_maintenance_4_properties;
pub const StructureType_device_buffer_memory_requirements_khr: StructureType = .device_buffer_memory_requirements;
pub const StructureType_device_image_memory_requirements_khr: StructureType = .device_image_memory_requirements;
pub const StructureType_physical_device_shader_subgroup_rotate_features_khr: StructureType = .physical_device_shader_subgroup_rotate_features;
pub const StructureType_physical_device_depth_clamp_zero_one_features_ext: StructureType = .physical_device_depth_clamp_zero_one_features_khr;
pub const StructureType_physical_device_fragment_density_map_offset_features_qcom: StructureType = .physical_device_fragment_density_map_offset_features_ext;
pub const StructureType_physical_device_fragment_density_map_offset_properties_qcom: StructureType = .physical_device_fragment_density_map_offset_properties_ext;
pub const StructureType_subpass_fragment_density_map_offset_end_info_qcom: StructureType = .render_pass_fragment_density_map_offset_end_info_ext;
pub const StructureType_physical_device_copy_memory_indirect_properties_nv: StructureType = .physical_device_copy_memory_indirect_properties_khr;
pub const StructureType_physical_device_memory_decompression_features_nv: StructureType = .physical_device_memory_decompression_features_ext;
pub const StructureType_physical_device_memory_decompression_properties_nv: StructureType = .physical_device_memory_decompression_properties_ext;
pub const StructureType_physical_device_pipeline_protected_access_features_ext: StructureType = .physical_device_pipeline_protected_access_features;
pub const StructureType_physical_device_maintenance_5_features_khr: StructureType = .physical_device_maintenance_5_features;
pub const StructureType_physical_device_maintenance_5_properties_khr: StructureType = .physical_device_maintenance_5_properties;
pub const StructureType_rendering_area_info_khr: StructureType = .rendering_area_info;
pub const StructureType_device_image_subresource_info_khr: StructureType = .device_image_subresource_info;
pub const StructureType_subresource_layout_2_khr: StructureType = .subresource_layout_2;
pub const StructureType_image_subresource_2_khr: StructureType = .image_subresource_2;
pub const StructureType_pipeline_create_flags_2_create_info_khr: StructureType = .pipeline_create_flags_2_create_info;
pub const StructureType_buffer_usage_flags_2_create_info_khr: StructureType = .buffer_usage_flags_2_create_info;
pub const StructureType_shader_required_subgroup_size_create_info_ext: StructureType = .pipeline_shader_stage_required_subgroup_size_create_info;
pub const StructureType_physical_device_vertex_attribute_divisor_properties_khr: StructureType = .physical_device_vertex_attribute_divisor_properties;
pub const StructureType_pipeline_vertex_input_divisor_state_create_info_khr: StructureType = .pipeline_vertex_input_divisor_state_create_info;
pub const StructureType_physical_device_vertex_attribute_divisor_features_khr: StructureType = .physical_device_vertex_attribute_divisor_features;
pub const StructureType_physical_device_shader_float_controls_2_features_khr: StructureType = .physical_device_shader_float_controls_2_features;
pub const StructureType_physical_device_index_type_uint8_features_khr: StructureType = .physical_device_index_type_uint8_features;
pub const StructureType_physical_device_line_rasterization_features_khr: StructureType = .physical_device_line_rasterization_features;
pub const StructureType_pipeline_rasterization_line_state_create_info_khr: StructureType = .pipeline_rasterization_line_state_create_info;
pub const StructureType_physical_device_line_rasterization_properties_khr: StructureType = .physical_device_line_rasterization_properties;
pub const StructureType_physical_device_shader_expect_assume_features_khr: StructureType = .physical_device_shader_expect_assume_features;
pub const StructureType_physical_device_maintenance_6_features_khr: StructureType = .physical_device_maintenance_6_features;
pub const StructureType_physical_device_maintenance_6_properties_khr: StructureType = .physical_device_maintenance_6_properties;
pub const StructureType_bind_memory_status_khr: StructureType = .bind_memory_status;
pub const StructureType_bind_descriptor_sets_info_khr: StructureType = .bind_descriptor_sets_info;
pub const StructureType_push_constants_info_khr: StructureType = .push_constants_info;
pub const StructureType_push_descriptor_set_info_khr: StructureType = .push_descriptor_set_info;
pub const StructureType_push_descriptor_set_with_template_info_khr: StructureType = .push_descriptor_set_with_template_info;
pub const StructureType_rendering_end_info_ext: StructureType = .rendering_end_info_khr;

pub const SubpassContents = enum(i32) {
    @"inline" = 0,
    secondary_command_buffers = 1,
    inline_and_secondary_command_buffers_khr = 1000451000,
    _,
};
pub const SubpassContents_inline_and_secondary_command_buffers_ext: SubpassContents = .inline_and_secondary_command_buffers_khr;

pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,
    error_validation_failed = -1000011001,
    error_out_of_pool_memory = -1000069000,
    error_invalid_external_handle = -1000072003,
    error_invalid_opaque_capture_address = -1000257000,
    error_fragmentation = -1000161000,
    pipeline_compile_required = 1000297000,
    error_not_permitted = -1000174001,
    error_invalid_pipeline_cache_data = -1000298000,
    error_no_pipeline_match = -1000298001,
    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    suboptimal_khr = 1000001003,
    error_out_of_date_khr = -1000001004,
    error_incompatible_display_khr = -1000003001,
    error_invalid_shader_nv = -1000012000,
    error_image_usage_not_supported_khr = -1000023000,
    error_video_picture_layout_not_supported_khr = -1000023001,
    error_video_profile_operation_not_supported_khr = -1000023002,
    error_video_profile_format_not_supported_khr = -1000023003,
    error_video_profile_codec_not_supported_khr = -1000023004,
    error_video_std_version_not_supported_khr = -1000023005,
    error_invalid_drm_format_modifier_plane_layout_ext = -1000158000,
    error_present_timing_queue_full_ext = -1000208000,
    error_full_screen_exclusive_mode_lost_ext = -1000255000,
    thread_idle_khr = 1000268000,
    thread_done_khr = 1000268001,
    operation_deferred_khr = 1000268002,
    operation_not_deferred_khr = 1000268003,
    error_invalid_video_std_parameters_khr = -1000299000,
    error_compression_exhausted_ext = -1000338000,
    incompatible_shader_binary_ext = 1000482000,
    pipeline_binary_missing_khr = 1000483000,
    error_not_enough_space_khr = -1000483000,
    _,
};
pub const Result_error_validation_failed_ext: Result = .error_validation_failed;
pub const Result_error_out_of_pool_memory_khr: Result = .error_out_of_pool_memory;
pub const Result_error_invalid_external_handle_khr: Result = .error_invalid_external_handle;
pub const Result_error_fragmentation_ext: Result = .error_fragmentation;
pub const Result_error_not_permitted_ext: Result = .error_not_permitted;
pub const Result_error_not_permitted_khr: Result = .error_not_permitted;
pub const Result_error_invalid_device_address_ext: Result = .error_invalid_opaque_capture_address;
pub const Result_error_invalid_opaque_capture_address_khr: Result = .error_invalid_opaque_capture_address;
pub const Result_pipeline_compile_required_ext: Result = .pipeline_compile_required;
pub const Result_error_pipeline_compile_required_ext: Result = .pipeline_compile_required;
pub const Result_error_incompatible_shader_binary_ext: Result = .incompatible_shader_binary_ext;

pub const DynamicState = enum(i32) {
    viewport = 0,
    scissor = 1,
    line_width = 2,
    depth_bias = 3,
    blend_constants = 4,
    depth_bounds = 5,
    stencil_compare_mask = 6,
    stencil_write_mask = 7,
    stencil_reference = 8,
    cull_mode = 1000267000,
    front_face = 1000267001,
    primitive_topology = 1000267002,
    viewport_with_count = 1000267003,
    scissor_with_count = 1000267004,
    vertex_input_binding_stride = 1000267005,
    depth_test_enable = 1000267006,
    depth_write_enable = 1000267007,
    depth_compare_op = 1000267008,
    depth_bounds_test_enable = 1000267009,
    stencil_test_enable = 1000267010,
    stencil_op = 1000267011,
    rasterizer_discard_enable = 1000377001,
    depth_bias_enable = 1000377002,
    primitive_restart_enable = 1000377004,
    line_stipple = 1000259000,
    viewport_w_scaling_nv = 1000087000,
    discard_rectangle_ext = 1000099000,
    discard_rectangle_enable_ext = 1000099001,
    discard_rectangle_mode_ext = 1000099002,
    sample_locations_ext = 1000143000,
    ray_tracing_pipeline_stack_size_khr = 1000347000,
    viewport_shading_rate_palette_nv = 1000164004,
    viewport_coarse_sample_order_nv = 1000164006,
    exclusive_scissor_enable_nv = 1000205000,
    exclusive_scissor_nv = 1000205001,
    fragment_shading_rate_khr = 1000226000,
    vertex_input_ext = 1000352000,
    patch_control_points_ext = 1000377000,
    logic_op_ext = 1000377003,
    color_write_enable_ext = 1000381000,
    depth_clamp_enable_ext = 1000455003,
    polygon_mode_ext = 1000455004,
    rasterization_samples_ext = 1000455005,
    sample_mask_ext = 1000455006,
    alpha_to_coverage_enable_ext = 1000455007,
    alpha_to_one_enable_ext = 1000455008,
    logic_op_enable_ext = 1000455009,
    color_blend_enable_ext = 1000455010,
    color_blend_equation_ext = 1000455011,
    color_write_mask_ext = 1000455012,
    tessellation_domain_origin_ext = 1000455002,
    rasterization_stream_ext = 1000455013,
    conservative_rasterization_mode_ext = 1000455014,
    extra_primitive_overestimation_size_ext = 1000455015,
    depth_clip_enable_ext = 1000455016,
    sample_locations_enable_ext = 1000455017,
    color_blend_advanced_ext = 1000455018,
    provoking_vertex_mode_ext = 1000455019,
    line_rasterization_mode_ext = 1000455020,
    line_stipple_enable_ext = 1000455021,
    depth_clip_negative_one_to_one_ext = 1000455022,
    viewport_w_scaling_enable_nv = 1000455023,
    viewport_swizzle_nv = 1000455024,
    coverage_to_color_enable_nv = 1000455025,
    coverage_to_color_location_nv = 1000455026,
    coverage_modulation_mode_nv = 1000455027,
    coverage_modulation_table_enable_nv = 1000455028,
    coverage_modulation_table_nv = 1000455029,
    shading_rate_image_enable_nv = 1000455030,
    representative_fragment_test_enable_nv = 1000455031,
    coverage_reduction_mode_nv = 1000455032,
    attachment_feedback_loop_enable_ext = 1000524000,
    depth_clamp_range_ext = 1000582000,
    _,
};
pub const DynamicState_line_stipple_ext: DynamicState = .line_stipple;
pub const DynamicState_cull_mode_ext: DynamicState = .cull_mode;
pub const DynamicState_front_face_ext: DynamicState = .front_face;
pub const DynamicState_primitive_topology_ext: DynamicState = .primitive_topology;
pub const DynamicState_viewport_with_count_ext: DynamicState = .viewport_with_count;
pub const DynamicState_scissor_with_count_ext: DynamicState = .scissor_with_count;
pub const DynamicState_vertex_input_binding_stride_ext: DynamicState = .vertex_input_binding_stride;
pub const DynamicState_depth_test_enable_ext: DynamicState = .depth_test_enable;
pub const DynamicState_depth_write_enable_ext: DynamicState = .depth_write_enable;
pub const DynamicState_depth_compare_op_ext: DynamicState = .depth_compare_op;
pub const DynamicState_depth_bounds_test_enable_ext: DynamicState = .depth_bounds_test_enable;
pub const DynamicState_stencil_test_enable_ext: DynamicState = .stencil_test_enable;
pub const DynamicState_stencil_op_ext: DynamicState = .stencil_op;
pub const DynamicState_rasterizer_discard_enable_ext: DynamicState = .rasterizer_discard_enable;
pub const DynamicState_depth_bias_enable_ext: DynamicState = .depth_bias_enable;
pub const DynamicState_primitive_restart_enable_ext: DynamicState = .primitive_restart_enable;
pub const DynamicState_line_stipple_khr: DynamicState = .line_stipple;

pub const DescriptorUpdateTemplateType = enum(i32) {
    descriptor_set = 0,
    push_descriptors = 1,
    _,
};
pub const DescriptorUpdateTemplateType_push_descriptors_khr: DescriptorUpdateTemplateType = .push_descriptors;
pub const DescriptorUpdateTemplateType_descriptor_set_khr: DescriptorUpdateTemplateType = .descriptor_set;

pub const ObjectType = enum(i32) {
    unknown = 0,
    instance = 1,
    physical_device = 2,
    device = 3,
    queue = 4,
    semaphore = 5,
    command_buffer = 6,
    fence = 7,
    device_memory = 8,
    buffer = 9,
    image = 10,
    event = 11,
    query_pool = 12,
    buffer_view = 13,
    image_view = 14,
    shader_module = 15,
    pipeline_cache = 16,
    pipeline_layout = 17,
    render_pass = 18,
    pipeline = 19,
    descriptor_set_layout = 20,
    sampler = 21,
    descriptor_pool = 22,
    descriptor_set = 23,
    framebuffer = 24,
    command_pool = 25,
    descriptor_update_template = 1000085000,
    sampler_ycbcr_conversion = 1000156000,
    private_data_slot = 1000295000,
    surface_khr = 1000000000,
    swapchain_khr = 1000001000,
    display_khr = 1000002000,
    display_mode_khr = 1000002001,
    debug_report_callback_ext = 1000011000,
    video_session_khr = 1000023000,
    video_session_parameters_khr = 1000023001,
    cu_module_nvx = 1000029000,
    cu_function_nvx = 1000029001,
    debug_utils_messenger_ext = 1000128000,
    acceleration_structure_khr = 1000150000,
    validation_cache_ext = 1000160000,
    acceleration_structure_nv = 1000165000,
    performance_configuration_intel = 1000210000,
    deferred_operation_khr = 1000268000,
    indirect_commands_layout_nv = 1000277000,
    cuda_module_nv = 1000307000,
    cuda_function_nv = 1000307001,
    buffer_collection_fuchsia = 1000366000,
    micromap_ext = 1000396000,
    tensor_arm = 1000460000,
    tensor_view_arm = 1000460001,
    optical_flow_session_nv = 1000464000,
    shader_ext = 1000482000,
    pipeline_binary_khr = 1000483000,
    semaphore_sci_sync_pool_nv = 1000489000,
    data_graph_pipeline_session_arm = 1000507000,
    external_compute_queue_nv = 1000556000,
    indirect_commands_layout_ext = 1000572000,
    indirect_execution_set_ext = 1000572001,
    _,
};
pub const ObjectType_descriptor_update_template_khr: ObjectType = .descriptor_update_template;
pub const ObjectType_sampler_ycbcr_conversion_khr: ObjectType = .sampler_ycbcr_conversion;
pub const ObjectType_private_data_slot_ext: ObjectType = .private_data_slot;

pub const QueueFlagBits = enum(i32) {
    _,
};

pub const CullModeFlagBits = enum(i32) {
    none = 0,
    front_and_back = 0x00000003,
    _,
};

pub const RenderPassCreateFlagBits = enum(i32) {
    _,
};

pub const DeviceQueueCreateFlagBits = enum(i32) {
    _,
};

pub const MemoryPropertyFlagBits = enum(i32) {
    _,
};

pub const MemoryHeapFlagBits = enum(i32) {
    _,
};
pub const MemoryHeapFlagBits_multi_instance_bit_khr: MemoryHeapFlagBits = .multi_instance_bit;

pub const AccessFlagBits = enum(i32) {
    none = 0,
    _,
};
pub const AccessFlagBits_shading_rate_image_read_bit_nv: AccessFlagBits = .fragment_shading_rate_attachment_read_bit_khr;
pub const AccessFlagBits_acceleration_structure_read_bit_nv: AccessFlagBits = .acceleration_structure_read_bit_khr;
pub const AccessFlagBits_acceleration_structure_write_bit_nv: AccessFlagBits = .acceleration_structure_write_bit_khr;
pub const AccessFlagBits_command_preprocess_read_bit_nv: AccessFlagBits = .command_preprocess_read_bit_ext;
pub const AccessFlagBits_command_preprocess_write_bit_nv: AccessFlagBits = .command_preprocess_write_bit_ext;
pub const AccessFlagBits_none_khr: AccessFlagBits = .none;

pub const BufferUsageFlagBits = enum(i32) {
    _,
};
pub const BufferUsageFlagBits_ray_tracing_bit_nv: BufferUsageFlagBits = .shader_binding_table_bit_khr;
pub const BufferUsageFlagBits_shader_device_address_bit_ext: BufferUsageFlagBits = .shader_device_address_bit;
pub const BufferUsageFlagBits_shader_device_address_bit_khr: BufferUsageFlagBits = .shader_device_address_bit;

pub const BufferCreateFlagBits = enum(i32) {
    _,
};
pub const BufferCreateFlagBits_device_address_capture_replay_bit_ext: BufferCreateFlagBits = .device_address_capture_replay_bit;
pub const BufferCreateFlagBits_device_address_capture_replay_bit_khr: BufferCreateFlagBits = .device_address_capture_replay_bit;

pub const ShaderStageFlagBits = enum(i32) {
    all_graphics = 0x0000001F,
    all = 0x7FFFFFFF,
    _,
};
pub const ShaderStageFlagBits_raygen_bit_nv: ShaderStageFlagBits = .raygen_bit_khr;
pub const ShaderStageFlagBits_any_hit_bit_nv: ShaderStageFlagBits = .any_hit_bit_khr;
pub const ShaderStageFlagBits_closest_hit_bit_nv: ShaderStageFlagBits = .closest_hit_bit_khr;
pub const ShaderStageFlagBits_miss_bit_nv: ShaderStageFlagBits = .miss_bit_khr;
pub const ShaderStageFlagBits_intersection_bit_nv: ShaderStageFlagBits = .intersection_bit_khr;
pub const ShaderStageFlagBits_callable_bit_nv: ShaderStageFlagBits = .callable_bit_khr;
pub const ShaderStageFlagBits_task_bit_nv: ShaderStageFlagBits = .task_bit_ext;
pub const ShaderStageFlagBits_mesh_bit_nv: ShaderStageFlagBits = .mesh_bit_ext;

pub const ImageUsageFlagBits = enum(i32) {
    _,
};
pub const ImageUsageFlagBits_shading_rate_image_bit_nv: ImageUsageFlagBits = .fragment_shading_rate_attachment_bit_khr;
pub const ImageUsageFlagBits_host_transfer_bit_ext: ImageUsageFlagBits = .host_transfer_bit;

pub const ImageCreateFlagBits = enum(i32) {
    _,
};
pub const ImageCreateFlagBits_split_instance_bind_regions_bit_khr: ImageCreateFlagBits = .split_instance_bind_regions_bit;
pub const ImageCreateFlagBits__2d_array_compatible_bit_khr: ImageCreateFlagBits = ._2d_array_compatible_bit;
pub const ImageCreateFlagBits_block_texel_view_compatible_bit_khr: ImageCreateFlagBits = .block_texel_view_compatible_bit;
pub const ImageCreateFlagBits_extended_usage_bit_khr: ImageCreateFlagBits = .extended_usage_bit;
pub const ImageCreateFlagBits_disjoint_bit_khr: ImageCreateFlagBits = .disjoint_bit;
pub const ImageCreateFlagBits_alias_bit_khr: ImageCreateFlagBits = .alias_bit;
pub const ImageCreateFlagBits_descriptor_buffer_capture_replay_bit_ext: ImageCreateFlagBits = .descriptor_heap_capture_replay_bit_ext;
pub const ImageCreateFlagBits_fragment_density_map_offset_bit_qcom: ImageCreateFlagBits = .fragment_density_map_offset_bit_ext;

pub const ImageViewCreateFlagBits = enum(i32) {
    _,
};

pub const SamplerCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineCreateFlagBits = enum(i32) {
    _,
};
pub const PipelineCreateFlagBits_dispatch_base: PipelineCreateFlagBits = .dispatch_base_bit;
pub const PipelineCreateFlagBits_view_index_from_device_index_bit_khr: PipelineCreateFlagBits = .view_index_from_device_index_bit;
pub const PipelineCreateFlagBits_dispatch_base_bit_khr: PipelineCreateFlagBits = .dispatch_base_bit;
pub const PipelineCreateFlagBits_dispatch_base_khr: PipelineCreateFlagBits = .dispatch_base_bit;
pub const PipelineCreateFlagBits_pipeline_rasterization_state_create_fragment_density_map_attachment_bit_ext: PipelineCreateFlagBits = .rendering_fragment_density_map_attachment_bit_ext;
pub const PipelineCreateFlagBits_pipeline_rasterization_state_create_fragment_shading_rate_attachment_bit_khr: PipelineCreateFlagBits = .rendering_fragment_shading_rate_attachment_bit_khr;
pub const PipelineCreateFlagBits_fail_on_pipeline_compile_required_bit_ext: PipelineCreateFlagBits = .fail_on_pipeline_compile_required_bit;
pub const PipelineCreateFlagBits_early_return_on_failure_bit_ext: PipelineCreateFlagBits = .early_return_on_failure_bit;
pub const PipelineCreateFlagBits_no_protected_access_bit_ext: PipelineCreateFlagBits = .no_protected_access_bit;
pub const PipelineCreateFlagBits_protected_access_only_bit_ext: PipelineCreateFlagBits = .protected_access_only_bit;

pub const PipelineShaderStageCreateFlagBits = enum(i32) {
    _,
};
pub const PipelineShaderStageCreateFlagBits_allow_varying_subgroup_size_bit_ext: PipelineShaderStageCreateFlagBits = .allow_varying_subgroup_size_bit;
pub const PipelineShaderStageCreateFlagBits_require_full_subgroups_bit_ext: PipelineShaderStageCreateFlagBits = .require_full_subgroups_bit;

pub const ColorComponentFlagBits = enum(i32) {
    _,
};

pub const FenceCreateFlagBits = enum(i32) {
    _,
};

pub const FormatFeatureFlagBits = enum(i32) {
    _,
};
pub const FormatFeatureFlagBits_sampled_image_filter_cubic_bit_img: FormatFeatureFlagBits = .sampled_image_filter_cubic_bit_ext;
pub const FormatFeatureFlagBits_transfer_src_bit_khr: FormatFeatureFlagBits = .transfer_src_bit;
pub const FormatFeatureFlagBits_transfer_dst_bit_khr: FormatFeatureFlagBits = .transfer_dst_bit;
pub const FormatFeatureFlagBits_sampled_image_filter_minmax_bit_ext: FormatFeatureFlagBits = .sampled_image_filter_minmax_bit;
pub const FormatFeatureFlagBits_midpoint_chroma_samples_bit_khr: FormatFeatureFlagBits = .midpoint_chroma_samples_bit;
pub const FormatFeatureFlagBits_sampled_image_ycbcr_conversion_linear_filter_bit_khr: FormatFeatureFlagBits = .sampled_image_ycbcr_conversion_linear_filter_bit;
pub const FormatFeatureFlagBits_sampled_image_ycbcr_conversion_separate_reconstruction_filter_bit_khr: FormatFeatureFlagBits = .sampled_image_ycbcr_conversion_separate_reconstruction_filter_bit;
pub const FormatFeatureFlagBits_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_bit_khr: FormatFeatureFlagBits = .sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_bit;
pub const FormatFeatureFlagBits_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable_bit_khr: FormatFeatureFlagBits = .sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable_bit;
pub const FormatFeatureFlagBits_disjoint_bit_khr: FormatFeatureFlagBits = .disjoint_bit;
pub const FormatFeatureFlagBits_cosited_chroma_samples_bit_khr: FormatFeatureFlagBits = .cosited_chroma_samples_bit;

pub const QueryControlFlagBits = enum(i32) {
    _,
};

pub const QueryResultFlagBits = enum(i32) {
    _,
};

pub const CommandBufferUsageFlagBits = enum(i32) {
    _,
};

pub const QueryPipelineStatisticFlagBits = enum(i32) {
    _,
};

pub const MemoryMapFlagBits = enum(i32) {
    _,
};

pub const ImageAspectFlagBits = enum(i32) {
    none = 0,
    _,
};
pub const ImageAspectFlagBits_plane_0_bit_khr: ImageAspectFlagBits = .plane_0_bit;
pub const ImageAspectFlagBits_plane_1_bit_khr: ImageAspectFlagBits = .plane_1_bit;
pub const ImageAspectFlagBits_plane_2_bit_khr: ImageAspectFlagBits = .plane_2_bit;
pub const ImageAspectFlagBits_none_khr: ImageAspectFlagBits = .none;

pub const SparseImageFormatFlagBits = enum(i32) {
    _,
};

pub const SparseMemoryBindFlagBits = enum(i32) {
    _,
};

pub const PipelineStageFlagBits = enum(i32) {
    none = 0,
    _,
};
pub const PipelineStageFlagBits_shading_rate_image_bit_nv: PipelineStageFlagBits = .fragment_shading_rate_attachment_bit_khr;
pub const PipelineStageFlagBits_ray_tracing_shader_bit_nv: PipelineStageFlagBits = .ray_tracing_shader_bit_khr;
pub const PipelineStageFlagBits_acceleration_structure_build_bit_nv: PipelineStageFlagBits = .acceleration_structure_build_bit_khr;
pub const PipelineStageFlagBits_task_shader_bit_nv: PipelineStageFlagBits = .task_shader_bit_ext;
pub const PipelineStageFlagBits_mesh_shader_bit_nv: PipelineStageFlagBits = .mesh_shader_bit_ext;
pub const PipelineStageFlagBits_command_preprocess_bit_nv: PipelineStageFlagBits = .command_preprocess_bit_ext;
pub const PipelineStageFlagBits_none_khr: PipelineStageFlagBits = .none;

pub const CommandPoolCreateFlagBits = enum(i32) {
    _,
};

pub const CommandPoolResetFlagBits = enum(i32) {
    _,
};

pub const CommandBufferResetFlagBits = enum(i32) {
    _,
};

pub const SampleCountFlagBits = enum(i32) {
    _,
};

pub const AttachmentDescriptionFlagBits = enum(i32) {
    _,
};

pub const StencilFaceFlagBits = enum(i32) {
    front_and_back = 0x00000003,
    _,
};
pub const StencilFaceFlagBits_stencil_front_and_back: StencilFaceFlagBits = .front_and_back;

pub const DescriptorPoolCreateFlagBits = enum(i32) {
    _,
};
pub const DescriptorPoolCreateFlagBits_update_after_bind_bit_ext: DescriptorPoolCreateFlagBits = .update_after_bind_bit;
pub const DescriptorPoolCreateFlagBits_host_only_bit_valve: DescriptorPoolCreateFlagBits = .host_only_bit_ext;

pub const DependencyFlagBits = enum(i32) {
    _,
};
pub const DependencyFlagBits_view_local_bit_khr: DependencyFlagBits = .view_local_bit;
pub const DependencyFlagBits_device_group_bit_khr: DependencyFlagBits = .device_group_bit;

pub const SemaphoreType = enum(i32) {
    binary = 0,
    timeline = 1,
    _,
};
pub const SemaphoreType_binary_khr: SemaphoreType = .binary;
pub const SemaphoreType_timeline_khr: SemaphoreType = .timeline;

pub const SemaphoreWaitFlagBits = enum(i32) {
    _,
};
pub const SemaphoreWaitFlagBits_any_bit_khr: SemaphoreWaitFlagBits = .any_bit;

pub const PresentModeKHR = enum(i32) {
    immediate = 0,
    mailbox = 1,
    fifo = 2,
    fifo_relaxed = 3,
    shared_demand_refresh = 1000111000,
    shared_continuous_refresh = 1000111001,
    fifo_latest_ready = 1000361000,
    _,
};
pub const PresentModeKHR_fifo_latest_ready_ext: PresentModeKHR = .fifo_latest_ready;

pub const ColorSpaceKHR = enum(i32) {
    srgb_nonlinear = 0,
    display_p3_nonlinear_ext = 1000104001,
    extended_srgb_linear_ext = 1000104002,
    display_p3_linear_ext = 1000104003,
    dci_p3_nonlinear_ext = 1000104004,
    bt709_linear_ext = 1000104005,
    bt709_nonlinear_ext = 1000104006,
    bt2020_linear_ext = 1000104007,
    hdr10_st2084_ext = 1000104008,
    dolbyvision_ext = 1000104009,
    hdr10_hlg_ext = 1000104010,
    adobergb_linear_ext = 1000104011,
    adobergb_nonlinear_ext = 1000104012,
    pass_through_ext = 1000104013,
    extended_srgb_nonlinear_ext = 1000104014,
    display_native_amd = 1000213000,
    _,
};
pub const ColorSpaceKHR_colorspace_srgb_nonlinear: ColorSpaceKHR = .srgb_nonlinear;
pub const ColorSpaceKHR_dci_p3_linear_ext: ColorSpaceKHR = .display_p3_linear_ext;

pub const CompositeAlphaFlagBitsKHR = enum(i32) {
    _,
};

pub const SurfaceTransformFlagBitsKHR = enum(i32) {
    _,
};

pub const SubgroupFeatureFlagBits = enum(i32) {
    _,
};
pub const SubgroupFeatureFlagBits_partitioned_bit_nv: SubgroupFeatureFlagBits = .partitioned_bit_ext;
pub const SubgroupFeatureFlagBits_rotate_bit_khr: SubgroupFeatureFlagBits = .rotate_bit;
pub const SubgroupFeatureFlagBits_rotate_clustered_bit_khr: SubgroupFeatureFlagBits = .rotate_clustered_bit;

pub const DescriptorSetLayoutCreateFlagBits = enum(i32) {
    _,
};
pub const DescriptorSetLayoutCreateFlagBits_push_descriptor_bit_khr: DescriptorSetLayoutCreateFlagBits = .push_descriptor_bit;
pub const DescriptorSetLayoutCreateFlagBits_update_after_bind_pool_bit_ext: DescriptorSetLayoutCreateFlagBits = .update_after_bind_pool_bit;
pub const DescriptorSetLayoutCreateFlagBits_host_only_pool_bit_valve: DescriptorSetLayoutCreateFlagBits = .host_only_pool_bit_ext;

pub const ExternalMemoryHandleTypeFlagBits = enum(i32) {
    _,
};
pub const ExternalMemoryHandleTypeFlagBits_opaque_fd_bit_khr: ExternalMemoryHandleTypeFlagBits = .opaque_fd_bit;
pub const ExternalMemoryHandleTypeFlagBits_opaque_win32_bit_khr: ExternalMemoryHandleTypeFlagBits = .opaque_win32_bit;
pub const ExternalMemoryHandleTypeFlagBits_opaque_win32_kmt_bit_khr: ExternalMemoryHandleTypeFlagBits = .opaque_win32_kmt_bit;
pub const ExternalMemoryHandleTypeFlagBits_d3d11_texture_bit_khr: ExternalMemoryHandleTypeFlagBits = .d3d11_texture_bit;
pub const ExternalMemoryHandleTypeFlagBits_d3d11_texture_kmt_bit_khr: ExternalMemoryHandleTypeFlagBits = .d3d11_texture_kmt_bit;
pub const ExternalMemoryHandleTypeFlagBits_d3d12_heap_bit_khr: ExternalMemoryHandleTypeFlagBits = .d3d12_heap_bit;
pub const ExternalMemoryHandleTypeFlagBits_d3d12_resource_bit_khr: ExternalMemoryHandleTypeFlagBits = .d3d12_resource_bit;

pub const ExternalMemoryFeatureFlagBits = enum(i32) {
    _,
};
pub const ExternalMemoryFeatureFlagBits_dedicated_only_bit_khr: ExternalMemoryFeatureFlagBits = .dedicated_only_bit;
pub const ExternalMemoryFeatureFlagBits_exportable_bit_khr: ExternalMemoryFeatureFlagBits = .exportable_bit;
pub const ExternalMemoryFeatureFlagBits_importable_bit_khr: ExternalMemoryFeatureFlagBits = .importable_bit;

pub const ExternalSemaphoreHandleTypeFlagBits = enum(i32) {
    _,
};
pub const ExternalSemaphoreHandleTypeFlagBits_d3d11_fence_bit: ExternalSemaphoreHandleTypeFlagBits = .d3d12_fence_bit;
pub const ExternalSemaphoreHandleTypeFlagBits_opaque_fd_bit_khr: ExternalSemaphoreHandleTypeFlagBits = .opaque_fd_bit;
pub const ExternalSemaphoreHandleTypeFlagBits_opaque_win32_bit_khr: ExternalSemaphoreHandleTypeFlagBits = .opaque_win32_bit;
pub const ExternalSemaphoreHandleTypeFlagBits_opaque_win32_kmt_bit_khr: ExternalSemaphoreHandleTypeFlagBits = .opaque_win32_kmt_bit;
pub const ExternalSemaphoreHandleTypeFlagBits_d3d12_fence_bit_khr: ExternalSemaphoreHandleTypeFlagBits = .d3d12_fence_bit;
pub const ExternalSemaphoreHandleTypeFlagBits_sync_fd_bit_khr: ExternalSemaphoreHandleTypeFlagBits = .sync_fd_bit;

pub const ExternalSemaphoreFeatureFlagBits = enum(i32) {
    _,
};
pub const ExternalSemaphoreFeatureFlagBits_exportable_bit_khr: ExternalSemaphoreFeatureFlagBits = .exportable_bit;
pub const ExternalSemaphoreFeatureFlagBits_importable_bit_khr: ExternalSemaphoreFeatureFlagBits = .importable_bit;

pub const SemaphoreImportFlagBits = enum(i32) {
    _,
};
pub const SemaphoreImportFlagBits_temporary_bit_khr: SemaphoreImportFlagBits = .temporary_bit;

pub const ExternalFenceHandleTypeFlagBits = enum(i32) {
    _,
};
pub const ExternalFenceHandleTypeFlagBits_opaque_fd_bit_khr: ExternalFenceHandleTypeFlagBits = .opaque_fd_bit;
pub const ExternalFenceHandleTypeFlagBits_opaque_win32_bit_khr: ExternalFenceHandleTypeFlagBits = .opaque_win32_bit;
pub const ExternalFenceHandleTypeFlagBits_opaque_win32_kmt_bit_khr: ExternalFenceHandleTypeFlagBits = .opaque_win32_kmt_bit;
pub const ExternalFenceHandleTypeFlagBits_sync_fd_bit_khr: ExternalFenceHandleTypeFlagBits = .sync_fd_bit;

pub const ExternalFenceFeatureFlagBits = enum(i32) {
    _,
};
pub const ExternalFenceFeatureFlagBits_exportable_bit_khr: ExternalFenceFeatureFlagBits = .exportable_bit;
pub const ExternalFenceFeatureFlagBits_importable_bit_khr: ExternalFenceFeatureFlagBits = .importable_bit;

pub const FenceImportFlagBits = enum(i32) {
    _,
};
pub const FenceImportFlagBits_temporary_bit_khr: FenceImportFlagBits = .temporary_bit;

pub const PeerMemoryFeatureFlagBits = enum(i32) {
    _,
};
pub const PeerMemoryFeatureFlagBits_copy_src_bit_khr: PeerMemoryFeatureFlagBits = .copy_src_bit;
pub const PeerMemoryFeatureFlagBits_copy_dst_bit_khr: PeerMemoryFeatureFlagBits = .copy_dst_bit;
pub const PeerMemoryFeatureFlagBits_generic_src_bit_khr: PeerMemoryFeatureFlagBits = .generic_src_bit;
pub const PeerMemoryFeatureFlagBits_generic_dst_bit_khr: PeerMemoryFeatureFlagBits = .generic_dst_bit;

pub const MemoryAllocateFlagBits = enum(i32) {
    _,
};
pub const MemoryAllocateFlagBits_device_mask_bit_khr: MemoryAllocateFlagBits = .device_mask_bit;
pub const MemoryAllocateFlagBits_device_address_bit_khr: MemoryAllocateFlagBits = .device_address_bit;
pub const MemoryAllocateFlagBits_device_address_capture_replay_bit_khr: MemoryAllocateFlagBits = .device_address_capture_replay_bit;

pub const DeviceGroupPresentModeFlagBitsKHR = enum(i32) {
    _,
};

pub const SwapchainCreateFlagBitsKHR = enum(i32) {
    _,
};
pub const SwapchainCreateFlagBitsKHR_deferred_memory_allocation_bit_ext: SwapchainCreateFlagBitsKHR = .deferred_memory_allocation_bit;

pub const SubpassDescriptionFlagBits = enum(i32) {
    _,
};
pub const SubpassDescriptionFlagBits_fragment_region_bit_qcom: SubpassDescriptionFlagBits = .fragment_region_bit_ext;
pub const SubpassDescriptionFlagBits_shader_resolve_bit_qcom: SubpassDescriptionFlagBits = .custom_resolve_bit_ext;
pub const SubpassDescriptionFlagBits_rasterization_order_attachment_color_access_bit_arm: SubpassDescriptionFlagBits = .rasterization_order_attachment_color_access_bit_ext;
pub const SubpassDescriptionFlagBits_rasterization_order_attachment_depth_access_bit_arm: SubpassDescriptionFlagBits = .rasterization_order_attachment_depth_access_bit_ext;
pub const SubpassDescriptionFlagBits_rasterization_order_attachment_stencil_access_bit_arm: SubpassDescriptionFlagBits = .rasterization_order_attachment_stencil_access_bit_ext;

pub const PointClippingBehavior = enum(i32) {
    all_clip_planes = 0,
    user_clip_planes_only = 1,
    _,
};
pub const PointClippingBehavior_all_clip_planes_khr: PointClippingBehavior = .all_clip_planes;
pub const PointClippingBehavior_user_clip_planes_only_khr: PointClippingBehavior = .user_clip_planes_only;

pub const SamplerReductionMode = enum(i32) {
    weighted_average = 0,
    min = 1,
    max = 2,
    weighted_average_rangeclamp_qcom = 1000521000,
    _,
};
pub const SamplerReductionMode_weighted_average_ext: SamplerReductionMode = .weighted_average;
pub const SamplerReductionMode_min_ext: SamplerReductionMode = .min;
pub const SamplerReductionMode_max_ext: SamplerReductionMode = .max;

pub const TessellationDomainOrigin = enum(i32) {
    upper_left = 0,
    lower_left = 1,
    _,
};
pub const TessellationDomainOrigin_upper_left_khr: TessellationDomainOrigin = .upper_left;
pub const TessellationDomainOrigin_lower_left_khr: TessellationDomainOrigin = .lower_left;

pub const SamplerYcbcrModelConversion = enum(i32) {
    rgb_identity = 0,
    ycbcr_identity = 1,
    ycbcr_709 = 2,
    ycbcr_601 = 3,
    ycbcr_2020 = 4,
    _,
};
pub const SamplerYcbcrModelConversion_rgb_identity_khr: SamplerYcbcrModelConversion = .rgb_identity;
pub const SamplerYcbcrModelConversion_ycbcr_identity_khr: SamplerYcbcrModelConversion = .ycbcr_identity;
pub const SamplerYcbcrModelConversion_ycbcr_709_khr: SamplerYcbcrModelConversion = .ycbcr_709;
pub const SamplerYcbcrModelConversion_ycbcr_601_khr: SamplerYcbcrModelConversion = .ycbcr_601;
pub const SamplerYcbcrModelConversion_ycbcr_2020_khr: SamplerYcbcrModelConversion = .ycbcr_2020;

pub const SamplerYcbcrRange = enum(i32) {
    itu_full = 0,
    itu_narrow = 1,
    _,
};
pub const SamplerYcbcrRange_itu_full_khr: SamplerYcbcrRange = .itu_full;
pub const SamplerYcbcrRange_itu_narrow_khr: SamplerYcbcrRange = .itu_narrow;

pub const ChromaLocation = enum(i32) {
    cosited_even = 0,
    midpoint = 1,
    _,
};
pub const ChromaLocation_cosited_even_khr: ChromaLocation = .cosited_even;
pub const ChromaLocation_midpoint_khr: ChromaLocation = .midpoint;

pub const DebugUtilsMessageSeverityFlagBitsEXT = enum(i32) {
    _,
};

pub const DebugUtilsMessageTypeFlagBitsEXT = enum(i32) {
    _,
};

pub const DescriptorBindingFlagBits = enum(i32) {
    _,
};
pub const DescriptorBindingFlagBits_update_after_bind_bit_ext: DescriptorBindingFlagBits = .update_after_bind_bit;
pub const DescriptorBindingFlagBits_update_unused_while_pending_bit_ext: DescriptorBindingFlagBits = .update_unused_while_pending_bit;
pub const DescriptorBindingFlagBits_partially_bound_bit_ext: DescriptorBindingFlagBits = .partially_bound_bit;
pub const DescriptorBindingFlagBits_variable_descriptor_count_bit_ext: DescriptorBindingFlagBits = .variable_descriptor_count_bit;

pub const VendorId = enum(i32) {
    khronos = 0x10000,
    viv = 0x10001,
    vsi = 0x10002,
    kazan = 0x10003,
    codeplay = 0x10004,
    mesa = 0x10005,
    pocl = 0x10006,
    mobileye = 0x10007,
    _,
};

pub const DriverId = enum(i32) {
    amd_proprietary = 1,
    amd_open_source = 2,
    mesa_radv = 3,
    nvidia_proprietary = 4,
    intel_proprietary_windows = 5,
    intel_open_source_mesa = 6,
    imagination_proprietary = 7,
    qualcomm_proprietary = 8,
    arm_proprietary = 9,
    google_swiftshader = 10,
    ggp_proprietary = 11,
    broadcom_proprietary = 12,
    mesa_llvmpipe = 13,
    moltenvk = 14,
    coreavi_proprietary = 15,
    juice_proprietary = 16,
    verisilicon_proprietary = 17,
    mesa_turnip = 18,
    mesa_v3dv = 19,
    mesa_panvk = 20,
    samsung_proprietary = 21,
    mesa_venus = 22,
    mesa_dozen = 23,
    mesa_nvk = 24,
    imagination_open_source_mesa = 25,
    mesa_honeykrisp = 26,
    vulkan_sc_emulation_on_vulkan = 27,
    mesa_kosmickrisp = 28,
    _,
};
pub const DriverId_amd_proprietary_khr: DriverId = .amd_proprietary;
pub const DriverId_amd_open_source_khr: DriverId = .amd_open_source;
pub const DriverId_mesa_radv_khr: DriverId = .mesa_radv;
pub const DriverId_nvidia_proprietary_khr: DriverId = .nvidia_proprietary;
pub const DriverId_intel_proprietary_windows_khr: DriverId = .intel_proprietary_windows;
pub const DriverId_intel_open_source_mesa_khr: DriverId = .intel_open_source_mesa;
pub const DriverId_imagination_proprietary_khr: DriverId = .imagination_proprietary;
pub const DriverId_qualcomm_proprietary_khr: DriverId = .qualcomm_proprietary;
pub const DriverId_arm_proprietary_khr: DriverId = .arm_proprietary;
pub const DriverId_google_swiftshader_khr: DriverId = .google_swiftshader;
pub const DriverId_ggp_proprietary_khr: DriverId = .ggp_proprietary;
pub const DriverId_broadcom_proprietary_khr: DriverId = .broadcom_proprietary;

pub const ResolveModeFlagBits = enum(i32) {
    none = 0,
    _,
};
pub const ResolveModeFlagBits_none_khr: ResolveModeFlagBits = .none;
pub const ResolveModeFlagBits_sample_zero_bit_khr: ResolveModeFlagBits = .sample_zero_bit;
pub const ResolveModeFlagBits_average_bit_khr: ResolveModeFlagBits = .average_bit;
pub const ResolveModeFlagBits_min_bit_khr: ResolveModeFlagBits = .min_bit;
pub const ResolveModeFlagBits_max_bit_khr: ResolveModeFlagBits = .max_bit;
pub const ResolveModeFlagBits_external_format_downsample_android: ResolveModeFlagBits = .external_format_downsample_bit_android;

pub const FramebufferCreateFlagBits = enum(i32) {
    _,
};
pub const FramebufferCreateFlagBits_imageless_bit_khr: FramebufferCreateFlagBits = .imageless_bit;

pub const QueryPoolCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineCreationFeedbackFlagBits = enum(i32) {
    _,
};
pub const PipelineCreationFeedbackFlagBits_valid_bit_ext: PipelineCreationFeedbackFlagBits = .valid_bit;
pub const PipelineCreationFeedbackFlagBits_application_pipeline_cache_hit_bit_ext: PipelineCreationFeedbackFlagBits = .application_pipeline_cache_hit_bit;
pub const PipelineCreationFeedbackFlagBits_base_pipeline_acceleration_bit_ext: PipelineCreationFeedbackFlagBits = .base_pipeline_acceleration_bit;

pub const ShaderFloatControlsIndependence = enum(i32) {
    _32_bit_only = 0,
    all = 1,
    none = 2,
    _,
};
pub const ShaderFloatControlsIndependence__32_bit_only_khr: ShaderFloatControlsIndependence = ._32_bit_only;
pub const ShaderFloatControlsIndependence_all_khr: ShaderFloatControlsIndependence = .all;
pub const ShaderFloatControlsIndependence_none_khr: ShaderFloatControlsIndependence = .none;

pub const ToolPurposeFlagBits = enum(i32) {
    _,
};
pub const ToolPurposeFlagBits_validation_bit_ext: ToolPurposeFlagBits = .validation_bit;
pub const ToolPurposeFlagBits_profiling_bit_ext: ToolPurposeFlagBits = .profiling_bit;
pub const ToolPurposeFlagBits_tracing_bit_ext: ToolPurposeFlagBits = .tracing_bit;
pub const ToolPurposeFlagBits_additional_features_bit_ext: ToolPurposeFlagBits = .additional_features_bit;
pub const ToolPurposeFlagBits_modifying_features_bit_ext: ToolPurposeFlagBits = .modifying_features_bit;

pub const AccessFlagBits2 = enum(u64) {
    _2_none = 0,
    _,
};
pub const AccessFlagBits2__2_none_khr: AccessFlagBits2 = ._2_none;
pub const AccessFlagBits2__2_indirect_command_read_bit_khr: AccessFlagBits2 = ._2_indirect_command_read_bit;
pub const AccessFlagBits2__2_index_read_bit_khr: AccessFlagBits2 = ._2_index_read_bit;
pub const AccessFlagBits2__2_vertex_attribute_read_bit_khr: AccessFlagBits2 = ._2_vertex_attribute_read_bit;
pub const AccessFlagBits2__2_uniform_read_bit_khr: AccessFlagBits2 = ._2_uniform_read_bit;
pub const AccessFlagBits2__2_input_attachment_read_bit_khr: AccessFlagBits2 = ._2_input_attachment_read_bit;
pub const AccessFlagBits2__2_shader_read_bit_khr: AccessFlagBits2 = ._2_shader_read_bit;
pub const AccessFlagBits2__2_shader_write_bit_khr: AccessFlagBits2 = ._2_shader_write_bit;
pub const AccessFlagBits2__2_color_attachment_read_bit_khr: AccessFlagBits2 = ._2_color_attachment_read_bit;
pub const AccessFlagBits2__2_color_attachment_write_bit_khr: AccessFlagBits2 = ._2_color_attachment_write_bit;
pub const AccessFlagBits2__2_depth_stencil_attachment_read_bit_khr: AccessFlagBits2 = ._2_depth_stencil_attachment_read_bit;
pub const AccessFlagBits2__2_depth_stencil_attachment_write_bit_khr: AccessFlagBits2 = ._2_depth_stencil_attachment_write_bit;
pub const AccessFlagBits2__2_transfer_read_bit_khr: AccessFlagBits2 = ._2_transfer_read_bit;
pub const AccessFlagBits2__2_transfer_write_bit_khr: AccessFlagBits2 = ._2_transfer_write_bit;
pub const AccessFlagBits2__2_host_read_bit_khr: AccessFlagBits2 = ._2_host_read_bit;
pub const AccessFlagBits2__2_host_write_bit_khr: AccessFlagBits2 = ._2_host_write_bit;
pub const AccessFlagBits2__2_memory_read_bit_khr: AccessFlagBits2 = ._2_memory_read_bit;
pub const AccessFlagBits2__2_memory_write_bit_khr: AccessFlagBits2 = ._2_memory_write_bit;
pub const AccessFlagBits2__2_shader_sampled_read_bit_khr: AccessFlagBits2 = ._2_shader_sampled_read_bit;
pub const AccessFlagBits2__2_shader_storage_read_bit_khr: AccessFlagBits2 = ._2_shader_storage_read_bit;
pub const AccessFlagBits2__2_shader_storage_write_bit_khr: AccessFlagBits2 = ._2_shader_storage_write_bit;
pub const AccessFlagBits2__2_command_preprocess_read_bit_nv: AccessFlagBits2 = ._2_command_preprocess_read_bit_ext;
pub const AccessFlagBits2__2_command_preprocess_write_bit_nv: AccessFlagBits2 = ._2_command_preprocess_write_bit_ext;
pub const AccessFlagBits2__2_shading_rate_image_read_bit_nv: AccessFlagBits2 = ._2_fragment_shading_rate_attachment_read_bit_khr;
pub const AccessFlagBits2__2_acceleration_structure_read_bit_nv: AccessFlagBits2 = ._2_acceleration_structure_read_bit_khr;
pub const AccessFlagBits2__2_acceleration_structure_write_bit_nv: AccessFlagBits2 = ._2_acceleration_structure_write_bit_khr;

pub const PipelineStageFlagBits2 = enum(u64) {
    _2_none = 0,
    _,
};
pub const PipelineStageFlagBits2__2_transfer_bit: PipelineStageFlagBits2 = ._2_all_transfer_bit;
pub const PipelineStageFlagBits2__2_none_khr: PipelineStageFlagBits2 = ._2_none;
pub const PipelineStageFlagBits2__2_top_of_pipe_bit_khr: PipelineStageFlagBits2 = ._2_top_of_pipe_bit;
pub const PipelineStageFlagBits2__2_draw_indirect_bit_khr: PipelineStageFlagBits2 = ._2_draw_indirect_bit;
pub const PipelineStageFlagBits2__2_vertex_input_bit_khr: PipelineStageFlagBits2 = ._2_vertex_input_bit;
pub const PipelineStageFlagBits2__2_vertex_shader_bit_khr: PipelineStageFlagBits2 = ._2_vertex_shader_bit;
pub const PipelineStageFlagBits2__2_tessellation_control_shader_bit_khr: PipelineStageFlagBits2 = ._2_tessellation_control_shader_bit;
pub const PipelineStageFlagBits2__2_tessellation_evaluation_shader_bit_khr: PipelineStageFlagBits2 = ._2_tessellation_evaluation_shader_bit;
pub const PipelineStageFlagBits2__2_geometry_shader_bit_khr: PipelineStageFlagBits2 = ._2_geometry_shader_bit;
pub const PipelineStageFlagBits2__2_fragment_shader_bit_khr: PipelineStageFlagBits2 = ._2_fragment_shader_bit;
pub const PipelineStageFlagBits2__2_early_fragment_tests_bit_khr: PipelineStageFlagBits2 = ._2_early_fragment_tests_bit;
pub const PipelineStageFlagBits2__2_late_fragment_tests_bit_khr: PipelineStageFlagBits2 = ._2_late_fragment_tests_bit;
pub const PipelineStageFlagBits2__2_color_attachment_output_bit_khr: PipelineStageFlagBits2 = ._2_color_attachment_output_bit;
pub const PipelineStageFlagBits2__2_compute_shader_bit_khr: PipelineStageFlagBits2 = ._2_compute_shader_bit;
pub const PipelineStageFlagBits2__2_all_transfer_bit_khr: PipelineStageFlagBits2 = ._2_all_transfer_bit;
pub const PipelineStageFlagBits2__2_transfer_bit_khr: PipelineStageFlagBits2 = ._2_all_transfer_bit;
pub const PipelineStageFlagBits2__2_bottom_of_pipe_bit_khr: PipelineStageFlagBits2 = ._2_bottom_of_pipe_bit;
pub const PipelineStageFlagBits2__2_host_bit_khr: PipelineStageFlagBits2 = ._2_host_bit;
pub const PipelineStageFlagBits2__2_all_graphics_bit_khr: PipelineStageFlagBits2 = ._2_all_graphics_bit;
pub const PipelineStageFlagBits2__2_all_commands_bit_khr: PipelineStageFlagBits2 = ._2_all_commands_bit;
pub const PipelineStageFlagBits2__2_copy_bit_khr: PipelineStageFlagBits2 = ._2_copy_bit;
pub const PipelineStageFlagBits2__2_resolve_bit_khr: PipelineStageFlagBits2 = ._2_resolve_bit;
pub const PipelineStageFlagBits2__2_blit_bit_khr: PipelineStageFlagBits2 = ._2_blit_bit;
pub const PipelineStageFlagBits2__2_clear_bit_khr: PipelineStageFlagBits2 = ._2_clear_bit;
pub const PipelineStageFlagBits2__2_index_input_bit_khr: PipelineStageFlagBits2 = ._2_index_input_bit;
pub const PipelineStageFlagBits2__2_vertex_attribute_input_bit_khr: PipelineStageFlagBits2 = ._2_vertex_attribute_input_bit;
pub const PipelineStageFlagBits2__2_pre_rasterization_shaders_bit_khr: PipelineStageFlagBits2 = ._2_pre_rasterization_shaders_bit;
pub const PipelineStageFlagBits2__2_command_preprocess_bit_nv: PipelineStageFlagBits2 = ._2_command_preprocess_bit_ext;
pub const PipelineStageFlagBits2__2_shading_rate_image_bit_nv: PipelineStageFlagBits2 = ._2_fragment_shading_rate_attachment_bit_khr;
pub const PipelineStageFlagBits2__2_ray_tracing_shader_bit_nv: PipelineStageFlagBits2 = ._2_ray_tracing_shader_bit_khr;
pub const PipelineStageFlagBits2__2_acceleration_structure_build_bit_nv: PipelineStageFlagBits2 = ._2_acceleration_structure_build_bit_khr;
pub const PipelineStageFlagBits2__2_task_shader_bit_nv: PipelineStageFlagBits2 = ._2_task_shader_bit_ext;
pub const PipelineStageFlagBits2__2_mesh_shader_bit_nv: PipelineStageFlagBits2 = ._2_mesh_shader_bit_ext;
pub const PipelineStageFlagBits2__2_subpass_shading_bit_huawei: PipelineStageFlagBits2 = ._2_subpass_shader_bit_huawei;

pub const SubmitFlagBits = enum(i32) {
    _,
};
pub const SubmitFlagBits_protected_bit_khr: SubmitFlagBits = .protected_bit;

pub const EventCreateFlagBits = enum(i32) {
    _,
};
pub const EventCreateFlagBits_device_only_bit_khr: EventCreateFlagBits = .device_only_bit;

pub const PipelineLayoutCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineColorBlendStateCreateFlagBits = enum(i32) {
    _,
};
pub const PipelineColorBlendStateCreateFlagBits_rasterization_order_attachment_access_bit_arm: PipelineColorBlendStateCreateFlagBits = .rasterization_order_attachment_access_bit_ext;

pub const PipelineDepthStencilStateCreateFlagBits = enum(i32) {
    _,
};
pub const PipelineDepthStencilStateCreateFlagBits_rasterization_order_attachment_depth_access_bit_arm: PipelineDepthStencilStateCreateFlagBits = .rasterization_order_attachment_depth_access_bit_ext;
pub const PipelineDepthStencilStateCreateFlagBits_rasterization_order_attachment_stencil_access_bit_arm: PipelineDepthStencilStateCreateFlagBits = .rasterization_order_attachment_stencil_access_bit_ext;

pub const FormatFeatureFlagBits2 = enum(u64) {
    _,
};
pub const FormatFeatureFlagBits2__2_host_image_transfer_bit_ext: FormatFeatureFlagBits2 = ._2_host_image_transfer_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_bit;
pub const FormatFeatureFlagBits2__2_storage_image_bit_khr: FormatFeatureFlagBits2 = ._2_storage_image_bit;
pub const FormatFeatureFlagBits2__2_storage_image_atomic_bit_khr: FormatFeatureFlagBits2 = ._2_storage_image_atomic_bit;
pub const FormatFeatureFlagBits2__2_uniform_texel_buffer_bit_khr: FormatFeatureFlagBits2 = ._2_uniform_texel_buffer_bit;
pub const FormatFeatureFlagBits2__2_storage_texel_buffer_bit_khr: FormatFeatureFlagBits2 = ._2_storage_texel_buffer_bit;
pub const FormatFeatureFlagBits2__2_storage_texel_buffer_atomic_bit_khr: FormatFeatureFlagBits2 = ._2_storage_texel_buffer_atomic_bit;
pub const FormatFeatureFlagBits2__2_vertex_buffer_bit_khr: FormatFeatureFlagBits2 = ._2_vertex_buffer_bit;
pub const FormatFeatureFlagBits2__2_color_attachment_bit_khr: FormatFeatureFlagBits2 = ._2_color_attachment_bit;
pub const FormatFeatureFlagBits2__2_color_attachment_blend_bit_khr: FormatFeatureFlagBits2 = ._2_color_attachment_blend_bit;
pub const FormatFeatureFlagBits2__2_depth_stencil_attachment_bit_khr: FormatFeatureFlagBits2 = ._2_depth_stencil_attachment_bit;
pub const FormatFeatureFlagBits2__2_blit_src_bit_khr: FormatFeatureFlagBits2 = ._2_blit_src_bit;
pub const FormatFeatureFlagBits2__2_blit_dst_bit_khr: FormatFeatureFlagBits2 = ._2_blit_dst_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_filter_linear_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_filter_linear_bit;
pub const FormatFeatureFlagBits2__2_transfer_src_bit_khr: FormatFeatureFlagBits2 = ._2_transfer_src_bit;
pub const FormatFeatureFlagBits2__2_transfer_dst_bit_khr: FormatFeatureFlagBits2 = ._2_transfer_dst_bit;
pub const FormatFeatureFlagBits2__2_midpoint_chroma_samples_bit_khr: FormatFeatureFlagBits2 = ._2_midpoint_chroma_samples_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_ycbcr_conversion_linear_filter_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_ycbcr_conversion_linear_filter_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_ycbcr_conversion_separate_reconstruction_filter_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_ycbcr_conversion_separate_reconstruction_filter_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable_bit;
pub const FormatFeatureFlagBits2__2_disjoint_bit_khr: FormatFeatureFlagBits2 = ._2_disjoint_bit;
pub const FormatFeatureFlagBits2__2_cosited_chroma_samples_bit_khr: FormatFeatureFlagBits2 = ._2_cosited_chroma_samples_bit;
pub const FormatFeatureFlagBits2__2_storage_read_without_format_bit_khr: FormatFeatureFlagBits2 = ._2_storage_read_without_format_bit;
pub const FormatFeatureFlagBits2__2_storage_write_without_format_bit_khr: FormatFeatureFlagBits2 = ._2_storage_write_without_format_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_depth_comparison_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_depth_comparison_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_filter_minmax_bit_khr: FormatFeatureFlagBits2 = ._2_sampled_image_filter_minmax_bit;
pub const FormatFeatureFlagBits2__2_sampled_image_filter_cubic_bit_ext: FormatFeatureFlagBits2 = ._2_sampled_image_filter_cubic_bit;

pub const RenderingFlagBits = enum(i32) {
    _,
};
pub const RenderingFlagBits_contents_secondary_command_buffers_bit_khr: RenderingFlagBits = .contents_secondary_command_buffers_bit;
pub const RenderingFlagBits_suspending_bit_khr: RenderingFlagBits = .suspending_bit;
pub const RenderingFlagBits_resuming_bit_khr: RenderingFlagBits = .resuming_bit;
pub const RenderingFlagBits_contents_inline_bit_ext: RenderingFlagBits = .contents_inline_bit_khr;

pub const InstanceCreateFlagBits = enum(i32) {
    _,
};

// ---- Bitmask flag types ----

pub const FramebufferCreateFlags = packed struct(u32) {
    imageless: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const QueryPoolCreateFlags = packed struct(u32) {
    reset: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const RenderPassCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
    transform: bool = false,
    per_layer_fragment_density: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SamplerCreateFlags = packed struct(u32) {
    subsampled: bool = false,
    subsampled_coarse_reconstruction: bool = false,
    non_seamless_cube_map: bool = false,
    descriptor_buffer_capture_replay: bool = false,
    image_processing: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineLayoutCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
    independent_sets: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineCacheCreateFlags = packed struct(u32) {
    externally_synchronized: bool = false,
    read_only: bool = false,
    use_application_storage: bool = false,
    internally_synchronized_merge: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineDepthStencilStateCreateFlags = packed struct(u32) {
    rasterization_order_attachment_depth_access: bool = false,
    rasterization_order_attachment_stencil_access: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineDynamicStateCreateFlags = u32;

pub const PipelineColorBlendStateCreateFlags = packed struct(u32) {
    rasterization_order_attachment_access: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineMultisampleStateCreateFlags = u32;

pub const PipelineRasterizationStateCreateFlags = u32;

pub const PipelineViewportStateCreateFlags = u32;

pub const PipelineTessellationStateCreateFlags = u32;

pub const PipelineInputAssemblyStateCreateFlags = u32;

pub const PipelineVertexInputStateCreateFlags = u32;

pub const PipelineShaderStageCreateFlags = packed struct(u32) {
    allow_varying_subgroup_size: bool = false,
    require_full_subgroups: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DescriptorSetLayoutCreateFlags = packed struct(u32) {
    push_descriptor: bool = false,
    update_after_bind_pool: bool = false,
    host_only_pool: bool = false,
    _reserved_3: bool = false,
    descriptor_buffer: bool = false,
    embedded_immutable_samplers: bool = false,
    per_stage: bool = false,
    indirect_bindable: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const BufferViewCreateFlags = u32;

pub const InstanceCreateFlags = packed struct(u32) {
    enumerate_portability: bool = false,
    _reserved_616: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DeviceCreateFlags = u32;

pub const DeviceQueueCreateFlags = packed struct(u32) {
    protected: bool = false,
    _reserved_1: bool = false,
    internally_synchronized: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const QueueFlags = packed struct(u32) {
    graphics: bool = false,
    compute: bool = false,
    transfer: bool = false,
    sparse_binding: bool = false,
    protected: bool = false,
    video_decode: bool = false,
    video_encode: bool = false,
    _reserved_7: bool = false,
    optical_flow: bool = false,
    _reserved_9: bool = false,
    data_graph: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const MemoryPropertyFlags = packed struct(u32) {
    device_local: bool = false,
    host_visible: bool = false,
    host_coherent: bool = false,
    host_cached: bool = false,
    lazily_allocated: bool = false,
    protected: bool = false,
    device_coherent: bool = false,
    device_uncached: bool = false,
    rdma_capable: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const MemoryHeapFlags = packed struct(u32) {
    device_local: bool = false,
    multi_instance: bool = false,
    seu_safe: bool = false,
    tile_memory: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const AccessFlags = packed struct(u32) {
    indirect_command_read: bool = false,
    index_read: bool = false,
    vertex_attribute_read: bool = false,
    uniform_read: bool = false,
    input_attachment_read: bool = false,
    shader_read: bool = false,
    shader_write: bool = false,
    color_attachment_read: bool = false,
    color_attachment_write: bool = false,
    depth_stencil_attachment_read: bool = false,
    depth_stencil_attachment_write: bool = false,
    transfer_read: bool = false,
    transfer_write: bool = false,
    host_read: bool = false,
    host_write: bool = false,
    memory_read: bool = false,
    memory_write: bool = false,
    command_preprocess_read: bool = false,
    command_preprocess_write: bool = false,
    color_attachment_read_noncoherent: bool = false,
    conditional_rendering_read: bool = false,
    acceleration_structure_read: bool = false,
    acceleration_structure_write: bool = false,
    fragment_shading_rate_attachment_read: bool = false,
    fragment_density_map_read: bool = false,
    transform_feedback_write: bool = false,
    transform_feedback_counter_read: bool = false,
    transform_feedback_counter_write: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const BufferUsageFlags = packed struct(u32) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    uniform_texel_buffer: bool = false,
    storage_texel_buffer: bool = false,
    uniform_buffer: bool = false,
    storage_buffer: bool = false,
    index_buffer: bool = false,
    vertex_buffer: bool = false,
    indirect_buffer: bool = false,
    conditional_rendering: bool = false,
    shader_binding_table: bool = false,
    transform_feedback_buffer: bool = false,
    transform_feedback_counter_buffer: bool = false,
    video_decode_src: bool = false,
    video_decode_dst: bool = false,
    video_encode_dst: bool = false,
    video_encode_src: bool = false,
    shader_device_address: bool = false,
    _reserved_18: bool = false,
    acceleration_structure_build_input_read_only: bool = false,
    acceleration_structure_storage: bool = false,
    sampler_descriptor_buffer: bool = false,
    resource_descriptor_buffer: bool = false,
    micromap_build_input_read_only: bool = false,
    micromap_storage: bool = false,
    execution_graph_scratch_bit_amdx: bool = false,
    push_descriptors_descriptor_buffer: bool = false,
    tile_memory: bool = false,
    descriptor_heap: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const BufferCreateFlags = packed struct(u32) {
    sparse_binding: bool = false,
    sparse_residency: bool = false,
    sparse_aliased: bool = false,
    protected: bool = false,
    device_address_capture_replay: bool = false,
    descriptor_buffer_capture_replay: bool = false,
    video_profile_independent: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ShaderStageFlags = packed struct(u32) {
    vertex: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    geometry: bool = false,
    fragment: bool = false,
    compute: bool = false,
    task: bool = false,
    mesh: bool = false,
    raygen: bool = false,
    any_hit: bool = false,
    closest_hit: bool = false,
    miss: bool = false,
    intersection: bool = false,
    callable: bool = false,
    subpass_shading: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    cluster_culling: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ImageUsageFlags = packed struct(u32) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transient_attachment: bool = false,
    input_attachment: bool = false,
    fragment_shading_rate_attachment: bool = false,
    fragment_density_map: bool = false,
    video_decode_dst: bool = false,
    video_decode_src: bool = false,
    video_decode_dpb: bool = false,
    video_encode_dst: bool = false,
    video_encode_src: bool = false,
    video_encode_dpb: bool = false,
    _reserved_16: bool = false,
    _reserved_27: bool = false,
    invocation_mask: bool = false,
    attachment_feedback_loop: bool = false,
    sample_weight: bool = false,
    sample_block_match: bool = false,
    host_transfer: bool = false,
    tensor_aliasing: bool = false,
    _reserved_24_bit_coreavi: bool = false,
    video_encode_quantization_delta_map: bool = false,
    video_encode_emphasis_map: bool = false,
    tile_memory: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ImageCreateFlags = packed struct(u32) {
    sparse_binding: bool = false,
    sparse_residency: bool = false,
    sparse_aliased: bool = false,
    mutable_format: bool = false,
    cube_compatible: bool = false,
    _2d_array_compatible: bool = false,
    split_instance_bind_regions: bool = false,
    block_texel_view_compatible: bool = false,
    extended_usage: bool = false,
    disjoint: bool = false,
    alias: bool = false,
    protected: bool = false,
    sample_locations_compatible_depth: bool = false,
    corner_sampled: bool = false,
    subsampled: bool = false,
    fragment_density_map_offset: bool = false,
    descriptor_heap_capture_replay: bool = false,
    _2d_view_compatible: bool = false,
    multisampled_render_to_single_sampled: bool = false,
    _reserved_19: bool = false,
    video_profile_independent: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ImageViewCreateFlags = packed struct(u32) {
    fragment_density_map_dynamic: bool = false,
    fragment_density_map_deferred: bool = false,
    descriptor_buffer_capture_replay: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineCreateFlags = packed struct(u32) {
    disable_optimization: bool = false,
    allow_derivatives: bool = false,
    derivative: bool = false,
    view_index_from_device_index: bool = false,
    dispatch_base: bool = false,
    defer_compile: bool = false,
    capture_statistics: bool = false,
    capture_internal_representations: bool = false,
    fail_on_pipeline_compile_required: bool = false,
    early_return_on_failure: bool = false,
    link_time_optimization: bool = false,
    library: bool = false,
    ray_tracing_skip_triangles: bool = false,
    ray_tracing_skip_aabbs: bool = false,
    ray_tracing_no_null_any_hit_shaders: bool = false,
    ray_tracing_no_null_closest_hit_shaders: bool = false,
    ray_tracing_no_null_miss_shaders: bool = false,
    ray_tracing_no_null_intersection_shaders: bool = false,
    indirect_bindable: bool = false,
    ray_tracing_shader_group_handle_capture_replay: bool = false,
    ray_tracing_allow_motion: bool = false,
    rendering_fragment_shading_rate_attachment: bool = false,
    rendering_fragment_density_map_attachment: bool = false,
    retain_link_time_optimization_info: bool = false,
    ray_tracing_opacity_micromap: bool = false,
    color_attachment_feedback_loop: bool = false,
    depth_stencil_attachment_feedback_loop: bool = false,
    no_protected_access: bool = false,
    ray_tracing_displacement_micromap: bool = false,
    descriptor_buffer: bool = false,
    protected_access_only: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ColorComponentFlags = packed struct(u32) {
    r: bool = false,
    g: bool = false,
    b: bool = false,
    a: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const FenceCreateFlags = packed struct(u32) {
    signaled: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SemaphoreCreateFlags = u32;

pub const FormatFeatureFlags = packed struct(u32) {
    sampled_image: bool = false,
    storage_image: bool = false,
    storage_image_atomic: bool = false,
    uniform_texel_buffer: bool = false,
    storage_texel_buffer: bool = false,
    storage_texel_buffer_atomic: bool = false,
    vertex_buffer: bool = false,
    color_attachment: bool = false,
    color_attachment_blend: bool = false,
    depth_stencil_attachment: bool = false,
    blit_src: bool = false,
    blit_dst: bool = false,
    sampled_image_filter_linear: bool = false,
    sampled_image_filter_cubic: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled_image_filter_minmax: bool = false,
    midpoint_chroma_samples: bool = false,
    sampled_image_ycbcr_conversion_linear_filter: bool = false,
    sampled_image_ycbcr_conversion_separate_reconstruction_filter: bool = false,
    sampled_image_ycbcr_conversion_chroma_reconstruction_explicit: bool = false,
    sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable: bool = false,
    disjoint: bool = false,
    cosited_chroma_samples: bool = false,
    fragment_density_map: bool = false,
    video_decode_output: bool = false,
    video_decode_dpb: bool = false,
    video_encode_input: bool = false,
    video_encode_dpb: bool = false,
    acceleration_structure_vertex_buffer: bool = false,
    fragment_shading_rate_attachment: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const QueryControlFlags = packed struct(u32) {
    precise: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const QueryResultFlags = packed struct(u32) {
    _64: bool = false,
    wait: bool = false,
    with_availability: bool = false,
    partial: bool = false,
    with_status: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ShaderModuleCreateFlags = u32;

pub const EventCreateFlags = packed struct(u32) {
    device_only: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CommandPoolCreateFlags = packed struct(u32) {
    transient: bool = false,
    reset_command_buffer: bool = false,
    protected: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CommandPoolResetFlags = packed struct(u32) {
    release_resources: bool = false,
    _reserved_1_bit_coreavi: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CommandBufferResetFlags = packed struct(u32) {
    release_resources: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CommandBufferUsageFlags = packed struct(u32) {
    one_time_submit: bool = false,
    render_pass_continue: bool = false,
    simultaneous_use: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const QueryPipelineStatisticFlags = packed struct(u32) {
    input_assembly_vertices: bool = false,
    input_assembly_primitives: bool = false,
    vertex_shader_invocations: bool = false,
    geometry_shader_invocations: bool = false,
    geometry_shader_primitives: bool = false,
    clipping_invocations: bool = false,
    clipping_primitives: bool = false,
    fragment_shader_invocations: bool = false,
    tessellation_control_shader_patches: bool = false,
    tessellation_evaluation_shader_invocations: bool = false,
    compute_shader_invocations: bool = false,
    task_shader_invocations: bool = false,
    mesh_shader_invocations: bool = false,
    cluster_culling_shader_invocations: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const MemoryMapFlags = packed struct(u32) {
    placed: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ImageAspectFlags = packed struct(u32) {
    color: bool = false,
    depth: bool = false,
    stencil: bool = false,
    metadata: bool = false,
    plane_0: bool = false,
    plane_1: bool = false,
    plane_2: bool = false,
    memory_plane_0: bool = false,
    memory_plane_1: bool = false,
    memory_plane_2: bool = false,
    memory_plane_3: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SparseMemoryBindFlags = packed struct(u32) {
    metadata: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SparseImageFormatFlags = packed struct(u32) {
    single_miptail: bool = false,
    aligned_mip_size: bool = false,
    nonstandard_block_size: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SubpassDescriptionFlags = packed struct(u32) {
    per_view_attributes_bit_nvx: bool = false,
    per_view_position_x_only_bit_nvx: bool = false,
    fragment_region: bool = false,
    custom_resolve: bool = false,
    rasterization_order_attachment_color_access: bool = false,
    rasterization_order_attachment_depth_access: bool = false,
    rasterization_order_attachment_stencil_access: bool = false,
    enable_legacy_dithering: bool = false,
    tile_shading_apron: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineStageFlags = packed struct(u32) {
    top_of_pipe: bool = false,
    draw_indirect: bool = false,
    vertex_input: bool = false,
    vertex_shader: bool = false,
    tessellation_control_shader: bool = false,
    tessellation_evaluation_shader: bool = false,
    geometry_shader: bool = false,
    fragment_shader: bool = false,
    early_fragment_tests: bool = false,
    late_fragment_tests: bool = false,
    color_attachment_output: bool = false,
    compute_shader: bool = false,
    transfer: bool = false,
    bottom_of_pipe: bool = false,
    host: bool = false,
    all_graphics: bool = false,
    all_commands: bool = false,
    command_preprocess: bool = false,
    conditional_rendering: bool = false,
    task_shader: bool = false,
    mesh_shader: bool = false,
    ray_tracing_shader: bool = false,
    fragment_shading_rate_attachment: bool = false,
    fragment_density_process: bool = false,
    transform_feedback: bool = false,
    acceleration_structure_build: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SampleCountFlags = packed struct(u32) {
    _1: bool = false,
    _2: bool = false,
    _4: bool = false,
    _8: bool = false,
    _16: bool = false,
    _32: bool = false,
    _64: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const AttachmentDescriptionFlags = packed struct(u32) {
    may_alias: bool = false,
    resolve_skip_transfer_function: bool = false,
    resolve_enable_transfer_function: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const StencilFaceFlags = packed struct(u32) {
    front: bool = false,
    back: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CullModeFlags = packed struct(u32) {
    front: bool = false,
    back: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DescriptorPoolCreateFlags = packed struct(u32) {
    free_descriptor_set: bool = false,
    update_after_bind: bool = false,
    host_only: bool = false,
    allow_overallocation_sets: bool = false,
    allow_overallocation_pools: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DescriptorPoolResetFlags = u32;

pub const DependencyFlags = packed struct(u32) {
    by_region: bool = false,
    view_local: bool = false,
    device_group: bool = false,
    feedback_loop: bool = false,
    extension_586: bool = false,
    queue_family_ownership_transfer_use_all_stages: bool = false,
    asymmetric_event: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SubgroupFeatureFlags = packed struct(u32) {
    basic: bool = false,
    vote: bool = false,
    arithmetic: bool = false,
    ballot: bool = false,
    shuffle: bool = false,
    shuffle_relative: bool = false,
    clustered: bool = false,
    quad: bool = false,
    partitioned: bool = false,
    rotate: bool = false,
    rotate_clustered: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const PrivateDataSlotCreateFlags = u32;

pub const DescriptorUpdateTemplateCreateFlags = u32;

pub const PipelineCreationFeedbackFlags = packed struct(u32) {
    valid: bool = false,
    application_pipeline_cache_hit: bool = false,
    base_pipeline_acceleration: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SemaphoreWaitFlags = packed struct(u32) {
    any: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const AccessFlags2 = packed struct(u64) {
    _2_indirect_command_read: bool = false,
    _2_index_read: bool = false,
    _2_vertex_attribute_read: bool = false,
    _2_uniform_read: bool = false,
    _2_input_attachment_read: bool = false,
    _2_shader_read: bool = false,
    _2_shader_write: bool = false,
    _2_color_attachment_read: bool = false,
    _2_color_attachment_write: bool = false,
    _2_depth_stencil_attachment_read: bool = false,
    _2_depth_stencil_attachment_write: bool = false,
    _2_transfer_read: bool = false,
    _2_transfer_write: bool = false,
    _2_host_read: bool = false,
    _2_host_write: bool = false,
    _2_memory_read: bool = false,
    _2_memory_write: bool = false,
    _2_command_preprocess_read: bool = false,
    _2_command_preprocess_write: bool = false,
    _2_color_attachment_read_noncoherent: bool = false,
    _2_conditional_rendering_read: bool = false,
    _2_acceleration_structure_read: bool = false,
    _2_acceleration_structure_write: bool = false,
    _2_fragment_shading_rate_attachment_read: bool = false,
    _2_fragment_density_map_read: bool = false,
    _2_transform_feedback_write: bool = false,
    _2_transform_feedback_counter_read: bool = false,
    _2_transform_feedback_counter_write: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,
    _2_shader_sampled_read: bool = false,
    _2_shader_storage_read: bool = false,
    _2_shader_storage_write: bool = false,
    _2_video_decode_read: bool = false,
    _2_video_decode_write: bool = false,
    _2_video_encode_read: bool = false,
    _2_video_encode_write: bool = false,
    _2_invocation_mask_read: bool = false,
    _2_shader_binding_table_read: bool = false,
    _2_descriptor_buffer_read: bool = false,
    _2_optical_flow_read: bool = false,
    _2_optical_flow_write: bool = false,
    _2_micromap_read: bool = false,
    _2_micromap_write: bool = false,
    _2_reserved_46: bool = false,
    _2_data_graph_read: bool = false,
    _2_data_graph_write: bool = false,
    _2_reserved_49: bool = false,
    _2_reserved_50: bool = false,
    _2_shader_tile_attachment_read: bool = false,
    _2_shader_tile_attachment_write: bool = false,
    _reserved_53: bool = false,
    _reserved_54: bool = false,
    _2_memory_decompression_read: bool = false,
    _2_memory_decompression_write: bool = false,
    _2_sampler_heap_read: bool = false,
    _2_resource_heap_read: bool = false,
    _reserved_59: bool = false,
    _2_reserved_60: bool = false,
    _2_reserved_61: bool = false,
    _2_reserved_62: bool = false,
    _2_reserved_63: bool = false,

    pub const empty: @This() = .{};
};

pub const PipelineStageFlags2 = packed struct(u64) {
    _2_top_of_pipe: bool = false,
    _2_draw_indirect: bool = false,
    _2_vertex_input: bool = false,
    _2_vertex_shader: bool = false,
    _2_tessellation_control_shader: bool = false,
    _2_tessellation_evaluation_shader: bool = false,
    _2_geometry_shader: bool = false,
    _2_fragment_shader: bool = false,
    _2_early_fragment_tests: bool = false,
    _2_late_fragment_tests: bool = false,
    _2_color_attachment_output: bool = false,
    _2_compute_shader: bool = false,
    _2_all_transfer: bool = false,
    _2_bottom_of_pipe: bool = false,
    _2_host: bool = false,
    _2_all_graphics: bool = false,
    _2_all_commands: bool = false,
    _2_command_preprocess: bool = false,
    _2_conditional_rendering: bool = false,
    _2_task_shader: bool = false,
    _2_mesh_shader: bool = false,
    _2_ray_tracing_shader: bool = false,
    _2_fragment_shading_rate_attachment: bool = false,
    _2_fragment_density_process: bool = false,
    _2_transform_feedback: bool = false,
    _2_acceleration_structure_build: bool = false,
    _2_video_decode: bool = false,
    _2_video_encode: bool = false,
    _2_acceleration_structure_copy: bool = false,
    _2_optical_flow: bool = false,
    _2_micromap_build: bool = false,
    _reserved_31: bool = false,
    _2_copy: bool = false,
    _2_resolve: bool = false,
    _2_blit: bool = false,
    _2_clear: bool = false,
    _2_index_input: bool = false,
    _2_vertex_attribute_input: bool = false,
    _2_pre_rasterization_shaders: bool = false,
    _2_subpass_shader: bool = false,
    _2_invocation_mask: bool = false,
    _2_cluster_culling_shader: bool = false,
    _2_data_graph: bool = false,
    _2_reserved_43: bool = false,
    _2_convert_cooperative_vector_matrix: bool = false,
    _2_memory_decompression: bool = false,
    _2_copy_indirect: bool = false,
    _2_reserved_47: bool = false,
    _2_reserved_48: bool = false,
    _2_reserved_49: bool = false,
    _reserved_50: bool = false,
    _reserved_51: bool = false,
    _reserved_52: bool = false,
    _reserved_53: bool = false,
    _reserved_54: bool = false,
    _reserved_55: bool = false,
    _reserved_56: bool = false,
    _reserved_57: bool = false,
    _reserved_58: bool = false,
    _reserved_59: bool = false,
    _reserved_60: bool = false,
    _reserved_61: bool = false,
    _reserved_62: bool = false,
    _reserved_63: bool = false,

    pub const empty: @This() = .{};
};

pub const FormatFeatureFlags2 = packed struct(u64) {
    _2_sampled_image: bool = false,
    _2_storage_image: bool = false,
    _2_storage_image_atomic: bool = false,
    _2_uniform_texel_buffer: bool = false,
    _2_storage_texel_buffer: bool = false,
    _2_storage_texel_buffer_atomic: bool = false,
    _2_vertex_buffer: bool = false,
    _2_color_attachment: bool = false,
    _2_color_attachment_blend: bool = false,
    _2_depth_stencil_attachment: bool = false,
    _2_blit_src: bool = false,
    _2_blit_dst: bool = false,
    _2_sampled_image_filter_linear: bool = false,
    _2_sampled_image_filter_cubic: bool = false,
    _2_transfer_src: bool = false,
    _2_transfer_dst: bool = false,
    _2_sampled_image_filter_minmax: bool = false,
    _2_midpoint_chroma_samples: bool = false,
    _2_sampled_image_ycbcr_conversion_linear_filter: bool = false,
    _2_sampled_image_ycbcr_conversion_separate_reconstruction_filter: bool = false,
    _2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit: bool = false,
    _2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable: bool = false,
    _2_disjoint: bool = false,
    _2_cosited_chroma_samples: bool = false,
    _2_fragment_density_map: bool = false,
    _2_video_decode_output: bool = false,
    _2_video_decode_dpb: bool = false,
    _2_video_encode_input: bool = false,
    _2_video_encode_dpb: bool = false,
    _2_acceleration_structure_vertex_buffer: bool = false,
    _2_fragment_shading_rate_attachment: bool = false,
    _2_storage_read_without_format: bool = false,
    _2_storage_write_without_format: bool = false,
    _2_sampled_image_depth_comparison: bool = false,
    _2_weight_image: bool = false,
    _2_weight_sampled_image: bool = false,
    _2_block_matching: bool = false,
    _2_box_filter_sampled: bool = false,
    _2_linear_color_attachment: bool = false,
    _2_tensor_shader: bool = false,
    _2_optical_flow_image: bool = false,
    _2_optical_flow_vector: bool = false,
    _2_optical_flow_cost: bool = false,
    _2_tensor_image_aliasing: bool = false,
    _2_reserved_44: bool = false,
    _reserved_45: bool = false,
    _2_host_image_transfer: bool = false,
    _2_reserved_47: bool = false,
    _2_tensor_data_graph: bool = false,
    _2_video_encode_quantization_delta_map: bool = false,
    _2_video_encode_emphasis_map: bool = false,
    _2_acceleration_structure_radius_buffer: bool = false,
    _2_depth_copy_on_compute_queue: bool = false,
    _2_depth_copy_on_transfer_queue: bool = false,
    _2_stencil_copy_on_compute_queue: bool = false,
    _2_stencil_copy_on_transfer_queue: bool = false,
    _2_reserved_56: bool = false,
    _2_reserved_57: bool = false,
    _2_reserved_58: bool = false,
    _2_copy_image_indirect_dst: bool = false,
    _2_reserved_60: bool = false,
    _2_reserved_61: bool = false,
    _reserved_62: bool = false,
    _reserved_63: bool = false,

    pub const empty: @This() = .{};
};

pub const RenderingFlags = packed struct(u32) {
    contents_secondary_command_buffers: bool = false,
    suspending: bool = false,
    resuming: bool = false,
    enable_legacy_dithering: bool = false,
    contents_inline: bool = false,
    per_layer_fragment_density: bool = false,
    fragment_region: bool = false,
    custom_resolve: bool = false,
    local_read_concurrent_access_control: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CompositeAlphaFlagsKHR = packed struct(u32) {
    @"opaque": bool = false,
    pre_multiplied: bool = false,
    post_multiplied: bool = false,
    inherit: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SurfaceTransformFlagsKHR = packed struct(u32) {
    identity: bool = false,
    rotate_90: bool = false,
    rotate_180: bool = false,
    rotate_270: bool = false,
    horizontal_mirror: bool = false,
    horizontal_mirror_rotate_90: bool = false,
    horizontal_mirror_rotate_180: bool = false,
    horizontal_mirror_rotate_270: bool = false,
    inherit: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SwapchainCreateFlagsKHR = packed struct(u32) {
    split_instance_bind_regions: bool = false,
    protected: bool = false,
    mutable_format: bool = false,
    deferred_memory_allocation: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    present_id_2: bool = false,
    present_wait_2: bool = false,
    _reserved_8: bool = false,
    present_timing: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const WaylandSurfaceCreateFlagsKHR = u32;

pub const Win32SurfaceCreateFlagsKHR = u32;

pub const PeerMemoryFeatureFlags = packed struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    generic_src: bool = false,
    generic_dst: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const MemoryAllocateFlags = packed struct(u32) {
    device_mask: bool = false,
    device_address: bool = false,
    device_address_capture_replay: bool = false,
    zero_initialize: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DeviceGroupPresentModeFlagsKHR = packed struct(u32) {
    local: bool = false,
    remote: bool = false,
    sum: bool = false,
    local_multi_device: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const CommandPoolTrimFlags = u32;

pub const ExternalMemoryHandleTypeFlags = packed struct(u32) {
    opaque_fd: bool = false,
    opaque_win32: bool = false,
    opaque_win32_kmt: bool = false,
    d3d11_texture: bool = false,
    d3d11_texture_kmt: bool = false,
    d3d12_heap: bool = false,
    d3d12_resource: bool = false,
    host_allocation: bool = false,
    host_mapped_foreign_memory: bool = false,
    dma_buf: bool = false,
    android_hardware_buffer: bool = false,
    zircon_vmo: bool = false,
    rdma_address: bool = false,
    sci_buf: bool = false,
    screen_buffer: bool = false,
    oh_native_buffer_bit_ohos: bool = false,
    mtlbuffer: bool = false,
    mtltexture: bool = false,
    mtlheap: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ExternalMemoryFeatureFlags = packed struct(u32) {
    dedicated_only: bool = false,
    exportable: bool = false,
    importable: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ExternalSemaphoreHandleTypeFlags = packed struct(u32) {
    opaque_fd: bool = false,
    opaque_win32: bool = false,
    opaque_win32_kmt: bool = false,
    d3d12_fence: bool = false,
    sync_fd: bool = false,
    sci_sync_obj: bool = false,
    _reserved_6: bool = false,
    zircon_event: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ExternalSemaphoreFeatureFlags = packed struct(u32) {
    exportable: bool = false,
    importable: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SemaphoreImportFlags = packed struct(u32) {
    temporary: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ExternalFenceHandleTypeFlags = packed struct(u32) {
    opaque_fd: bool = false,
    opaque_win32: bool = false,
    opaque_win32_kmt: bool = false,
    sync_fd: bool = false,
    sci_sync_obj: bool = false,
    sci_sync_fence: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ExternalFenceFeatureFlags = packed struct(u32) {
    exportable: bool = false,
    importable: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const FenceImportFlags = packed struct(u32) {
    temporary: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DebugUtilsMessageSeverityFlagsEXT = packed struct(u32) {
    verbose: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    info: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    warning: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    @"error": bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DebugUtilsMessageTypeFlagsEXT = packed struct(u32) {
    general: bool = false,
    validation: bool = false,
    performance: bool = false,
    device_address_binding: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const DebugUtilsMessengerCreateFlagsEXT = u32;

pub const DebugUtilsMessengerCallbackDataFlagsEXT = u32;

pub const DescriptorBindingFlags = packed struct(u32) {
    update_after_bind: bool = false,
    update_unused_while_pending: bool = false,
    partially_bound: bool = false,
    variable_descriptor_count: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ResolveModeFlags = packed struct(u32) {
    sample_zero: bool = false,
    average: bool = false,
    min: bool = false,
    max: bool = false,
    external_format_downsample: bool = false,
    custom: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const ToolPurposeFlags = packed struct(u32) {
    validation: bool = false,
    profiling: bool = false,
    tracing: bool = false,
    additional_features: bool = false,
    modifying_features: bool = false,
    debug_reporting: bool = false,
    debug_markers: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

pub const SubmitFlags = packed struct(u32) {
    protected: bool = false,
    _reserved_1: bool = false,
    _reserved_2: bool = false,
    _reserved_3: bool = false,
    _reserved_4: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    _reserved_8: bool = false,
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    _reserved_17: bool = false,
    _reserved_18: bool = false,
    _reserved_19: bool = false,
    _reserved_20: bool = false,
    _reserved_21: bool = false,
    _reserved_22: bool = false,
    _reserved_23: bool = false,
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _reserved_31: bool = false,

    pub const empty: @This() = .{};
};

// ---- Function pointer typedefs (callbacks) ----
// Emitted as opaque pointers in S2; the C decl is preserved as a comment
// for hand-casting at call sites. Replaced by typed signatures in S3.

// void PFN_vkInternalAllocationNotification
// void*                       pUserData
// size_t                      size
// VkInternalAllocationType    allocationType
// VkSystemAllocationScope     allocationScope
pub const PFN_vkInternalAllocationNotification = ?*const anyopaque;

// void PFN_vkInternalFreeNotification
// void*                       pUserData
// size_t                      size
// VkInternalAllocationType    allocationType
// VkSystemAllocationScope     allocationScope
pub const PFN_vkInternalFreeNotification = ?*const anyopaque;

// void* PFN_vkReallocationFunction
// void*                       pUserData
// void*                       pOriginal
// size_t                      size
// size_t                      alignment
// VkSystemAllocationScope     allocationScope
pub const PFN_vkReallocationFunction = ?*const anyopaque;

// void* PFN_vkAllocationFunction
// void*                       pUserData
// size_t                      size
// size_t                      alignment
// VkSystemAllocationScope     allocationScope
pub const PFN_vkAllocationFunction = ?*const anyopaque;

// void PFN_vkFreeFunction
// void*                       pUserData
// void*                       pMemory
pub const PFN_vkFreeFunction = ?*const anyopaque;

// void PFN_vkVoidFunction
pub const PFN_vkVoidFunction = ?*const anyopaque;

// VkBool32 PFN_vkDebugUtilsMessengerCallbackEXT
// VkDebugUtilsMessageSeverityFlagBitsEXT      messageSeverity
// VkDebugUtilsMessageTypeFlagsEXT             messageTypes
// const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData
// void*                                       pUserData
pub const PFN_vkDebugUtilsMessengerCallbackEXT = ?*const anyopaque;

// ---- Structs ----

pub const BaseOutStructure = extern struct {
    s_type: StructureType,
    p_next: ?*BaseOutStructure = null,
};

pub const BaseInStructure = extern struct {
    s_type: StructureType,
    p_next: ?*const BaseInStructure = null,
};

pub const Offset2D = extern struct {
    x: i32,
    y: i32,
};

pub const Offset3D = extern struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Extent2D = extern struct {
    width: u32,
    height: u32,
};

pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const Viewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

pub const Rect2D = extern struct {
    offset: Offset2D,
    extent: Extent2D,
};

pub const ClearRect = extern struct {
    rect: Rect2D,
    base_array_layer: u32,
    layer_count: u32,
};

pub const ComponentMapping = extern struct {
    r: ComponentSwizzle,
    g: ComponentSwizzle,
    b: ComponentSwizzle,
    a: ComponentSwizzle,
};

pub const PhysicalDeviceProperties = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: PhysicalDeviceType,
    device_name: [MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    pipeline_cache_uuid: [UUID_SIZE]u8,
    limits: PhysicalDeviceLimits,
    sparse_properties: PhysicalDeviceSparseProperties,
};

pub const ExtensionProperties = extern struct {
    extension_name: [MAX_EXTENSION_NAME_SIZE]u8,
    spec_version: u32,
};

pub const LayerProperties = extern struct {
    layer_name: [MAX_EXTENSION_NAME_SIZE]u8,
    spec_version: u32,
    implementation_version: u32,
    description: [MAX_DESCRIPTION_SIZE]u8,
};

pub const ApplicationInfo = extern struct {
    s_type: StructureType = .application_info,
    p_next: ?*const anyopaque = null,
    p_application_name: ?[*:0]const u8,
    application_version: u32,
    p_engine_name: ?[*:0]const u8,
    engine_version: u32,
    api_version: u32,
};

pub const AllocationCallbacks = extern struct {
    p_user_data: ?*anyopaque,
    pfn_allocation: PFN_vkAllocationFunction,
    pfn_reallocation: PFN_vkReallocationFunction,
    pfn_free: PFN_vkFreeFunction,
    pfn_internal_allocation: PFN_vkInternalAllocationNotification,
    pfn_internal_free: PFN_vkInternalFreeNotification,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = .device_queue_create_info,
    p_next: ?*const anyopaque = null,
    flags: DeviceQueueCreateFlags,
    queue_family_index: u32,
    queue_count: u32,
    p_queue_priorities: *const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = .device_create_info,
    p_next: ?*const anyopaque = null,
    flags: DeviceCreateFlags,
    queue_create_info_count: u32,
    p_queue_create_infos: *const DeviceQueueCreateInfo,
    enabled_layer_count: u32,
    pp_enabled_layer_names: [*]const [*:0]const u8,
    enabled_extension_count: u32,
    pp_enabled_extension_names: [*]const [*:0]const u8,
    p_enabled_features: ?*const PhysicalDeviceFeatures,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = .instance_create_info,
    p_next: ?*const anyopaque = null,
    flags: InstanceCreateFlags,
    p_application_info: ?*const ApplicationInfo,
    enabled_layer_count: u32,
    pp_enabled_layer_names: [*]const [*:0]const u8,
    enabled_extension_count: u32,
    pp_enabled_extension_names: [*]const [*:0]const u8,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: QueueFlags,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [MAX_MEMORY_TYPES]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [MAX_MEMORY_HEAPS]MemoryHeap,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = .memory_allocate_info,
    p_next: ?*const anyopaque = null,
    allocation_size: DeviceSize,
    memory_type_index: u32,
};

pub const MemoryRequirements = extern struct {
    size: DeviceSize,
    alignment: DeviceSize,
    memory_type_bits: u32,
};

pub const SparseImageFormatProperties = extern struct {
    aspect_mask: ImageAspectFlags,
    image_granularity: Extent3D,
    flags: SparseImageFormatFlags,
};

pub const SparseImageMemoryRequirements = extern struct {
    format_properties: SparseImageFormatProperties,
    image_mip_tail_first_lod: u32,
    image_mip_tail_size: DeviceSize,
    image_mip_tail_offset: DeviceSize,
    image_mip_tail_stride: DeviceSize,
};

pub const MemoryType = extern struct {
    property_flags: MemoryPropertyFlags,
    heap_index: u32,
};

pub const MemoryHeap = extern struct {
    size: DeviceSize,
    flags: MemoryHeapFlags,
};

pub const MappedMemoryRange = extern struct {
    s_type: StructureType = .mapped_memory_range,
    p_next: ?*const anyopaque = null,
    memory: DeviceMemory,
    offset: DeviceSize,
    size: DeviceSize,
};

pub const FormatProperties = extern struct {
    linear_tiling_features: FormatFeatureFlags,
    optimal_tiling_features: FormatFeatureFlags,
    buffer_features: FormatFeatureFlags,
};

pub const ImageFormatProperties = extern struct {
    max_extent: Extent3D,
    max_mip_levels: u32,
    max_array_layers: u32,
    sample_counts: SampleCountFlags,
    max_resource_size: DeviceSize,
};

pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: DeviceSize,
    range: DeviceSize,
};

pub const DescriptorImageInfo = extern struct {
    sampler: Sampler,
    image_view: ImageView,
    image_layout: ImageLayout,
};

pub const WriteDescriptorSet = extern struct {
    s_type: StructureType = .write_descriptor_set,
    p_next: ?*const anyopaque = null,
    dst_set: DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32,
    descriptor_count: u32,
    descriptor_type: DescriptorType,
    p_image_info: *const DescriptorImageInfo,
    p_buffer_info: *const DescriptorBufferInfo,
    p_texel_buffer_view: *const BufferView,
};

pub const CopyDescriptorSet = extern struct {
    s_type: StructureType = .copy_descriptor_set,
    p_next: ?*const anyopaque = null,
    src_set: DescriptorSet,
    src_binding: u32,
    src_array_element: u32,
    dst_set: DescriptorSet,
    dst_binding: u32,
    dst_array_element: u32,
    descriptor_count: u32,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = .buffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: BufferCreateFlags,
    size: DeviceSize,
    usage: BufferUsageFlags,
    sharing_mode: SharingMode,
    queue_family_index_count: u32,
    p_queue_family_indices: *const u32,
};

pub const BufferViewCreateInfo = extern struct {
    s_type: StructureType = .buffer_view_create_info,
    p_next: ?*const anyopaque = null,
    flags: BufferViewCreateFlags,
    buffer: Buffer,
    format: Format,
    offset: DeviceSize,
    range: DeviceSize,
};

pub const ImageSubresource = extern struct {
    aspect_mask: ImageAspectFlags,
    mip_level: u32,
    array_layer: u32,
};

pub const ImageSubresourceLayers = extern struct {
    aspect_mask: ImageAspectFlags,
    mip_level: u32,
    base_array_layer: u32,
    layer_count: u32,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: ImageAspectFlags,
    base_mip_level: u32,
    level_count: u32,
    base_array_layer: u32,
    layer_count: u32,
};

pub const MemoryBarrier = extern struct {
    s_type: StructureType = .memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
};

pub const BufferMemoryBarrier = extern struct {
    s_type: StructureType = .buffer_memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    src_queue_family_index: u32,
    dst_queue_family_index: u32,
    buffer: Buffer,
    offset: DeviceSize,
    size: DeviceSize,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: StructureType = .image_memory_barrier,
    p_next: ?*const anyopaque = null,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    old_layout: ImageLayout,
    new_layout: ImageLayout,
    src_queue_family_index: u32,
    dst_queue_family_index: u32,
    image: Image,
    subresource_range: ImageSubresourceRange,
};

pub const ImageCreateInfo = extern struct {
    s_type: StructureType = .image_create_info,
    p_next: ?*const anyopaque = null,
    flags: ImageCreateFlags,
    image_type: ImageType,
    format: Format,
    extent: Extent3D,
    mip_levels: u32,
    array_layers: u32,
    samples: SampleCountFlagBits,
    tiling: ImageTiling,
    usage: ImageUsageFlags,
    sharing_mode: SharingMode,
    queue_family_index_count: u32,
    p_queue_family_indices: *const u32,
    initial_layout: ImageLayout,
};

pub const SubresourceLayout = extern struct {
    offset: DeviceSize,
    size: DeviceSize,
    row_pitch: DeviceSize,
    array_pitch: DeviceSize,
    depth_pitch: DeviceSize,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: StructureType = .image_view_create_info,
    p_next: ?*const anyopaque = null,
    flags: ImageViewCreateFlags,
    image: Image,
    view_type: ImageViewType,
    format: Format,
    components: ComponentMapping,
    subresource_range: ImageSubresourceRange,
};

pub const BufferCopy = extern struct {
    src_offset: DeviceSize,
    dst_offset: DeviceSize,
    size: DeviceSize,
};

pub const SparseMemoryBind = extern struct {
    resource_offset: DeviceSize,
    size: DeviceSize,
    memory: DeviceMemory,
    memory_offset: DeviceSize,
    flags: SparseMemoryBindFlags,
};

pub const SparseImageMemoryBind = extern struct {
    subresource: ImageSubresource,
    offset: Offset3D,
    extent: Extent3D,
    memory: DeviceMemory,
    memory_offset: DeviceSize,
    flags: SparseMemoryBindFlags,
};

pub const SparseBufferMemoryBindInfo = extern struct {
    buffer: Buffer,
    bind_count: u32,
    p_binds: *const SparseMemoryBind,
};

pub const SparseImageOpaqueMemoryBindInfo = extern struct {
    image: Image,
    bind_count: u32,
    p_binds: *const SparseMemoryBind,
};

pub const SparseImageMemoryBindInfo = extern struct {
    image: Image,
    bind_count: u32,
    p_binds: *const SparseImageMemoryBind,
};

pub const BindSparseInfo = extern struct {
    s_type: StructureType = .bind_sparse_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32,
    p_wait_semaphores: *const Semaphore,
    buffer_bind_count: u32,
    p_buffer_binds: *const SparseBufferMemoryBindInfo,
    image_opaque_bind_count: u32,
    p_image_opaque_binds: *const SparseImageOpaqueMemoryBindInfo,
    image_bind_count: u32,
    p_image_binds: *const SparseImageMemoryBindInfo,
    signal_semaphore_count: u32,
    p_signal_semaphores: *const Semaphore,
};

pub const ImageCopy = extern struct {
    src_subresource: ImageSubresourceLayers,
    src_offset: Offset3D,
    dst_subresource: ImageSubresourceLayers,
    dst_offset: Offset3D,
    extent: Extent3D,
};

pub const ImageBlit = extern struct {
    src_subresource: ImageSubresourceLayers,
    src_offsets: [2]Offset3D,
    dst_subresource: ImageSubresourceLayers,
    dst_offsets: [2]Offset3D,
};

pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize,
    buffer_row_length: u32,
    buffer_image_height: u32,
    image_subresource: ImageSubresourceLayers,
    image_offset: Offset3D,
    image_extent: Extent3D,
};

pub const ImageResolve = extern struct {
    src_subresource: ImageSubresourceLayers,
    src_offset: Offset3D,
    dst_subresource: ImageSubresourceLayers,
    dst_offset: Offset3D,
    extent: Extent3D,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: StructureType = .shader_module_create_info,
    p_next: ?*const anyopaque = null,
    flags: ShaderModuleCreateFlags,
    code_size: usize,
    p_code: *const u32,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: DescriptorType,
    descriptor_count: u32,
    stage_flags: ShaderStageFlags,
    p_immutable_samplers: ?*const Sampler,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: StructureType = .descriptor_set_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: DescriptorSetLayoutCreateFlags,
    binding_count: u32,
    p_bindings: *const DescriptorSetLayoutBinding,
};

pub const DescriptorPoolSize = extern struct {
    type: DescriptorType,
    descriptor_count: u32,
};

pub const DescriptorPoolCreateInfo = extern struct {
    s_type: StructureType = .descriptor_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: DescriptorPoolCreateFlags,
    max_sets: u32,
    pool_size_count: u32,
    p_pool_sizes: *const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: StructureType = .descriptor_set_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    p_set_layouts: *const DescriptorSetLayout,
};

pub const SpecializationMapEntry = extern struct {
    constant_id: u32,
    offset: u32,
    size: usize,
};

pub const SpecializationInfo = extern struct {
    map_entry_count: u32,
    p_map_entries: *const SpecializationMapEntry,
    data_size: usize,
    p_data: *const anyopaque,
};

pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: StructureType = .pipeline_shader_stage_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineShaderStageCreateFlags,
    stage: ShaderStageFlagBits,
    module: ShaderModule,
    p_name: [*:0]const u8,
    p_specialization_info: ?*const SpecializationInfo,
};

pub const ComputePipelineCreateInfo = extern struct {
    s_type: StructureType = .compute_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineCreateFlags,
    stage: PipelineShaderStageCreateInfo,
    layout: PipelineLayout,
    base_pipeline_handle: Pipeline,
    base_pipeline_index: i32,
};

pub const VertexInputBindingDescription = extern struct {
    binding: u32,
    stride: u32,
    input_rate: VertexInputRate,
};

pub const VertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32,
    format: Format,
    offset: u32,
};

pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_vertex_input_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineVertexInputStateCreateFlags,
    vertex_binding_description_count: u32,
    p_vertex_binding_descriptions: *const VertexInputBindingDescription,
    vertex_attribute_description_count: u32,
    p_vertex_attribute_descriptions: *const VertexInputAttributeDescription,
};

pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_input_assembly_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineInputAssemblyStateCreateFlags,
    topology: PrimitiveTopology,
    primitive_restart_enable: Bool32,
};

pub const PipelineTessellationStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_tessellation_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineTessellationStateCreateFlags,
    patch_control_points: u32,
};

pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_viewport_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineViewportStateCreateFlags,
    viewport_count: u32,
    p_viewports: ?*const Viewport,
    scissor_count: u32,
    p_scissors: ?*const Rect2D,
};

pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_rasterization_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineRasterizationStateCreateFlags,
    depth_clamp_enable: Bool32,
    rasterizer_discard_enable: Bool32,
    polygon_mode: PolygonMode,
    cull_mode: CullModeFlags,
    front_face: FrontFace,
    depth_bias_enable: Bool32,
    depth_bias_constant_factor: f32,
    depth_bias_clamp: f32,
    depth_bias_slope_factor: f32,
    line_width: f32,
};

pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_multisample_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineMultisampleStateCreateFlags,
    rasterization_samples: SampleCountFlagBits,
    sample_shading_enable: Bool32,
    min_sample_shading: f32,
    p_sample_mask: ?*const SampleMask,
    alpha_to_coverage_enable: Bool32,
    alpha_to_one_enable: Bool32,
};

pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: Bool32,
    src_color_blend_factor: BlendFactor,
    dst_color_blend_factor: BlendFactor,
    color_blend_op: BlendOp,
    src_alpha_blend_factor: BlendFactor,
    dst_alpha_blend_factor: BlendFactor,
    alpha_blend_op: BlendOp,
    color_write_mask: ColorComponentFlags,
};

pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_color_blend_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineColorBlendStateCreateFlags,
    logic_op_enable: Bool32,
    logic_op: LogicOp,
    attachment_count: u32,
    p_attachments: ?*const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32,
};

pub const PipelineDynamicStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_dynamic_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineDynamicStateCreateFlags,
    dynamic_state_count: u32,
    p_dynamic_states: *const DynamicState,
};

pub const StencilOpState = extern struct {
    fail_op: StencilOp,
    pass_op: StencilOp,
    depth_fail_op: StencilOp,
    compare_op: CompareOp,
    compare_mask: u32,
    write_mask: u32,
    reference: u32,
};

pub const PipelineDepthStencilStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_depth_stencil_state_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineDepthStencilStateCreateFlags,
    depth_test_enable: Bool32,
    depth_write_enable: Bool32,
    depth_compare_op: CompareOp,
    depth_bounds_test_enable: Bool32,
    stencil_test_enable: Bool32,
    front: StencilOpState,
    back: StencilOpState,
    min_depth_bounds: f32,
    max_depth_bounds: f32,
};

pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: StructureType = .graphics_pipeline_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineCreateFlags,
    stage_count: u32,
    p_stages: ?*const PipelineShaderStageCreateInfo,
    p_vertex_input_state: ?*const PipelineVertexInputStateCreateInfo,
    p_input_assembly_state: ?*const PipelineInputAssemblyStateCreateInfo,
    p_tessellation_state: ?*const PipelineTessellationStateCreateInfo,
    p_viewport_state: ?*const PipelineViewportStateCreateInfo,
    p_rasterization_state: ?*const PipelineRasterizationStateCreateInfo,
    p_multisample_state: ?*const PipelineMultisampleStateCreateInfo,
    p_depth_stencil_state: ?*const PipelineDepthStencilStateCreateInfo,
    p_color_blend_state: ?*const PipelineColorBlendStateCreateInfo,
    p_dynamic_state: ?*const PipelineDynamicStateCreateInfo,
    layout: PipelineLayout,
    render_pass: RenderPass,
    subpass: u32,
    base_pipeline_handle: Pipeline,
    base_pipeline_index: i32,
};

pub const PipelineCacheCreateInfo = extern struct {
    s_type: StructureType = .pipeline_cache_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineCacheCreateFlags,
    initial_data_size: usize,
    p_initial_data: *const anyopaque,
};

pub const PipelineCacheHeaderVersionOne = extern struct {
    header_size: u32,
    header_version: PipelineCacheHeaderVersion,
    vendor_id: u32,
    device_id: u32,
    pipeline_cache_uuid: [UUID_SIZE]u8,
};

pub const PushConstantRange = extern struct {
    stage_flags: ShaderStageFlags,
    offset: u32,
    size: u32,
};

pub const PipelineLayoutCreateInfo = extern struct {
    s_type: StructureType = .pipeline_layout_create_info,
    p_next: ?*const anyopaque = null,
    flags: PipelineLayoutCreateFlags,
    set_layout_count: u32,
    p_set_layouts: *const DescriptorSetLayout,
    push_constant_range_count: u32,
    p_push_constant_ranges: *const PushConstantRange,
};

pub const SamplerCreateInfo = extern struct {
    s_type: StructureType = .sampler_create_info,
    p_next: ?*const anyopaque = null,
    flags: SamplerCreateFlags,
    mag_filter: Filter,
    min_filter: Filter,
    mipmap_mode: SamplerMipmapMode,
    address_mode_u: SamplerAddressMode,
    address_mode_v: SamplerAddressMode,
    address_mode_w: SamplerAddressMode,
    mip_lod_bias: f32,
    anisotropy_enable: Bool32,
    max_anisotropy: f32,
    compare_enable: Bool32,
    compare_op: CompareOp,
    min_lod: f32,
    max_lod: f32,
    border_color: BorderColor,
    unnormalized_coordinates: Bool32,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = .command_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: CommandPoolCreateFlags,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = .command_buffer_allocate_info,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: CommandBufferLevel,
    command_buffer_count: u32,
};

pub const CommandBufferInheritanceInfo = extern struct {
    s_type: StructureType = .command_buffer_inheritance_info,
    p_next: ?*const anyopaque = null,
    render_pass: RenderPass,
    subpass: u32,
    framebuffer: Framebuffer,
    occlusion_query_enable: Bool32,
    query_flags: QueryControlFlags,
    pipeline_statistics: QueryPipelineStatisticFlags,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = .command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    flags: CommandBufferUsageFlags,
    p_inheritance_info: ?*const CommandBufferInheritanceInfo,
};

pub const RenderPassBeginInfo = extern struct {
    s_type: StructureType = .render_pass_begin_info,
    p_next: ?*const anyopaque = null,
    render_pass: RenderPass,
    framebuffer: Framebuffer,
    render_area: Rect2D,
    clear_value_count: u32,
    p_clear_values: *const ClearValue,
};

pub const ClearDepthStencilValue = extern struct {
    depth: f32,
    stencil: u32,
};

pub const ClearAttachment = extern struct {
    aspect_mask: ImageAspectFlags,
    color_attachment: u32,
    clear_value: ClearValue,
};

pub const AttachmentDescription = extern struct {
    flags: AttachmentDescriptionFlags,
    format: Format,
    samples: SampleCountFlagBits,
    load_op: AttachmentLoadOp,
    store_op: AttachmentStoreOp,
    stencil_load_op: AttachmentLoadOp,
    stencil_store_op: AttachmentStoreOp,
    initial_layout: ImageLayout,
    final_layout: ImageLayout,
};

pub const AttachmentReference = extern struct {
    attachment: u32,
    layout: ImageLayout,
};

pub const SubpassDescription = extern struct {
    flags: SubpassDescriptionFlags,
    pipeline_bind_point: PipelineBindPoint,
    input_attachment_count: u32,
    p_input_attachments: *const AttachmentReference,
    color_attachment_count: u32,
    p_color_attachments: *const AttachmentReference,
    p_resolve_attachments: ?*const AttachmentReference,
    p_depth_stencil_attachment: ?*const AttachmentReference,
    preserve_attachment_count: u32,
    p_preserve_attachments: *const u32,
};

pub const SubpassDependency = extern struct {
    src_subpass: u32,
    dst_subpass: u32,
    src_stage_mask: PipelineStageFlags,
    dst_stage_mask: PipelineStageFlags,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    dependency_flags: DependencyFlags,
};

pub const RenderPassCreateInfo = extern struct {
    s_type: StructureType = .render_pass_create_info,
    p_next: ?*const anyopaque = null,
    flags: RenderPassCreateFlags,
    attachment_count: u32,
    p_attachments: *const AttachmentDescription,
    subpass_count: u32,
    p_subpasses: *const SubpassDescription,
    dependency_count: u32,
    p_dependencies: *const SubpassDependency,
};

pub const EventCreateInfo = extern struct {
    s_type: StructureType = .event_create_info,
    p_next: ?*const anyopaque = null,
    flags: EventCreateFlags,
};

pub const FenceCreateInfo = extern struct {
    s_type: StructureType = .fence_create_info,
    p_next: ?*const anyopaque = null,
    flags: FenceCreateFlags,
};

pub const PhysicalDeviceFeatures = extern struct {
    robust_buffer_access: Bool32,
    full_draw_index_uint32: Bool32,
    image_cube_array: Bool32,
    independent_blend: Bool32,
    geometry_shader: Bool32,
    tessellation_shader: Bool32,
    sample_rate_shading: Bool32,
    dual_src_blend: Bool32,
    logic_op: Bool32,
    multi_draw_indirect: Bool32,
    draw_indirect_first_instance: Bool32,
    depth_clamp: Bool32,
    depth_bias_clamp: Bool32,
    fill_mode_non_solid: Bool32,
    depth_bounds: Bool32,
    wide_lines: Bool32,
    large_points: Bool32,
    alpha_to_one: Bool32,
    multi_viewport: Bool32,
    sampler_anisotropy: Bool32,
    texture_compression_etc2: Bool32,
    texture_compression_astc__ldr: Bool32,
    texture_compression_bc: Bool32,
    occlusion_query_precise: Bool32,
    pipeline_statistics_query: Bool32,
    vertex_pipeline_stores_and_atomics: Bool32,
    fragment_stores_and_atomics: Bool32,
    shader_tessellation_and_geometry_point_size: Bool32,
    shader_image_gather_extended: Bool32,
    shader_storage_image_extended_formats: Bool32,
    shader_storage_image_multisample: Bool32,
    shader_storage_image_read_without_format: Bool32,
    shader_storage_image_write_without_format: Bool32,
    shader_uniform_buffer_array_dynamic_indexing: Bool32,
    shader_sampled_image_array_dynamic_indexing: Bool32,
    shader_storage_buffer_array_dynamic_indexing: Bool32,
    shader_storage_image_array_dynamic_indexing: Bool32,
    shader_clip_distance: Bool32,
    shader_cull_distance: Bool32,
    shader_float64: Bool32,
    shader_int64: Bool32,
    shader_int16: Bool32,
    shader_resource_residency: Bool32,
    shader_resource_min_lod: Bool32,
    sparse_binding: Bool32,
    sparse_residency_buffer: Bool32,
    sparse_residency_image2_d: Bool32,
    sparse_residency_image3_d: Bool32,
    sparse_residency2_samples: Bool32,
    sparse_residency4_samples: Bool32,
    sparse_residency8_samples: Bool32,
    sparse_residency16_samples: Bool32,
    sparse_residency_aliased: Bool32,
    variable_multisample_rate: Bool32,
    inherited_queries: Bool32,
};

pub const PhysicalDeviceSparseProperties = extern struct {
    residency_standard2_dblock_shape: Bool32,
    residency_standard2_dmultisample_block_shape: Bool32,
    residency_standard3_dblock_shape: Bool32,
    residency_aligned_mip_size: Bool32,
    residency_non_resident_strict: Bool32,
};

pub const PhysicalDeviceLimits = extern struct {
    max_image_dimension1_d: u32,
    max_image_dimension2_d: u32,
    max_image_dimension3_d: u32,
    max_image_dimension_cube: u32,
    max_image_array_layers: u32,
    max_texel_buffer_elements: u32,
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,
    max_push_constants_size: u32,
    max_memory_allocation_count: u32,
    max_sampler_allocation_count: u32,
    buffer_image_granularity: DeviceSize,
    sparse_address_space_size: DeviceSize,
    max_bound_descriptor_sets: u32,
    max_per_stage_descriptor_samplers: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    max_per_stage_descriptor_storage_buffers: u32,
    max_per_stage_descriptor_sampled_images: u32,
    max_per_stage_descriptor_storage_images: u32,
    max_per_stage_descriptor_input_attachments: u32,
    max_per_stage_resources: u32,
    max_descriptor_set_samplers: u32,
    max_descriptor_set_uniform_buffers: u32,
    max_descriptor_set_uniform_buffers_dynamic: u32,
    max_descriptor_set_storage_buffers: u32,
    max_descriptor_set_storage_buffers_dynamic: u32,
    max_descriptor_set_sampled_images: u32,
    max_descriptor_set_storage_images: u32,
    max_descriptor_set_input_attachments: u32,
    max_vertex_input_attributes: u32,
    max_vertex_input_bindings: u32,
    max_vertex_input_attribute_offset: u32,
    max_vertex_input_binding_stride: u32,
    max_vertex_output_components: u32,
    max_tessellation_generation_level: u32,
    max_tessellation_patch_size: u32,
    max_tessellation_control_per_vertex_input_components: u32,
    max_tessellation_control_per_vertex_output_components: u32,
    max_tessellation_control_per_patch_output_components: u32,
    max_tessellation_control_total_output_components: u32,
    max_tessellation_evaluation_input_components: u32,
    max_tessellation_evaluation_output_components: u32,
    max_geometry_shader_invocations: u32,
    max_geometry_input_components: u32,
    max_geometry_output_components: u32,
    max_geometry_output_vertices: u32,
    max_geometry_total_output_components: u32,
    max_fragment_input_components: u32,
    max_fragment_output_attachments: u32,
    max_fragment_dual_src_attachments: u32,
    max_fragment_combined_output_resources: u32,
    max_compute_shared_memory_size: u32,
    max_compute_work_group_count: [3]u32,
    max_compute_work_group_invocations: u32,
    max_compute_work_group_size: [3]u32,
    sub_pixel_precision_bits: u32,
    sub_texel_precision_bits: u32,
    mipmap_precision_bits: u32,
    max_draw_indexed_index_value: u32,
    max_draw_indirect_count: u32,
    max_sampler_lod_bias: f32,
    max_sampler_anisotropy: f32,
    max_viewports: u32,
    max_viewport_dimensions: [2]u32,
    viewport_bounds_range: [2]f32,
    viewport_sub_pixel_bits: u32,
    min_memory_map_alignment: usize,
    min_texel_buffer_offset_alignment: DeviceSize,
    min_uniform_buffer_offset_alignment: DeviceSize,
    min_storage_buffer_offset_alignment: DeviceSize,
    min_texel_offset: i32,
    max_texel_offset: u32,
    min_texel_gather_offset: i32,
    max_texel_gather_offset: u32,
    min_interpolation_offset: f32,
    max_interpolation_offset: f32,
    sub_pixel_interpolation_offset_bits: u32,
    max_framebuffer_width: u32,
    max_framebuffer_height: u32,
    max_framebuffer_layers: u32,
    framebuffer_color_sample_counts: SampleCountFlags,
    framebuffer_depth_sample_counts: SampleCountFlags,
    framebuffer_stencil_sample_counts: SampleCountFlags,
    framebuffer_no_attachments_sample_counts: SampleCountFlags,
    max_color_attachments: u32,
    sampled_image_color_sample_counts: SampleCountFlags,
    sampled_image_integer_sample_counts: SampleCountFlags,
    sampled_image_depth_sample_counts: SampleCountFlags,
    sampled_image_stencil_sample_counts: SampleCountFlags,
    storage_image_sample_counts: SampleCountFlags,
    max_sample_mask_words: u32,
    timestamp_compute_and_graphics: Bool32,
    timestamp_period: f32,
    max_clip_distances: u32,
    max_cull_distances: u32,
    max_combined_clip_and_cull_distances: u32,
    discrete_queue_priorities: u32,
    point_size_range: [2]f32,
    line_width_range: [2]f32,
    point_size_granularity: f32,
    line_width_granularity: f32,
    strict_lines: Bool32,
    standard_sample_locations: Bool32,
    optimal_buffer_copy_offset_alignment: DeviceSize,
    optimal_buffer_copy_row_pitch_alignment: DeviceSize,
    non_coherent_atom_size: DeviceSize,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType = .semaphore_create_info,
    p_next: ?*const anyopaque = null,
    flags: SemaphoreCreateFlags,
};

pub const QueryPoolCreateInfo = extern struct {
    s_type: StructureType = .query_pool_create_info,
    p_next: ?*const anyopaque = null,
    flags: QueryPoolCreateFlags,
    query_type: QueryType,
    query_count: u32,
    pipeline_statistics: QueryPipelineStatisticFlags,
};

pub const FramebufferCreateInfo = extern struct {
    s_type: StructureType = .framebuffer_create_info,
    p_next: ?*const anyopaque = null,
    flags: FramebufferCreateFlags,
    render_pass: RenderPass,
    attachment_count: u32,
    p_attachments: *const ImageView,
    width: u32,
    height: u32,
    layers: u32,
};

pub const DrawIndirectCommand = extern struct {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

pub const DrawIndexedIndirectCommand = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const DispatchIndirectCommand = extern struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const SubmitInfo = extern struct {
    s_type: StructureType = .submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32,
    p_wait_semaphores: *const Semaphore,
    p_wait_dst_stage_mask: *const PipelineStageFlags,
    command_buffer_count: u32,
    p_command_buffers: *const *CommandBuffer,
    signal_semaphore_count: u32,
    p_signal_semaphores: *const Semaphore,
};

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32,
    max_image_count: u32,
    current_extent: Extent2D,
    min_image_extent: Extent2D,
    max_image_extent: Extent2D,
    max_image_array_layers: u32,
    supported_transforms: SurfaceTransformFlagsKHR,
    current_transform: SurfaceTransformFlagBitsKHR,
    supported_composite_alpha: CompositeAlphaFlagsKHR,
    supported_usage_flags: ImageUsageFlags,
};

pub const WaylandSurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .wayland_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: WaylandSurfaceCreateFlagsKHR,
    display: *wl_display,
    surface: *wl_surface,
};

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: StructureType = .win32_surface_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: Win32SurfaceCreateFlagsKHR,
    hinstance: HINSTANCE,
    hwnd: HWND,
};

pub const SurfaceFormatKHR = extern struct {
    format: Format,
    color_space: ColorSpaceKHR,
};

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: StructureType = .swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    flags: SwapchainCreateFlagsKHR,
    surface: SurfaceKHR,
    min_image_count: u32,
    image_format: Format,
    image_color_space: ColorSpaceKHR,
    image_extent: Extent2D,
    image_array_layers: u32,
    image_usage: ImageUsageFlags,
    image_sharing_mode: SharingMode,
    queue_family_index_count: u32,
    p_queue_family_indices: *const u32,
    pre_transform: SurfaceTransformFlagBitsKHR,
    composite_alpha: CompositeAlphaFlagBitsKHR,
    present_mode: PresentModeKHR,
    clipped: Bool32,
    old_swapchain: SwapchainKHR,
};

pub const PresentInfoKHR = extern struct {
    s_type: StructureType = .present_info_khr,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32,
    p_wait_semaphores: *const Semaphore,
    swapchain_count: u32,
    p_swapchains: *const SwapchainKHR,
    p_image_indices: *const u32,
    p_results: ?*Result,
};

pub const DevicePrivateDataCreateInfo = extern struct {
    s_type: StructureType = .device_private_data_create_info,
    p_next: ?*const anyopaque = null,
    private_data_slot_request_count: u32,
};

pub const PrivateDataSlotCreateInfo = extern struct {
    s_type: StructureType = .private_data_slot_create_info,
    p_next: ?*const anyopaque = null,
    flags: PrivateDataSlotCreateFlags,
};

pub const PhysicalDevicePrivateDataFeatures = extern struct {
    s_type: StructureType = .physical_device_private_data_features,
    p_next: ?*anyopaque = null,
    private_data: Bool32,
};

pub const PhysicalDeviceFeatures2 = extern struct {
    s_type: StructureType = .physical_device_features_2,
    p_next: ?*anyopaque = null,
    features: PhysicalDeviceFeatures,
};

pub const PhysicalDeviceProperties2 = extern struct {
    s_type: StructureType = .physical_device_properties_2,
    p_next: ?*anyopaque = null,
    properties: PhysicalDeviceProperties,
};

pub const FormatProperties2 = extern struct {
    s_type: StructureType = .format_properties_2,
    p_next: ?*anyopaque = null,
    format_properties: FormatProperties,
};

pub const ImageFormatProperties2 = extern struct {
    s_type: StructureType = .image_format_properties_2,
    p_next: ?*anyopaque = null,
    image_format_properties: ImageFormatProperties,
};

pub const PhysicalDeviceImageFormatInfo2 = extern struct {
    s_type: StructureType = .physical_device_image_format_info_2,
    p_next: ?*const anyopaque = null,
    format: Format,
    type: ImageType,
    tiling: ImageTiling,
    usage: ImageUsageFlags,
    flags: ImageCreateFlags,
};

pub const QueueFamilyProperties2 = extern struct {
    s_type: StructureType = .queue_family_properties_2,
    p_next: ?*anyopaque = null,
    queue_family_properties: QueueFamilyProperties,
};

pub const PhysicalDeviceMemoryProperties2 = extern struct {
    s_type: StructureType = .physical_device_memory_properties_2,
    p_next: ?*anyopaque = null,
    memory_properties: PhysicalDeviceMemoryProperties,
};

pub const SparseImageFormatProperties2 = extern struct {
    s_type: StructureType = .sparse_image_format_properties_2,
    p_next: ?*anyopaque = null,
    properties: SparseImageFormatProperties,
};

pub const PhysicalDeviceSparseImageFormatInfo2 = extern struct {
    s_type: StructureType = .physical_device_sparse_image_format_info_2,
    p_next: ?*const anyopaque = null,
    format: Format,
    type: ImageType,
    samples: SampleCountFlagBits,
    usage: ImageUsageFlags,
    tiling: ImageTiling,
};

pub const ConformanceVersion = extern struct {
    major: u8,
    minor: u8,
    subminor: u8,
    patch: u8,
};

pub const PhysicalDeviceDriverProperties = extern struct {
    s_type: StructureType = .physical_device_driver_properties,
    p_next: ?*anyopaque = null,
    driver_id: DriverId,
    driver_name: [MAX_DRIVER_NAME_SIZE]u8,
    driver_info: [MAX_DRIVER_INFO_SIZE]u8,
    conformance_version: ConformanceVersion,
};

pub const PhysicalDeviceVariablePointersFeatures = extern struct {
    s_type: StructureType = .physical_device_variable_pointers_features,
    p_next: ?*anyopaque = null,
    variable_pointers_storage_buffer: Bool32,
    variable_pointers: Bool32,
};

pub const ExternalMemoryProperties = extern struct {
    external_memory_features: ExternalMemoryFeatureFlags,
    export_from_imported_handle_types: ExternalMemoryHandleTypeFlags,
    compatible_handle_types: ExternalMemoryHandleTypeFlags,
};

pub const PhysicalDeviceExternalImageFormatInfo = extern struct {
    s_type: StructureType = .physical_device_external_image_format_info,
    p_next: ?*const anyopaque = null,
    handle_type: ExternalMemoryHandleTypeFlagBits,
};

pub const ExternalImageFormatProperties = extern struct {
    s_type: StructureType = .external_image_format_properties,
    p_next: ?*anyopaque = null,
    external_memory_properties: ExternalMemoryProperties,
};

pub const PhysicalDeviceExternalBufferInfo = extern struct {
    s_type: StructureType = .physical_device_external_buffer_info,
    p_next: ?*const anyopaque = null,
    flags: BufferCreateFlags,
    usage: BufferUsageFlags,
    handle_type: ExternalMemoryHandleTypeFlagBits,
};

pub const ExternalBufferProperties = extern struct {
    s_type: StructureType = .external_buffer_properties,
    p_next: ?*anyopaque = null,
    external_memory_properties: ExternalMemoryProperties,
};

pub const PhysicalDeviceIDProperties = extern struct {
    s_type: StructureType = .physical_device_id_properties,
    p_next: ?*anyopaque = null,
    device_uuid: [UUID_SIZE]u8,
    driver_uuid: [UUID_SIZE]u8,
    device_luid: [LUID_SIZE]u8,
    device_node_mask: u32,
    device_luidvalid: Bool32,
};

pub const ExternalMemoryImageCreateInfo = extern struct {
    s_type: StructureType = .external_memory_image_create_info,
    p_next: ?*const anyopaque = null,
    handle_types: ExternalMemoryHandleTypeFlags,
};

pub const ExternalMemoryBufferCreateInfo = extern struct {
    s_type: StructureType = .external_memory_buffer_create_info,
    p_next: ?*const anyopaque = null,
    handle_types: ExternalMemoryHandleTypeFlags,
};

pub const ExportMemoryAllocateInfo = extern struct {
    s_type: StructureType = .export_memory_allocate_info,
    p_next: ?*const anyopaque = null,
    handle_types: ExternalMemoryHandleTypeFlags,
};

pub const PhysicalDeviceExternalSemaphoreInfo = extern struct {
    s_type: StructureType = .physical_device_external_semaphore_info,
    p_next: ?*const anyopaque = null,
    handle_type: ExternalSemaphoreHandleTypeFlagBits,
};

pub const ExternalSemaphoreProperties = extern struct {
    s_type: StructureType = .external_semaphore_properties,
    p_next: ?*anyopaque = null,
    export_from_imported_handle_types: ExternalSemaphoreHandleTypeFlags,
    compatible_handle_types: ExternalSemaphoreHandleTypeFlags,
    external_semaphore_features: ExternalSemaphoreFeatureFlags,
};

pub const ExportSemaphoreCreateInfo = extern struct {
    s_type: StructureType = .export_semaphore_create_info,
    p_next: ?*const anyopaque = null,
    handle_types: ExternalSemaphoreHandleTypeFlags,
};

pub const PhysicalDeviceExternalFenceInfo = extern struct {
    s_type: StructureType = .physical_device_external_fence_info,
    p_next: ?*const anyopaque = null,
    handle_type: ExternalFenceHandleTypeFlagBits,
};

pub const ExternalFenceProperties = extern struct {
    s_type: StructureType = .external_fence_properties,
    p_next: ?*anyopaque = null,
    export_from_imported_handle_types: ExternalFenceHandleTypeFlags,
    compatible_handle_types: ExternalFenceHandleTypeFlags,
    external_fence_features: ExternalFenceFeatureFlags,
};

pub const ExportFenceCreateInfo = extern struct {
    s_type: StructureType = .export_fence_create_info,
    p_next: ?*const anyopaque = null,
    handle_types: ExternalFenceHandleTypeFlags,
};

pub const PhysicalDeviceMultiviewFeatures = extern struct {
    s_type: StructureType = .physical_device_multiview_features,
    p_next: ?*anyopaque = null,
    multiview: Bool32,
    multiview_geometry_shader: Bool32,
    multiview_tessellation_shader: Bool32,
};

pub const PhysicalDeviceMultiviewProperties = extern struct {
    s_type: StructureType = .physical_device_multiview_properties,
    p_next: ?*anyopaque = null,
    max_multiview_view_count: u32,
    max_multiview_instance_index: u32,
};

pub const RenderPassMultiviewCreateInfo = extern struct {
    s_type: StructureType = .render_pass_multiview_create_info,
    p_next: ?*const anyopaque = null,
    subpass_count: u32,
    p_view_masks: *const u32,
    dependency_count: u32,
    p_view_offsets: *const i32,
    correlation_mask_count: u32,
    p_correlation_masks: *const u32,
};

pub const PhysicalDeviceGroupProperties = extern struct {
    s_type: StructureType = .physical_device_group_properties,
    p_next: ?*anyopaque = null,
    physical_device_count: u32,
    physical_devices: [MAX_DEVICE_GROUP_SIZE]PhysicalDevice,
    subset_allocation: Bool32,
};

pub const MemoryAllocateFlagsInfo = extern struct {
    s_type: StructureType = .memory_allocate_flags_info,
    p_next: ?*const anyopaque = null,
    flags: MemoryAllocateFlags,
    device_mask: u32,
};

pub const BindBufferMemoryInfo = extern struct {
    s_type: StructureType = .bind_buffer_memory_info,
    p_next: ?*const anyopaque = null,
    buffer: Buffer,
    memory: DeviceMemory,
    memory_offset: DeviceSize,
};

pub const BindBufferMemoryDeviceGroupInfo = extern struct {
    s_type: StructureType = .bind_buffer_memory_device_group_info,
    p_next: ?*const anyopaque = null,
    device_index_count: u32,
    p_device_indices: *const u32,
};

pub const BindImageMemoryInfo = extern struct {
    s_type: StructureType = .bind_image_memory_info,
    p_next: ?*const anyopaque = null,
    image: Image,
    memory: DeviceMemory,
    memory_offset: DeviceSize,
};

pub const BindImageMemoryDeviceGroupInfo = extern struct {
    s_type: StructureType = .bind_image_memory_device_group_info,
    p_next: ?*const anyopaque = null,
    device_index_count: u32,
    p_device_indices: *const u32,
    split_instance_bind_region_count: u32,
    p_split_instance_bind_regions: *const Rect2D,
};

pub const DeviceGroupRenderPassBeginInfo = extern struct {
    s_type: StructureType = .device_group_render_pass_begin_info,
    p_next: ?*const anyopaque = null,
    device_mask: u32,
    device_render_area_count: u32,
    p_device_render_areas: *const Rect2D,
};

pub const DeviceGroupCommandBufferBeginInfo = extern struct {
    s_type: StructureType = .device_group_command_buffer_begin_info,
    p_next: ?*const anyopaque = null,
    device_mask: u32,
};

pub const DeviceGroupSubmitInfo = extern struct {
    s_type: StructureType = .device_group_submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32,
    p_wait_semaphore_device_indices: *const u32,
    command_buffer_count: u32,
    p_command_buffer_device_masks: *const u32,
    signal_semaphore_count: u32,
    p_signal_semaphore_device_indices: *const u32,
};

pub const DeviceGroupBindSparseInfo = extern struct {
    s_type: StructureType = .device_group_bind_sparse_info,
    p_next: ?*const anyopaque = null,
    resource_device_index: u32,
    memory_device_index: u32,
};

pub const DeviceGroupPresentCapabilitiesKHR = extern struct {
    s_type: StructureType = .device_group_present_capabilities_khr,
    p_next: ?*anyopaque = null,
    present_mask: [MAX_DEVICE_GROUP_SIZE]u32,
    modes: DeviceGroupPresentModeFlagsKHR,
};

pub const ImageSwapchainCreateInfoKHR = extern struct {
    s_type: StructureType = .image_swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    swapchain: SwapchainKHR,
};

pub const BindImageMemorySwapchainInfoKHR = extern struct {
    s_type: StructureType = .bind_image_memory_swapchain_info_khr,
    p_next: ?*const anyopaque = null,
    swapchain: SwapchainKHR,
    image_index: u32,
};

pub const AcquireNextImageInfoKHR = extern struct {
    s_type: StructureType = .acquire_next_image_info_khr,
    p_next: ?*const anyopaque = null,
    swapchain: SwapchainKHR,
    timeout: u64,
    semaphore: Semaphore,
    fence: Fence,
    device_mask: u32,
};

pub const DeviceGroupPresentInfoKHR = extern struct {
    s_type: StructureType = .device_group_present_info_khr,
    p_next: ?*const anyopaque = null,
    swapchain_count: u32,
    p_device_masks: *const u32,
    mode: DeviceGroupPresentModeFlagBitsKHR,
};

pub const DeviceGroupDeviceCreateInfo = extern struct {
    s_type: StructureType = .device_group_device_create_info,
    p_next: ?*const anyopaque = null,
    physical_device_count: u32,
    p_physical_devices: *const *PhysicalDevice,
};

pub const DeviceGroupSwapchainCreateInfoKHR = extern struct {
    s_type: StructureType = .device_group_swapchain_create_info_khr,
    p_next: ?*const anyopaque = null,
    modes: DeviceGroupPresentModeFlagsKHR,
};

pub const DescriptorUpdateTemplateEntry = extern struct {
    dst_binding: u32,
    dst_array_element: u32,
    descriptor_count: u32,
    descriptor_type: DescriptorType,
    offset: usize,
    stride: usize,
};

pub const DescriptorUpdateTemplateCreateInfo = extern struct {
    s_type: StructureType = .descriptor_update_template_create_info,
    p_next: ?*const anyopaque = null,
    flags: DescriptorUpdateTemplateCreateFlags,
    descriptor_update_entry_count: u32,
    p_descriptor_update_entries: *const DescriptorUpdateTemplateEntry,
    template_type: DescriptorUpdateTemplateType,
    descriptor_set_layout: DescriptorSetLayout,
    pipeline_bind_point: PipelineBindPoint,
    pipeline_layout: PipelineLayout,
    set: u32,
};

pub const InputAttachmentAspectReference = extern struct {
    subpass: u32,
    input_attachment_index: u32,
    aspect_mask: ImageAspectFlags,
};

pub const RenderPassInputAttachmentAspectCreateInfo = extern struct {
    s_type: StructureType = .render_pass_input_attachment_aspect_create_info,
    p_next: ?*const anyopaque = null,
    aspect_reference_count: u32,
    p_aspect_references: *const InputAttachmentAspectReference,
};

pub const PhysicalDevice16BitStorageFeatures = extern struct {
    s_type: StructureType = .physical_device_16bit_storage_features,
    p_next: ?*anyopaque = null,
    storage_buffer16_bit_access: Bool32,
    uniform_and_storage_buffer16_bit_access: Bool32,
    storage_push_constant16: Bool32,
    storage_input_output16: Bool32,
};

pub const PhysicalDeviceSubgroupProperties = extern struct {
    s_type: StructureType = .physical_device_subgroup_properties,
    p_next: ?*anyopaque = null,
    subgroup_size: u32,
    supported_stages: ShaderStageFlags,
    supported_operations: SubgroupFeatureFlags,
    quad_operations_in_all_stages: Bool32,
};

pub const PhysicalDeviceShaderSubgroupExtendedTypesFeatures = extern struct {
    s_type: StructureType = .physical_device_shader_subgroup_extended_types_features,
    p_next: ?*anyopaque = null,
    shader_subgroup_extended_types: Bool32,
};

pub const BufferMemoryRequirementsInfo2 = extern struct {
    s_type: StructureType = .buffer_memory_requirements_info_2,
    p_next: ?*const anyopaque = null,
    buffer: Buffer,
};

pub const DeviceBufferMemoryRequirements = extern struct {
    s_type: StructureType = .device_buffer_memory_requirements,
    p_next: ?*const anyopaque = null,
    p_create_info: *const BufferCreateInfo,
};

pub const ImageMemoryRequirementsInfo2 = extern struct {
    s_type: StructureType = .image_memory_requirements_info_2,
    p_next: ?*const anyopaque = null,
    image: Image,
};

pub const ImageSparseMemoryRequirementsInfo2 = extern struct {
    s_type: StructureType = .image_sparse_memory_requirements_info_2,
    p_next: ?*const anyopaque = null,
    image: Image,
};

pub const DeviceImageMemoryRequirements = extern struct {
    s_type: StructureType = .device_image_memory_requirements,
    p_next: ?*const anyopaque = null,
    p_create_info: *const ImageCreateInfo,
    plane_aspect: ImageAspectFlagBits,
};

pub const MemoryRequirements2 = extern struct {
    s_type: StructureType = .memory_requirements_2,
    p_next: ?*anyopaque = null,
    memory_requirements: MemoryRequirements,
};

pub const SparseImageMemoryRequirements2 = extern struct {
    s_type: StructureType = .sparse_image_memory_requirements_2,
    p_next: ?*anyopaque = null,
    memory_requirements: SparseImageMemoryRequirements,
};

pub const PhysicalDevicePointClippingProperties = extern struct {
    s_type: StructureType = .physical_device_point_clipping_properties,
    p_next: ?*anyopaque = null,
    point_clipping_behavior: PointClippingBehavior,
};

pub const MemoryDedicatedRequirements = extern struct {
    s_type: StructureType = .memory_dedicated_requirements,
    p_next: ?*anyopaque = null,
    prefers_dedicated_allocation: Bool32,
    requires_dedicated_allocation: Bool32,
};

pub const MemoryDedicatedAllocateInfo = extern struct {
    s_type: StructureType = .memory_dedicated_allocate_info,
    p_next: ?*const anyopaque = null,
    image: Image,
    buffer: Buffer,
};

pub const ImageViewUsageCreateInfo = extern struct {
    s_type: StructureType = .image_view_usage_create_info,
    p_next: ?*const anyopaque = null,
    usage: ImageUsageFlags,
};

pub const PipelineTessellationDomainOriginStateCreateInfo = extern struct {
    s_type: StructureType = .pipeline_tessellation_domain_origin_state_create_info,
    p_next: ?*const anyopaque = null,
    domain_origin: TessellationDomainOrigin,
};

pub const SamplerYcbcrConversionInfo = extern struct {
    s_type: StructureType = .sampler_ycbcr_conversion_info,
    p_next: ?*const anyopaque = null,
    conversion: SamplerYcbcrConversion,
};

pub const SamplerYcbcrConversionCreateInfo = extern struct {
    s_type: StructureType = .sampler_ycbcr_conversion_create_info,
    p_next: ?*const anyopaque = null,
    format: Format,
    ycbcr_model: SamplerYcbcrModelConversion,
    ycbcr_range: SamplerYcbcrRange,
    components: ComponentMapping,
    x_chroma_offset: ChromaLocation,
    y_chroma_offset: ChromaLocation,
    chroma_filter: Filter,
    force_explicit_reconstruction: Bool32,
};

pub const BindImagePlaneMemoryInfo = extern struct {
    s_type: StructureType = .bind_image_plane_memory_info,
    p_next: ?*const anyopaque = null,
    plane_aspect: ImageAspectFlagBits,
};

pub const ImagePlaneMemoryRequirementsInfo = extern struct {
    s_type: StructureType = .image_plane_memory_requirements_info,
    p_next: ?*const anyopaque = null,
    plane_aspect: ImageAspectFlagBits,
};

pub const PhysicalDeviceSamplerYcbcrConversionFeatures = extern struct {
    s_type: StructureType = .physical_device_sampler_ycbcr_conversion_features,
    p_next: ?*anyopaque = null,
    sampler_ycbcr_conversion: Bool32,
};

pub const SamplerYcbcrConversionImageFormatProperties = extern struct {
    s_type: StructureType = .sampler_ycbcr_conversion_image_format_properties,
    p_next: ?*anyopaque = null,
    combined_image_sampler_descriptor_count: u32,
};

pub const ProtectedSubmitInfo = extern struct {
    s_type: StructureType = .protected_submit_info,
    p_next: ?*const anyopaque = null,
    protected_submit: Bool32,
};

pub const PhysicalDeviceProtectedMemoryFeatures = extern struct {
    s_type: StructureType = .physical_device_protected_memory_features,
    p_next: ?*anyopaque = null,
    protected_memory: Bool32,
};

pub const PhysicalDeviceProtectedMemoryProperties = extern struct {
    s_type: StructureType = .physical_device_protected_memory_properties,
    p_next: ?*anyopaque = null,
    protected_no_fault: Bool32,
};

pub const DeviceQueueInfo2 = extern struct {
    s_type: StructureType = .device_queue_info_2,
    p_next: ?*const anyopaque = null,
    flags: DeviceQueueCreateFlags,
    queue_family_index: u32,
    queue_index: u32,
};

pub const PhysicalDeviceSamplerFilterMinmaxProperties = extern struct {
    s_type: StructureType = .physical_device_sampler_filter_minmax_properties,
    p_next: ?*anyopaque = null,
    filter_minmax_single_component_formats: Bool32,
    filter_minmax_image_component_mapping: Bool32,
};

pub const SamplerReductionModeCreateInfo = extern struct {
    s_type: StructureType = .sampler_reduction_mode_create_info,
    p_next: ?*const anyopaque = null,
    reduction_mode: SamplerReductionMode,
};

pub const PhysicalDeviceInlineUniformBlockFeatures = extern struct {
    s_type: StructureType = .physical_device_inline_uniform_block_features,
    p_next: ?*anyopaque = null,
    inline_uniform_block: Bool32,
    descriptor_binding_inline_uniform_block_update_after_bind: Bool32,
};

pub const PhysicalDeviceInlineUniformBlockProperties = extern struct {
    s_type: StructureType = .physical_device_inline_uniform_block_properties,
    p_next: ?*anyopaque = null,
    max_inline_uniform_block_size: u32,
    max_per_stage_descriptor_inline_uniform_blocks: u32,
    max_per_stage_descriptor_update_after_bind_inline_uniform_blocks: u32,
    max_descriptor_set_inline_uniform_blocks: u32,
    max_descriptor_set_update_after_bind_inline_uniform_blocks: u32,
};

pub const WriteDescriptorSetInlineUniformBlock = extern struct {
    s_type: StructureType = .write_descriptor_set_inline_uniform_block,
    p_next: ?*const anyopaque = null,
    data_size: u32,
    p_data: *const anyopaque,
};

pub const DescriptorPoolInlineUniformBlockCreateInfo = extern struct {
    s_type: StructureType = .descriptor_pool_inline_uniform_block_create_info,
    p_next: ?*const anyopaque = null,
    max_inline_uniform_block_bindings: u32,
};

pub const ImageFormatListCreateInfo = extern struct {
    s_type: StructureType = .image_format_list_create_info,
    p_next: ?*const anyopaque = null,
    view_format_count: u32,
    p_view_formats: *const Format,
};

pub const PhysicalDeviceMaintenance3Properties = extern struct {
    s_type: StructureType = .physical_device_maintenance_3_properties,
    p_next: ?*anyopaque = null,
    max_per_set_descriptors: u32,
    max_memory_allocation_size: DeviceSize,
};

pub const PhysicalDeviceMaintenance4Features = extern struct {
    s_type: StructureType = .physical_device_maintenance_4_features,
    p_next: ?*anyopaque = null,
    maintenance4: Bool32,
};

pub const PhysicalDeviceMaintenance4Properties = extern struct {
    s_type: StructureType = .physical_device_maintenance_4_properties,
    p_next: ?*anyopaque = null,
    max_buffer_size: DeviceSize,
};

pub const DescriptorSetLayoutSupport = extern struct {
    s_type: StructureType = .descriptor_set_layout_support,
    p_next: ?*anyopaque = null,
    supported: Bool32,
};

pub const PhysicalDeviceShaderDrawParametersFeatures = extern struct {
    s_type: StructureType = .physical_device_shader_draw_parameters_features,
    p_next: ?*anyopaque = null,
    shader_draw_parameters: Bool32,
};

pub const PhysicalDeviceShaderFloat16Int8Features = extern struct {
    s_type: StructureType = .physical_device_shader_float16_int8_features,
    p_next: ?*anyopaque = null,
    shader_float16: Bool32,
    shader_int8: Bool32,
};

pub const PhysicalDeviceFloatControlsProperties = extern struct {
    s_type: StructureType = .physical_device_float_controls_properties,
    p_next: ?*anyopaque = null,
    denorm_behavior_independence: ShaderFloatControlsIndependence,
    rounding_mode_independence: ShaderFloatControlsIndependence,
    shader_signed_zero_inf_nan_preserve_float16: Bool32,
    shader_signed_zero_inf_nan_preserve_float32: Bool32,
    shader_signed_zero_inf_nan_preserve_float64: Bool32,
    shader_denorm_preserve_float16: Bool32,
    shader_denorm_preserve_float32: Bool32,
    shader_denorm_preserve_float64: Bool32,
    shader_denorm_flush_to_zero_float16: Bool32,
    shader_denorm_flush_to_zero_float32: Bool32,
    shader_denorm_flush_to_zero_float64: Bool32,
    shader_rounding_mode_rtefloat16: Bool32,
    shader_rounding_mode_rtefloat32: Bool32,
    shader_rounding_mode_rtefloat64: Bool32,
    shader_rounding_mode_rtzfloat16: Bool32,
    shader_rounding_mode_rtzfloat32: Bool32,
    shader_rounding_mode_rtzfloat64: Bool32,
};

pub const PhysicalDeviceHostQueryResetFeatures = extern struct {
    s_type: StructureType = .physical_device_host_query_reset_features,
    p_next: ?*anyopaque = null,
    host_query_reset: Bool32,
};

pub const DebugUtilsObjectNameInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_object_name_info_ext,
    p_next: ?*const anyopaque = null,
    object_type: ObjectType,
    object_handle: u64,
    p_object_name: ?[*:0]const u8,
};

pub const DebugUtilsObjectTagInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_object_tag_info_ext,
    p_next: ?*const anyopaque = null,
    object_type: ObjectType,
    object_handle: u64,
    tag_name: u64,
    tag_size: usize,
    p_tag: *const anyopaque,
};

pub const DebugUtilsLabelEXT = extern struct {
    s_type: StructureType = .debug_utils_label_ext,
    p_next: ?*const anyopaque = null,
    p_label_name: [*:0]const u8,
    color: [4]f32,
};

pub const DebugUtilsMessengerCreateInfoEXT = extern struct {
    s_type: StructureType = .debug_utils_messenger_create_info_ext,
    p_next: ?*const anyopaque = null,
    flags: DebugUtilsMessengerCreateFlagsEXT,
    message_severity: DebugUtilsMessageSeverityFlagsEXT,
    message_type: DebugUtilsMessageTypeFlagsEXT,
    pfn_user_callback: PFN_vkDebugUtilsMessengerCallbackEXT,
    p_user_data: ?*anyopaque,
};

pub const DebugUtilsMessengerCallbackDataEXT = extern struct {
    s_type: StructureType = .debug_utils_messenger_callback_data_ext,
    p_next: ?*const anyopaque = null,
    flags: DebugUtilsMessengerCallbackDataFlagsEXT,
    p_message_id_name: ?[*:0]const u8,
    message_id_number: i32,
    p_message: ?[*:0]const u8,
    queue_label_count: u32,
    p_queue_labels: *const DebugUtilsLabelEXT,
    cmd_buf_label_count: u32,
    p_cmd_buf_labels: *const DebugUtilsLabelEXT,
    object_count: u32,
    p_objects: *const DebugUtilsObjectNameInfoEXT,
};

pub const PhysicalDeviceDescriptorIndexingFeatures = extern struct {
    s_type: StructureType = .physical_device_descriptor_indexing_features,
    p_next: ?*anyopaque = null,
    shader_input_attachment_array_dynamic_indexing: Bool32,
    shader_uniform_texel_buffer_array_dynamic_indexing: Bool32,
    shader_storage_texel_buffer_array_dynamic_indexing: Bool32,
    shader_uniform_buffer_array_non_uniform_indexing: Bool32,
    shader_sampled_image_array_non_uniform_indexing: Bool32,
    shader_storage_buffer_array_non_uniform_indexing: Bool32,
    shader_storage_image_array_non_uniform_indexing: Bool32,
    shader_input_attachment_array_non_uniform_indexing: Bool32,
    shader_uniform_texel_buffer_array_non_uniform_indexing: Bool32,
    shader_storage_texel_buffer_array_non_uniform_indexing: Bool32,
    descriptor_binding_uniform_buffer_update_after_bind: Bool32,
    descriptor_binding_sampled_image_update_after_bind: Bool32,
    descriptor_binding_storage_image_update_after_bind: Bool32,
    descriptor_binding_storage_buffer_update_after_bind: Bool32,
    descriptor_binding_uniform_texel_buffer_update_after_bind: Bool32,
    descriptor_binding_storage_texel_buffer_update_after_bind: Bool32,
    descriptor_binding_update_unused_while_pending: Bool32,
    descriptor_binding_partially_bound: Bool32,
    descriptor_binding_variable_descriptor_count: Bool32,
    runtime_descriptor_array: Bool32,
};

pub const PhysicalDeviceDescriptorIndexingProperties = extern struct {
    s_type: StructureType = .physical_device_descriptor_indexing_properties,
    p_next: ?*anyopaque = null,
    max_update_after_bind_descriptors_in_all_pools: u32,
    shader_uniform_buffer_array_non_uniform_indexing_native: Bool32,
    shader_sampled_image_array_non_uniform_indexing_native: Bool32,
    shader_storage_buffer_array_non_uniform_indexing_native: Bool32,
    shader_storage_image_array_non_uniform_indexing_native: Bool32,
    shader_input_attachment_array_non_uniform_indexing_native: Bool32,
    robust_buffer_access_update_after_bind: Bool32,
    quad_divergent_implicit_lod: Bool32,
    max_per_stage_descriptor_update_after_bind_samplers: u32,
    max_per_stage_descriptor_update_after_bind_uniform_buffers: u32,
    max_per_stage_descriptor_update_after_bind_storage_buffers: u32,
    max_per_stage_descriptor_update_after_bind_sampled_images: u32,
    max_per_stage_descriptor_update_after_bind_storage_images: u32,
    max_per_stage_descriptor_update_after_bind_input_attachments: u32,
    max_per_stage_update_after_bind_resources: u32,
    max_descriptor_set_update_after_bind_samplers: u32,
    max_descriptor_set_update_after_bind_uniform_buffers: u32,
    max_descriptor_set_update_after_bind_uniform_buffers_dynamic: u32,
    max_descriptor_set_update_after_bind_storage_buffers: u32,
    max_descriptor_set_update_after_bind_storage_buffers_dynamic: u32,
    max_descriptor_set_update_after_bind_sampled_images: u32,
    max_descriptor_set_update_after_bind_storage_images: u32,
    max_descriptor_set_update_after_bind_input_attachments: u32,
};

pub const DescriptorSetLayoutBindingFlagsCreateInfo = extern struct {
    s_type: StructureType = .descriptor_set_layout_binding_flags_create_info,
    p_next: ?*const anyopaque = null,
    binding_count: u32,
    p_binding_flags: *const DescriptorBindingFlags,
};

pub const DescriptorSetVariableDescriptorCountAllocateInfo = extern struct {
    s_type: StructureType = .descriptor_set_variable_descriptor_count_allocate_info,
    p_next: ?*const anyopaque = null,
    descriptor_set_count: u32,
    p_descriptor_counts: *const u32,
};

pub const DescriptorSetVariableDescriptorCountLayoutSupport = extern struct {
    s_type: StructureType = .descriptor_set_variable_descriptor_count_layout_support,
    p_next: ?*anyopaque = null,
    max_variable_descriptor_count: u32,
};

pub const AttachmentDescription2 = extern struct {
    s_type: StructureType = .attachment_description_2,
    p_next: ?*const anyopaque = null,
    flags: AttachmentDescriptionFlags,
    format: Format,
    samples: SampleCountFlagBits,
    load_op: AttachmentLoadOp,
    store_op: AttachmentStoreOp,
    stencil_load_op: AttachmentLoadOp,
    stencil_store_op: AttachmentStoreOp,
    initial_layout: ImageLayout,
    final_layout: ImageLayout,
};

pub const AttachmentReference2 = extern struct {
    s_type: StructureType = .attachment_reference_2,
    p_next: ?*const anyopaque = null,
    attachment: u32,
    layout: ImageLayout,
    aspect_mask: ImageAspectFlags,
};

pub const SubpassDescription2 = extern struct {
    s_type: StructureType = .subpass_description_2,
    p_next: ?*const anyopaque = null,
    flags: SubpassDescriptionFlags,
    pipeline_bind_point: PipelineBindPoint,
    view_mask: u32,
    input_attachment_count: u32,
    p_input_attachments: *const AttachmentReference2,
    color_attachment_count: u32,
    p_color_attachments: *const AttachmentReference2,
    p_resolve_attachments: ?*const AttachmentReference2,
    p_depth_stencil_attachment: ?*const AttachmentReference2,
    preserve_attachment_count: u32,
    p_preserve_attachments: *const u32,
};

pub const SubpassDependency2 = extern struct {
    s_type: StructureType = .subpass_dependency_2,
    p_next: ?*const anyopaque = null,
    src_subpass: u32,
    dst_subpass: u32,
    src_stage_mask: PipelineStageFlags,
    dst_stage_mask: PipelineStageFlags,
    src_access_mask: AccessFlags,
    dst_access_mask: AccessFlags,
    dependency_flags: DependencyFlags,
    view_offset: i32,
};

pub const RenderPassCreateInfo2 = extern struct {
    s_type: StructureType = .render_pass_create_info_2,
    p_next: ?*const anyopaque = null,
    flags: RenderPassCreateFlags,
    attachment_count: u32,
    p_attachments: *const AttachmentDescription2,
    subpass_count: u32,
    p_subpasses: *const SubpassDescription2,
    dependency_count: u32,
    p_dependencies: *const SubpassDependency2,
    correlated_view_mask_count: u32,
    p_correlated_view_masks: *const u32,
};

pub const SubpassBeginInfo = extern struct {
    s_type: StructureType = .subpass_begin_info,
    p_next: ?*const anyopaque = null,
    contents: SubpassContents,
};

pub const SubpassEndInfo = extern struct {
    s_type: StructureType = .subpass_end_info,
    p_next: ?*const anyopaque = null,
};

pub const PhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    s_type: StructureType = .physical_device_timeline_semaphore_features,
    p_next: ?*anyopaque = null,
    timeline_semaphore: Bool32,
};

pub const PhysicalDeviceTimelineSemaphoreProperties = extern struct {
    s_type: StructureType = .physical_device_timeline_semaphore_properties,
    p_next: ?*anyopaque = null,
    max_timeline_semaphore_value_difference: u64,
};

pub const SemaphoreTypeCreateInfo = extern struct {
    s_type: StructureType = .semaphore_type_create_info,
    p_next: ?*const anyopaque = null,
    semaphore_type: SemaphoreType,
    initial_value: u64,
};

pub const TimelineSemaphoreSubmitInfo = extern struct {
    s_type: StructureType = .timeline_semaphore_submit_info,
    p_next: ?*const anyopaque = null,
    wait_semaphore_value_count: u32,
    p_wait_semaphore_values: ?*const u64,
    signal_semaphore_value_count: u32,
    p_signal_semaphore_values: ?*const u64,
};

pub const SemaphoreWaitInfo = extern struct {
    s_type: StructureType = .semaphore_wait_info,
    p_next: ?*const anyopaque = null,
    flags: SemaphoreWaitFlags,
    semaphore_count: u32,
    p_semaphores: *const Semaphore,
    p_values: *const u64,
};

pub const SemaphoreSignalInfo = extern struct {
    s_type: StructureType = .semaphore_signal_info,
    p_next: ?*const anyopaque = null,
    semaphore: Semaphore,
    value: u64,
};

pub const PhysicalDevice8BitStorageFeatures = extern struct {
    s_type: StructureType = .physical_device_8bit_storage_features,
    p_next: ?*anyopaque = null,
    storage_buffer8_bit_access: Bool32,
    uniform_and_storage_buffer8_bit_access: Bool32,
    storage_push_constant8: Bool32,
};

pub const PhysicalDeviceVulkanMemoryModelFeatures = extern struct {
    s_type: StructureType = .physical_device_vulkan_memory_model_features,
    p_next: ?*anyopaque = null,
    vulkan_memory_model: Bool32,
    vulkan_memory_model_device_scope: Bool32,
    vulkan_memory_model_availability_visibility_chains: Bool32,
};

pub const PhysicalDeviceShaderAtomicInt64Features = extern struct {
    s_type: StructureType = .physical_device_shader_atomic_int64_features,
    p_next: ?*anyopaque = null,
    shader_buffer_int64_atomics: Bool32,
    shader_shared_int64_atomics: Bool32,
};

pub const PhysicalDeviceDepthStencilResolveProperties = extern struct {
    s_type: StructureType = .physical_device_depth_stencil_resolve_properties,
    p_next: ?*anyopaque = null,
    supported_depth_resolve_modes: ResolveModeFlags,
    supported_stencil_resolve_modes: ResolveModeFlags,
    independent_resolve_none: Bool32,
    independent_resolve: Bool32,
};

pub const SubpassDescriptionDepthStencilResolve = extern struct {
    s_type: StructureType = .subpass_description_depth_stencil_resolve,
    p_next: ?*const anyopaque = null,
    depth_resolve_mode: ResolveModeFlagBits,
    stencil_resolve_mode: ResolveModeFlagBits,
    p_depth_stencil_resolve_attachment: ?*const AttachmentReference2,
};

pub const ImageStencilUsageCreateInfo = extern struct {
    s_type: StructureType = .image_stencil_usage_create_info,
    p_next: ?*const anyopaque = null,
    stencil_usage: ImageUsageFlags,
};

pub const PhysicalDeviceScalarBlockLayoutFeatures = extern struct {
    s_type: StructureType = .physical_device_scalar_block_layout_features,
    p_next: ?*anyopaque = null,
    scalar_block_layout: Bool32,
};

pub const PhysicalDeviceUniformBufferStandardLayoutFeatures = extern struct {
    s_type: StructureType = .physical_device_uniform_buffer_standard_layout_features,
    p_next: ?*anyopaque = null,
    uniform_buffer_standard_layout: Bool32,
};

pub const PhysicalDeviceBufferDeviceAddressFeatures = extern struct {
    s_type: StructureType = .physical_device_buffer_device_address_features,
    p_next: ?*anyopaque = null,
    buffer_device_address: Bool32,
    buffer_device_address_capture_replay: Bool32,
    buffer_device_address_multi_device: Bool32,
};

pub const BufferDeviceAddressInfo = extern struct {
    s_type: StructureType = .buffer_device_address_info,
    p_next: ?*const anyopaque = null,
    buffer: Buffer,
};

pub const BufferOpaqueCaptureAddressCreateInfo = extern struct {
    s_type: StructureType = .buffer_opaque_capture_address_create_info,
    p_next: ?*const anyopaque = null,
    opaque_capture_address: u64,
};

pub const PhysicalDeviceImagelessFramebufferFeatures = extern struct {
    s_type: StructureType = .physical_device_imageless_framebuffer_features,
    p_next: ?*anyopaque = null,
    imageless_framebuffer: Bool32,
};

pub const FramebufferAttachmentsCreateInfo = extern struct {
    s_type: StructureType = .framebuffer_attachments_create_info,
    p_next: ?*const anyopaque = null,
    attachment_image_info_count: u32,
    p_attachment_image_infos: *const FramebufferAttachmentImageInfo,
};

pub const FramebufferAttachmentImageInfo = extern struct {
    s_type: StructureType = .framebuffer_attachment_image_info,
    p_next: ?*const anyopaque = null,
    flags: ImageCreateFlags,
    usage: ImageUsageFlags,
    width: u32,
    height: u32,
    layer_count: u32,
    view_format_count: u32,
    p_view_formats: *const Format,
};

pub const RenderPassAttachmentBeginInfo = extern struct {
    s_type: StructureType = .render_pass_attachment_begin_info,
    p_next: ?*const anyopaque = null,
    attachment_count: u32,
    p_attachments: *const ImageView,
};

pub const PhysicalDeviceTextureCompressionASTCHDRFeatures = extern struct {
    s_type: StructureType = .physical_device_texture_compression_astc_hdr_features,
    p_next: ?*anyopaque = null,
    texture_compression_astc__hdr: Bool32,
};

pub const PipelineCreationFeedback = extern struct {
    flags: PipelineCreationFeedbackFlags,
    duration: u64,
};

pub const PipelineCreationFeedbackCreateInfo = extern struct {
    s_type: StructureType = .pipeline_creation_feedback_create_info,
    p_next: ?*const anyopaque = null,
    p_pipeline_creation_feedback: *PipelineCreationFeedback,
    pipeline_stage_creation_feedback_count: u32,
    p_pipeline_stage_creation_feedbacks: *PipelineCreationFeedback,
};

pub const PhysicalDeviceSeparateDepthStencilLayoutsFeatures = extern struct {
    s_type: StructureType = .physical_device_separate_depth_stencil_layouts_features,
    p_next: ?*anyopaque = null,
    separate_depth_stencil_layouts: Bool32,
};

pub const AttachmentReferenceStencilLayout = extern struct {
    s_type: StructureType = .attachment_reference_stencil_layout,
    p_next: ?*anyopaque = null,
    stencil_layout: ImageLayout,
};

pub const AttachmentDescriptionStencilLayout = extern struct {
    s_type: StructureType = .attachment_description_stencil_layout,
    p_next: ?*anyopaque = null,
    stencil_initial_layout: ImageLayout,
    stencil_final_layout: ImageLayout,
};

pub const PhysicalDeviceShaderDemoteToHelperInvocationFeatures = extern struct {
    s_type: StructureType = .physical_device_shader_demote_to_helper_invocation_features,
    p_next: ?*anyopaque = null,
    shader_demote_to_helper_invocation: Bool32,
};

pub const PhysicalDeviceTexelBufferAlignmentProperties = extern struct {
    s_type: StructureType = .physical_device_texel_buffer_alignment_properties,
    p_next: ?*anyopaque = null,
    storage_texel_buffer_offset_alignment_bytes: DeviceSize,
    storage_texel_buffer_offset_single_texel_alignment: Bool32,
    uniform_texel_buffer_offset_alignment_bytes: DeviceSize,
    uniform_texel_buffer_offset_single_texel_alignment: Bool32,
};

pub const PhysicalDeviceSubgroupSizeControlFeatures = extern struct {
    s_type: StructureType = .physical_device_subgroup_size_control_features,
    p_next: ?*anyopaque = null,
    subgroup_size_control: Bool32,
    compute_full_subgroups: Bool32,
};

pub const PhysicalDeviceSubgroupSizeControlProperties = extern struct {
    s_type: StructureType = .physical_device_subgroup_size_control_properties,
    p_next: ?*anyopaque = null,
    min_subgroup_size: u32,
    max_subgroup_size: u32,
    max_compute_workgroup_subgroups: u32,
    required_subgroup_size_stages: ShaderStageFlags,
};

pub const PipelineShaderStageRequiredSubgroupSizeCreateInfo = extern struct {
    s_type: StructureType = .pipeline_shader_stage_required_subgroup_size_create_info,
    p_next: ?*const anyopaque = null,
    required_subgroup_size: u32,
};

pub const MemoryOpaqueCaptureAddressAllocateInfo = extern struct {
    s_type: StructureType = .memory_opaque_capture_address_allocate_info,
    p_next: ?*const anyopaque = null,
    opaque_capture_address: u64,
};

pub const DeviceMemoryOpaqueCaptureAddressInfo = extern struct {
    s_type: StructureType = .device_memory_opaque_capture_address_info,
    p_next: ?*const anyopaque = null,
    memory: DeviceMemory,
};

pub const PhysicalDevicePipelineCreationCacheControlFeatures = extern struct {
    s_type: StructureType = .physical_device_pipeline_creation_cache_control_features,
    p_next: ?*anyopaque = null,
    pipeline_creation_cache_control: Bool32,
};

pub const PhysicalDeviceVulkan11Features = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_1_features,
    p_next: ?*anyopaque = null,
    storage_buffer16_bit_access: Bool32,
    uniform_and_storage_buffer16_bit_access: Bool32,
    storage_push_constant16: Bool32,
    storage_input_output16: Bool32,
    multiview: Bool32,
    multiview_geometry_shader: Bool32,
    multiview_tessellation_shader: Bool32,
    variable_pointers_storage_buffer: Bool32,
    variable_pointers: Bool32,
    protected_memory: Bool32,
    sampler_ycbcr_conversion: Bool32,
    shader_draw_parameters: Bool32,
};

pub const PhysicalDeviceVulkan11Properties = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_1_properties,
    p_next: ?*anyopaque = null,
    device_uuid: [UUID_SIZE]u8,
    driver_uuid: [UUID_SIZE]u8,
    device_luid: [LUID_SIZE]u8,
    device_node_mask: u32,
    device_luidvalid: Bool32,
    subgroup_size: u32,
    subgroup_supported_stages: ShaderStageFlags,
    subgroup_supported_operations: SubgroupFeatureFlags,
    subgroup_quad_operations_in_all_stages: Bool32,
    point_clipping_behavior: PointClippingBehavior,
    max_multiview_view_count: u32,
    max_multiview_instance_index: u32,
    protected_no_fault: Bool32,
    max_per_set_descriptors: u32,
    max_memory_allocation_size: DeviceSize,
};

pub const PhysicalDeviceVulkan12Features = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_2_features,
    p_next: ?*anyopaque = null,
    sampler_mirror_clamp_to_edge: Bool32,
    draw_indirect_count: Bool32,
    storage_buffer8_bit_access: Bool32,
    uniform_and_storage_buffer8_bit_access: Bool32,
    storage_push_constant8: Bool32,
    shader_buffer_int64_atomics: Bool32,
    shader_shared_int64_atomics: Bool32,
    shader_float16: Bool32,
    shader_int8: Bool32,
    descriptor_indexing: Bool32,
    shader_input_attachment_array_dynamic_indexing: Bool32,
    shader_uniform_texel_buffer_array_dynamic_indexing: Bool32,
    shader_storage_texel_buffer_array_dynamic_indexing: Bool32,
    shader_uniform_buffer_array_non_uniform_indexing: Bool32,
    shader_sampled_image_array_non_uniform_indexing: Bool32,
    shader_storage_buffer_array_non_uniform_indexing: Bool32,
    shader_storage_image_array_non_uniform_indexing: Bool32,
    shader_input_attachment_array_non_uniform_indexing: Bool32,
    shader_uniform_texel_buffer_array_non_uniform_indexing: Bool32,
    shader_storage_texel_buffer_array_non_uniform_indexing: Bool32,
    descriptor_binding_uniform_buffer_update_after_bind: Bool32,
    descriptor_binding_sampled_image_update_after_bind: Bool32,
    descriptor_binding_storage_image_update_after_bind: Bool32,
    descriptor_binding_storage_buffer_update_after_bind: Bool32,
    descriptor_binding_uniform_texel_buffer_update_after_bind: Bool32,
    descriptor_binding_storage_texel_buffer_update_after_bind: Bool32,
    descriptor_binding_update_unused_while_pending: Bool32,
    descriptor_binding_partially_bound: Bool32,
    descriptor_binding_variable_descriptor_count: Bool32,
    runtime_descriptor_array: Bool32,
    sampler_filter_minmax: Bool32,
    scalar_block_layout: Bool32,
    imageless_framebuffer: Bool32,
    uniform_buffer_standard_layout: Bool32,
    shader_subgroup_extended_types: Bool32,
    separate_depth_stencil_layouts: Bool32,
    host_query_reset: Bool32,
    timeline_semaphore: Bool32,
    buffer_device_address: Bool32,
    buffer_device_address_capture_replay: Bool32,
    buffer_device_address_multi_device: Bool32,
    vulkan_memory_model: Bool32,
    vulkan_memory_model_device_scope: Bool32,
    vulkan_memory_model_availability_visibility_chains: Bool32,
    shader_output_viewport_index: Bool32,
    shader_output_layer: Bool32,
    subgroup_broadcast_dynamic_id: Bool32,
};

pub const PhysicalDeviceVulkan12Properties = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_2_properties,
    p_next: ?*anyopaque = null,
    driver_id: DriverId,
    driver_name: [MAX_DRIVER_NAME_SIZE]u8,
    driver_info: [MAX_DRIVER_INFO_SIZE]u8,
    conformance_version: ConformanceVersion,
    denorm_behavior_independence: ShaderFloatControlsIndependence,
    rounding_mode_independence: ShaderFloatControlsIndependence,
    shader_signed_zero_inf_nan_preserve_float16: Bool32,
    shader_signed_zero_inf_nan_preserve_float32: Bool32,
    shader_signed_zero_inf_nan_preserve_float64: Bool32,
    shader_denorm_preserve_float16: Bool32,
    shader_denorm_preserve_float32: Bool32,
    shader_denorm_preserve_float64: Bool32,
    shader_denorm_flush_to_zero_float16: Bool32,
    shader_denorm_flush_to_zero_float32: Bool32,
    shader_denorm_flush_to_zero_float64: Bool32,
    shader_rounding_mode_rtefloat16: Bool32,
    shader_rounding_mode_rtefloat32: Bool32,
    shader_rounding_mode_rtefloat64: Bool32,
    shader_rounding_mode_rtzfloat16: Bool32,
    shader_rounding_mode_rtzfloat32: Bool32,
    shader_rounding_mode_rtzfloat64: Bool32,
    max_update_after_bind_descriptors_in_all_pools: u32,
    shader_uniform_buffer_array_non_uniform_indexing_native: Bool32,
    shader_sampled_image_array_non_uniform_indexing_native: Bool32,
    shader_storage_buffer_array_non_uniform_indexing_native: Bool32,
    shader_storage_image_array_non_uniform_indexing_native: Bool32,
    shader_input_attachment_array_non_uniform_indexing_native: Bool32,
    robust_buffer_access_update_after_bind: Bool32,
    quad_divergent_implicit_lod: Bool32,
    max_per_stage_descriptor_update_after_bind_samplers: u32,
    max_per_stage_descriptor_update_after_bind_uniform_buffers: u32,
    max_per_stage_descriptor_update_after_bind_storage_buffers: u32,
    max_per_stage_descriptor_update_after_bind_sampled_images: u32,
    max_per_stage_descriptor_update_after_bind_storage_images: u32,
    max_per_stage_descriptor_update_after_bind_input_attachments: u32,
    max_per_stage_update_after_bind_resources: u32,
    max_descriptor_set_update_after_bind_samplers: u32,
    max_descriptor_set_update_after_bind_uniform_buffers: u32,
    max_descriptor_set_update_after_bind_uniform_buffers_dynamic: u32,
    max_descriptor_set_update_after_bind_storage_buffers: u32,
    max_descriptor_set_update_after_bind_storage_buffers_dynamic: u32,
    max_descriptor_set_update_after_bind_sampled_images: u32,
    max_descriptor_set_update_after_bind_storage_images: u32,
    max_descriptor_set_update_after_bind_input_attachments: u32,
    supported_depth_resolve_modes: ResolveModeFlags,
    supported_stencil_resolve_modes: ResolveModeFlags,
    independent_resolve_none: Bool32,
    independent_resolve: Bool32,
    filter_minmax_single_component_formats: Bool32,
    filter_minmax_image_component_mapping: Bool32,
    max_timeline_semaphore_value_difference: u64,
    framebuffer_integer_color_sample_counts: SampleCountFlags,
};

pub const PhysicalDeviceVulkan13Features = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_3_features,
    p_next: ?*anyopaque = null,
    robust_image_access: Bool32,
    inline_uniform_block: Bool32,
    descriptor_binding_inline_uniform_block_update_after_bind: Bool32,
    pipeline_creation_cache_control: Bool32,
    private_data: Bool32,
    shader_demote_to_helper_invocation: Bool32,
    shader_terminate_invocation: Bool32,
    subgroup_size_control: Bool32,
    compute_full_subgroups: Bool32,
    synchronization2: Bool32,
    texture_compression_astc__hdr: Bool32,
    shader_zero_initialize_workgroup_memory: Bool32,
    dynamic_rendering: Bool32,
    shader_integer_dot_product: Bool32,
    maintenance4: Bool32,
};

pub const PhysicalDeviceVulkan13Properties = extern struct {
    s_type: StructureType = .physical_device_vulkan_1_3_properties,
    p_next: ?*anyopaque = null,
    min_subgroup_size: u32,
    max_subgroup_size: u32,
    max_compute_workgroup_subgroups: u32,
    required_subgroup_size_stages: ShaderStageFlags,
    max_inline_uniform_block_size: u32,
    max_per_stage_descriptor_inline_uniform_blocks: u32,
    max_per_stage_descriptor_update_after_bind_inline_uniform_blocks: u32,
    max_descriptor_set_inline_uniform_blocks: u32,
    max_descriptor_set_update_after_bind_inline_uniform_blocks: u32,
    max_inline_uniform_total_size: u32,
    integer_dot_product8_bit_unsigned_accelerated: Bool32,
    integer_dot_product8_bit_signed_accelerated: Bool32,
    integer_dot_product8_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product4x8_bit_packed_unsigned_accelerated: Bool32,
    integer_dot_product4x8_bit_packed_signed_accelerated: Bool32,
    integer_dot_product4x8_bit_packed_mixed_signedness_accelerated: Bool32,
    integer_dot_product16_bit_unsigned_accelerated: Bool32,
    integer_dot_product16_bit_signed_accelerated: Bool32,
    integer_dot_product16_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product32_bit_unsigned_accelerated: Bool32,
    integer_dot_product32_bit_signed_accelerated: Bool32,
    integer_dot_product32_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product64_bit_unsigned_accelerated: Bool32,
    integer_dot_product64_bit_signed_accelerated: Bool32,
    integer_dot_product64_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating8_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating8_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating8_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating4x8_bit_packed_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating4x8_bit_packed_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating4x8_bit_packed_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating16_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating16_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating16_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating32_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating32_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating32_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating64_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating64_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating64_bit_mixed_signedness_accelerated: Bool32,
    storage_texel_buffer_offset_alignment_bytes: DeviceSize,
    storage_texel_buffer_offset_single_texel_alignment: Bool32,
    uniform_texel_buffer_offset_alignment_bytes: DeviceSize,
    uniform_texel_buffer_offset_single_texel_alignment: Bool32,
    max_buffer_size: DeviceSize,
};

pub const PhysicalDeviceToolProperties = extern struct {
    s_type: StructureType = .physical_device_tool_properties,
    p_next: ?*anyopaque = null,
    name: [MAX_EXTENSION_NAME_SIZE]u8,
    version: [MAX_EXTENSION_NAME_SIZE]u8,
    purposes: ToolPurposeFlags,
    description: [MAX_DESCRIPTION_SIZE]u8,
    layer: [MAX_EXTENSION_NAME_SIZE]u8,
};

pub const PhysicalDeviceZeroInitializeWorkgroupMemoryFeatures = extern struct {
    s_type: StructureType = .physical_device_zero_initialize_workgroup_memory_features,
    p_next: ?*anyopaque = null,
    shader_zero_initialize_workgroup_memory: Bool32,
};

pub const PhysicalDeviceImageRobustnessFeatures = extern struct {
    s_type: StructureType = .physical_device_image_robustness_features,
    p_next: ?*anyopaque = null,
    robust_image_access: Bool32,
};

pub const BufferCopy2 = extern struct {
    s_type: StructureType = .buffer_copy_2,
    p_next: ?*const anyopaque = null,
    src_offset: DeviceSize,
    dst_offset: DeviceSize,
    size: DeviceSize,
};

pub const ImageCopy2 = extern struct {
    s_type: StructureType = .image_copy_2,
    p_next: ?*const anyopaque = null,
    src_subresource: ImageSubresourceLayers,
    src_offset: Offset3D,
    dst_subresource: ImageSubresourceLayers,
    dst_offset: Offset3D,
    extent: Extent3D,
};

pub const ImageBlit2 = extern struct {
    s_type: StructureType = .image_blit_2,
    p_next: ?*const anyopaque = null,
    src_subresource: ImageSubresourceLayers,
    src_offsets: [2]Offset3D,
    dst_subresource: ImageSubresourceLayers,
    dst_offsets: [2]Offset3D,
};

pub const BufferImageCopy2 = extern struct {
    s_type: StructureType = .buffer_image_copy_2,
    p_next: ?*const anyopaque = null,
    buffer_offset: DeviceSize,
    buffer_row_length: u32,
    buffer_image_height: u32,
    image_subresource: ImageSubresourceLayers,
    image_offset: Offset3D,
    image_extent: Extent3D,
};

pub const ImageResolve2 = extern struct {
    s_type: StructureType = .image_resolve_2,
    p_next: ?*const anyopaque = null,
    src_subresource: ImageSubresourceLayers,
    src_offset: Offset3D,
    dst_subresource: ImageSubresourceLayers,
    dst_offset: Offset3D,
    extent: Extent3D,
};

pub const CopyBufferInfo2 = extern struct {
    s_type: StructureType = .copy_buffer_info_2,
    p_next: ?*const anyopaque = null,
    src_buffer: Buffer,
    dst_buffer: Buffer,
    region_count: u32,
    p_regions: *const BufferCopy2,
};

pub const CopyImageInfo2 = extern struct {
    s_type: StructureType = .copy_image_info_2,
    p_next: ?*const anyopaque = null,
    src_image: Image,
    src_image_layout: ImageLayout,
    dst_image: Image,
    dst_image_layout: ImageLayout,
    region_count: u32,
    p_regions: *const ImageCopy2,
};

pub const BlitImageInfo2 = extern struct {
    s_type: StructureType = .blit_image_info_2,
    p_next: ?*const anyopaque = null,
    src_image: Image,
    src_image_layout: ImageLayout,
    dst_image: Image,
    dst_image_layout: ImageLayout,
    region_count: u32,
    p_regions: *const ImageBlit2,
    filter: Filter,
};

pub const CopyBufferToImageInfo2 = extern struct {
    s_type: StructureType = .copy_buffer_to_image_info_2,
    p_next: ?*const anyopaque = null,
    src_buffer: Buffer,
    dst_image: Image,
    dst_image_layout: ImageLayout,
    region_count: u32,
    p_regions: *const BufferImageCopy2,
};

pub const CopyImageToBufferInfo2 = extern struct {
    s_type: StructureType = .copy_image_to_buffer_info_2,
    p_next: ?*const anyopaque = null,
    src_image: Image,
    src_image_layout: ImageLayout,
    dst_buffer: Buffer,
    region_count: u32,
    p_regions: *const BufferImageCopy2,
};

pub const ResolveImageInfo2 = extern struct {
    s_type: StructureType = .resolve_image_info_2,
    p_next: ?*const anyopaque = null,
    src_image: Image,
    src_image_layout: ImageLayout,
    dst_image: Image,
    dst_image_layout: ImageLayout,
    region_count: u32,
    p_regions: *const ImageResolve2,
};

pub const PhysicalDeviceShaderTerminateInvocationFeatures = extern struct {
    s_type: StructureType = .physical_device_shader_terminate_invocation_features,
    p_next: ?*anyopaque = null,
    shader_terminate_invocation: Bool32,
};

pub const MemoryBarrier2 = extern struct {
    s_type: StructureType = .memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: PipelineStageFlags2,
    src_access_mask: AccessFlags2,
    dst_stage_mask: PipelineStageFlags2,
    dst_access_mask: AccessFlags2,
};

pub const ImageMemoryBarrier2 = extern struct {
    s_type: StructureType = .image_memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: PipelineStageFlags2,
    src_access_mask: AccessFlags2,
    dst_stage_mask: PipelineStageFlags2,
    dst_access_mask: AccessFlags2,
    old_layout: ImageLayout,
    new_layout: ImageLayout,
    src_queue_family_index: u32,
    dst_queue_family_index: u32,
    image: Image,
    subresource_range: ImageSubresourceRange,
};

pub const BufferMemoryBarrier2 = extern struct {
    s_type: StructureType = .buffer_memory_barrier_2,
    p_next: ?*const anyopaque = null,
    src_stage_mask: PipelineStageFlags2,
    src_access_mask: AccessFlags2,
    dst_stage_mask: PipelineStageFlags2,
    dst_access_mask: AccessFlags2,
    src_queue_family_index: u32,
    dst_queue_family_index: u32,
    buffer: Buffer,
    offset: DeviceSize,
    size: DeviceSize,
};

pub const DependencyInfo = extern struct {
    s_type: StructureType = .dependency_info,
    p_next: ?*const anyopaque = null,
    dependency_flags: DependencyFlags,
    memory_barrier_count: u32,
    p_memory_barriers: *const MemoryBarrier2,
    buffer_memory_barrier_count: u32,
    p_buffer_memory_barriers: *const BufferMemoryBarrier2,
    image_memory_barrier_count: u32,
    p_image_memory_barriers: *const ImageMemoryBarrier2,
};

pub const SemaphoreSubmitInfo = extern struct {
    s_type: StructureType = .semaphore_submit_info,
    p_next: ?*const anyopaque = null,
    semaphore: Semaphore,
    value: u64,
    stage_mask: PipelineStageFlags2,
    device_index: u32,
};

pub const CommandBufferSubmitInfo = extern struct {
    s_type: StructureType = .command_buffer_submit_info,
    p_next: ?*const anyopaque = null,
    command_buffer: *CommandBuffer,
    device_mask: u32,
};

pub const SubmitInfo2 = extern struct {
    s_type: StructureType = .submit_info_2,
    p_next: ?*const anyopaque = null,
    flags: SubmitFlags,
    wait_semaphore_info_count: u32,
    p_wait_semaphore_infos: *const SemaphoreSubmitInfo,
    command_buffer_info_count: u32,
    p_command_buffer_infos: *const CommandBufferSubmitInfo,
    signal_semaphore_info_count: u32,
    p_signal_semaphore_infos: *const SemaphoreSubmitInfo,
};

pub const PhysicalDeviceSynchronization2Features = extern struct {
    s_type: StructureType = .physical_device_synchronization_2_features,
    p_next: ?*anyopaque = null,
    synchronization2: Bool32,
};

pub const PhysicalDeviceShaderIntegerDotProductFeatures = extern struct {
    s_type: StructureType = .physical_device_shader_integer_dot_product_features,
    p_next: ?*anyopaque = null,
    shader_integer_dot_product: Bool32,
};

pub const PhysicalDeviceShaderIntegerDotProductProperties = extern struct {
    s_type: StructureType = .physical_device_shader_integer_dot_product_properties,
    p_next: ?*anyopaque = null,
    integer_dot_product8_bit_unsigned_accelerated: Bool32,
    integer_dot_product8_bit_signed_accelerated: Bool32,
    integer_dot_product8_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product4x8_bit_packed_unsigned_accelerated: Bool32,
    integer_dot_product4x8_bit_packed_signed_accelerated: Bool32,
    integer_dot_product4x8_bit_packed_mixed_signedness_accelerated: Bool32,
    integer_dot_product16_bit_unsigned_accelerated: Bool32,
    integer_dot_product16_bit_signed_accelerated: Bool32,
    integer_dot_product16_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product32_bit_unsigned_accelerated: Bool32,
    integer_dot_product32_bit_signed_accelerated: Bool32,
    integer_dot_product32_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product64_bit_unsigned_accelerated: Bool32,
    integer_dot_product64_bit_signed_accelerated: Bool32,
    integer_dot_product64_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating8_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating8_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating8_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating4x8_bit_packed_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating4x8_bit_packed_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating4x8_bit_packed_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating16_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating16_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating16_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating32_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating32_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating32_bit_mixed_signedness_accelerated: Bool32,
    integer_dot_product_accumulating_saturating64_bit_unsigned_accelerated: Bool32,
    integer_dot_product_accumulating_saturating64_bit_signed_accelerated: Bool32,
    integer_dot_product_accumulating_saturating64_bit_mixed_signedness_accelerated: Bool32,
};

pub const FormatProperties3 = extern struct {
    s_type: StructureType = .format_properties_3,
    p_next: ?*anyopaque = null,
    linear_tiling_features: FormatFeatureFlags2,
    optimal_tiling_features: FormatFeatureFlags2,
    buffer_features: FormatFeatureFlags2,
};

pub const PipelineRenderingCreateInfo = extern struct {
    s_type: StructureType = .pipeline_rendering_create_info,
    p_next: ?*const anyopaque = null,
    view_mask: u32,
    color_attachment_count: u32,
    p_color_attachment_formats: *const Format,
    depth_attachment_format: Format,
    stencil_attachment_format: Format,
};

pub const RenderingInfo = extern struct {
    s_type: StructureType = .rendering_info,
    p_next: ?*const anyopaque = null,
    flags: RenderingFlags,
    render_area: Rect2D,
    layer_count: u32,
    view_mask: u32,
    color_attachment_count: u32,
    p_color_attachments: *const RenderingAttachmentInfo,
    p_depth_attachment: ?*const RenderingAttachmentInfo,
    p_stencil_attachment: ?*const RenderingAttachmentInfo,
};

pub const RenderingAttachmentInfo = extern struct {
    s_type: StructureType = .rendering_attachment_info,
    p_next: ?*const anyopaque = null,
    image_view: ImageView,
    image_layout: ImageLayout,
    resolve_mode: ResolveModeFlagBits,
    resolve_image_view: ImageView,
    resolve_image_layout: ImageLayout,
    load_op: AttachmentLoadOp,
    store_op: AttachmentStoreOp,
    clear_value: ClearValue,
};

pub const PhysicalDeviceDynamicRenderingFeatures = extern struct {
    s_type: StructureType = .physical_device_dynamic_rendering_features,
    p_next: ?*anyopaque = null,
    dynamic_rendering: Bool32,
};

pub const CommandBufferInheritanceRenderingInfo = extern struct {
    s_type: StructureType = .command_buffer_inheritance_rendering_info,
    p_next: ?*const anyopaque = null,
    flags: RenderingFlags,
    view_mask: u32,
    color_attachment_count: u32,
    p_color_attachment_formats: *const Format,
    depth_attachment_format: Format,
    stencil_attachment_format: Format,
    rasterization_samples: SampleCountFlagBits,
};

// ---- Unions ----

pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const ClearValue = extern union {
    color: ClearColorValue,
    depth_stencil: ClearDepthStencilValue,
};

// ---- Aliases ----

pub const PhysicalDeviceVariablePointerFeatures = PhysicalDeviceVariablePointersFeatures;
pub const PhysicalDeviceShaderDrawParameterFeatures = PhysicalDeviceShaderDrawParametersFeatures;

// ---- Error set + checkResult helper ----

pub const Error = error{
    LoaderNotFound,
    SymbolNotFound,
    Unknown,
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    SurfaceLost,
    NativeWindowInUse,
    OutOfDate,
    IncompatibleDisplay,
    ValidationFailed,
    InvalidShader,
    OutOfPoolMemory,
    InvalidExternalHandle,
    Fragmentation,
    InvalidOpaqueCaptureAddress,
    PipelineCompileRequired,
    UnknownVkResult,
};

pub fn checkResult(r: Result) Error!void {
    return switch (r) {
        .success, .not_ready, .timeout, .event_set, .event_reset, .incomplete, .suboptimal_khr => {},
        .error_out_of_host_memory => error.OutOfHostMemory,
        .error_out_of_device_memory => error.OutOfDeviceMemory,
        .error_initialization_failed => error.InitializationFailed,
        .error_device_lost => error.DeviceLost,
        .error_memory_map_failed => error.MemoryMapFailed,
        .error_layer_not_present => error.LayerNotPresent,
        .error_extension_not_present => error.ExtensionNotPresent,
        .error_feature_not_present => error.FeatureNotPresent,
        .error_incompatible_driver => error.IncompatibleDriver,
        .error_too_many_objects => error.TooManyObjects,
        .error_format_not_supported => error.FormatNotSupported,
        .error_fragmented_pool => error.FragmentedPool,
        .error_surface_lost_khr => error.SurfaceLost,
        .error_native_window_in_use_khr => error.NativeWindowInUse,
        .error_out_of_date_khr => error.OutOfDate,
        .error_incompatible_display_khr => error.IncompatibleDisplay,
        .error_validation_failed_ext => error.ValidationFailed,
        .error_invalid_shader_nv => error.InvalidShader,
        else => if (@intFromEnum(r) < 0) error.Unknown else {},
    };
}

// ---- PFN_* command function pointer types ----

pub const PFN_vkCreateInstance = *const fn (*const InstanceCreateInfo, ?*const AllocationCallbacks, **Instance) callconv(.c) Result;
pub const PFN_vkDestroyInstance = *const fn (*Instance, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkEnumeratePhysicalDevices = *const fn (*Instance, *u32, ?**PhysicalDevice) callconv(.c) Result;
pub const PFN_vkGetDeviceProcAddr = *const fn (*Device, [*:0]const u8) callconv(.c) PFN_vkVoidFunction;
pub const PFN_vkGetInstanceProcAddr = *const fn (*Instance, [*:0]const u8) callconv(.c) PFN_vkVoidFunction;
pub const PFN_vkGetPhysicalDeviceProperties = *const fn (*PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceQueueFamilyProperties = *const fn (*PhysicalDevice, *u32, ?*QueueFamilyProperties) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceMemoryProperties = *const fn (*PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceFeatures = *const fn (*PhysicalDevice, *PhysicalDeviceFeatures) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceFormatProperties = *const fn (*PhysicalDevice, Format, *FormatProperties) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceImageFormatProperties = *const fn (*PhysicalDevice, Format, ImageType, ImageTiling, ImageUsageFlags, ImageCreateFlags, *ImageFormatProperties) callconv(.c) Result;
pub const PFN_vkCreateDevice = *const fn (*PhysicalDevice, *const DeviceCreateInfo, ?*const AllocationCallbacks, **Device) callconv(.c) Result;
pub const PFN_vkDestroyDevice = *const fn (*Device, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkEnumerateInstanceVersion = *const fn (*u32) callconv(.c) Result;
pub const PFN_vkEnumerateInstanceLayerProperties = *const fn (*u32, ?*LayerProperties) callconv(.c) Result;
pub const PFN_vkEnumerateInstanceExtensionProperties = *const fn (?[*:0]const u8, *u32, ?*ExtensionProperties) callconv(.c) Result;
pub const PFN_vkEnumerateDeviceLayerProperties = *const fn (*PhysicalDevice, *u32, ?*LayerProperties) callconv(.c) Result;
pub const PFN_vkEnumerateDeviceExtensionProperties = *const fn (*PhysicalDevice, ?[*:0]const u8, *u32, ?*ExtensionProperties) callconv(.c) Result;
pub const PFN_vkGetDeviceQueue = *const fn (*Device, u32, u32, **Queue) callconv(.c) void;
pub const PFN_vkQueueSubmit = *const fn (*Queue, u32, *const SubmitInfo, Fence) callconv(.c) Result;
pub const PFN_vkQueueWaitIdle = *const fn (*Queue) callconv(.c) Result;
pub const PFN_vkDeviceWaitIdle = *const fn (*Device) callconv(.c) Result;
pub const PFN_vkAllocateMemory = *const fn (*Device, *const MemoryAllocateInfo, ?*const AllocationCallbacks, *DeviceMemory) callconv(.c) Result;
pub const PFN_vkFreeMemory = *const fn (*Device, DeviceMemory, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkMapMemory = *const fn (*Device, DeviceMemory, DeviceSize, DeviceSize, MemoryMapFlags, [*c]anyopaque) callconv(.c) Result;
pub const PFN_vkUnmapMemory = *const fn (*Device, DeviceMemory) callconv(.c) void;
pub const PFN_vkFlushMappedMemoryRanges = *const fn (*Device, u32, *const MappedMemoryRange) callconv(.c) Result;
pub const PFN_vkInvalidateMappedMemoryRanges = *const fn (*Device, u32, *const MappedMemoryRange) callconv(.c) Result;
pub const PFN_vkGetDeviceMemoryCommitment = *const fn (*Device, DeviceMemory, *DeviceSize) callconv(.c) void;
pub const PFN_vkGetBufferMemoryRequirements = *const fn (*Device, Buffer, *MemoryRequirements) callconv(.c) void;
pub const PFN_vkBindBufferMemory = *const fn (*Device, Buffer, DeviceMemory, DeviceSize) callconv(.c) Result;
pub const PFN_vkGetImageMemoryRequirements = *const fn (*Device, Image, *MemoryRequirements) callconv(.c) void;
pub const PFN_vkBindImageMemory = *const fn (*Device, Image, DeviceMemory, DeviceSize) callconv(.c) Result;
pub const PFN_vkGetImageSparseMemoryRequirements = *const fn (*Device, Image, *u32, ?*SparseImageMemoryRequirements) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceSparseImageFormatProperties = *const fn (*PhysicalDevice, Format, ImageType, SampleCountFlagBits, ImageUsageFlags, ImageTiling, *u32, ?*SparseImageFormatProperties) callconv(.c) void;
pub const PFN_vkQueueBindSparse = *const fn (*Queue, u32, *const BindSparseInfo, Fence) callconv(.c) Result;
pub const PFN_vkCreateFence = *const fn (*Device, *const FenceCreateInfo, ?*const AllocationCallbacks, *Fence) callconv(.c) Result;
pub const PFN_vkDestroyFence = *const fn (*Device, Fence, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkResetFences = *const fn (*Device, u32, *const Fence) callconv(.c) Result;
pub const PFN_vkGetFenceStatus = *const fn (*Device, Fence) callconv(.c) Result;
pub const PFN_vkWaitForFences = *const fn (*Device, u32, *const Fence, Bool32, u64) callconv(.c) Result;
pub const PFN_vkCreateSemaphore = *const fn (*Device, *const SemaphoreCreateInfo, ?*const AllocationCallbacks, *Semaphore) callconv(.c) Result;
pub const PFN_vkDestroySemaphore = *const fn (*Device, Semaphore, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateEvent = *const fn (*Device, *const EventCreateInfo, ?*const AllocationCallbacks, *Event) callconv(.c) Result;
pub const PFN_vkDestroyEvent = *const fn (*Device, Event, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetEventStatus = *const fn (*Device, Event) callconv(.c) Result;
pub const PFN_vkSetEvent = *const fn (*Device, Event) callconv(.c) Result;
pub const PFN_vkResetEvent = *const fn (*Device, Event) callconv(.c) Result;
pub const PFN_vkCreateQueryPool = *const fn (*Device, *const QueryPoolCreateInfo, ?*const AllocationCallbacks, *QueryPool) callconv(.c) Result;
pub const PFN_vkDestroyQueryPool = *const fn (*Device, QueryPool, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetQueryPoolResults = *const fn (*Device, QueryPool, u32, u32, usize, *anyopaque, DeviceSize, QueryResultFlags) callconv(.c) Result;
pub const PFN_vkResetQueryPool = *const fn (*Device, QueryPool, u32, u32) callconv(.c) void;
pub const PFN_vkCreateBuffer = *const fn (*Device, *const BufferCreateInfo, ?*const AllocationCallbacks, *Buffer) callconv(.c) Result;
pub const PFN_vkDestroyBuffer = *const fn (*Device, Buffer, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateBufferView = *const fn (*Device, *const BufferViewCreateInfo, ?*const AllocationCallbacks, *BufferView) callconv(.c) Result;
pub const PFN_vkDestroyBufferView = *const fn (*Device, BufferView, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateImage = *const fn (*Device, *const ImageCreateInfo, ?*const AllocationCallbacks, *Image) callconv(.c) Result;
pub const PFN_vkDestroyImage = *const fn (*Device, Image, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetImageSubresourceLayout = *const fn (*Device, Image, *const ImageSubresource, *SubresourceLayout) callconv(.c) void;
pub const PFN_vkCreateImageView = *const fn (*Device, *const ImageViewCreateInfo, ?*const AllocationCallbacks, *ImageView) callconv(.c) Result;
pub const PFN_vkDestroyImageView = *const fn (*Device, ImageView, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateShaderModule = *const fn (*Device, *const ShaderModuleCreateInfo, ?*const AllocationCallbacks, *ShaderModule) callconv(.c) Result;
pub const PFN_vkDestroyShaderModule = *const fn (*Device, ShaderModule, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreatePipelineCache = *const fn (*Device, *const PipelineCacheCreateInfo, ?*const AllocationCallbacks, *PipelineCache) callconv(.c) Result;
pub const PFN_vkDestroyPipelineCache = *const fn (*Device, PipelineCache, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetPipelineCacheData = *const fn (*Device, PipelineCache, *usize, ?*anyopaque) callconv(.c) Result;
pub const PFN_vkMergePipelineCaches = *const fn (*Device, PipelineCache, u32, *const PipelineCache) callconv(.c) Result;
pub const PFN_vkCreateGraphicsPipelines = *const fn (*Device, PipelineCache, u32, *const GraphicsPipelineCreateInfo, ?*const AllocationCallbacks, *Pipeline) callconv(.c) Result;
pub const PFN_vkCreateComputePipelines = *const fn (*Device, PipelineCache, u32, *const ComputePipelineCreateInfo, ?*const AllocationCallbacks, *Pipeline) callconv(.c) Result;
pub const PFN_vkDestroyPipeline = *const fn (*Device, Pipeline, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreatePipelineLayout = *const fn (*Device, *const PipelineLayoutCreateInfo, ?*const AllocationCallbacks, *PipelineLayout) callconv(.c) Result;
pub const PFN_vkDestroyPipelineLayout = *const fn (*Device, PipelineLayout, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateSampler = *const fn (*Device, *const SamplerCreateInfo, ?*const AllocationCallbacks, *Sampler) callconv(.c) Result;
pub const PFN_vkDestroySampler = *const fn (*Device, Sampler, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateDescriptorSetLayout = *const fn (*Device, *const DescriptorSetLayoutCreateInfo, ?*const AllocationCallbacks, *DescriptorSetLayout) callconv(.c) Result;
pub const PFN_vkDestroyDescriptorSetLayout = *const fn (*Device, DescriptorSetLayout, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateDescriptorPool = *const fn (*Device, *const DescriptorPoolCreateInfo, ?*const AllocationCallbacks, *DescriptorPool) callconv(.c) Result;
pub const PFN_vkDestroyDescriptorPool = *const fn (*Device, DescriptorPool, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkResetDescriptorPool = *const fn (*Device, DescriptorPool, DescriptorPoolResetFlags) callconv(.c) Result;
pub const PFN_vkAllocateDescriptorSets = *const fn (*Device, *const DescriptorSetAllocateInfo, *DescriptorSet) callconv(.c) Result;
pub const PFN_vkFreeDescriptorSets = *const fn (*Device, DescriptorPool, u32, *const DescriptorSet) callconv(.c) Result;
pub const PFN_vkUpdateDescriptorSets = *const fn (*Device, u32, *const WriteDescriptorSet, u32, *const CopyDescriptorSet) callconv(.c) void;
pub const PFN_vkCreateFramebuffer = *const fn (*Device, *const FramebufferCreateInfo, ?*const AllocationCallbacks, *Framebuffer) callconv(.c) Result;
pub const PFN_vkDestroyFramebuffer = *const fn (*Device, Framebuffer, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkCreateRenderPass = *const fn (*Device, *const RenderPassCreateInfo, ?*const AllocationCallbacks, *RenderPass) callconv(.c) Result;
pub const PFN_vkDestroyRenderPass = *const fn (*Device, RenderPass, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetRenderAreaGranularity = *const fn (*Device, RenderPass, *Extent2D) callconv(.c) void;
pub const PFN_vkCreateCommandPool = *const fn (*Device, *const CommandPoolCreateInfo, ?*const AllocationCallbacks, *CommandPool) callconv(.c) Result;
pub const PFN_vkDestroyCommandPool = *const fn (*Device, CommandPool, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkResetCommandPool = *const fn (*Device, CommandPool, CommandPoolResetFlags) callconv(.c) Result;
pub const PFN_vkAllocateCommandBuffers = *const fn (*Device, *const CommandBufferAllocateInfo, **CommandBuffer) callconv(.c) Result;
pub const PFN_vkFreeCommandBuffers = *const fn (*Device, CommandPool, u32, *const *CommandBuffer) callconv(.c) void;
pub const PFN_vkBeginCommandBuffer = *const fn (*CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result;
pub const PFN_vkEndCommandBuffer = *const fn (*CommandBuffer) callconv(.c) Result;
pub const PFN_vkResetCommandBuffer = *const fn (*CommandBuffer, CommandBufferResetFlags) callconv(.c) Result;
pub const PFN_vkCmdBindPipeline = *const fn (*CommandBuffer, PipelineBindPoint, Pipeline) callconv(.c) void;
pub const PFN_vkCmdSetViewport = *const fn (*CommandBuffer, u32, u32, *const Viewport) callconv(.c) void;
pub const PFN_vkCmdSetScissor = *const fn (*CommandBuffer, u32, u32, *const Rect2D) callconv(.c) void;
pub const PFN_vkCmdSetLineWidth = *const fn (*CommandBuffer, f32) callconv(.c) void;
pub const PFN_vkCmdSetDepthBias = *const fn (*CommandBuffer, f32, f32, f32) callconv(.c) void;
pub const PFN_vkCmdSetBlendConstants = *const fn (*CommandBuffer, [4]f32) callconv(.c) void;
pub const PFN_vkCmdSetDepthBounds = *const fn (*CommandBuffer, f32, f32) callconv(.c) void;
pub const PFN_vkCmdSetStencilCompareMask = *const fn (*CommandBuffer, StencilFaceFlags, u32) callconv(.c) void;
pub const PFN_vkCmdSetStencilWriteMask = *const fn (*CommandBuffer, StencilFaceFlags, u32) callconv(.c) void;
pub const PFN_vkCmdSetStencilReference = *const fn (*CommandBuffer, StencilFaceFlags, u32) callconv(.c) void;
pub const PFN_vkCmdBindDescriptorSets = *const fn (*CommandBuffer, PipelineBindPoint, PipelineLayout, u32, u32, *const DescriptorSet, u32, *const u32) callconv(.c) void;
pub const PFN_vkCmdBindIndexBuffer = *const fn (*CommandBuffer, Buffer, DeviceSize, IndexType) callconv(.c) void;
pub const PFN_vkCmdBindVertexBuffers = *const fn (*CommandBuffer, u32, u32, *const Buffer, *const DeviceSize) callconv(.c) void;
pub const PFN_vkCmdDraw = *const fn (*CommandBuffer, u32, u32, u32, u32) callconv(.c) void;
pub const PFN_vkCmdDrawIndexed = *const fn (*CommandBuffer, u32, u32, u32, i32, u32) callconv(.c) void;
pub const PFN_vkCmdDrawIndirect = *const fn (*CommandBuffer, Buffer, DeviceSize, u32, u32) callconv(.c) void;
pub const PFN_vkCmdDrawIndexedIndirect = *const fn (*CommandBuffer, Buffer, DeviceSize, u32, u32) callconv(.c) void;
pub const PFN_vkCmdDispatch = *const fn (*CommandBuffer, u32, u32, u32) callconv(.c) void;
pub const PFN_vkCmdDispatchIndirect = *const fn (*CommandBuffer, Buffer, DeviceSize) callconv(.c) void;
pub const PFN_vkCmdCopyBuffer = *const fn (*CommandBuffer, Buffer, Buffer, u32, *const BufferCopy) callconv(.c) void;
pub const PFN_vkCmdCopyImage = *const fn (*CommandBuffer, Image, ImageLayout, Image, ImageLayout, u32, *const ImageCopy) callconv(.c) void;
pub const PFN_vkCmdBlitImage = *const fn (*CommandBuffer, Image, ImageLayout, Image, ImageLayout, u32, *const ImageBlit, Filter) callconv(.c) void;
pub const PFN_vkCmdCopyBufferToImage = *const fn (*CommandBuffer, Buffer, Image, ImageLayout, u32, *const BufferImageCopy) callconv(.c) void;
pub const PFN_vkCmdCopyImageToBuffer = *const fn (*CommandBuffer, Image, ImageLayout, Buffer, u32, *const BufferImageCopy) callconv(.c) void;
pub const PFN_vkCmdUpdateBuffer = *const fn (*CommandBuffer, Buffer, DeviceSize, DeviceSize, *const anyopaque) callconv(.c) void;
pub const PFN_vkCmdFillBuffer = *const fn (*CommandBuffer, Buffer, DeviceSize, DeviceSize, u32) callconv(.c) void;
pub const PFN_vkCmdClearColorImage = *const fn (*CommandBuffer, Image, ImageLayout, *const ClearColorValue, u32, *const ImageSubresourceRange) callconv(.c) void;
pub const PFN_vkCmdClearDepthStencilImage = *const fn (*CommandBuffer, Image, ImageLayout, *const ClearDepthStencilValue, u32, *const ImageSubresourceRange) callconv(.c) void;
pub const PFN_vkCmdClearAttachments = *const fn (*CommandBuffer, u32, *const ClearAttachment, u32, *const ClearRect) callconv(.c) void;
pub const PFN_vkCmdResolveImage = *const fn (*CommandBuffer, Image, ImageLayout, Image, ImageLayout, u32, *const ImageResolve) callconv(.c) void;
pub const PFN_vkCmdSetEvent = *const fn (*CommandBuffer, Event, PipelineStageFlags) callconv(.c) void;
pub const PFN_vkCmdResetEvent = *const fn (*CommandBuffer, Event, PipelineStageFlags) callconv(.c) void;
pub const PFN_vkCmdWaitEvents = *const fn (*CommandBuffer, u32, *const Event, PipelineStageFlags, PipelineStageFlags, u32, *const MemoryBarrier, u32, *const BufferMemoryBarrier, u32, *const ImageMemoryBarrier) callconv(.c) void;
pub const PFN_vkCmdPipelineBarrier = *const fn (*CommandBuffer, PipelineStageFlags, PipelineStageFlags, DependencyFlags, u32, *const MemoryBarrier, u32, *const BufferMemoryBarrier, u32, *const ImageMemoryBarrier) callconv(.c) void;
pub const PFN_vkCmdBeginQuery = *const fn (*CommandBuffer, QueryPool, u32, QueryControlFlags) callconv(.c) void;
pub const PFN_vkCmdEndQuery = *const fn (*CommandBuffer, QueryPool, u32) callconv(.c) void;
pub const PFN_vkCmdResetQueryPool = *const fn (*CommandBuffer, QueryPool, u32, u32) callconv(.c) void;
pub const PFN_vkCmdWriteTimestamp = *const fn (*CommandBuffer, PipelineStageFlagBits, QueryPool, u32) callconv(.c) void;
pub const PFN_vkCmdCopyQueryPoolResults = *const fn (*CommandBuffer, QueryPool, u32, u32, Buffer, DeviceSize, DeviceSize, QueryResultFlags) callconv(.c) void;
pub const PFN_vkCmdPushConstants = *const fn (*CommandBuffer, PipelineLayout, ShaderStageFlags, u32, u32, *const anyopaque) callconv(.c) void;
pub const PFN_vkCmdBeginRenderPass = *const fn (*CommandBuffer, *const RenderPassBeginInfo, SubpassContents) callconv(.c) void;
pub const PFN_vkCmdNextSubpass = *const fn (*CommandBuffer, SubpassContents) callconv(.c) void;
pub const PFN_vkCmdEndRenderPass = *const fn (*CommandBuffer) callconv(.c) void;
pub const PFN_vkCmdExecuteCommands = *const fn (*CommandBuffer, u32, *const *CommandBuffer) callconv(.c) void;
pub const PFN_vkDestroySurfaceKHR = *const fn (*Instance, SurfaceKHR, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceSurfaceSupportKHR = *const fn (*PhysicalDevice, u32, SurfaceKHR, *Bool32) callconv(.c) Result;
pub const PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (*PhysicalDevice, SurfaceKHR, *SurfaceCapabilitiesKHR) callconv(.c) Result;
pub const PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = *const fn (*PhysicalDevice, SurfaceKHR, *u32, ?*SurfaceFormatKHR) callconv(.c) Result;
pub const PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = *const fn (*PhysicalDevice, SurfaceKHR, *u32, ?*PresentModeKHR) callconv(.c) Result;
pub const PFN_vkCreateSwapchainKHR = *const fn (*Device, *const SwapchainCreateInfoKHR, ?*const AllocationCallbacks, *SwapchainKHR) callconv(.c) Result;
pub const PFN_vkDestroySwapchainKHR = *const fn (*Device, SwapchainKHR, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetSwapchainImagesKHR = *const fn (*Device, SwapchainKHR, *u32, ?*Image) callconv(.c) Result;
pub const PFN_vkAcquireNextImageKHR = *const fn (*Device, SwapchainKHR, u64, Semaphore, Fence, *u32) callconv(.c) Result;
pub const PFN_vkQueuePresentKHR = *const fn (*Queue, *const PresentInfoKHR) callconv(.c) Result;
pub const PFN_vkCreateWaylandSurfaceKHR = *const fn (*Instance, *const WaylandSurfaceCreateInfoKHR, ?*const AllocationCallbacks, *SurfaceKHR) callconv(.c) Result;
pub const PFN_vkGetPhysicalDeviceWaylandPresentationSupportKHR = *const fn (*PhysicalDevice, u32, *wl_display) callconv(.c) Bool32;
pub const PFN_vkCreateWin32SurfaceKHR = *const fn (*Instance, *const Win32SurfaceCreateInfoKHR, ?*const AllocationCallbacks, *SurfaceKHR) callconv(.c) Result;
pub const PFN_vkGetPhysicalDeviceWin32PresentationSupportKHR = *const fn (*PhysicalDevice, u32) callconv(.c) Bool32;
pub const PFN_vkGetPhysicalDeviceFeatures2 = *const fn (*PhysicalDevice, *PhysicalDeviceFeatures2) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceProperties2 = *const fn (*PhysicalDevice, *PhysicalDeviceProperties2) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceFormatProperties2 = *const fn (*PhysicalDevice, Format, *FormatProperties2) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceImageFormatProperties2 = *const fn (*PhysicalDevice, *const PhysicalDeviceImageFormatInfo2, *ImageFormatProperties2) callconv(.c) Result;
pub const PFN_vkGetPhysicalDeviceQueueFamilyProperties2 = *const fn (*PhysicalDevice, *u32, ?*QueueFamilyProperties2) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceMemoryProperties2 = *const fn (*PhysicalDevice, *PhysicalDeviceMemoryProperties2) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceSparseImageFormatProperties2 = *const fn (*PhysicalDevice, *const PhysicalDeviceSparseImageFormatInfo2, *u32, ?*SparseImageFormatProperties2) callconv(.c) void;
pub const PFN_vkTrimCommandPool = *const fn (*Device, CommandPool, CommandPoolTrimFlags) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceExternalBufferProperties = *const fn (*PhysicalDevice, *const PhysicalDeviceExternalBufferInfo, *ExternalBufferProperties) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceExternalSemaphoreProperties = *const fn (*PhysicalDevice, *const PhysicalDeviceExternalSemaphoreInfo, *ExternalSemaphoreProperties) callconv(.c) void;
pub const PFN_vkGetPhysicalDeviceExternalFenceProperties = *const fn (*PhysicalDevice, *const PhysicalDeviceExternalFenceInfo, *ExternalFenceProperties) callconv(.c) void;
pub const PFN_vkEnumeratePhysicalDeviceGroups = *const fn (*Instance, *u32, ?*PhysicalDeviceGroupProperties) callconv(.c) Result;
pub const PFN_vkGetDeviceGroupPeerMemoryFeatures = *const fn (*Device, u32, u32, u32, *PeerMemoryFeatureFlags) callconv(.c) void;
pub const PFN_vkBindBufferMemory2 = *const fn (*Device, u32, *const BindBufferMemoryInfo) callconv(.c) Result;
pub const PFN_vkBindImageMemory2 = *const fn (*Device, u32, *const BindImageMemoryInfo) callconv(.c) Result;
pub const PFN_vkCmdSetDeviceMask = *const fn (*CommandBuffer, u32) callconv(.c) void;
pub const PFN_vkGetDeviceGroupPresentCapabilitiesKHR = *const fn (*Device, *DeviceGroupPresentCapabilitiesKHR) callconv(.c) Result;
pub const PFN_vkGetDeviceGroupSurfacePresentModesKHR = *const fn (*Device, SurfaceKHR, *DeviceGroupPresentModeFlagsKHR) callconv(.c) Result;
pub const PFN_vkAcquireNextImage2KHR = *const fn (*Device, *const AcquireNextImageInfoKHR, *u32) callconv(.c) Result;
pub const PFN_vkCmdDispatchBase = *const fn (*CommandBuffer, u32, u32, u32, u32, u32, u32) callconv(.c) void;
pub const PFN_vkGetPhysicalDevicePresentRectanglesKHR = *const fn (*PhysicalDevice, SurfaceKHR, *u32, ?*Rect2D) callconv(.c) Result;
pub const PFN_vkCreateDescriptorUpdateTemplate = *const fn (*Device, *const DescriptorUpdateTemplateCreateInfo, ?*const AllocationCallbacks, *DescriptorUpdateTemplate) callconv(.c) Result;
pub const PFN_vkDestroyDescriptorUpdateTemplate = *const fn (*Device, DescriptorUpdateTemplate, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkUpdateDescriptorSetWithTemplate = *const fn (*Device, DescriptorSet, DescriptorUpdateTemplate, *const anyopaque) callconv(.c) void;
pub const PFN_vkGetBufferMemoryRequirements2 = *const fn (*Device, *const BufferMemoryRequirementsInfo2, *MemoryRequirements2) callconv(.c) void;
pub const PFN_vkGetImageMemoryRequirements2 = *const fn (*Device, *const ImageMemoryRequirementsInfo2, *MemoryRequirements2) callconv(.c) void;
pub const PFN_vkGetImageSparseMemoryRequirements2 = *const fn (*Device, *const ImageSparseMemoryRequirementsInfo2, *u32, ?*SparseImageMemoryRequirements2) callconv(.c) void;
pub const PFN_vkGetDeviceBufferMemoryRequirements = *const fn (*Device, *const DeviceBufferMemoryRequirements, *MemoryRequirements2) callconv(.c) void;
pub const PFN_vkGetDeviceImageMemoryRequirements = *const fn (*Device, *const DeviceImageMemoryRequirements, *MemoryRequirements2) callconv(.c) void;
pub const PFN_vkGetDeviceImageSparseMemoryRequirements = *const fn (*Device, *const DeviceImageMemoryRequirements, *u32, ?*SparseImageMemoryRequirements2) callconv(.c) void;
pub const PFN_vkCreateSamplerYcbcrConversion = *const fn (*Device, *const SamplerYcbcrConversionCreateInfo, ?*const AllocationCallbacks, *SamplerYcbcrConversion) callconv(.c) Result;
pub const PFN_vkDestroySamplerYcbcrConversion = *const fn (*Device, SamplerYcbcrConversion, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkGetDeviceQueue2 = *const fn (*Device, *const DeviceQueueInfo2, **Queue) callconv(.c) void;
pub const PFN_vkGetDescriptorSetLayoutSupport = *const fn (*Device, *const DescriptorSetLayoutCreateInfo, *DescriptorSetLayoutSupport) callconv(.c) void;
pub const PFN_vkSetDebugUtilsObjectNameEXT = *const fn (*Device, *const DebugUtilsObjectNameInfoEXT) callconv(.c) Result;
pub const PFN_vkSetDebugUtilsObjectTagEXT = *const fn (*Device, *const DebugUtilsObjectTagInfoEXT) callconv(.c) Result;
pub const PFN_vkQueueBeginDebugUtilsLabelEXT = *const fn (*Queue, *const DebugUtilsLabelEXT) callconv(.c) void;
pub const PFN_vkQueueEndDebugUtilsLabelEXT = *const fn (*Queue) callconv(.c) void;
pub const PFN_vkQueueInsertDebugUtilsLabelEXT = *const fn (*Queue, *const DebugUtilsLabelEXT) callconv(.c) void;
pub const PFN_vkCmdBeginDebugUtilsLabelEXT = *const fn (*CommandBuffer, *const DebugUtilsLabelEXT) callconv(.c) void;
pub const PFN_vkCmdEndDebugUtilsLabelEXT = *const fn (*CommandBuffer) callconv(.c) void;
pub const PFN_vkCmdInsertDebugUtilsLabelEXT = *const fn (*CommandBuffer, *const DebugUtilsLabelEXT) callconv(.c) void;
pub const PFN_vkCreateDebugUtilsMessengerEXT = *const fn (*Instance, *const DebugUtilsMessengerCreateInfoEXT, ?*const AllocationCallbacks, *DebugUtilsMessengerEXT) callconv(.c) Result;
pub const PFN_vkDestroyDebugUtilsMessengerEXT = *const fn (*Instance, DebugUtilsMessengerEXT, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkSubmitDebugUtilsMessageEXT = *const fn (*Instance, DebugUtilsMessageSeverityFlagBitsEXT, DebugUtilsMessageTypeFlagsEXT, *const DebugUtilsMessengerCallbackDataEXT) callconv(.c) void;
pub const PFN_vkCreateRenderPass2 = *const fn (*Device, *const RenderPassCreateInfo2, ?*const AllocationCallbacks, *RenderPass) callconv(.c) Result;
pub const PFN_vkCmdBeginRenderPass2 = *const fn (*CommandBuffer, *const RenderPassBeginInfo, *const SubpassBeginInfo) callconv(.c) void;
pub const PFN_vkCmdNextSubpass2 = *const fn (*CommandBuffer, *const SubpassBeginInfo, *const SubpassEndInfo) callconv(.c) void;
pub const PFN_vkCmdEndRenderPass2 = *const fn (*CommandBuffer, *const SubpassEndInfo) callconv(.c) void;
pub const PFN_vkGetSemaphoreCounterValue = *const fn (*Device, Semaphore, *u64) callconv(.c) Result;
pub const PFN_vkWaitSemaphores = *const fn (*Device, *const SemaphoreWaitInfo, u64) callconv(.c) Result;
pub const PFN_vkSignalSemaphore = *const fn (*Device, *const SemaphoreSignalInfo) callconv(.c) Result;
pub const PFN_vkCmdDrawIndirectCount = *const fn (*CommandBuffer, Buffer, DeviceSize, Buffer, DeviceSize, u32, u32) callconv(.c) void;
pub const PFN_vkCmdDrawIndexedIndirectCount = *const fn (*CommandBuffer, Buffer, DeviceSize, Buffer, DeviceSize, u32, u32) callconv(.c) void;
pub const PFN_vkGetBufferOpaqueCaptureAddress = *const fn (*Device, *const BufferDeviceAddressInfo) callconv(.c) u64;
pub const PFN_vkGetBufferDeviceAddress = *const fn (*Device, *const BufferDeviceAddressInfo) callconv(.c) DeviceAddress;
pub const PFN_vkGetDeviceMemoryOpaqueCaptureAddress = *const fn (*Device, *const DeviceMemoryOpaqueCaptureAddressInfo) callconv(.c) u64;
pub const PFN_vkGetPhysicalDeviceToolProperties = *const fn (*PhysicalDevice, *u32, ?*PhysicalDeviceToolProperties) callconv(.c) Result;
pub const PFN_vkCmdSetCullMode = *const fn (*CommandBuffer, CullModeFlags) callconv(.c) void;
pub const PFN_vkCmdSetFrontFace = *const fn (*CommandBuffer, FrontFace) callconv(.c) void;
pub const PFN_vkCmdSetPrimitiveTopology = *const fn (*CommandBuffer, PrimitiveTopology) callconv(.c) void;
pub const PFN_vkCmdSetViewportWithCount = *const fn (*CommandBuffer, u32, *const Viewport) callconv(.c) void;
pub const PFN_vkCmdSetScissorWithCount = *const fn (*CommandBuffer, u32, *const Rect2D) callconv(.c) void;
pub const PFN_vkCmdBindVertexBuffers2 = *const fn (*CommandBuffer, u32, u32, *const Buffer, *const DeviceSize, ?*const DeviceSize, ?*const DeviceSize) callconv(.c) void;
pub const PFN_vkCmdSetDepthTestEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCmdSetDepthWriteEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCmdSetDepthCompareOp = *const fn (*CommandBuffer, CompareOp) callconv(.c) void;
pub const PFN_vkCmdSetDepthBoundsTestEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCmdSetStencilTestEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCmdSetStencilOp = *const fn (*CommandBuffer, StencilFaceFlags, StencilOp, StencilOp, StencilOp, CompareOp) callconv(.c) void;
pub const PFN_vkCmdSetRasterizerDiscardEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCmdSetDepthBiasEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCmdSetPrimitiveRestartEnable = *const fn (*CommandBuffer, Bool32) callconv(.c) void;
pub const PFN_vkCreatePrivateDataSlot = *const fn (*Device, *const PrivateDataSlotCreateInfo, ?*const AllocationCallbacks, *PrivateDataSlot) callconv(.c) Result;
pub const PFN_vkDestroyPrivateDataSlot = *const fn (*Device, PrivateDataSlot, ?*const AllocationCallbacks) callconv(.c) void;
pub const PFN_vkSetPrivateData = *const fn (*Device, ObjectType, u64, PrivateDataSlot, u64) callconv(.c) Result;
pub const PFN_vkGetPrivateData = *const fn (*Device, ObjectType, u64, PrivateDataSlot, *u64) callconv(.c) void;
pub const PFN_vkCmdCopyBuffer2 = *const fn (*CommandBuffer, *const CopyBufferInfo2) callconv(.c) void;
pub const PFN_vkCmdCopyImage2 = *const fn (*CommandBuffer, *const CopyImageInfo2) callconv(.c) void;
pub const PFN_vkCmdBlitImage2 = *const fn (*CommandBuffer, *const BlitImageInfo2) callconv(.c) void;
pub const PFN_vkCmdCopyBufferToImage2 = *const fn (*CommandBuffer, *const CopyBufferToImageInfo2) callconv(.c) void;
pub const PFN_vkCmdCopyImageToBuffer2 = *const fn (*CommandBuffer, *const CopyImageToBufferInfo2) callconv(.c) void;
pub const PFN_vkCmdResolveImage2 = *const fn (*CommandBuffer, *const ResolveImageInfo2) callconv(.c) void;
pub const PFN_vkCmdSetEvent2 = *const fn (*CommandBuffer, Event, *const DependencyInfo) callconv(.c) void;
pub const PFN_vkCmdResetEvent2 = *const fn (*CommandBuffer, Event, PipelineStageFlags2) callconv(.c) void;
pub const PFN_vkCmdWaitEvents2 = *const fn (*CommandBuffer, u32, *const Event, *const DependencyInfo) callconv(.c) void;
pub const PFN_vkCmdPipelineBarrier2 = *const fn (*CommandBuffer, *const DependencyInfo) callconv(.c) void;
pub const PFN_vkQueueSubmit2 = *const fn (*Queue, u32, *const SubmitInfo2, Fence) callconv(.c) Result;
pub const PFN_vkCmdWriteTimestamp2 = *const fn (*CommandBuffer, PipelineStageFlags2, QueryPool, u32) callconv(.c) void;
pub const PFN_vkCmdBeginRendering = *const fn (*CommandBuffer, *const RenderingInfo) callconv(.c) void;
pub const PFN_vkCmdEndRendering = *const fn (*CommandBuffer) callconv(.c) void;

// ---- Dispatch tables ----

pub const BaseDispatch = struct {
    vkCreateInstance: PFN_vkCreateInstance = undefined,
    vkEnumerateInstanceVersion: PFN_vkEnumerateInstanceVersion = undefined,
    vkEnumerateInstanceLayerProperties: PFN_vkEnumerateInstanceLayerProperties = undefined,
    vkEnumerateInstanceExtensionProperties: PFN_vkEnumerateInstanceExtensionProperties = undefined,
};

pub const InstanceDispatch = struct {
    vkDestroyInstance: PFN_vkDestroyInstance = undefined,
    vkEnumeratePhysicalDevices: PFN_vkEnumeratePhysicalDevices = undefined,
    vkGetInstanceProcAddr: PFN_vkGetInstanceProcAddr = undefined,
    vkGetPhysicalDeviceProperties: PFN_vkGetPhysicalDeviceProperties = undefined,
    vkGetPhysicalDeviceQueueFamilyProperties: PFN_vkGetPhysicalDeviceQueueFamilyProperties = undefined,
    vkGetPhysicalDeviceMemoryProperties: PFN_vkGetPhysicalDeviceMemoryProperties = undefined,
    vkGetPhysicalDeviceFeatures: PFN_vkGetPhysicalDeviceFeatures = undefined,
    vkGetPhysicalDeviceFormatProperties: PFN_vkGetPhysicalDeviceFormatProperties = undefined,
    vkGetPhysicalDeviceImageFormatProperties: PFN_vkGetPhysicalDeviceImageFormatProperties = undefined,
    vkCreateDevice: PFN_vkCreateDevice = undefined,
    vkEnumerateDeviceLayerProperties: PFN_vkEnumerateDeviceLayerProperties = undefined,
    vkEnumerateDeviceExtensionProperties: PFN_vkEnumerateDeviceExtensionProperties = undefined,
    vkGetPhysicalDeviceSparseImageFormatProperties: PFN_vkGetPhysicalDeviceSparseImageFormatProperties = undefined,
    vkDestroySurfaceKHR: PFN_vkDestroySurfaceKHR = undefined,
    vkGetPhysicalDeviceSurfaceSupportKHR: PFN_vkGetPhysicalDeviceSurfaceSupportKHR = undefined,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = undefined,
    vkGetPhysicalDeviceSurfaceFormatsKHR: PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = undefined,
    vkGetPhysicalDeviceSurfacePresentModesKHR: PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = undefined,
    vkCreateWaylandSurfaceKHR: PFN_vkCreateWaylandSurfaceKHR = undefined,
    vkGetPhysicalDeviceWaylandPresentationSupportKHR: PFN_vkGetPhysicalDeviceWaylandPresentationSupportKHR = undefined,
    vkCreateWin32SurfaceKHR: PFN_vkCreateWin32SurfaceKHR = undefined,
    vkGetPhysicalDeviceWin32PresentationSupportKHR: PFN_vkGetPhysicalDeviceWin32PresentationSupportKHR = undefined,
    vkGetPhysicalDeviceFeatures2: PFN_vkGetPhysicalDeviceFeatures2 = undefined,
    vkGetPhysicalDeviceProperties2: PFN_vkGetPhysicalDeviceProperties2 = undefined,
    vkGetPhysicalDeviceFormatProperties2: PFN_vkGetPhysicalDeviceFormatProperties2 = undefined,
    vkGetPhysicalDeviceImageFormatProperties2: PFN_vkGetPhysicalDeviceImageFormatProperties2 = undefined,
    vkGetPhysicalDeviceQueueFamilyProperties2: PFN_vkGetPhysicalDeviceQueueFamilyProperties2 = undefined,
    vkGetPhysicalDeviceMemoryProperties2: PFN_vkGetPhysicalDeviceMemoryProperties2 = undefined,
    vkGetPhysicalDeviceSparseImageFormatProperties2: PFN_vkGetPhysicalDeviceSparseImageFormatProperties2 = undefined,
    vkGetPhysicalDeviceExternalBufferProperties: PFN_vkGetPhysicalDeviceExternalBufferProperties = undefined,
    vkGetPhysicalDeviceExternalSemaphoreProperties: PFN_vkGetPhysicalDeviceExternalSemaphoreProperties = undefined,
    vkGetPhysicalDeviceExternalFenceProperties: PFN_vkGetPhysicalDeviceExternalFenceProperties = undefined,
    vkEnumeratePhysicalDeviceGroups: PFN_vkEnumeratePhysicalDeviceGroups = undefined,
    vkGetPhysicalDevicePresentRectanglesKHR: PFN_vkGetPhysicalDevicePresentRectanglesKHR = undefined,
    vkCreateDebugUtilsMessengerEXT: PFN_vkCreateDebugUtilsMessengerEXT = undefined,
    vkDestroyDebugUtilsMessengerEXT: PFN_vkDestroyDebugUtilsMessengerEXT = undefined,
    vkSubmitDebugUtilsMessageEXT: PFN_vkSubmitDebugUtilsMessageEXT = undefined,
    vkGetPhysicalDeviceToolProperties: PFN_vkGetPhysicalDeviceToolProperties = undefined,
};

pub const DeviceDispatch = struct {
    vkGetDeviceProcAddr: PFN_vkGetDeviceProcAddr = undefined,
    vkDestroyDevice: PFN_vkDestroyDevice = undefined,
    vkGetDeviceQueue: PFN_vkGetDeviceQueue = undefined,
    vkQueueSubmit: PFN_vkQueueSubmit = undefined,
    vkQueueWaitIdle: PFN_vkQueueWaitIdle = undefined,
    vkDeviceWaitIdle: PFN_vkDeviceWaitIdle = undefined,
    vkAllocateMemory: PFN_vkAllocateMemory = undefined,
    vkFreeMemory: PFN_vkFreeMemory = undefined,
    vkMapMemory: PFN_vkMapMemory = undefined,
    vkUnmapMemory: PFN_vkUnmapMemory = undefined,
    vkFlushMappedMemoryRanges: PFN_vkFlushMappedMemoryRanges = undefined,
    vkInvalidateMappedMemoryRanges: PFN_vkInvalidateMappedMemoryRanges = undefined,
    vkGetDeviceMemoryCommitment: PFN_vkGetDeviceMemoryCommitment = undefined,
    vkGetBufferMemoryRequirements: PFN_vkGetBufferMemoryRequirements = undefined,
    vkBindBufferMemory: PFN_vkBindBufferMemory = undefined,
    vkGetImageMemoryRequirements: PFN_vkGetImageMemoryRequirements = undefined,
    vkBindImageMemory: PFN_vkBindImageMemory = undefined,
    vkGetImageSparseMemoryRequirements: PFN_vkGetImageSparseMemoryRequirements = undefined,
    vkQueueBindSparse: PFN_vkQueueBindSparse = undefined,
    vkCreateFence: PFN_vkCreateFence = undefined,
    vkDestroyFence: PFN_vkDestroyFence = undefined,
    vkResetFences: PFN_vkResetFences = undefined,
    vkGetFenceStatus: PFN_vkGetFenceStatus = undefined,
    vkWaitForFences: PFN_vkWaitForFences = undefined,
    vkCreateSemaphore: PFN_vkCreateSemaphore = undefined,
    vkDestroySemaphore: PFN_vkDestroySemaphore = undefined,
    vkCreateEvent: PFN_vkCreateEvent = undefined,
    vkDestroyEvent: PFN_vkDestroyEvent = undefined,
    vkGetEventStatus: PFN_vkGetEventStatus = undefined,
    vkSetEvent: PFN_vkSetEvent = undefined,
    vkResetEvent: PFN_vkResetEvent = undefined,
    vkCreateQueryPool: PFN_vkCreateQueryPool = undefined,
    vkDestroyQueryPool: PFN_vkDestroyQueryPool = undefined,
    vkGetQueryPoolResults: PFN_vkGetQueryPoolResults = undefined,
    vkResetQueryPool: PFN_vkResetQueryPool = undefined,
    vkCreateBuffer: PFN_vkCreateBuffer = undefined,
    vkDestroyBuffer: PFN_vkDestroyBuffer = undefined,
    vkCreateBufferView: PFN_vkCreateBufferView = undefined,
    vkDestroyBufferView: PFN_vkDestroyBufferView = undefined,
    vkCreateImage: PFN_vkCreateImage = undefined,
    vkDestroyImage: PFN_vkDestroyImage = undefined,
    vkGetImageSubresourceLayout: PFN_vkGetImageSubresourceLayout = undefined,
    vkCreateImageView: PFN_vkCreateImageView = undefined,
    vkDestroyImageView: PFN_vkDestroyImageView = undefined,
    vkCreateShaderModule: PFN_vkCreateShaderModule = undefined,
    vkDestroyShaderModule: PFN_vkDestroyShaderModule = undefined,
    vkCreatePipelineCache: PFN_vkCreatePipelineCache = undefined,
    vkDestroyPipelineCache: PFN_vkDestroyPipelineCache = undefined,
    vkGetPipelineCacheData: PFN_vkGetPipelineCacheData = undefined,
    vkMergePipelineCaches: PFN_vkMergePipelineCaches = undefined,
    vkCreateGraphicsPipelines: PFN_vkCreateGraphicsPipelines = undefined,
    vkCreateComputePipelines: PFN_vkCreateComputePipelines = undefined,
    vkDestroyPipeline: PFN_vkDestroyPipeline = undefined,
    vkCreatePipelineLayout: PFN_vkCreatePipelineLayout = undefined,
    vkDestroyPipelineLayout: PFN_vkDestroyPipelineLayout = undefined,
    vkCreateSampler: PFN_vkCreateSampler = undefined,
    vkDestroySampler: PFN_vkDestroySampler = undefined,
    vkCreateDescriptorSetLayout: PFN_vkCreateDescriptorSetLayout = undefined,
    vkDestroyDescriptorSetLayout: PFN_vkDestroyDescriptorSetLayout = undefined,
    vkCreateDescriptorPool: PFN_vkCreateDescriptorPool = undefined,
    vkDestroyDescriptorPool: PFN_vkDestroyDescriptorPool = undefined,
    vkResetDescriptorPool: PFN_vkResetDescriptorPool = undefined,
    vkAllocateDescriptorSets: PFN_vkAllocateDescriptorSets = undefined,
    vkFreeDescriptorSets: PFN_vkFreeDescriptorSets = undefined,
    vkUpdateDescriptorSets: PFN_vkUpdateDescriptorSets = undefined,
    vkCreateFramebuffer: PFN_vkCreateFramebuffer = undefined,
    vkDestroyFramebuffer: PFN_vkDestroyFramebuffer = undefined,
    vkCreateRenderPass: PFN_vkCreateRenderPass = undefined,
    vkDestroyRenderPass: PFN_vkDestroyRenderPass = undefined,
    vkGetRenderAreaGranularity: PFN_vkGetRenderAreaGranularity = undefined,
    vkCreateCommandPool: PFN_vkCreateCommandPool = undefined,
    vkDestroyCommandPool: PFN_vkDestroyCommandPool = undefined,
    vkResetCommandPool: PFN_vkResetCommandPool = undefined,
    vkAllocateCommandBuffers: PFN_vkAllocateCommandBuffers = undefined,
    vkFreeCommandBuffers: PFN_vkFreeCommandBuffers = undefined,
    vkBeginCommandBuffer: PFN_vkBeginCommandBuffer = undefined,
    vkEndCommandBuffer: PFN_vkEndCommandBuffer = undefined,
    vkResetCommandBuffer: PFN_vkResetCommandBuffer = undefined,
    vkCmdBindPipeline: PFN_vkCmdBindPipeline = undefined,
    vkCmdSetViewport: PFN_vkCmdSetViewport = undefined,
    vkCmdSetScissor: PFN_vkCmdSetScissor = undefined,
    vkCmdSetLineWidth: PFN_vkCmdSetLineWidth = undefined,
    vkCmdSetDepthBias: PFN_vkCmdSetDepthBias = undefined,
    vkCmdSetBlendConstants: PFN_vkCmdSetBlendConstants = undefined,
    vkCmdSetDepthBounds: PFN_vkCmdSetDepthBounds = undefined,
    vkCmdSetStencilCompareMask: PFN_vkCmdSetStencilCompareMask = undefined,
    vkCmdSetStencilWriteMask: PFN_vkCmdSetStencilWriteMask = undefined,
    vkCmdSetStencilReference: PFN_vkCmdSetStencilReference = undefined,
    vkCmdBindDescriptorSets: PFN_vkCmdBindDescriptorSets = undefined,
    vkCmdBindIndexBuffer: PFN_vkCmdBindIndexBuffer = undefined,
    vkCmdBindVertexBuffers: PFN_vkCmdBindVertexBuffers = undefined,
    vkCmdDraw: PFN_vkCmdDraw = undefined,
    vkCmdDrawIndexed: PFN_vkCmdDrawIndexed = undefined,
    vkCmdDrawIndirect: PFN_vkCmdDrawIndirect = undefined,
    vkCmdDrawIndexedIndirect: PFN_vkCmdDrawIndexedIndirect = undefined,
    vkCmdDispatch: PFN_vkCmdDispatch = undefined,
    vkCmdDispatchIndirect: PFN_vkCmdDispatchIndirect = undefined,
    vkCmdCopyBuffer: PFN_vkCmdCopyBuffer = undefined,
    vkCmdCopyImage: PFN_vkCmdCopyImage = undefined,
    vkCmdBlitImage: PFN_vkCmdBlitImage = undefined,
    vkCmdCopyBufferToImage: PFN_vkCmdCopyBufferToImage = undefined,
    vkCmdCopyImageToBuffer: PFN_vkCmdCopyImageToBuffer = undefined,
    vkCmdUpdateBuffer: PFN_vkCmdUpdateBuffer = undefined,
    vkCmdFillBuffer: PFN_vkCmdFillBuffer = undefined,
    vkCmdClearColorImage: PFN_vkCmdClearColorImage = undefined,
    vkCmdClearDepthStencilImage: PFN_vkCmdClearDepthStencilImage = undefined,
    vkCmdClearAttachments: PFN_vkCmdClearAttachments = undefined,
    vkCmdResolveImage: PFN_vkCmdResolveImage = undefined,
    vkCmdSetEvent: PFN_vkCmdSetEvent = undefined,
    vkCmdResetEvent: PFN_vkCmdResetEvent = undefined,
    vkCmdWaitEvents: PFN_vkCmdWaitEvents = undefined,
    vkCmdPipelineBarrier: PFN_vkCmdPipelineBarrier = undefined,
    vkCmdBeginQuery: PFN_vkCmdBeginQuery = undefined,
    vkCmdEndQuery: PFN_vkCmdEndQuery = undefined,
    vkCmdResetQueryPool: PFN_vkCmdResetQueryPool = undefined,
    vkCmdWriteTimestamp: PFN_vkCmdWriteTimestamp = undefined,
    vkCmdCopyQueryPoolResults: PFN_vkCmdCopyQueryPoolResults = undefined,
    vkCmdPushConstants: PFN_vkCmdPushConstants = undefined,
    vkCmdBeginRenderPass: PFN_vkCmdBeginRenderPass = undefined,
    vkCmdNextSubpass: PFN_vkCmdNextSubpass = undefined,
    vkCmdEndRenderPass: PFN_vkCmdEndRenderPass = undefined,
    vkCmdExecuteCommands: PFN_vkCmdExecuteCommands = undefined,
    vkCreateSwapchainKHR: PFN_vkCreateSwapchainKHR = undefined,
    vkDestroySwapchainKHR: PFN_vkDestroySwapchainKHR = undefined,
    vkGetSwapchainImagesKHR: PFN_vkGetSwapchainImagesKHR = undefined,
    vkAcquireNextImageKHR: PFN_vkAcquireNextImageKHR = undefined,
    vkQueuePresentKHR: PFN_vkQueuePresentKHR = undefined,
    vkTrimCommandPool: PFN_vkTrimCommandPool = undefined,
    vkGetDeviceGroupPeerMemoryFeatures: PFN_vkGetDeviceGroupPeerMemoryFeatures = undefined,
    vkBindBufferMemory2: PFN_vkBindBufferMemory2 = undefined,
    vkBindImageMemory2: PFN_vkBindImageMemory2 = undefined,
    vkCmdSetDeviceMask: PFN_vkCmdSetDeviceMask = undefined,
    vkGetDeviceGroupPresentCapabilitiesKHR: PFN_vkGetDeviceGroupPresentCapabilitiesKHR = undefined,
    vkGetDeviceGroupSurfacePresentModesKHR: PFN_vkGetDeviceGroupSurfacePresentModesKHR = undefined,
    vkAcquireNextImage2KHR: PFN_vkAcquireNextImage2KHR = undefined,
    vkCmdDispatchBase: PFN_vkCmdDispatchBase = undefined,
    vkCreateDescriptorUpdateTemplate: PFN_vkCreateDescriptorUpdateTemplate = undefined,
    vkDestroyDescriptorUpdateTemplate: PFN_vkDestroyDescriptorUpdateTemplate = undefined,
    vkUpdateDescriptorSetWithTemplate: PFN_vkUpdateDescriptorSetWithTemplate = undefined,
    vkGetBufferMemoryRequirements2: PFN_vkGetBufferMemoryRequirements2 = undefined,
    vkGetImageMemoryRequirements2: PFN_vkGetImageMemoryRequirements2 = undefined,
    vkGetImageSparseMemoryRequirements2: PFN_vkGetImageSparseMemoryRequirements2 = undefined,
    vkGetDeviceBufferMemoryRequirements: PFN_vkGetDeviceBufferMemoryRequirements = undefined,
    vkGetDeviceImageMemoryRequirements: PFN_vkGetDeviceImageMemoryRequirements = undefined,
    vkGetDeviceImageSparseMemoryRequirements: PFN_vkGetDeviceImageSparseMemoryRequirements = undefined,
    vkCreateSamplerYcbcrConversion: PFN_vkCreateSamplerYcbcrConversion = undefined,
    vkDestroySamplerYcbcrConversion: PFN_vkDestroySamplerYcbcrConversion = undefined,
    vkGetDeviceQueue2: PFN_vkGetDeviceQueue2 = undefined,
    vkGetDescriptorSetLayoutSupport: PFN_vkGetDescriptorSetLayoutSupport = undefined,
    vkSetDebugUtilsObjectNameEXT: PFN_vkSetDebugUtilsObjectNameEXT = undefined,
    vkSetDebugUtilsObjectTagEXT: PFN_vkSetDebugUtilsObjectTagEXT = undefined,
    vkQueueBeginDebugUtilsLabelEXT: PFN_vkQueueBeginDebugUtilsLabelEXT = undefined,
    vkQueueEndDebugUtilsLabelEXT: PFN_vkQueueEndDebugUtilsLabelEXT = undefined,
    vkQueueInsertDebugUtilsLabelEXT: PFN_vkQueueInsertDebugUtilsLabelEXT = undefined,
    vkCmdBeginDebugUtilsLabelEXT: PFN_vkCmdBeginDebugUtilsLabelEXT = undefined,
    vkCmdEndDebugUtilsLabelEXT: PFN_vkCmdEndDebugUtilsLabelEXT = undefined,
    vkCmdInsertDebugUtilsLabelEXT: PFN_vkCmdInsertDebugUtilsLabelEXT = undefined,
    vkCreateRenderPass2: PFN_vkCreateRenderPass2 = undefined,
    vkCmdBeginRenderPass2: PFN_vkCmdBeginRenderPass2 = undefined,
    vkCmdNextSubpass2: PFN_vkCmdNextSubpass2 = undefined,
    vkCmdEndRenderPass2: PFN_vkCmdEndRenderPass2 = undefined,
    vkGetSemaphoreCounterValue: PFN_vkGetSemaphoreCounterValue = undefined,
    vkWaitSemaphores: PFN_vkWaitSemaphores = undefined,
    vkSignalSemaphore: PFN_vkSignalSemaphore = undefined,
    vkCmdDrawIndirectCount: PFN_vkCmdDrawIndirectCount = undefined,
    vkCmdDrawIndexedIndirectCount: PFN_vkCmdDrawIndexedIndirectCount = undefined,
    vkGetBufferOpaqueCaptureAddress: PFN_vkGetBufferOpaqueCaptureAddress = undefined,
    vkGetBufferDeviceAddress: PFN_vkGetBufferDeviceAddress = undefined,
    vkGetDeviceMemoryOpaqueCaptureAddress: PFN_vkGetDeviceMemoryOpaqueCaptureAddress = undefined,
    vkCmdSetCullMode: PFN_vkCmdSetCullMode = undefined,
    vkCmdSetFrontFace: PFN_vkCmdSetFrontFace = undefined,
    vkCmdSetPrimitiveTopology: PFN_vkCmdSetPrimitiveTopology = undefined,
    vkCmdSetViewportWithCount: PFN_vkCmdSetViewportWithCount = undefined,
    vkCmdSetScissorWithCount: PFN_vkCmdSetScissorWithCount = undefined,
    vkCmdBindVertexBuffers2: PFN_vkCmdBindVertexBuffers2 = undefined,
    vkCmdSetDepthTestEnable: PFN_vkCmdSetDepthTestEnable = undefined,
    vkCmdSetDepthWriteEnable: PFN_vkCmdSetDepthWriteEnable = undefined,
    vkCmdSetDepthCompareOp: PFN_vkCmdSetDepthCompareOp = undefined,
    vkCmdSetDepthBoundsTestEnable: PFN_vkCmdSetDepthBoundsTestEnable = undefined,
    vkCmdSetStencilTestEnable: PFN_vkCmdSetStencilTestEnable = undefined,
    vkCmdSetStencilOp: PFN_vkCmdSetStencilOp = undefined,
    vkCmdSetRasterizerDiscardEnable: PFN_vkCmdSetRasterizerDiscardEnable = undefined,
    vkCmdSetDepthBiasEnable: PFN_vkCmdSetDepthBiasEnable = undefined,
    vkCmdSetPrimitiveRestartEnable: PFN_vkCmdSetPrimitiveRestartEnable = undefined,
    vkCreatePrivateDataSlot: PFN_vkCreatePrivateDataSlot = undefined,
    vkDestroyPrivateDataSlot: PFN_vkDestroyPrivateDataSlot = undefined,
    vkSetPrivateData: PFN_vkSetPrivateData = undefined,
    vkGetPrivateData: PFN_vkGetPrivateData = undefined,
    vkCmdCopyBuffer2: PFN_vkCmdCopyBuffer2 = undefined,
    vkCmdCopyImage2: PFN_vkCmdCopyImage2 = undefined,
    vkCmdBlitImage2: PFN_vkCmdBlitImage2 = undefined,
    vkCmdCopyBufferToImage2: PFN_vkCmdCopyBufferToImage2 = undefined,
    vkCmdCopyImageToBuffer2: PFN_vkCmdCopyImageToBuffer2 = undefined,
    vkCmdResolveImage2: PFN_vkCmdResolveImage2 = undefined,
    vkCmdSetEvent2: PFN_vkCmdSetEvent2 = undefined,
    vkCmdResetEvent2: PFN_vkCmdResetEvent2 = undefined,
    vkCmdWaitEvents2: PFN_vkCmdWaitEvents2 = undefined,
    vkCmdPipelineBarrier2: PFN_vkCmdPipelineBarrier2 = undefined,
    vkQueueSubmit2: PFN_vkQueueSubmit2 = undefined,
    vkCmdWriteTimestamp2: PFN_vkCmdWriteTimestamp2 = undefined,
    vkCmdBeginRendering: PFN_vkCmdBeginRendering = undefined,
    vkCmdEndRendering: PFN_vkCmdEndRendering = undefined,
};

pub var base: BaseDispatch = .{};
pub var instance_dispatch: InstanceDispatch = .{};
pub var device_dispatch: DeviceDispatch = .{};

// ---- Loader ----
//
// Phase 1: dlopen libvulkan, resolve `vkGetInstanceProcAddr`,
//          fill the `BaseDispatch` table with loader-level entries.
// Phase 2: once `vkCreateInstance` returns, call `loadInstance(handle)`
//          to fill the `InstanceDispatch` table via vkGetInstanceProcAddr.
// Phase 3: once `vkCreateDevice` returns, call `loadDevice(handle)` to
//          fill the `DeviceDispatch` table via vkGetDeviceProcAddr.

var lib_handle: ?std.DynLib = null;

pub fn loadLoader() Error!void {
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{ "libvulkan.so.1", "libvulkan.so" },
        .windows => &.{"vulkan-1.dll"},
        .macos, .ios => &.{ "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib" },
        else => return error.LoaderNotFound,
    };
    for (candidates) |path| {
        if (std.DynLib.open(path)) |dl| {
            lib_handle = dl;
            break;
        } else |_| continue;
    }
    if (lib_handle == null) return error.LoaderNotFound;

    base.vkGetInstanceProcAddr = lib_handle.?.lookup(PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
        return error.SymbolNotFound;

    inline for (@typeInfo(BaseDispatch).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "vkGetInstanceProcAddr")) continue;
        const sym = base.vkGetInstanceProcAddr(null, f.name.ptr);
        if (sym == null) return error.SymbolNotFound;
        @field(base, f.name) = @ptrCast(sym);
    }
}

pub fn loadInstance(instance: *Instance) Error!void {
    inline for (@typeInfo(InstanceDispatch).@"struct".fields) |f| {
        const sym = base.vkGetInstanceProcAddr(instance, f.name.ptr);
        if (sym == null) return error.SymbolNotFound;
        @field(instance_dispatch, f.name) = @ptrCast(sym);
    }
}

pub fn loadDevice(device: *Device) Error!void {
    inline for (@typeInfo(DeviceDispatch).@"struct".fields) |f| {
        const sym = instance_dispatch.vkGetDeviceProcAddr(device, f.name.ptr);
        if (sym == null) return error.SymbolNotFound;
        @field(device_dispatch, f.name) = @ptrCast(sym);
    }
}

// ---- Loader-level functions (no `self`) ----

pub fn createInstance(create_info: *const InstanceCreateInfo, allocator: ?*const AllocationCallbacks) Error!*Instance {
    var _out: *Instance = undefined;
    const _r = base.vkCreateInstance(create_info, allocator, &_out);
    try checkResult(_r);
    return _out;
}

pub fn enumerateInstanceVersion() Error!u32 {
    var _out: u32 = undefined;
    const _r = base.vkEnumerateInstanceVersion(&_out);
    try checkResult(_r);
    return _out;
}

pub fn enumerateInstanceLayerProperties(gpa: std.mem.Allocator) Error![]LayerProperties {
    var _count: u32 = 0;
    {
        const _r = base.vkEnumerateInstanceLayerProperties(&_count, null);
        try checkResult(_r);
    }
    const _out = gpa.alloc(LayerProperties, _count) catch return error.OutOfHostMemory;
    errdefer gpa.free(_out);
    {
        const _r = base.vkEnumerateInstanceLayerProperties(&_count, _out.ptr);
        try checkResult(_r);
    }
    return _out[0.._count];
}

pub fn enumerateInstanceExtensionProperties(layer_name: ?[*:0]const u8, gpa: std.mem.Allocator) Error![]ExtensionProperties {
    var _count: u32 = 0;
    {
        const _r = base.vkEnumerateInstanceExtensionProperties(layer_name, &_count, null);
        try checkResult(_r);
    }
    const _out = gpa.alloc(ExtensionProperties, _count) catch return error.OutOfHostMemory;
    errdefer gpa.free(_out);
    {
        const _r = base.vkEnumerateInstanceExtensionProperties(layer_name, &_count, _out.ptr);
        try checkResult(_r);
    }
    return _out[0.._count];
}

// ---- Handle types (with methods) ----

pub const Instance = opaque {
    pub fn destroyInstance(self: *Instance, allocator: ?*const AllocationCallbacks) void {
        return instance_dispatch.vkDestroyInstance(self, allocator);
    }

    pub fn enumeratePhysicalDevices(self: *Instance, gpa: std.mem.Allocator) Error![]*PhysicalDevice {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkEnumeratePhysicalDevices(self, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(*PhysicalDevice, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkEnumeratePhysicalDevices(self, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn getInstanceProcAddr(self: *Instance, name: [*:0]const u8) PFN_vkVoidFunction {
        return instance_dispatch.vkGetInstanceProcAddr(self, name);
    }

    pub fn destroySurfaceKHR(self: *Instance, surface: SurfaceKHR, allocator: ?*const AllocationCallbacks) void {
        return instance_dispatch.vkDestroySurfaceKHR(self, surface, allocator);
    }

    pub fn createWaylandSurfaceKHR(self: *Instance, create_info: *const WaylandSurfaceCreateInfoKHR, allocator: ?*const AllocationCallbacks) Error!SurfaceKHR {
        var _out: SurfaceKHR = undefined;
        const _r = instance_dispatch.vkCreateWaylandSurfaceKHR(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn createWin32SurfaceKHR(self: *Instance, create_info: *const Win32SurfaceCreateInfoKHR, allocator: ?*const AllocationCallbacks) Error!SurfaceKHR {
        var _out: SurfaceKHR = undefined;
        const _r = instance_dispatch.vkCreateWin32SurfaceKHR(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn enumeratePhysicalDeviceGroups(self: *Instance, gpa: std.mem.Allocator) Error![]PhysicalDeviceGroupProperties {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkEnumeratePhysicalDeviceGroups(self, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(PhysicalDeviceGroupProperties, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkEnumeratePhysicalDeviceGroups(self, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn createDebugUtilsMessengerEXT(self: *Instance, create_info: *const DebugUtilsMessengerCreateInfoEXT, allocator: ?*const AllocationCallbacks) Error!DebugUtilsMessengerEXT {
        var _out: DebugUtilsMessengerEXT = undefined;
        const _r = instance_dispatch.vkCreateDebugUtilsMessengerEXT(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyDebugUtilsMessengerEXT(self: *Instance, messenger: DebugUtilsMessengerEXT, allocator: ?*const AllocationCallbacks) void {
        return instance_dispatch.vkDestroyDebugUtilsMessengerEXT(self, messenger, allocator);
    }

    pub fn submitDebugUtilsMessageEXT(self: *Instance, message_severity: DebugUtilsMessageSeverityFlagBitsEXT, message_types: DebugUtilsMessageTypeFlagsEXT, callback_data: *const DebugUtilsMessengerCallbackDataEXT) void {
        return instance_dispatch.vkSubmitDebugUtilsMessageEXT(self, message_severity, message_types, callback_data);
    }
};

pub const PhysicalDevice = opaque {
    pub fn getPhysicalDeviceProperties(self: *PhysicalDevice) PhysicalDeviceProperties {
        var _out: PhysicalDeviceProperties = undefined;
        instance_dispatch.vkGetPhysicalDeviceProperties(self, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceQueueFamilyProperties(self: *PhysicalDevice, gpa: std.mem.Allocator) Error![]QueueFamilyProperties {
        var _count: u32 = 0;
        {
            instance_dispatch.vkGetPhysicalDeviceQueueFamilyProperties(self, &_count, null);
        }
        const _out = gpa.alloc(QueueFamilyProperties, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            instance_dispatch.vkGetPhysicalDeviceQueueFamilyProperties(self, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceMemoryProperties(self: *PhysicalDevice) PhysicalDeviceMemoryProperties {
        var _out: PhysicalDeviceMemoryProperties = undefined;
        instance_dispatch.vkGetPhysicalDeviceMemoryProperties(self, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceFeatures(self: *PhysicalDevice) PhysicalDeviceFeatures {
        var _out: PhysicalDeviceFeatures = undefined;
        instance_dispatch.vkGetPhysicalDeviceFeatures(self, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceFormatProperties(self: *PhysicalDevice, format: Format) FormatProperties {
        var _out: FormatProperties = undefined;
        instance_dispatch.vkGetPhysicalDeviceFormatProperties(self, format, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceImageFormatProperties(self: *PhysicalDevice, format: Format, @"type": ImageType, tiling: ImageTiling, usage: ImageUsageFlags, flags: ImageCreateFlags) Error!ImageFormatProperties {
        var _out: ImageFormatProperties = undefined;
        const _r = instance_dispatch.vkGetPhysicalDeviceImageFormatProperties(self, format, @"type", tiling, usage, flags, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn createDevice(self: *PhysicalDevice, create_info: *const DeviceCreateInfo, allocator: ?*const AllocationCallbacks) Error!*Device {
        var _out: *Device = undefined;
        const _r = instance_dispatch.vkCreateDevice(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn enumerateDeviceLayerProperties(self: *PhysicalDevice, gpa: std.mem.Allocator) Error![]LayerProperties {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkEnumerateDeviceLayerProperties(self, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(LayerProperties, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkEnumerateDeviceLayerProperties(self, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn enumerateDeviceExtensionProperties(self: *PhysicalDevice, layer_name: ?[*:0]const u8, gpa: std.mem.Allocator) Error![]ExtensionProperties {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkEnumerateDeviceExtensionProperties(self, layer_name, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(ExtensionProperties, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkEnumerateDeviceExtensionProperties(self, layer_name, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceSparseImageFormatProperties(self: *PhysicalDevice, format: Format, @"type": ImageType, samples: SampleCountFlagBits, usage: ImageUsageFlags, tiling: ImageTiling, gpa: std.mem.Allocator) Error![]SparseImageFormatProperties {
        var _count: u32 = 0;
        {
            instance_dispatch.vkGetPhysicalDeviceSparseImageFormatProperties(self, format, @"type", samples, usage, tiling, &_count, null);
        }
        const _out = gpa.alloc(SparseImageFormatProperties, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            instance_dispatch.vkGetPhysicalDeviceSparseImageFormatProperties(self, format, @"type", samples, usage, tiling, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceSurfaceSupportKHR(self: *PhysicalDevice, queue_family_index: u32, surface: SurfaceKHR) Error!Bool32 {
        var _out: Bool32 = undefined;
        const _r = instance_dispatch.vkGetPhysicalDeviceSurfaceSupportKHR(self, queue_family_index, surface, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn getPhysicalDeviceSurfaceCapabilitiesKHR(self: *PhysicalDevice, surface: SurfaceKHR) Error!SurfaceCapabilitiesKHR {
        var _out: SurfaceCapabilitiesKHR = undefined;
        const _r = instance_dispatch.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self, surface, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn getPhysicalDeviceSurfaceFormatsKHR(self: *PhysicalDevice, surface: SurfaceKHR, gpa: std.mem.Allocator) Error![]SurfaceFormatKHR {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkGetPhysicalDeviceSurfaceFormatsKHR(self, surface, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(SurfaceFormatKHR, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkGetPhysicalDeviceSurfaceFormatsKHR(self, surface, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceSurfacePresentModesKHR(self: *PhysicalDevice, surface: SurfaceKHR, gpa: std.mem.Allocator) Error![]PresentModeKHR {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkGetPhysicalDeviceSurfacePresentModesKHR(self, surface, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(PresentModeKHR, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkGetPhysicalDeviceSurfacePresentModesKHR(self, surface, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceWaylandPresentationSupportKHR(self: *PhysicalDevice, queue_family_index: u32) wl_display {
        var _out: wl_display = undefined;
        instance_dispatch.vkGetPhysicalDeviceWaylandPresentationSupportKHR(self, queue_family_index, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceWin32PresentationSupportKHR(self: *PhysicalDevice, queue_family_index: u32) Bool32 {
        return instance_dispatch.vkGetPhysicalDeviceWin32PresentationSupportKHR(self, queue_family_index);
    }

    pub fn getPhysicalDeviceFeatures2(self: *PhysicalDevice) PhysicalDeviceFeatures2 {
        var _out: PhysicalDeviceFeatures2 = undefined;
        instance_dispatch.vkGetPhysicalDeviceFeatures2(self, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceProperties2(self: *PhysicalDevice) PhysicalDeviceProperties2 {
        var _out: PhysicalDeviceProperties2 = undefined;
        instance_dispatch.vkGetPhysicalDeviceProperties2(self, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceFormatProperties2(self: *PhysicalDevice, format: Format) FormatProperties2 {
        var _out: FormatProperties2 = undefined;
        instance_dispatch.vkGetPhysicalDeviceFormatProperties2(self, format, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceImageFormatProperties2(self: *PhysicalDevice, image_format_info: *const PhysicalDeviceImageFormatInfo2) Error!ImageFormatProperties2 {
        var _out: ImageFormatProperties2 = undefined;
        const _r = instance_dispatch.vkGetPhysicalDeviceImageFormatProperties2(self, image_format_info, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn getPhysicalDeviceQueueFamilyProperties2(self: *PhysicalDevice, gpa: std.mem.Allocator) Error![]QueueFamilyProperties2 {
        var _count: u32 = 0;
        {
            instance_dispatch.vkGetPhysicalDeviceQueueFamilyProperties2(self, &_count, null);
        }
        const _out = gpa.alloc(QueueFamilyProperties2, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            instance_dispatch.vkGetPhysicalDeviceQueueFamilyProperties2(self, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceMemoryProperties2(self: *PhysicalDevice) PhysicalDeviceMemoryProperties2 {
        var _out: PhysicalDeviceMemoryProperties2 = undefined;
        instance_dispatch.vkGetPhysicalDeviceMemoryProperties2(self, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceSparseImageFormatProperties2(self: *PhysicalDevice, format_info: *const PhysicalDeviceSparseImageFormatInfo2, gpa: std.mem.Allocator) Error![]SparseImageFormatProperties2 {
        var _count: u32 = 0;
        {
            instance_dispatch.vkGetPhysicalDeviceSparseImageFormatProperties2(self, format_info, &_count, null);
        }
        const _out = gpa.alloc(SparseImageFormatProperties2, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            instance_dispatch.vkGetPhysicalDeviceSparseImageFormatProperties2(self, format_info, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceExternalBufferProperties(self: *PhysicalDevice, external_buffer_info: *const PhysicalDeviceExternalBufferInfo) ExternalBufferProperties {
        var _out: ExternalBufferProperties = undefined;
        instance_dispatch.vkGetPhysicalDeviceExternalBufferProperties(self, external_buffer_info, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceExternalSemaphoreProperties(self: *PhysicalDevice, external_semaphore_info: *const PhysicalDeviceExternalSemaphoreInfo) ExternalSemaphoreProperties {
        var _out: ExternalSemaphoreProperties = undefined;
        instance_dispatch.vkGetPhysicalDeviceExternalSemaphoreProperties(self, external_semaphore_info, &_out);
        return _out;
    }

    pub fn getPhysicalDeviceExternalFenceProperties(self: *PhysicalDevice, external_fence_info: *const PhysicalDeviceExternalFenceInfo) ExternalFenceProperties {
        var _out: ExternalFenceProperties = undefined;
        instance_dispatch.vkGetPhysicalDeviceExternalFenceProperties(self, external_fence_info, &_out);
        return _out;
    }

    pub fn getPhysicalDevicePresentRectanglesKHR(self: *PhysicalDevice, surface: SurfaceKHR, gpa: std.mem.Allocator) Error![]Rect2D {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkGetPhysicalDevicePresentRectanglesKHR(self, surface, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(Rect2D, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkGetPhysicalDevicePresentRectanglesKHR(self, surface, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn getPhysicalDeviceToolProperties(self: *PhysicalDevice, gpa: std.mem.Allocator) Error![]PhysicalDeviceToolProperties {
        var _count: u32 = 0;
        {
            const _r = instance_dispatch.vkGetPhysicalDeviceToolProperties(self, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(PhysicalDeviceToolProperties, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = instance_dispatch.vkGetPhysicalDeviceToolProperties(self, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }
};

pub const Device = opaque {
    pub fn getDeviceProcAddr(self: *Device, name: [*:0]const u8) PFN_vkVoidFunction {
        return device_dispatch.vkGetDeviceProcAddr(self, name);
    }

    pub fn destroyDevice(self: *Device, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyDevice(self, allocator);
    }

    pub fn getDeviceQueue(self: *Device, queue_family_index: u32, queue_index: u32) *Queue {
        var _out: *Queue = undefined;
        device_dispatch.vkGetDeviceQueue(self, queue_family_index, queue_index, &_out);
        return _out;
    }

    pub fn waitIdle(self: *Device) Error!void {
        const _r = device_dispatch.vkDeviceWaitIdle(self);
        try checkResult(_r);
    }

    pub fn allocateMemory(self: *Device, allocate_info: *const MemoryAllocateInfo, allocator: ?*const AllocationCallbacks) Error!DeviceMemory {
        var _out: DeviceMemory = undefined;
        const _r = device_dispatch.vkAllocateMemory(self, allocate_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn freeMemory(self: *Device, memory: DeviceMemory, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkFreeMemory(self, memory, allocator);
    }

    pub fn mapMemory(self: *Device, memory: DeviceMemory, offset: DeviceSize, size: DeviceSize, flags: MemoryMapFlags) Error!void {
        var _out: void = undefined;
        const _r = device_dispatch.vkMapMemory(self, memory, offset, size, flags, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn unmapMemory(self: *Device, memory: DeviceMemory) void {
        return device_dispatch.vkUnmapMemory(self, memory);
    }

    pub fn flushMappedMemoryRanges(self: *Device, memory_ranges: []const MappedMemoryRange) Error!void {
        const _r = device_dispatch.vkFlushMappedMemoryRanges(self, @intCast(memory_ranges.len), memory_ranges.ptr);
        try checkResult(_r);
    }

    pub fn invalidateMappedMemoryRanges(self: *Device, memory_ranges: []const MappedMemoryRange) Error!void {
        const _r = device_dispatch.vkInvalidateMappedMemoryRanges(self, @intCast(memory_ranges.len), memory_ranges.ptr);
        try checkResult(_r);
    }

    pub fn getDeviceMemoryCommitment(self: *Device, memory: DeviceMemory) DeviceSize {
        var _out: DeviceSize = undefined;
        device_dispatch.vkGetDeviceMemoryCommitment(self, memory, &_out);
        return _out;
    }

    pub fn getBufferMemoryRequirements(self: *Device, buffer: Buffer) MemoryRequirements {
        var _out: MemoryRequirements = undefined;
        device_dispatch.vkGetBufferMemoryRequirements(self, buffer, &_out);
        return _out;
    }

    pub fn bindBufferMemory(self: *Device, buffer: Buffer, memory: DeviceMemory, memory_offset: DeviceSize) Error!void {
        const _r = device_dispatch.vkBindBufferMemory(self, buffer, memory, memory_offset);
        try checkResult(_r);
    }

    pub fn getImageMemoryRequirements(self: *Device, image: Image) MemoryRequirements {
        var _out: MemoryRequirements = undefined;
        device_dispatch.vkGetImageMemoryRequirements(self, image, &_out);
        return _out;
    }

    pub fn bindImageMemory(self: *Device, image: Image, memory: DeviceMemory, memory_offset: DeviceSize) Error!void {
        const _r = device_dispatch.vkBindImageMemory(self, image, memory, memory_offset);
        try checkResult(_r);
    }

    pub fn getImageSparseMemoryRequirements(self: *Device, image: Image, gpa: std.mem.Allocator) Error![]SparseImageMemoryRequirements {
        var _count: u32 = 0;
        {
            device_dispatch.vkGetImageSparseMemoryRequirements(self, image, &_count, null);
        }
        const _out = gpa.alloc(SparseImageMemoryRequirements, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            device_dispatch.vkGetImageSparseMemoryRequirements(self, image, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn createFence(self: *Device, create_info: *const FenceCreateInfo, allocator: ?*const AllocationCallbacks) Error!Fence {
        var _out: Fence = undefined;
        const _r = device_dispatch.vkCreateFence(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyFence(self: *Device, fence: Fence, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyFence(self, fence, allocator);
    }

    pub fn resetFences(self: *Device, fences: []const Fence) Error!void {
        const _r = device_dispatch.vkResetFences(self, @intCast(fences.len), fences.ptr);
        try checkResult(_r);
    }

    pub fn getFenceStatus(self: *Device, fence: Fence) Error!void {
        const _r = device_dispatch.vkGetFenceStatus(self, fence);
        try checkResult(_r);
    }

    pub fn waitForFences(self: *Device, fences: []const Fence, wait_all: Bool32, timeout: u64) Error!void {
        const _r = device_dispatch.vkWaitForFences(self, @intCast(fences.len), fences.ptr, wait_all, timeout);
        try checkResult(_r);
    }

    pub fn createSemaphore(self: *Device, create_info: *const SemaphoreCreateInfo, allocator: ?*const AllocationCallbacks) Error!Semaphore {
        var _out: Semaphore = undefined;
        const _r = device_dispatch.vkCreateSemaphore(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroySemaphore(self: *Device, semaphore: Semaphore, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroySemaphore(self, semaphore, allocator);
    }

    pub fn createEvent(self: *Device, create_info: *const EventCreateInfo, allocator: ?*const AllocationCallbacks) Error!Event {
        var _out: Event = undefined;
        const _r = device_dispatch.vkCreateEvent(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyEvent(self: *Device, event: Event, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyEvent(self, event, allocator);
    }

    pub fn getEventStatus(self: *Device, event: Event) Error!void {
        const _r = device_dispatch.vkGetEventStatus(self, event);
        try checkResult(_r);
    }

    pub fn setEvent(self: *Device, event: Event) Error!void {
        const _r = device_dispatch.vkSetEvent(self, event);
        try checkResult(_r);
    }

    pub fn resetEvent(self: *Device, event: Event) Error!void {
        const _r = device_dispatch.vkResetEvent(self, event);
        try checkResult(_r);
    }

    pub fn createQueryPool(self: *Device, create_info: *const QueryPoolCreateInfo, allocator: ?*const AllocationCallbacks) Error!QueryPool {
        var _out: QueryPool = undefined;
        const _r = device_dispatch.vkCreateQueryPool(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyQueryPool(self: *Device, query_pool: QueryPool, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyQueryPool(self, query_pool, allocator);
    }

    pub fn getQueryPoolResults(self: *Device, query_pool: QueryPool, first_query: u32, query_count: u32, data: []void, stride: DeviceSize, flags: QueryResultFlags) Error!void {
        const _r = device_dispatch.vkGetQueryPoolResults(self, query_pool, first_query, query_count, @intCast(data.len), data.ptr, stride, flags);
        try checkResult(_r);
    }

    pub fn resetQueryPool(self: *Device, query_pool: QueryPool, first_query: u32, query_count: u32) void {
        return device_dispatch.vkResetQueryPool(self, query_pool, first_query, query_count);
    }

    pub fn createBuffer(self: *Device, create_info: *const BufferCreateInfo, allocator: ?*const AllocationCallbacks) Error!Buffer {
        var _out: Buffer = undefined;
        const _r = device_dispatch.vkCreateBuffer(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyBuffer(self: *Device, buffer: Buffer, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyBuffer(self, buffer, allocator);
    }

    pub fn createBufferView(self: *Device, create_info: *const BufferViewCreateInfo, allocator: ?*const AllocationCallbacks) Error!BufferView {
        var _out: BufferView = undefined;
        const _r = device_dispatch.vkCreateBufferView(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyBufferView(self: *Device, buffer_view: BufferView, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyBufferView(self, buffer_view, allocator);
    }

    pub fn createImage(self: *Device, create_info: *const ImageCreateInfo, allocator: ?*const AllocationCallbacks) Error!Image {
        var _out: Image = undefined;
        const _r = device_dispatch.vkCreateImage(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyImage(self: *Device, image: Image, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyImage(self, image, allocator);
    }

    pub fn getImageSubresourceLayout(self: *Device, image: Image, subresource: *const ImageSubresource) SubresourceLayout {
        var _out: SubresourceLayout = undefined;
        device_dispatch.vkGetImageSubresourceLayout(self, image, subresource, &_out);
        return _out;
    }

    pub fn createImageView(self: *Device, create_info: *const ImageViewCreateInfo, allocator: ?*const AllocationCallbacks) Error!ImageView {
        var _out: ImageView = undefined;
        const _r = device_dispatch.vkCreateImageView(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyImageView(self: *Device, image_view: ImageView, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyImageView(self, image_view, allocator);
    }

    pub fn createShaderModule(self: *Device, create_info: *const ShaderModuleCreateInfo, allocator: ?*const AllocationCallbacks) Error!ShaderModule {
        var _out: ShaderModule = undefined;
        const _r = device_dispatch.vkCreateShaderModule(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyShaderModule(self: *Device, shader_module: ShaderModule, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyShaderModule(self, shader_module, allocator);
    }

    pub fn createPipelineCache(self: *Device, create_info: *const PipelineCacheCreateInfo, allocator: ?*const AllocationCallbacks) Error!PipelineCache {
        var _out: PipelineCache = undefined;
        const _r = device_dispatch.vkCreatePipelineCache(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyPipelineCache(self: *Device, pipeline_cache: PipelineCache, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyPipelineCache(self, pipeline_cache, allocator);
    }

    pub fn getPipelineCacheData(self: *Device, pipeline_cache: PipelineCache, data_size: *usize, data: []void) Error!void {
        const _r = device_dispatch.vkGetPipelineCacheData(self, pipeline_cache, data_size, data.ptr);
        try checkResult(_r);
    }

    pub fn mergePipelineCaches(self: *Device, dst_cache: PipelineCache, src_caches: []const PipelineCache) Error!void {
        const _r = device_dispatch.vkMergePipelineCaches(self, dst_cache, @intCast(src_caches.len), src_caches.ptr);
        try checkResult(_r);
    }

    pub fn createGraphicsPipelines(self: *Device, pipeline_cache: PipelineCache, create_infos: []const GraphicsPipelineCreateInfo, allocator: ?*const AllocationCallbacks, pipelines: []Pipeline) Error!void {
        const _r = device_dispatch.vkCreateGraphicsPipelines(self, pipeline_cache, @intCast(create_infos.len), create_infos.ptr, allocator, pipelines.ptr);
        try checkResult(_r);
    }

    pub fn createComputePipelines(self: *Device, pipeline_cache: PipelineCache, create_infos: []const ComputePipelineCreateInfo, allocator: ?*const AllocationCallbacks, pipelines: []Pipeline) Error!void {
        const _r = device_dispatch.vkCreateComputePipelines(self, pipeline_cache, @intCast(create_infos.len), create_infos.ptr, allocator, pipelines.ptr);
        try checkResult(_r);
    }

    pub fn destroyPipeline(self: *Device, pipeline: Pipeline, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyPipeline(self, pipeline, allocator);
    }

    pub fn createPipelineLayout(self: *Device, create_info: *const PipelineLayoutCreateInfo, allocator: ?*const AllocationCallbacks) Error!PipelineLayout {
        var _out: PipelineLayout = undefined;
        const _r = device_dispatch.vkCreatePipelineLayout(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyPipelineLayout(self: *Device, pipeline_layout: PipelineLayout, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyPipelineLayout(self, pipeline_layout, allocator);
    }

    pub fn createSampler(self: *Device, create_info: *const SamplerCreateInfo, allocator: ?*const AllocationCallbacks) Error!Sampler {
        var _out: Sampler = undefined;
        const _r = device_dispatch.vkCreateSampler(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroySampler(self: *Device, sampler: Sampler, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroySampler(self, sampler, allocator);
    }

    pub fn createDescriptorSetLayout(self: *Device, create_info: *const DescriptorSetLayoutCreateInfo, allocator: ?*const AllocationCallbacks) Error!DescriptorSetLayout {
        var _out: DescriptorSetLayout = undefined;
        const _r = device_dispatch.vkCreateDescriptorSetLayout(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyDescriptorSetLayout(self: *Device, descriptor_set_layout: DescriptorSetLayout, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyDescriptorSetLayout(self, descriptor_set_layout, allocator);
    }

    pub fn createDescriptorPool(self: *Device, create_info: *const DescriptorPoolCreateInfo, allocator: ?*const AllocationCallbacks) Error!DescriptorPool {
        var _out: DescriptorPool = undefined;
        const _r = device_dispatch.vkCreateDescriptorPool(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyDescriptorPool(self: *Device, descriptor_pool: DescriptorPool, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyDescriptorPool(self, descriptor_pool, allocator);
    }

    pub fn resetDescriptorPool(self: *Device, descriptor_pool: DescriptorPool, flags: DescriptorPoolResetFlags) Error!void {
        const _r = device_dispatch.vkResetDescriptorPool(self, descriptor_pool, flags);
        try checkResult(_r);
    }

    pub fn allocateDescriptorSets(self: *Device, allocate_info: *const DescriptorSetAllocateInfo, descriptor_sets: []DescriptorSet) Error!void {
        const _r = device_dispatch.vkAllocateDescriptorSets(self, allocate_info, descriptor_sets.ptr);
        try checkResult(_r);
    }

    pub fn freeDescriptorSets(self: *Device, descriptor_pool: DescriptorPool, descriptor_sets: []const DescriptorSet) Error!void {
        const _r = device_dispatch.vkFreeDescriptorSets(self, descriptor_pool, @intCast(descriptor_sets.len), descriptor_sets.ptr);
        try checkResult(_r);
    }

    pub fn updateDescriptorSets(self: *Device, descriptor_writes: []const WriteDescriptorSet, descriptor_copies: []const CopyDescriptorSet) void {
        return device_dispatch.vkUpdateDescriptorSets(self, @intCast(descriptor_writes.len), descriptor_writes.ptr, @intCast(descriptor_copies.len), descriptor_copies.ptr);
    }

    pub fn createFramebuffer(self: *Device, create_info: *const FramebufferCreateInfo, allocator: ?*const AllocationCallbacks) Error!Framebuffer {
        var _out: Framebuffer = undefined;
        const _r = device_dispatch.vkCreateFramebuffer(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyFramebuffer(self: *Device, framebuffer: Framebuffer, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyFramebuffer(self, framebuffer, allocator);
    }

    pub fn createRenderPass(self: *Device, create_info: *const RenderPassCreateInfo, allocator: ?*const AllocationCallbacks) Error!RenderPass {
        var _out: RenderPass = undefined;
        const _r = device_dispatch.vkCreateRenderPass(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyRenderPass(self: *Device, render_pass: RenderPass, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyRenderPass(self, render_pass, allocator);
    }

    pub fn getRenderAreaGranularity(self: *Device, render_pass: RenderPass) Extent2D {
        var _out: Extent2D = undefined;
        device_dispatch.vkGetRenderAreaGranularity(self, render_pass, &_out);
        return _out;
    }

    pub fn createCommandPool(self: *Device, create_info: *const CommandPoolCreateInfo, allocator: ?*const AllocationCallbacks) Error!CommandPool {
        var _out: CommandPool = undefined;
        const _r = device_dispatch.vkCreateCommandPool(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyCommandPool(self: *Device, command_pool: CommandPool, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyCommandPool(self, command_pool, allocator);
    }

    pub fn resetCommandPool(self: *Device, command_pool: CommandPool, flags: CommandPoolResetFlags) Error!void {
        const _r = device_dispatch.vkResetCommandPool(self, command_pool, flags);
        try checkResult(_r);
    }

    pub fn allocateCommandBuffers(self: *Device, allocate_info: *const CommandBufferAllocateInfo, command_buffers: []*CommandBuffer) Error!void {
        const _r = device_dispatch.vkAllocateCommandBuffers(self, allocate_info, command_buffers.ptr);
        try checkResult(_r);
    }

    pub fn freeCommandBuffers(self: *Device, command_pool: CommandPool, command_buffers: []const *CommandBuffer) void {
        return device_dispatch.vkFreeCommandBuffers(self, command_pool, @intCast(command_buffers.len), command_buffers.ptr);
    }

    pub fn createSwapchainKHR(self: *Device, create_info: *const SwapchainCreateInfoKHR, allocator: ?*const AllocationCallbacks) Error!SwapchainKHR {
        var _out: SwapchainKHR = undefined;
        const _r = device_dispatch.vkCreateSwapchainKHR(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroySwapchainKHR(self: *Device, swapchain: SwapchainKHR, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroySwapchainKHR(self, swapchain, allocator);
    }

    pub fn getSwapchainImagesKHR(self: *Device, swapchain: SwapchainKHR, gpa: std.mem.Allocator) Error![]Image {
        var _count: u32 = 0;
        {
            const _r = device_dispatch.vkGetSwapchainImagesKHR(self, swapchain, &_count, null);
            try checkResult(_r);
        }
        const _out = gpa.alloc(Image, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            const _r = device_dispatch.vkGetSwapchainImagesKHR(self, swapchain, &_count, _out.ptr);
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn acquireNextImageKHR(self: *Device, swapchain: SwapchainKHR, timeout: u64, semaphore: Semaphore, fence: Fence) Error!u32 {
        var _out: u32 = undefined;
        const _r = device_dispatch.vkAcquireNextImageKHR(self, swapchain, timeout, semaphore, fence, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn trimCommandPool(self: *Device, command_pool: CommandPool, flags: CommandPoolTrimFlags) void {
        return device_dispatch.vkTrimCommandPool(self, command_pool, flags);
    }

    pub fn getDeviceGroupPeerMemoryFeatures(self: *Device, heap_index: u32, local_device_index: u32, remote_device_index: u32) PeerMemoryFeatureFlags {
        var _out: PeerMemoryFeatureFlags = undefined;
        device_dispatch.vkGetDeviceGroupPeerMemoryFeatures(self, heap_index, local_device_index, remote_device_index, &_out);
        return _out;
    }

    pub fn bindBufferMemory2(self: *Device, bind_infos: []const BindBufferMemoryInfo) Error!void {
        const _r = device_dispatch.vkBindBufferMemory2(self, @intCast(bind_infos.len), bind_infos.ptr);
        try checkResult(_r);
    }

    pub fn bindImageMemory2(self: *Device, bind_infos: []const BindImageMemoryInfo) Error!void {
        const _r = device_dispatch.vkBindImageMemory2(self, @intCast(bind_infos.len), bind_infos.ptr);
        try checkResult(_r);
    }

    pub fn getDeviceGroupPresentCapabilitiesKHR(self: *Device) Error!DeviceGroupPresentCapabilitiesKHR {
        var _out: DeviceGroupPresentCapabilitiesKHR = undefined;
        const _r = device_dispatch.vkGetDeviceGroupPresentCapabilitiesKHR(self, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn getDeviceGroupSurfacePresentModesKHR(self: *Device, surface: SurfaceKHR) Error!DeviceGroupPresentModeFlagsKHR {
        var _out: DeviceGroupPresentModeFlagsKHR = undefined;
        const _r = device_dispatch.vkGetDeviceGroupSurfacePresentModesKHR(self, surface, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn acquireNextImage2KHR(self: *Device, acquire_info: *const AcquireNextImageInfoKHR) Error!u32 {
        var _out: u32 = undefined;
        const _r = device_dispatch.vkAcquireNextImage2KHR(self, acquire_info, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn createDescriptorUpdateTemplate(self: *Device, create_info: *const DescriptorUpdateTemplateCreateInfo, allocator: ?*const AllocationCallbacks) Error!DescriptorUpdateTemplate {
        var _out: DescriptorUpdateTemplate = undefined;
        const _r = device_dispatch.vkCreateDescriptorUpdateTemplate(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyDescriptorUpdateTemplate(self: *Device, descriptor_update_template: DescriptorUpdateTemplate, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyDescriptorUpdateTemplate(self, descriptor_update_template, allocator);
    }

    pub fn updateDescriptorSetWithTemplate(self: *Device, descriptor_set: DescriptorSet, descriptor_update_template: DescriptorUpdateTemplate, data: *const anyopaque) void {
        return device_dispatch.vkUpdateDescriptorSetWithTemplate(self, descriptor_set, descriptor_update_template, data);
    }

    pub fn getBufferMemoryRequirements2(self: *Device, info: *const BufferMemoryRequirementsInfo2) MemoryRequirements2 {
        var _out: MemoryRequirements2 = undefined;
        device_dispatch.vkGetBufferMemoryRequirements2(self, info, &_out);
        return _out;
    }

    pub fn getImageMemoryRequirements2(self: *Device, info: *const ImageMemoryRequirementsInfo2) MemoryRequirements2 {
        var _out: MemoryRequirements2 = undefined;
        device_dispatch.vkGetImageMemoryRequirements2(self, info, &_out);
        return _out;
    }

    pub fn getImageSparseMemoryRequirements2(self: *Device, info: *const ImageSparseMemoryRequirementsInfo2, gpa: std.mem.Allocator) Error![]SparseImageMemoryRequirements2 {
        var _count: u32 = 0;
        {
            device_dispatch.vkGetImageSparseMemoryRequirements2(self, info, &_count, null);
        }
        const _out = gpa.alloc(SparseImageMemoryRequirements2, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            device_dispatch.vkGetImageSparseMemoryRequirements2(self, info, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn getDeviceBufferMemoryRequirements(self: *Device, info: *const DeviceBufferMemoryRequirements) MemoryRequirements2 {
        var _out: MemoryRequirements2 = undefined;
        device_dispatch.vkGetDeviceBufferMemoryRequirements(self, info, &_out);
        return _out;
    }

    pub fn getDeviceImageMemoryRequirements(self: *Device, info: *const DeviceImageMemoryRequirements) MemoryRequirements2 {
        var _out: MemoryRequirements2 = undefined;
        device_dispatch.vkGetDeviceImageMemoryRequirements(self, info, &_out);
        return _out;
    }

    pub fn getDeviceImageSparseMemoryRequirements(self: *Device, info: *const DeviceImageMemoryRequirements, gpa: std.mem.Allocator) Error![]SparseImageMemoryRequirements2 {
        var _count: u32 = 0;
        {
            device_dispatch.vkGetDeviceImageSparseMemoryRequirements(self, info, &_count, null);
        }
        const _out = gpa.alloc(SparseImageMemoryRequirements2, _count) catch return error.OutOfHostMemory;
        errdefer gpa.free(_out);
        {
            device_dispatch.vkGetDeviceImageSparseMemoryRequirements(self, info, &_count, _out.ptr);
        }
        return _out[0.._count];
    }

    pub fn createSamplerYcbcrConversion(self: *Device, create_info: *const SamplerYcbcrConversionCreateInfo, allocator: ?*const AllocationCallbacks) Error!SamplerYcbcrConversion {
        var _out: SamplerYcbcrConversion = undefined;
        const _r = device_dispatch.vkCreateSamplerYcbcrConversion(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroySamplerYcbcrConversion(self: *Device, ycbcr_conversion: SamplerYcbcrConversion, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroySamplerYcbcrConversion(self, ycbcr_conversion, allocator);
    }

    pub fn getDeviceQueue2(self: *Device, queue_info: *const DeviceQueueInfo2) *Queue {
        var _out: *Queue = undefined;
        device_dispatch.vkGetDeviceQueue2(self, queue_info, &_out);
        return _out;
    }

    pub fn getDescriptorSetLayoutSupport(self: *Device, create_info: *const DescriptorSetLayoutCreateInfo) DescriptorSetLayoutSupport {
        var _out: DescriptorSetLayoutSupport = undefined;
        device_dispatch.vkGetDescriptorSetLayoutSupport(self, create_info, &_out);
        return _out;
    }

    pub fn setDebugUtilsObjectNameEXT(self: *Device, name_info: *const DebugUtilsObjectNameInfoEXT) Error!void {
        const _r = device_dispatch.vkSetDebugUtilsObjectNameEXT(self, name_info);
        try checkResult(_r);
    }

    pub fn setDebugUtilsObjectTagEXT(self: *Device, tag_info: *const DebugUtilsObjectTagInfoEXT) Error!void {
        const _r = device_dispatch.vkSetDebugUtilsObjectTagEXT(self, tag_info);
        try checkResult(_r);
    }

    pub fn createRenderPass2(self: *Device, create_info: *const RenderPassCreateInfo2, allocator: ?*const AllocationCallbacks) Error!RenderPass {
        var _out: RenderPass = undefined;
        const _r = device_dispatch.vkCreateRenderPass2(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn getSemaphoreCounterValue(self: *Device, semaphore: Semaphore) Error!u64 {
        var _out: u64 = undefined;
        const _r = device_dispatch.vkGetSemaphoreCounterValue(self, semaphore, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn waitSemaphores(self: *Device, wait_info: *const SemaphoreWaitInfo, timeout: u64) Error!void {
        const _r = device_dispatch.vkWaitSemaphores(self, wait_info, timeout);
        try checkResult(_r);
    }

    pub fn signalSemaphore(self: *Device, signal_info: *const SemaphoreSignalInfo) Error!void {
        const _r = device_dispatch.vkSignalSemaphore(self, signal_info);
        try checkResult(_r);
    }

    pub fn getBufferOpaqueCaptureAddress(self: *Device, info: *const BufferDeviceAddressInfo) u64 {
        return device_dispatch.vkGetBufferOpaqueCaptureAddress(self, info);
    }

    pub fn getBufferDeviceAddress(self: *Device, info: *const BufferDeviceAddressInfo) DeviceAddress {
        return device_dispatch.vkGetBufferDeviceAddress(self, info);
    }

    pub fn getDeviceMemoryOpaqueCaptureAddress(self: *Device, info: *const DeviceMemoryOpaqueCaptureAddressInfo) u64 {
        return device_dispatch.vkGetDeviceMemoryOpaqueCaptureAddress(self, info);
    }

    pub fn createPrivateDataSlot(self: *Device, create_info: *const PrivateDataSlotCreateInfo, allocator: ?*const AllocationCallbacks) Error!PrivateDataSlot {
        var _out: PrivateDataSlot = undefined;
        const _r = device_dispatch.vkCreatePrivateDataSlot(self, create_info, allocator, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn destroyPrivateDataSlot(self: *Device, private_data_slot: PrivateDataSlot, allocator: ?*const AllocationCallbacks) void {
        return device_dispatch.vkDestroyPrivateDataSlot(self, private_data_slot, allocator);
    }

    pub fn setPrivateData(self: *Device, object_type: ObjectType, object_handle: u64, private_data_slot: PrivateDataSlot, data: u64) Error!void {
        const _r = device_dispatch.vkSetPrivateData(self, object_type, object_handle, private_data_slot, data);
        try checkResult(_r);
    }

    pub fn getPrivateData(self: *Device, object_type: ObjectType, object_handle: u64, private_data_slot: PrivateDataSlot) u64 {
        var _out: u64 = undefined;
        device_dispatch.vkGetPrivateData(self, object_type, object_handle, private_data_slot, &_out);
        return _out;
    }
};

pub const Queue = opaque {
    pub fn submit(self: *Queue, submits: []const SubmitInfo, fence: Fence) Error!void {
        const _r = device_dispatch.vkQueueSubmit(self, @intCast(submits.len), submits.ptr, fence);
        try checkResult(_r);
    }

    pub fn waitIdle(self: *Queue) Error!void {
        const _r = device_dispatch.vkQueueWaitIdle(self);
        try checkResult(_r);
    }

    pub fn bindSparse(self: *Queue, bind_info: []const BindSparseInfo, fence: Fence) Error!void {
        const _r = device_dispatch.vkQueueBindSparse(self, @intCast(bind_info.len), bind_info.ptr, fence);
        try checkResult(_r);
    }

    pub fn presentKHR(self: *Queue, present_info: *const PresentInfoKHR) Error!void {
        const _r = device_dispatch.vkQueuePresentKHR(self, present_info);
        try checkResult(_r);
    }

    pub fn beginDebugUtilsLabelEXT(self: *Queue, label_info: *const DebugUtilsLabelEXT) void {
        return device_dispatch.vkQueueBeginDebugUtilsLabelEXT(self, label_info);
    }

    pub fn endDebugUtilsLabelEXT(self: *Queue) void {
        return device_dispatch.vkQueueEndDebugUtilsLabelEXT(self);
    }

    pub fn insertDebugUtilsLabelEXT(self: *Queue, label_info: *const DebugUtilsLabelEXT) void {
        return device_dispatch.vkQueueInsertDebugUtilsLabelEXT(self, label_info);
    }

    pub fn submit2(self: *Queue, submits: []const SubmitInfo2, fence: Fence) Error!void {
        const _r = device_dispatch.vkQueueSubmit2(self, @intCast(submits.len), submits.ptr, fence);
        try checkResult(_r);
    }
};

pub const CommandBuffer = opaque {
    pub fn beginCommandBuffer(self: *CommandBuffer, begin_info: *const CommandBufferBeginInfo) Error!void {
        const _r = device_dispatch.vkBeginCommandBuffer(self, begin_info);
        try checkResult(_r);
    }

    pub fn endCommandBuffer(self: *CommandBuffer) Error!void {
        const _r = device_dispatch.vkEndCommandBuffer(self);
        try checkResult(_r);
    }

    pub fn resetCommandBuffer(self: *CommandBuffer, flags: CommandBufferResetFlags) Error!void {
        const _r = device_dispatch.vkResetCommandBuffer(self, flags);
        try checkResult(_r);
    }

    pub fn cmdBindPipeline(self: *CommandBuffer, pipeline_bind_point: PipelineBindPoint, pipeline: Pipeline) void {
        return device_dispatch.vkCmdBindPipeline(self, pipeline_bind_point, pipeline);
    }

    pub fn cmdSetViewport(self: *CommandBuffer, first_viewport: u32, viewports: []const Viewport) void {
        return device_dispatch.vkCmdSetViewport(self, first_viewport, @intCast(viewports.len), viewports.ptr);
    }

    pub fn cmdSetScissor(self: *CommandBuffer, first_scissor: u32, scissors: []const Rect2D) void {
        return device_dispatch.vkCmdSetScissor(self, first_scissor, @intCast(scissors.len), scissors.ptr);
    }

    pub fn cmdSetLineWidth(self: *CommandBuffer, line_width: f32) void {
        return device_dispatch.vkCmdSetLineWidth(self, line_width);
    }

    pub fn cmdSetDepthBias(self: *CommandBuffer, depth_bias_constant_factor: f32, depth_bias_clamp: f32, depth_bias_slope_factor: f32) void {
        return device_dispatch.vkCmdSetDepthBias(self, depth_bias_constant_factor, depth_bias_clamp, depth_bias_slope_factor);
    }

    pub fn cmdSetBlendConstants(self: *CommandBuffer, blend_constants: [4]f32) void {
        return device_dispatch.vkCmdSetBlendConstants(self, blend_constants);
    }

    pub fn cmdSetDepthBounds(self: *CommandBuffer, min_depth_bounds: f32, max_depth_bounds: f32) void {
        return device_dispatch.vkCmdSetDepthBounds(self, min_depth_bounds, max_depth_bounds);
    }

    pub fn cmdSetStencilCompareMask(self: *CommandBuffer, face_mask: StencilFaceFlags, compare_mask: u32) void {
        return device_dispatch.vkCmdSetStencilCompareMask(self, face_mask, compare_mask);
    }

    pub fn cmdSetStencilWriteMask(self: *CommandBuffer, face_mask: StencilFaceFlags, write_mask: u32) void {
        return device_dispatch.vkCmdSetStencilWriteMask(self, face_mask, write_mask);
    }

    pub fn cmdSetStencilReference(self: *CommandBuffer, face_mask: StencilFaceFlags, reference: u32) void {
        return device_dispatch.vkCmdSetStencilReference(self, face_mask, reference);
    }

    pub fn cmdBindDescriptorSets(self: *CommandBuffer, pipeline_bind_point: PipelineBindPoint, layout: PipelineLayout, first_set: u32, descriptor_sets: []const DescriptorSet, dynamic_offsets: []const u32) void {
        return device_dispatch.vkCmdBindDescriptorSets(self, pipeline_bind_point, layout, first_set, @intCast(descriptor_sets.len), descriptor_sets.ptr, @intCast(dynamic_offsets.len), dynamic_offsets.ptr);
    }

    pub fn cmdBindIndexBuffer(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize, index_type: IndexType) void {
        return device_dispatch.vkCmdBindIndexBuffer(self, buffer, offset, index_type);
    }

    pub fn cmdBindVertexBuffers(self: *CommandBuffer, first_binding: u32, buffers: []const Buffer, offsets: []const DeviceSize) void {
        return device_dispatch.vkCmdBindVertexBuffers(self, first_binding, @intCast(buffers.len), buffers.ptr, offsets.ptr);
    }

    pub fn cmdDraw(self: *CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        return device_dispatch.vkCmdDraw(self, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn cmdDrawIndexed(self: *CommandBuffer, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        return device_dispatch.vkCmdDrawIndexed(self, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    pub fn cmdDrawIndirect(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize, draw_count: u32, stride: u32) void {
        return device_dispatch.vkCmdDrawIndirect(self, buffer, offset, draw_count, stride);
    }

    pub fn cmdDrawIndexedIndirect(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize, draw_count: u32, stride: u32) void {
        return device_dispatch.vkCmdDrawIndexedIndirect(self, buffer, offset, draw_count, stride);
    }

    pub fn cmdDispatch(self: *CommandBuffer, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
        return device_dispatch.vkCmdDispatch(self, group_count_x, group_count_y, group_count_z);
    }

    pub fn cmdDispatchIndirect(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize) void {
        return device_dispatch.vkCmdDispatchIndirect(self, buffer, offset);
    }

    pub fn cmdCopyBuffer(self: *CommandBuffer, src_buffer: Buffer, dst_buffer: Buffer, regions: []const BufferCopy) void {
        return device_dispatch.vkCmdCopyBuffer(self, src_buffer, dst_buffer, @intCast(regions.len), regions.ptr);
    }

    pub fn cmdCopyImage(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_image: Image, dst_image_layout: ImageLayout, regions: []const ImageCopy) void {
        return device_dispatch.vkCmdCopyImage(self, src_image, src_image_layout, dst_image, dst_image_layout, @intCast(regions.len), regions.ptr);
    }

    pub fn cmdBlitImage(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_image: Image, dst_image_layout: ImageLayout, regions: []const ImageBlit, filter: Filter) void {
        return device_dispatch.vkCmdBlitImage(self, src_image, src_image_layout, dst_image, dst_image_layout, @intCast(regions.len), regions.ptr, filter);
    }

    pub fn cmdCopyBufferToImage(self: *CommandBuffer, src_buffer: Buffer, dst_image: Image, dst_image_layout: ImageLayout, regions: []const BufferImageCopy) void {
        return device_dispatch.vkCmdCopyBufferToImage(self, src_buffer, dst_image, dst_image_layout, @intCast(regions.len), regions.ptr);
    }

    pub fn cmdCopyImageToBuffer(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_buffer: Buffer, regions: []const BufferImageCopy) void {
        return device_dispatch.vkCmdCopyImageToBuffer(self, src_image, src_image_layout, dst_buffer, @intCast(regions.len), regions.ptr);
    }

    pub fn cmdUpdateBuffer(self: *CommandBuffer, dst_buffer: Buffer, dst_offset: DeviceSize, data_size: DeviceSize, data: []const void) void {
        return device_dispatch.vkCmdUpdateBuffer(self, dst_buffer, dst_offset, data_size, data.ptr);
    }

    pub fn cmdFillBuffer(self: *CommandBuffer, dst_buffer: Buffer, dst_offset: DeviceSize, size: DeviceSize, data: u32) void {
        return device_dispatch.vkCmdFillBuffer(self, dst_buffer, dst_offset, size, data);
    }

    pub fn cmdClearColorImage(self: *CommandBuffer, image: Image, image_layout: ImageLayout, color: *const ClearColorValue, ranges: []const ImageSubresourceRange) void {
        return device_dispatch.vkCmdClearColorImage(self, image, image_layout, color, @intCast(ranges.len), ranges.ptr);
    }

    pub fn cmdClearDepthStencilImage(self: *CommandBuffer, image: Image, image_layout: ImageLayout, depth_stencil: *const ClearDepthStencilValue, ranges: []const ImageSubresourceRange) void {
        return device_dispatch.vkCmdClearDepthStencilImage(self, image, image_layout, depth_stencil, @intCast(ranges.len), ranges.ptr);
    }

    pub fn cmdClearAttachments(self: *CommandBuffer, attachments: []const ClearAttachment, rects: []const ClearRect) void {
        return device_dispatch.vkCmdClearAttachments(self, @intCast(attachments.len), attachments.ptr, @intCast(rects.len), rects.ptr);
    }

    pub fn cmdResolveImage(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_image: Image, dst_image_layout: ImageLayout, regions: []const ImageResolve) void {
        return device_dispatch.vkCmdResolveImage(self, src_image, src_image_layout, dst_image, dst_image_layout, @intCast(regions.len), regions.ptr);
    }

    pub fn cmdSetEvent(self: *CommandBuffer, event: Event, stage_mask: PipelineStageFlags) void {
        return device_dispatch.vkCmdSetEvent(self, event, stage_mask);
    }

    pub fn cmdResetEvent(self: *CommandBuffer, event: Event, stage_mask: PipelineStageFlags) void {
        return device_dispatch.vkCmdResetEvent(self, event, stage_mask);
    }

    pub fn cmdWaitEvents(self: *CommandBuffer, events: []const Event, src_stage_mask: PipelineStageFlags, dst_stage_mask: PipelineStageFlags, memory_barriers: []const MemoryBarrier, buffer_memory_barriers: []const BufferMemoryBarrier, image_memory_barriers: []const ImageMemoryBarrier) void {
        return device_dispatch.vkCmdWaitEvents(self, @intCast(events.len), events.ptr, src_stage_mask, dst_stage_mask, @intCast(memory_barriers.len), memory_barriers.ptr, @intCast(buffer_memory_barriers.len), buffer_memory_barriers.ptr, @intCast(image_memory_barriers.len), image_memory_barriers.ptr);
    }

    pub fn cmdPipelineBarrier(self: *CommandBuffer, src_stage_mask: PipelineStageFlags, dst_stage_mask: PipelineStageFlags, dependency_flags: DependencyFlags, memory_barriers: []const MemoryBarrier, buffer_memory_barriers: []const BufferMemoryBarrier, image_memory_barriers: []const ImageMemoryBarrier) void {
        return device_dispatch.vkCmdPipelineBarrier(self, src_stage_mask, dst_stage_mask, dependency_flags, @intCast(memory_barriers.len), memory_barriers.ptr, @intCast(buffer_memory_barriers.len), buffer_memory_barriers.ptr, @intCast(image_memory_barriers.len), image_memory_barriers.ptr);
    }

    pub fn cmdBeginQuery(self: *CommandBuffer, query_pool: QueryPool, query: u32, flags: QueryControlFlags) void {
        return device_dispatch.vkCmdBeginQuery(self, query_pool, query, flags);
    }

    pub fn cmdEndQuery(self: *CommandBuffer, query_pool: QueryPool, query: u32) void {
        return device_dispatch.vkCmdEndQuery(self, query_pool, query);
    }

    pub fn cmdResetQueryPool(self: *CommandBuffer, query_pool: QueryPool, first_query: u32, query_count: u32) void {
        return device_dispatch.vkCmdResetQueryPool(self, query_pool, first_query, query_count);
    }

    pub fn cmdWriteTimestamp(self: *CommandBuffer, pipeline_stage: PipelineStageFlagBits, query_pool: QueryPool, query: u32) void {
        return device_dispatch.vkCmdWriteTimestamp(self, pipeline_stage, query_pool, query);
    }

    pub fn cmdCopyQueryPoolResults(self: *CommandBuffer, query_pool: QueryPool, first_query: u32, query_count: u32, dst_buffer: Buffer, dst_offset: DeviceSize, stride: DeviceSize, flags: QueryResultFlags) void {
        return device_dispatch.vkCmdCopyQueryPoolResults(self, query_pool, first_query, query_count, dst_buffer, dst_offset, stride, flags);
    }

    pub fn cmdPushConstants(self: *CommandBuffer, layout: PipelineLayout, stage_flags: ShaderStageFlags, offset: u32, values: []const void) void {
        return device_dispatch.vkCmdPushConstants(self, layout, stage_flags, offset, @intCast(values.len), values.ptr);
    }

    pub fn cmdBeginRenderPass(self: *CommandBuffer, render_pass_begin: *const RenderPassBeginInfo, contents: SubpassContents) void {
        return device_dispatch.vkCmdBeginRenderPass(self, render_pass_begin, contents);
    }

    pub fn cmdNextSubpass(self: *CommandBuffer, contents: SubpassContents) void {
        return device_dispatch.vkCmdNextSubpass(self, contents);
    }

    pub fn cmdEndRenderPass(self: *CommandBuffer) void {
        return device_dispatch.vkCmdEndRenderPass(self);
    }

    pub fn cmdExecuteCommands(self: *CommandBuffer, command_buffers: []const *CommandBuffer) void {
        return device_dispatch.vkCmdExecuteCommands(self, @intCast(command_buffers.len), command_buffers.ptr);
    }

    pub fn cmdSetDeviceMask(self: *CommandBuffer, device_mask: u32) void {
        return device_dispatch.vkCmdSetDeviceMask(self, device_mask);
    }

    pub fn cmdDispatchBase(self: *CommandBuffer, base_group_x: u32, base_group_y: u32, base_group_z: u32, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
        return device_dispatch.vkCmdDispatchBase(self, base_group_x, base_group_y, base_group_z, group_count_x, group_count_y, group_count_z);
    }

    pub fn cmdBeginDebugUtilsLabelEXT(self: *CommandBuffer, label_info: *const DebugUtilsLabelEXT) void {
        return device_dispatch.vkCmdBeginDebugUtilsLabelEXT(self, label_info);
    }

    pub fn cmdEndDebugUtilsLabelEXT(self: *CommandBuffer) void {
        return device_dispatch.vkCmdEndDebugUtilsLabelEXT(self);
    }

    pub fn cmdInsertDebugUtilsLabelEXT(self: *CommandBuffer, label_info: *const DebugUtilsLabelEXT) void {
        return device_dispatch.vkCmdInsertDebugUtilsLabelEXT(self, label_info);
    }

    pub fn cmdBeginRenderPass2(self: *CommandBuffer, render_pass_begin: *const RenderPassBeginInfo, subpass_begin_info: *const SubpassBeginInfo) void {
        return device_dispatch.vkCmdBeginRenderPass2(self, render_pass_begin, subpass_begin_info);
    }

    pub fn cmdNextSubpass2(self: *CommandBuffer, subpass_begin_info: *const SubpassBeginInfo, subpass_end_info: *const SubpassEndInfo) void {
        return device_dispatch.vkCmdNextSubpass2(self, subpass_begin_info, subpass_end_info);
    }

    pub fn cmdEndRenderPass2(self: *CommandBuffer, subpass_end_info: *const SubpassEndInfo) void {
        return device_dispatch.vkCmdEndRenderPass2(self, subpass_end_info);
    }

    pub fn cmdDrawIndirectCount(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize, count_buffer: Buffer, count_buffer_offset: DeviceSize, max_draw_count: u32, stride: u32) void {
        return device_dispatch.vkCmdDrawIndirectCount(self, buffer, offset, count_buffer, count_buffer_offset, max_draw_count, stride);
    }

    pub fn cmdDrawIndexedIndirectCount(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize, count_buffer: Buffer, count_buffer_offset: DeviceSize, max_draw_count: u32, stride: u32) void {
        return device_dispatch.vkCmdDrawIndexedIndirectCount(self, buffer, offset, count_buffer, count_buffer_offset, max_draw_count, stride);
    }

    pub fn cmdSetCullMode(self: *CommandBuffer, cull_mode: CullModeFlags) void {
        return device_dispatch.vkCmdSetCullMode(self, cull_mode);
    }

    pub fn cmdSetFrontFace(self: *CommandBuffer, front_face: FrontFace) void {
        return device_dispatch.vkCmdSetFrontFace(self, front_face);
    }

    pub fn cmdSetPrimitiveTopology(self: *CommandBuffer, primitive_topology: PrimitiveTopology) void {
        return device_dispatch.vkCmdSetPrimitiveTopology(self, primitive_topology);
    }

    pub fn cmdSetViewportWithCount(self: *CommandBuffer, viewports: []const Viewport) void {
        return device_dispatch.vkCmdSetViewportWithCount(self, @intCast(viewports.len), viewports.ptr);
    }

    pub fn cmdSetScissorWithCount(self: *CommandBuffer, scissors: []const Rect2D) void {
        return device_dispatch.vkCmdSetScissorWithCount(self, @intCast(scissors.len), scissors.ptr);
    }

    pub fn cmdBindVertexBuffers2(self: *CommandBuffer, first_binding: u32, buffers: []const Buffer, offsets: []const DeviceSize, sizes: []const DeviceSize, strides: []const DeviceSize) void {
        return device_dispatch.vkCmdBindVertexBuffers2(self, first_binding, @intCast(buffers.len), buffers.ptr, offsets.ptr, sizes.ptr, strides.ptr);
    }

    pub fn cmdSetDepthTestEnable(self: *CommandBuffer, depth_test_enable: Bool32) void {
        return device_dispatch.vkCmdSetDepthTestEnable(self, depth_test_enable);
    }

    pub fn cmdSetDepthWriteEnable(self: *CommandBuffer, depth_write_enable: Bool32) void {
        return device_dispatch.vkCmdSetDepthWriteEnable(self, depth_write_enable);
    }

    pub fn cmdSetDepthCompareOp(self: *CommandBuffer, depth_compare_op: CompareOp) void {
        return device_dispatch.vkCmdSetDepthCompareOp(self, depth_compare_op);
    }

    pub fn cmdSetDepthBoundsTestEnable(self: *CommandBuffer, depth_bounds_test_enable: Bool32) void {
        return device_dispatch.vkCmdSetDepthBoundsTestEnable(self, depth_bounds_test_enable);
    }

    pub fn cmdSetStencilTestEnable(self: *CommandBuffer, stencil_test_enable: Bool32) void {
        return device_dispatch.vkCmdSetStencilTestEnable(self, stencil_test_enable);
    }

    pub fn cmdSetStencilOp(self: *CommandBuffer, face_mask: StencilFaceFlags, fail_op: StencilOp, pass_op: StencilOp, depth_fail_op: StencilOp, compare_op: CompareOp) void {
        return device_dispatch.vkCmdSetStencilOp(self, face_mask, fail_op, pass_op, depth_fail_op, compare_op);
    }

    pub fn cmdSetRasterizerDiscardEnable(self: *CommandBuffer, rasterizer_discard_enable: Bool32) void {
        return device_dispatch.vkCmdSetRasterizerDiscardEnable(self, rasterizer_discard_enable);
    }

    pub fn cmdSetDepthBiasEnable(self: *CommandBuffer, depth_bias_enable: Bool32) void {
        return device_dispatch.vkCmdSetDepthBiasEnable(self, depth_bias_enable);
    }

    pub fn cmdSetPrimitiveRestartEnable(self: *CommandBuffer, primitive_restart_enable: Bool32) void {
        return device_dispatch.vkCmdSetPrimitiveRestartEnable(self, primitive_restart_enable);
    }

    pub fn cmdCopyBuffer2(self: *CommandBuffer, copy_buffer_info: *const CopyBufferInfo2) void {
        return device_dispatch.vkCmdCopyBuffer2(self, copy_buffer_info);
    }

    pub fn cmdCopyImage2(self: *CommandBuffer, copy_image_info: *const CopyImageInfo2) void {
        return device_dispatch.vkCmdCopyImage2(self, copy_image_info);
    }

    pub fn cmdBlitImage2(self: *CommandBuffer, blit_image_info: *const BlitImageInfo2) void {
        return device_dispatch.vkCmdBlitImage2(self, blit_image_info);
    }

    pub fn cmdCopyBufferToImage2(self: *CommandBuffer, copy_buffer_to_image_info: *const CopyBufferToImageInfo2) void {
        return device_dispatch.vkCmdCopyBufferToImage2(self, copy_buffer_to_image_info);
    }

    pub fn cmdCopyImageToBuffer2(self: *CommandBuffer, copy_image_to_buffer_info: *const CopyImageToBufferInfo2) void {
        return device_dispatch.vkCmdCopyImageToBuffer2(self, copy_image_to_buffer_info);
    }

    pub fn cmdResolveImage2(self: *CommandBuffer, resolve_image_info: *const ResolveImageInfo2) void {
        return device_dispatch.vkCmdResolveImage2(self, resolve_image_info);
    }

    pub fn cmdSetEvent2(self: *CommandBuffer, event: Event, dependency_info: *const DependencyInfo) void {
        return device_dispatch.vkCmdSetEvent2(self, event, dependency_info);
    }

    pub fn cmdResetEvent2(self: *CommandBuffer, event: Event, stage_mask: PipelineStageFlags2) void {
        return device_dispatch.vkCmdResetEvent2(self, event, stage_mask);
    }

    pub fn cmdWaitEvents2(self: *CommandBuffer, events: []const Event, dependency_infos: []const DependencyInfo) void {
        return device_dispatch.vkCmdWaitEvents2(self, @intCast(events.len), events.ptr, dependency_infos.ptr);
    }

    pub fn cmdPipelineBarrier2(self: *CommandBuffer, dependency_info: *const DependencyInfo) void {
        return device_dispatch.vkCmdPipelineBarrier2(self, dependency_info);
    }

    pub fn cmdWriteTimestamp2(self: *CommandBuffer, stage: PipelineStageFlags2, query_pool: QueryPool, query: u32) void {
        return device_dispatch.vkCmdWriteTimestamp2(self, stage, query_pool, query);
    }

    pub fn cmdBeginRendering(self: *CommandBuffer, rendering_info: *const RenderingInfo) void {
        return device_dispatch.vkCmdBeginRendering(self, rendering_info);
    }

    pub fn cmdEndRendering(self: *CommandBuffer) void {
        return device_dispatch.vkCmdEndRendering(self);
    }
};

pub const DeviceMemory = enum(u64) { null = 0, _ };
pub const CommandPool = enum(u64) { null = 0, _ };
pub const Buffer = enum(u64) { null = 0, _ };
pub const BufferView = enum(u64) { null = 0, _ };
pub const Image = enum(u64) { null = 0, _ };
pub const ImageView = enum(u64) { null = 0, _ };
pub const ShaderModule = enum(u64) { null = 0, _ };
pub const Pipeline = enum(u64) { null = 0, _ };
pub const PipelineLayout = enum(u64) { null = 0, _ };
pub const Sampler = enum(u64) { null = 0, _ };
pub const DescriptorSet = enum(u64) { null = 0, _ };
pub const DescriptorSetLayout = enum(u64) { null = 0, _ };
pub const DescriptorPool = enum(u64) { null = 0, _ };
pub const Fence = enum(u64) { null = 0, _ };
pub const Semaphore = enum(u64) { null = 0, _ };
pub const Event = enum(u64) { null = 0, _ };
pub const QueryPool = enum(u64) { null = 0, _ };
pub const Framebuffer = enum(u64) { null = 0, _ };
pub const RenderPass = enum(u64) { null = 0, _ };
pub const PipelineCache = enum(u64) { null = 0, _ };
pub const DescriptorUpdateTemplate = enum(u64) { null = 0, _ };
pub const SamplerYcbcrConversion = enum(u64) { null = 0, _ };
pub const PrivateDataSlot = enum(u64) { null = 0, _ };
pub const SurfaceKHR = enum(u64) { null = 0, _ };
pub const SwapchainKHR = enum(u64) { null = 0, _ };
pub const DebugUtilsMessengerEXT = enum(u64) { null = 0, _ };
