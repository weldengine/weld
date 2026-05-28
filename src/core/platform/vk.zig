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
    _,
};

pub const AttachmentLoadOp = enum(i32) {
    load = 0,
    clear = 1,
    dont_care = 2,
    none = 1000400000,
    _,
};

pub const AttachmentStoreOp = enum(i32) {
    store = 0,
    dont_care = 1,
    none = 1000301000,
    _,
};

pub const ImageType = enum(i32) {
    _1d = 0,
    _2d = 1,
    _3d = 2,
    _,
};

pub const ImageTiling = enum(i32) {
    optimal = 0,
    linear = 1,
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
    _,
};

pub const QueryType = enum(i32) {
    occlusion = 0,
    pipeline_statistics = 1,
    timestamp = 2,
    _,
};

pub const BorderColor = enum(i32) {
    float_transparent_black = 0,
    int_transparent_black = 1,
    float_opaque_black = 2,
    int_opaque_black = 3,
    float_opaque_white = 4,
    int_opaque_white = 5,
    _,
};

pub const PipelineBindPoint = enum(i32) {
    graphics = 0,
    compute = 1,
    _,
};

pub const PipelineCacheHeaderVersion = enum(i32) {
    one = 1,
    safety_critical_one = 1000298001,
    _,
};

pub const PipelineCacheCreateFlagBits = enum(i32) {
    externally_synchronized_bit = 1,
    read_only_bit = 2,
    use_application_storage_bit = 4,
    _,
};

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
    _,
};

pub const Filter = enum(i32) {
    nearest = 0,
    linear = 1,
    _,
};

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
    _,
};

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
    wayland_surface_create_info_khr = 1000006000,
    win32_surface_create_info_khr = 1000009000,
    debug_utils_object_name_info_ext = 1000128000,
    debug_utils_object_tag_info_ext = 1000128001,
    debug_utils_label_ext = 1000128002,
    debug_utils_messenger_callback_data_ext = 1000128003,
    debug_utils_messenger_create_info_ext = 1000128004,
    _,
};
pub const StructureType_physical_device_variable_pointer_features: StructureType = .physical_device_variable_pointers_features;
pub const StructureType_physical_device_shader_draw_parameter_features: StructureType = .physical_device_shader_draw_parameters_features;

pub const SubpassContents = enum(i32) {
    @"inline" = 0,
    secondary_command_buffers = 1,
    _,
};

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
    _,
};

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
    _,
};

pub const DescriptorUpdateTemplateType = enum(i32) {
    descriptor_set = 0,
    push_descriptors = 1,
    _,
};

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
    debug_utils_messenger_ext = 1000128000,
    _,
};

pub const QueueFlagBits = enum(i32) {
    graphics_bit = 1,
    compute_bit = 2,
    transfer_bit = 4,
    sparse_binding_bit = 8,
    protected_bit = 16,
    _,
};

pub const CullModeFlagBits = enum(i32) {
    none = 0,
    front_bit = 1,
    back_bit = 2,
    front_and_back = 0x00000003,
    _,
};

pub const RenderPassCreateFlagBits = enum(i32) {
    _,
};

pub const DeviceQueueCreateFlagBits = enum(i32) {
    protected_bit = 1,
    _,
};

pub const MemoryPropertyFlagBits = enum(i32) {
    device_local_bit = 1,
    host_visible_bit = 2,
    host_coherent_bit = 4,
    host_cached_bit = 8,
    lazily_allocated_bit = 16,
    protected_bit = 32,
    _,
};

pub const MemoryHeapFlagBits = enum(i32) {
    device_local_bit = 1,
    multi_instance_bit = 2,
    seu_safe_bit = 4,
    _,
};

pub const AccessFlagBits = enum(i32) {
    indirect_command_read_bit = 1,
    index_read_bit = 2,
    vertex_attribute_read_bit = 4,
    uniform_read_bit = 8,
    input_attachment_read_bit = 16,
    shader_read_bit = 32,
    shader_write_bit = 64,
    color_attachment_read_bit = 128,
    color_attachment_write_bit = 256,
    depth_stencil_attachment_read_bit = 512,
    depth_stencil_attachment_write_bit = 1024,
    transfer_read_bit = 2048,
    transfer_write_bit = 4096,
    host_read_bit = 8192,
    host_write_bit = 16384,
    memory_read_bit = 32768,
    memory_write_bit = 65536,
    none = 0,
    _,
};

pub const BufferUsageFlagBits = enum(i32) {
    transfer_src_bit = 1,
    transfer_dst_bit = 2,
    uniform_texel_buffer_bit = 4,
    storage_texel_buffer_bit = 8,
    uniform_buffer_bit = 16,
    storage_buffer_bit = 32,
    index_buffer_bit = 64,
    vertex_buffer_bit = 128,
    indirect_buffer_bit = 256,
    shader_device_address_bit = 131072,
    _,
};

pub const BufferCreateFlagBits = enum(i32) {
    sparse_binding_bit = 1,
    sparse_residency_bit = 2,
    sparse_aliased_bit = 4,
    protected_bit = 8,
    device_address_capture_replay_bit = 16,
    _,
};

pub const ShaderStageFlagBits = enum(i32) {
    vertex_bit = 1,
    tessellation_control_bit = 2,
    tessellation_evaluation_bit = 4,
    geometry_bit = 8,
    fragment_bit = 16,
    compute_bit = 32,
    all_graphics = 0x0000001F,
    all = 0x7FFFFFFF,
    _,
};

pub const ImageUsageFlagBits = enum(i32) {
    transfer_src_bit = 1,
    transfer_dst_bit = 2,
    sampled_bit = 4,
    storage_bit = 8,
    color_attachment_bit = 16,
    depth_stencil_attachment_bit = 32,
    transient_attachment_bit = 64,
    input_attachment_bit = 128,
    host_transfer_bit = 4194304,
    _,
};

pub const ImageCreateFlagBits = enum(i32) {
    sparse_binding_bit = 1,
    sparse_residency_bit = 2,
    sparse_aliased_bit = 4,
    mutable_format_bit = 8,
    cube_compatible_bit = 16,
    alias_bit = 1024,
    split_instance_bind_regions_bit = 64,
    _2d_array_compatible_bit = 32,
    block_texel_view_compatible_bit = 128,
    extended_usage_bit = 256,
    protected_bit = 2048,
    disjoint_bit = 512,
    _,
};

pub const ImageViewCreateFlagBits = enum(i32) {
    _,
};

pub const SamplerCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineCreateFlagBits = enum(i32) {
    disable_optimization_bit = 1,
    allow_derivatives_bit = 2,
    derivative_bit = 4,
    dispatch_base_bit = 16,
    view_index_from_device_index_bit = 8,
    fail_on_pipeline_compile_required_bit = 256,
    early_return_on_failure_bit = 512,
    no_protected_access_bit = 134217728,
    protected_access_only_bit = 1073741824,
    _,
};
pub const PipelineCreateFlagBits_dispatch_base: PipelineCreateFlagBits = .dispatch_base_bit;

pub const PipelineShaderStageCreateFlagBits = enum(i32) {
    allow_varying_subgroup_size_bit = 1,
    require_full_subgroups_bit = 2,
    _,
};

pub const ColorComponentFlagBits = enum(i32) {
    r_bit = 1,
    g_bit = 2,
    b_bit = 4,
    a_bit = 8,
    _,
};

pub const FenceCreateFlagBits = enum(i32) {
    signaled_bit = 1,
    _,
};

pub const FormatFeatureFlagBits = enum(i32) {
    sampled_image_bit = 1,
    storage_image_bit = 2,
    storage_image_atomic_bit = 4,
    uniform_texel_buffer_bit = 8,
    storage_texel_buffer_bit = 16,
    storage_texel_buffer_atomic_bit = 32,
    vertex_buffer_bit = 64,
    color_attachment_bit = 128,
    color_attachment_blend_bit = 256,
    depth_stencil_attachment_bit = 512,
    blit_src_bit = 1024,
    blit_dst_bit = 2048,
    sampled_image_filter_linear_bit = 4096,
    transfer_src_bit = 16384,
    transfer_dst_bit = 32768,
    midpoint_chroma_samples_bit = 131072,
    sampled_image_ycbcr_conversion_linear_filter_bit = 262144,
    sampled_image_ycbcr_conversion_separate_reconstruction_filter_bit = 524288,
    sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_bit = 1048576,
    sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable_bit = 2097152,
    disjoint_bit = 4194304,
    cosited_chroma_samples_bit = 8388608,
    sampled_image_filter_minmax_bit = 65536,
    _,
};

pub const QueryControlFlagBits = enum(i32) {
    precise_bit = 1,
    _,
};

pub const QueryResultFlagBits = enum(i32) {
    _64_bit = 1,
    wait_bit = 2,
    with_availability_bit = 4,
    partial_bit = 8,
    _,
};

pub const CommandBufferUsageFlagBits = enum(i32) {
    one_time_submit_bit = 1,
    render_pass_continue_bit = 2,
    simultaneous_use_bit = 4,
    _,
};

pub const QueryPipelineStatisticFlagBits = enum(i32) {
    input_assembly_vertices_bit = 1,
    input_assembly_primitives_bit = 2,
    vertex_shader_invocations_bit = 4,
    geometry_shader_invocations_bit = 8,
    geometry_shader_primitives_bit = 16,
    clipping_invocations_bit = 32,
    clipping_primitives_bit = 64,
    fragment_shader_invocations_bit = 128,
    tessellation_control_shader_patches_bit = 256,
    tessellation_evaluation_shader_invocations_bit = 512,
    compute_shader_invocations_bit = 1024,
    _,
};

pub const MemoryMapFlagBits = enum(i32) {
    _,
};

pub const ImageAspectFlagBits = enum(i32) {
    color_bit = 1,
    depth_bit = 2,
    stencil_bit = 4,
    metadata_bit = 8,
    plane_0_bit = 16,
    plane_1_bit = 32,
    plane_2_bit = 64,
    none = 0,
    _,
};

pub const SparseImageFormatFlagBits = enum(i32) {
    single_miptail_bit = 1,
    aligned_mip_size_bit = 2,
    nonstandard_block_size_bit = 4,
    _,
};

pub const SparseMemoryBindFlagBits = enum(i32) {
    metadata_bit = 1,
    _,
};

pub const PipelineStageFlagBits = enum(i32) {
    top_of_pipe_bit = 1,
    draw_indirect_bit = 2,
    vertex_input_bit = 4,
    vertex_shader_bit = 8,
    tessellation_control_shader_bit = 16,
    tessellation_evaluation_shader_bit = 32,
    geometry_shader_bit = 64,
    fragment_shader_bit = 128,
    early_fragment_tests_bit = 256,
    late_fragment_tests_bit = 512,
    color_attachment_output_bit = 1024,
    compute_shader_bit = 2048,
    transfer_bit = 4096,
    bottom_of_pipe_bit = 8192,
    host_bit = 16384,
    all_graphics_bit = 32768,
    all_commands_bit = 65536,
    none = 0,
    _,
};

pub const CommandPoolCreateFlagBits = enum(i32) {
    transient_bit = 1,
    reset_command_buffer_bit = 2,
    protected_bit = 4,
    _,
};

pub const CommandPoolResetFlagBits = enum(i32) {
    release_resources_bit = 1,
    _,
};

pub const CommandBufferResetFlagBits = enum(i32) {
    release_resources_bit = 1,
    _,
};

pub const SampleCountFlagBits = enum(i32) {
    _1_bit = 1,
    _2_bit = 2,
    _4_bit = 4,
    _8_bit = 8,
    _16_bit = 16,
    _32_bit = 32,
    _64_bit = 64,
    _,
};

pub const AttachmentDescriptionFlagBits = enum(i32) {
    may_alias_bit = 1,
    _,
};

pub const StencilFaceFlagBits = enum(i32) {
    front_bit = 1,
    back_bit = 2,
    front_and_back = 0x00000003,
    _,
};
pub const StencilFaceFlagBits_stencil_front_and_back: StencilFaceFlagBits = .front_and_back;

pub const DescriptorPoolCreateFlagBits = enum(i32) {
    free_descriptor_set_bit = 1,
    update_after_bind_bit = 2,
    _,
};

pub const DependencyFlagBits = enum(i32) {
    by_region_bit = 1,
    device_group_bit = 4,
    view_local_bit = 2,
    _,
};

pub const SemaphoreType = enum(i32) {
    binary = 0,
    timeline = 1,
    _,
};

pub const SemaphoreWaitFlagBits = enum(i32) {
    any_bit = 1,
    _,
};

pub const PresentModeKHR = enum(i32) {
    immediate = 0,
    mailbox = 1,
    fifo = 2,
    fifo_relaxed = 3,
    _,
};

pub const ColorSpaceKHR = enum(i32) {
    srgb_nonlinear = 0,
    _,
};
pub const ColorSpaceKHR_colorspace_srgb_nonlinear: ColorSpaceKHR = .srgb_nonlinear;

pub const CompositeAlphaFlagBitsKHR = enum(i32) {
    opaque_bit = 1,
    pre_multiplied_bit = 2,
    post_multiplied_bit = 4,
    inherit_bit = 8,
    _,
};

pub const SurfaceTransformFlagBitsKHR = enum(i32) {
    identity_bit = 1,
    rotate_90_bit = 2,
    rotate_180_bit = 4,
    rotate_270_bit = 8,
    horizontal_mirror_bit = 16,
    horizontal_mirror_rotate_90_bit = 32,
    horizontal_mirror_rotate_180_bit = 64,
    horizontal_mirror_rotate_270_bit = 128,
    inherit_bit = 256,
    _,
};

pub const SubgroupFeatureFlagBits = enum(i32) {
    basic_bit = 1,
    vote_bit = 2,
    arithmetic_bit = 4,
    ballot_bit = 8,
    shuffle_bit = 16,
    shuffle_relative_bit = 32,
    clustered_bit = 64,
    quad_bit = 128,
    rotate_bit = 512,
    rotate_clustered_bit = 1024,
    _,
};

pub const DescriptorSetLayoutCreateFlagBits = enum(i32) {
    update_after_bind_pool_bit = 2,
    push_descriptor_bit = 1,
    _,
};

pub const ExternalMemoryHandleTypeFlagBits = enum(i32) {
    opaque_fd_bit = 1,
    opaque_win32_bit = 2,
    opaque_win32_kmt_bit = 4,
    d3d11_texture_bit = 8,
    d3d11_texture_kmt_bit = 16,
    d3d12_heap_bit = 32,
    d3d12_resource_bit = 64,
    _,
};

pub const ExternalMemoryFeatureFlagBits = enum(i32) {
    dedicated_only_bit = 1,
    exportable_bit = 2,
    importable_bit = 4,
    _,
};

pub const ExternalSemaphoreHandleTypeFlagBits = enum(i32) {
    opaque_fd_bit = 1,
    opaque_win32_bit = 2,
    opaque_win32_kmt_bit = 4,
    d3d12_fence_bit = 8,
    sync_fd_bit = 16,
    _,
};
pub const ExternalSemaphoreHandleTypeFlagBits_d3d11_fence_bit: ExternalSemaphoreHandleTypeFlagBits = .d3d12_fence_bit;

pub const ExternalSemaphoreFeatureFlagBits = enum(i32) {
    exportable_bit = 1,
    importable_bit = 2,
    _,
};

pub const SemaphoreImportFlagBits = enum(i32) {
    temporary_bit = 1,
    _,
};

pub const ExternalFenceHandleTypeFlagBits = enum(i32) {
    opaque_fd_bit = 1,
    opaque_win32_bit = 2,
    opaque_win32_kmt_bit = 4,
    sync_fd_bit = 8,
    _,
};

pub const ExternalFenceFeatureFlagBits = enum(i32) {
    exportable_bit = 1,
    importable_bit = 2,
    _,
};

pub const FenceImportFlagBits = enum(i32) {
    temporary_bit = 1,
    _,
};

pub const PeerMemoryFeatureFlagBits = enum(i32) {
    copy_src_bit = 1,
    copy_dst_bit = 2,
    generic_src_bit = 4,
    generic_dst_bit = 8,
    _,
};

pub const MemoryAllocateFlagBits = enum(i32) {
    device_mask_bit = 1,
    device_address_bit = 2,
    device_address_capture_replay_bit = 4,
    _,
};

pub const DeviceGroupPresentModeFlagBitsKHR = enum(i32) {
    local_bit = 1,
    remote_bit = 2,
    sum_bit = 4,
    local_multi_device_bit = 8,
    _,
};

pub const SwapchainCreateFlagBitsKHR = enum(i32) {
    split_instance_bind_regions_bit = 1,
    protected_bit = 2,
    _,
};

pub const SubpassDescriptionFlagBits = enum(i32) {
    _,
};

pub const PointClippingBehavior = enum(i32) {
    all_clip_planes = 0,
    user_clip_planes_only = 1,
    _,
};

pub const SamplerReductionMode = enum(i32) {
    weighted_average = 0,
    min = 1,
    max = 2,
    _,
};

pub const TessellationDomainOrigin = enum(i32) {
    upper_left = 0,
    lower_left = 1,
    _,
};

pub const SamplerYcbcrModelConversion = enum(i32) {
    rgb_identity = 0,
    ycbcr_identity = 1,
    ycbcr_709 = 2,
    ycbcr_601 = 3,
    ycbcr_2020 = 4,
    _,
};

pub const SamplerYcbcrRange = enum(i32) {
    itu_full = 0,
    itu_narrow = 1,
    _,
};

pub const ChromaLocation = enum(i32) {
    cosited_even = 0,
    midpoint = 1,
    _,
};

pub const DebugUtilsMessageSeverityFlagBitsEXT = enum(i32) {
    verbose_bit = 1,
    info_bit = 16,
    warning_bit = 256,
    error_bit = 4096,
    _,
};

pub const DebugUtilsMessageTypeFlagBitsEXT = enum(i32) {
    general_bit = 1,
    validation_bit = 2,
    performance_bit = 4,
    _,
};

pub const DescriptorBindingFlagBits = enum(i32) {
    update_after_bind_bit = 1,
    update_unused_while_pending_bit = 2,
    partially_bound_bit = 4,
    variable_descriptor_count_bit = 8,
    _,
};

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

pub const ResolveModeFlagBits = enum(i32) {
    none = 0,
    sample_zero_bit = 1,
    average_bit = 2,
    min_bit = 4,
    max_bit = 8,
    _,
};

pub const FramebufferCreateFlagBits = enum(i32) {
    imageless_bit = 1,
    _,
};

pub const QueryPoolCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineCreationFeedbackFlagBits = enum(i32) {
    valid_bit = 1,
    application_pipeline_cache_hit_bit = 2,
    base_pipeline_acceleration_bit = 4,
    _,
};

pub const ShaderFloatControlsIndependence = enum(i32) {
    _32_bit_only = 0,
    all = 1,
    none = 2,
    _,
};

pub const ToolPurposeFlagBits = enum(i32) {
    validation_bit = 1,
    profiling_bit = 2,
    tracing_bit = 4,
    additional_features_bit = 8,
    modifying_features_bit = 16,
    _,
};

pub const AccessFlagBits2 = enum(u64) {
    _2_none = 0,
    _2_indirect_command_read_bit = 1,
    _2_index_read_bit = 2,
    _2_vertex_attribute_read_bit = 4,
    _2_uniform_read_bit = 8,
    _2_input_attachment_read_bit = 16,
    _2_shader_read_bit = 32,
    _2_shader_write_bit = 64,
    _2_color_attachment_read_bit = 128,
    _2_color_attachment_write_bit = 256,
    _2_depth_stencil_attachment_read_bit = 512,
    _2_depth_stencil_attachment_write_bit = 1024,
    _2_transfer_read_bit = 2048,
    _2_transfer_write_bit = 4096,
    _2_host_read_bit = 8192,
    _2_host_write_bit = 16384,
    _2_memory_read_bit = 32768,
    _2_memory_write_bit = 65536,
    _2_shader_sampled_read_bit = 4294967296,
    _2_shader_storage_read_bit = 8589934592,
    _2_shader_storage_write_bit = 17179869184,
    _,
};

pub const PipelineStageFlagBits2 = enum(u64) {
    _2_none = 0,
    _2_top_of_pipe_bit = 1,
    _2_draw_indirect_bit = 2,
    _2_vertex_input_bit = 4,
    _2_vertex_shader_bit = 8,
    _2_tessellation_control_shader_bit = 16,
    _2_tessellation_evaluation_shader_bit = 32,
    _2_geometry_shader_bit = 64,
    _2_fragment_shader_bit = 128,
    _2_early_fragment_tests_bit = 256,
    _2_late_fragment_tests_bit = 512,
    _2_color_attachment_output_bit = 1024,
    _2_compute_shader_bit = 2048,
    _2_all_transfer_bit = 4096,
    _2_bottom_of_pipe_bit = 8192,
    _2_host_bit = 16384,
    _2_all_graphics_bit = 32768,
    _2_all_commands_bit = 65536,
    _2_copy_bit = 4294967296,
    _2_resolve_bit = 8589934592,
    _2_blit_bit = 17179869184,
    _2_clear_bit = 34359738368,
    _2_index_input_bit = 68719476736,
    _2_vertex_attribute_input_bit = 137438953472,
    _2_pre_rasterization_shaders_bit = 274877906944,
    _,
};
pub const PipelineStageFlagBits2__2_transfer_bit: PipelineStageFlagBits2 = ._2_all_transfer_bit;

pub const SubmitFlagBits = enum(i32) {
    protected_bit = 1,
    _,
};

pub const EventCreateFlagBits = enum(i32) {
    device_only_bit = 1,
    _,
};

pub const PipelineLayoutCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineColorBlendStateCreateFlagBits = enum(i32) {
    _,
};

pub const PipelineDepthStencilStateCreateFlagBits = enum(i32) {
    _,
};

pub const FormatFeatureFlagBits2 = enum(u64) {
    _2_sampled_image_bit = 1,
    _2_storage_image_bit = 2,
    _2_storage_image_atomic_bit = 4,
    _2_uniform_texel_buffer_bit = 8,
    _2_storage_texel_buffer_bit = 16,
    _2_storage_texel_buffer_atomic_bit = 32,
    _2_vertex_buffer_bit = 64,
    _2_color_attachment_bit = 128,
    _2_color_attachment_blend_bit = 256,
    _2_depth_stencil_attachment_bit = 512,
    _2_blit_src_bit = 1024,
    _2_blit_dst_bit = 2048,
    _2_sampled_image_filter_linear_bit = 4096,
    _2_transfer_src_bit = 16384,
    _2_transfer_dst_bit = 32768,
    _2_sampled_image_filter_minmax_bit = 65536,
    _2_midpoint_chroma_samples_bit = 131072,
    _2_sampled_image_ycbcr_conversion_linear_filter_bit = 262144,
    _2_sampled_image_ycbcr_conversion_separate_reconstruction_filter_bit = 524288,
    _2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_bit = 1048576,
    _2_sampled_image_ycbcr_conversion_chroma_reconstruction_explicit_forceable_bit = 2097152,
    _2_disjoint_bit = 4194304,
    _2_cosited_chroma_samples_bit = 8388608,
    _2_storage_read_without_format_bit = 2147483648,
    _2_storage_write_without_format_bit = 4294967296,
    _2_sampled_image_depth_comparison_bit = 8589934592,
    _2_sampled_image_filter_cubic_bit = 8192,
    _2_host_image_transfer_bit = 70368744177664,
    _,
};

pub const RenderingFlagBits = enum(i32) {
    contents_secondary_command_buffers_bit = 1,
    suspending_bit = 2,
    resuming_bit = 4,
    _,
};

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
    _reserved_0: bool = false,
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

pub const SamplerCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineLayoutCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineCacheCreateFlags = packed struct(u32) {
    externally_synchronized: bool = false,
    read_only: bool = false,
    use_application_storage: bool = false,
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

pub const PipelineDepthStencilStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineDynamicStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineColorBlendStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineMultisampleStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineRasterizationStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineViewportStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineTessellationStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineInputAssemblyStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineVertexInputStateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const BufferViewCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const InstanceCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const DeviceCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const DeviceQueueCreateFlags = packed struct(u32) {
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

pub const QueueFlags = packed struct(u32) {
    graphics: bool = false,
    compute: bool = false,
    transfer: bool = false,
    sparse_binding: bool = false,
    protected: bool = false,
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

pub const MemoryPropertyFlags = packed struct(u32) {
    device_local: bool = false,
    host_visible: bool = false,
    host_coherent: bool = false,
    host_cached: bool = false,
    lazily_allocated: bool = false,
    protected: bool = false,
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

pub const MemoryHeapFlags = packed struct(u32) {
    device_local: bool = false,
    multi_instance: bool = false,
    seu_safe: bool = false,
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
    _reserved_9: bool = false,
    _reserved_10: bool = false,
    _reserved_11: bool = false,
    _reserved_12: bool = false,
    _reserved_13: bool = false,
    _reserved_14: bool = false,
    _reserved_15: bool = false,
    _reserved_16: bool = false,
    shader_device_address: bool = false,
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

pub const BufferCreateFlags = packed struct(u32) {
    sparse_binding: bool = false,
    sparse_residency: bool = false,
    sparse_aliased: bool = false,
    protected: bool = false,
    device_address_capture_replay: bool = false,
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

pub const ShaderStageFlags = packed struct(u32) {
    vertex: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    geometry: bool = false,
    fragment: bool = false,
    compute: bool = false,
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

pub const ImageUsageFlags = packed struct(u32) {
    transfer_src: bool = false,
    transfer_dst: bool = false,
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transient_attachment: bool = false,
    input_attachment: bool = false,
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
    host_transfer: bool = false,
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

pub const ImageViewCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const PipelineCreateFlags = packed struct(u32) {
    disable_optimization: bool = false,
    allow_derivatives: bool = false,
    derivative: bool = false,
    view_index_from_device_index: bool = false,
    dispatch_base: bool = false,
    _reserved_5: bool = false,
    _reserved_6: bool = false,
    _reserved_7: bool = false,
    fail_on_pipeline_compile_required: bool = false,
    early_return_on_failure: bool = false,
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
    no_protected_access: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
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

pub const SemaphoreCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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
    _reserved_13: bool = false,
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

pub const ShaderModuleCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const MemoryMapFlags = packed struct(u32) {
    _reserved_0: bool = false,
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
    _reserved_0: bool = false,
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

pub const DescriptorPoolResetFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const DependencyFlags = packed struct(u32) {
    by_region: bool = false,
    view_local: bool = false,
    device_group: bool = false,
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

pub const SubgroupFeatureFlags = packed struct(u32) {
    basic: bool = false,
    vote: bool = false,
    arithmetic: bool = false,
    ballot: bool = false,
    shuffle: bool = false,
    shuffle_relative: bool = false,
    clustered: bool = false,
    quad: bool = false,
    _reserved_8: bool = false,
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

pub const PrivateDataSlotCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const DescriptorUpdateTemplateCreateFlags = packed struct(u32) {
    _reserved_0: bool = false,
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
    _2_shader_sampled_read: bool = false,
    _2_shader_storage_read: bool = false,
    _2_shader_storage_write: bool = false,
    _reserved_35: bool = false,
    _reserved_36: bool = false,
    _reserved_37: bool = false,
    _reserved_38: bool = false,
    _reserved_39: bool = false,
    _reserved_40: bool = false,
    _reserved_41: bool = false,
    _reserved_42: bool = false,
    _reserved_43: bool = false,
    _reserved_44: bool = false,
    _reserved_45: bool = false,
    _reserved_46: bool = false,
    _reserved_47: bool = false,
    _reserved_48: bool = false,
    _reserved_49: bool = false,
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
    _2_copy: bool = false,
    _2_resolve: bool = false,
    _2_blit: bool = false,
    _2_clear: bool = false,
    _2_index_input: bool = false,
    _2_vertex_attribute_input: bool = false,
    _2_pre_rasterization_shaders: bool = false,
    _reserved_39: bool = false,
    _reserved_40: bool = false,
    _reserved_41: bool = false,
    _reserved_42: bool = false,
    _reserved_43: bool = false,
    _reserved_44: bool = false,
    _reserved_45: bool = false,
    _reserved_46: bool = false,
    _reserved_47: bool = false,
    _reserved_48: bool = false,
    _reserved_49: bool = false,
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
    _reserved_24: bool = false,
    _reserved_25: bool = false,
    _reserved_26: bool = false,
    _reserved_27: bool = false,
    _reserved_28: bool = false,
    _reserved_29: bool = false,
    _reserved_30: bool = false,
    _2_storage_read_without_format: bool = false,
    _2_storage_write_without_format: bool = false,
    _2_sampled_image_depth_comparison: bool = false,
    _reserved_34: bool = false,
    _reserved_35: bool = false,
    _reserved_36: bool = false,
    _reserved_37: bool = false,
    _reserved_38: bool = false,
    _reserved_39: bool = false,
    _reserved_40: bool = false,
    _reserved_41: bool = false,
    _reserved_42: bool = false,
    _reserved_43: bool = false,
    _reserved_44: bool = false,
    _reserved_45: bool = false,
    _2_host_image_transfer: bool = false,
    _reserved_47: bool = false,
    _reserved_48: bool = false,
    _reserved_49: bool = false,
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

pub const RenderingFlags = packed struct(u32) {
    contents_secondary_command_buffers: bool = false,
    suspending: bool = false,
    resuming: bool = false,
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

pub const WaylandSurfaceCreateFlagsKHR = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const Win32SurfaceCreateFlagsKHR = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const CommandPoolTrimFlags = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const ExternalMemoryHandleTypeFlags = packed struct(u32) {
    opaque_fd: bool = false,
    opaque_win32: bool = false,
    opaque_win32_kmt: bool = false,
    d3d11_texture: bool = false,
    d3d11_texture_kmt: bool = false,
    d3d12_heap: bool = false,
    d3d12_resource: bool = false,
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

pub const DebugUtilsMessengerCreateFlagsEXT = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const DebugUtilsMessengerCallbackDataFlagsEXT = packed struct(u32) {
    _reserved_0: bool = false,
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

pub const ToolPurposeFlags = packed struct(u32) {
    validation: bool = false,
    profiling: bool = false,
    tracing: bool = false,
    additional_features: bool = false,
    modifying_features: bool = false,
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
        .error_validation_failed => error.ValidationFailed,
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
pub const PFN_vkMapMemory = *const fn (*Device, DeviceMemory, DeviceSize, DeviceSize, MemoryMapFlags, ?*?*anyopaque) callconv(.c) Result;
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
    vkGetInstanceProcAddr: PFN_vkGetInstanceProcAddr = undefined,
    vkEnumerateInstanceVersion: PFN_vkEnumerateInstanceVersion = undefined,
    vkEnumerateInstanceLayerProperties: PFN_vkEnumerateInstanceLayerProperties = undefined,
    vkEnumerateInstanceExtensionProperties: PFN_vkEnumerateInstanceExtensionProperties = undefined,
};

pub const InstanceDispatch = struct {
    vkDestroyInstance: PFN_vkDestroyInstance = undefined,
    vkEnumeratePhysicalDevices: PFN_vkEnumeratePhysicalDevices = undefined,
    vkGetDeviceProcAddr: PFN_vkGetDeviceProcAddr = undefined,
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

var lib_handle: ?*anyopaque = null;

// `std.DynLib` is `@compileError("unsupported platform")` on Windows in
// Zig 0.16's stdlib, so we hand-roll a tiny dlopen/LoadLibrary
// abstraction here. Linux + macOS use POSIX `dlopen`/`dlsym`; Windows
// uses `LoadLibraryA`/`GetProcAddress`. Both keep the loader as a
// `?*anyopaque` so the surrounding code stays OS-agnostic.
const _dl = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {
    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
};

fn _dlOpen(path_z: [*:0]const u8) ?*anyopaque {
    return if (comptime builtin.os.tag == .windows)
        _dl.LoadLibraryA(path_z)
    else
        _dl.dlopen(path_z, 2); // RTLD_NOW
}

fn _dlLookup(handle: *anyopaque, name_z: [*:0]const u8) ?*anyopaque {
    return if (comptime builtin.os.tag == .windows)
        _dl.GetProcAddress(handle, name_z)
    else
        _dl.dlsym(handle, name_z);
}

pub fn loadLoader() Error!void {
    const candidates: []const [:0]const u8 = switch (builtin.os.tag) {
        .linux => &.{ "libvulkan.so.1", "libvulkan.so" },
        .windows => &.{"vulkan-1.dll"},
        .macos, .ios => &.{ "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib" },
        else => return error.LoaderNotFound,
    };
    for (candidates) |path| {
        if (_dlOpen(path.ptr)) |h| {
            lib_handle = h;
            break;
        }
    }
    if (lib_handle == null) return error.LoaderNotFound;

    // Resolve every BaseDispatch symbol directly — vkGetInstanceProcAddr
    // would work for instance-level lookups but the C ABI requires an
    // instance handle (vk.xml does not mark it optional), so we sidestep
    // by calling the OS loader for everything here.
    inline for (@typeInfo(BaseDispatch).@"struct".fields) |f| {
        const sym = _dlLookup(lib_handle.?, f.name.ptr) orelse return error.SymbolNotFound;
        @field(base, f.name) = @ptrCast(@alignCast(sym));
    }
}

// InstanceDispatch / DeviceDispatch mix universal entry points with
// platform- and extension-conditional ones (e.g. `vkCreateWin32SurfaceKHR`
// is NULL on Linux, `vkCreateDebugUtilsMessengerEXT` is NULL whenever
// `VK_EXT_debug_utils` is not enabled in the InstanceCreateInfo). A
// missing symbol is *not* an error — callers are responsible for only
// invoking entry points whose extension / platform precondition holds.
// Slots that the loader could not resolve stay at their default
// (`= undefined`); calling them is a programmer bug, same as calling
// `vkDestroyInstance` after `vkDestroyInstance`.
pub fn loadInstance(instance: *Instance) Error!void {
    inline for (@typeInfo(InstanceDispatch).@"struct".fields) |f| {
        if (base.vkGetInstanceProcAddr(instance, f.name.ptr)) |sym| {
            @field(instance_dispatch, f.name) = @ptrCast(@alignCast(sym));
        }
    }
}

pub fn loadDevice(device: *Device) Error!void {
    inline for (@typeInfo(DeviceDispatch).@"struct".fields) |f| {
        if (instance_dispatch.vkGetDeviceProcAddr(device, f.name.ptr)) |sym| {
            @field(device_dispatch, f.name) = @ptrCast(@alignCast(sym));
        }
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
        const _r = base.vkEnumerateInstanceLayerProperties(&_count, @ptrCast(_out.ptr));
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
        const _r = base.vkEnumerateInstanceExtensionProperties(layer_name, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkEnumeratePhysicalDevices(self, &_count, @ptrCast(_out.ptr));
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn getInstanceProcAddr(self: *Instance, name: [*:0]const u8) PFN_vkVoidFunction {
        return base.vkGetInstanceProcAddr(self, name);
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
            const _r = instance_dispatch.vkEnumeratePhysicalDeviceGroups(self, &_count, @ptrCast(_out.ptr));
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
            instance_dispatch.vkGetPhysicalDeviceQueueFamilyProperties(self, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkEnumerateDeviceLayerProperties(self, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkEnumerateDeviceExtensionProperties(self, layer_name, &_count, @ptrCast(_out.ptr));
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
            instance_dispatch.vkGetPhysicalDeviceSparseImageFormatProperties(self, format, @"type", samples, usage, tiling, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkGetPhysicalDeviceSurfaceFormatsKHR(self, surface, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkGetPhysicalDeviceSurfacePresentModesKHR(self, surface, &_count, @ptrCast(_out.ptr));
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
            instance_dispatch.vkGetPhysicalDeviceQueueFamilyProperties2(self, &_count, @ptrCast(_out.ptr));
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
            instance_dispatch.vkGetPhysicalDeviceSparseImageFormatProperties2(self, format_info, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkGetPhysicalDevicePresentRectanglesKHR(self, surface, &_count, @ptrCast(_out.ptr));
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
            const _r = instance_dispatch.vkGetPhysicalDeviceToolProperties(self, &_count, @ptrCast(_out.ptr));
            try checkResult(_r);
        }
        return _out[0.._count];
    }
};

pub const Device = opaque {
    pub fn getDeviceProcAddr(self: *Device, name: [*:0]const u8) PFN_vkVoidFunction {
        return instance_dispatch.vkGetDeviceProcAddr(self, name);
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

    pub fn mapMemory(self: *Device, memory: DeviceMemory, offset: DeviceSize, size: DeviceSize, flags: MemoryMapFlags) Error!?*anyopaque {
        var _out: ?*anyopaque = undefined;
        const _r = device_dispatch.vkMapMemory(self, memory, offset, size, flags, &_out);
        try checkResult(_r);
        return _out;
    }

    pub fn unmapMemory(self: *Device, memory: DeviceMemory) void {
        return device_dispatch.vkUnmapMemory(self, memory);
    }

    pub fn flushMappedMemoryRanges(self: *Device, memory_ranges: []const MappedMemoryRange) Error!void {
        const _r = device_dispatch.vkFlushMappedMemoryRanges(self, @intCast(memory_ranges.len), @ptrCast(memory_ranges.ptr));
        try checkResult(_r);
    }

    pub fn invalidateMappedMemoryRanges(self: *Device, memory_ranges: []const MappedMemoryRange) Error!void {
        const _r = device_dispatch.vkInvalidateMappedMemoryRanges(self, @intCast(memory_ranges.len), @ptrCast(memory_ranges.ptr));
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
            device_dispatch.vkGetImageSparseMemoryRequirements(self, image, &_count, @ptrCast(_out.ptr));
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
        const _r = device_dispatch.vkResetFences(self, @intCast(fences.len), @ptrCast(fences.ptr));
        try checkResult(_r);
    }

    pub fn getFenceStatus(self: *Device, fence: Fence) Error!void {
        const _r = device_dispatch.vkGetFenceStatus(self, fence);
        try checkResult(_r);
    }

    pub fn waitForFences(self: *Device, fences: []const Fence, wait_all: Bool32, timeout: u64) Error!void {
        const _r = device_dispatch.vkWaitForFences(self, @intCast(fences.len), @ptrCast(fences.ptr), wait_all, timeout);
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
        const _r = device_dispatch.vkGetQueryPoolResults(self, query_pool, first_query, query_count, @intCast(data.len), @ptrCast(data.ptr), stride, flags);
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
        const _r = device_dispatch.vkGetPipelineCacheData(self, pipeline_cache, data_size, @ptrCast(data.ptr));
        try checkResult(_r);
    }

    pub fn mergePipelineCaches(self: *Device, dst_cache: PipelineCache, src_caches: []const PipelineCache) Error!void {
        const _r = device_dispatch.vkMergePipelineCaches(self, dst_cache, @intCast(src_caches.len), @ptrCast(src_caches.ptr));
        try checkResult(_r);
    }

    pub fn createGraphicsPipelines(self: *Device, pipeline_cache: PipelineCache, create_infos: []const GraphicsPipelineCreateInfo, allocator: ?*const AllocationCallbacks, pipelines: []Pipeline) Error!void {
        const _r = device_dispatch.vkCreateGraphicsPipelines(self, pipeline_cache, @intCast(create_infos.len), @ptrCast(create_infos.ptr), allocator, @ptrCast(pipelines.ptr));
        try checkResult(_r);
    }

    pub fn createComputePipelines(self: *Device, pipeline_cache: PipelineCache, create_infos: []const ComputePipelineCreateInfo, allocator: ?*const AllocationCallbacks, pipelines: []Pipeline) Error!void {
        const _r = device_dispatch.vkCreateComputePipelines(self, pipeline_cache, @intCast(create_infos.len), @ptrCast(create_infos.ptr), allocator, @ptrCast(pipelines.ptr));
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
        const _r = device_dispatch.vkAllocateDescriptorSets(self, allocate_info, @ptrCast(descriptor_sets.ptr));
        try checkResult(_r);
    }

    pub fn freeDescriptorSets(self: *Device, descriptor_pool: DescriptorPool, descriptor_sets: []const DescriptorSet) Error!void {
        const _r = device_dispatch.vkFreeDescriptorSets(self, descriptor_pool, @intCast(descriptor_sets.len), @ptrCast(descriptor_sets.ptr));
        try checkResult(_r);
    }

    pub fn updateDescriptorSets(self: *Device, descriptor_writes: []const WriteDescriptorSet, descriptor_copies: []const CopyDescriptorSet) void {
        return device_dispatch.vkUpdateDescriptorSets(self, @intCast(descriptor_writes.len), @ptrCast(descriptor_writes.ptr), @intCast(descriptor_copies.len), @ptrCast(descriptor_copies.ptr));
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
        const _r = device_dispatch.vkAllocateCommandBuffers(self, allocate_info, @ptrCast(command_buffers.ptr));
        try checkResult(_r);
    }

    pub fn freeCommandBuffers(self: *Device, command_pool: CommandPool, command_buffers: []const *CommandBuffer) void {
        return device_dispatch.vkFreeCommandBuffers(self, command_pool, @intCast(command_buffers.len), @ptrCast(command_buffers.ptr));
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
            const _r = device_dispatch.vkGetSwapchainImagesKHR(self, swapchain, &_count, @ptrCast(_out.ptr));
            try checkResult(_r);
        }
        return _out[0.._count];
    }

    pub fn acquireNextImageKHRRaw(self: *Device, swapchain: SwapchainKHR, timeout: u64, semaphore: Semaphore, fence: Fence, image_index: *u32) Result {
        return device_dispatch.vkAcquireNextImageKHR(self, swapchain, timeout, semaphore, fence, image_index);
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
        const _r = device_dispatch.vkBindBufferMemory2(self, @intCast(bind_infos.len), @ptrCast(bind_infos.ptr));
        try checkResult(_r);
    }

    pub fn bindImageMemory2(self: *Device, bind_infos: []const BindImageMemoryInfo) Error!void {
        const _r = device_dispatch.vkBindImageMemory2(self, @intCast(bind_infos.len), @ptrCast(bind_infos.ptr));
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

    pub fn acquireNextImage2KHRRaw(self: *Device, acquire_info: *const AcquireNextImageInfoKHR, image_index: *u32) Result {
        return device_dispatch.vkAcquireNextImage2KHR(self, acquire_info, image_index);
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
            device_dispatch.vkGetImageSparseMemoryRequirements2(self, info, &_count, @ptrCast(_out.ptr));
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
            device_dispatch.vkGetDeviceImageSparseMemoryRequirements(self, info, &_count, @ptrCast(_out.ptr));
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
        const _r = device_dispatch.vkQueueSubmit(self, @intCast(submits.len), @ptrCast(submits.ptr), fence);
        try checkResult(_r);
    }

    pub fn waitIdle(self: *Queue) Error!void {
        const _r = device_dispatch.vkQueueWaitIdle(self);
        try checkResult(_r);
    }

    pub fn bindSparse(self: *Queue, bind_info: []const BindSparseInfo, fence: Fence) Error!void {
        const _r = device_dispatch.vkQueueBindSparse(self, @intCast(bind_info.len), @ptrCast(bind_info.ptr), fence);
        try checkResult(_r);
    }

    pub fn presentKHRRaw(self: *Queue, present_info: *const PresentInfoKHR) Result {
        return device_dispatch.vkQueuePresentKHR(self, present_info);
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
        const _r = device_dispatch.vkQueueSubmit2(self, @intCast(submits.len), @ptrCast(submits.ptr), fence);
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
        return device_dispatch.vkCmdSetViewport(self, first_viewport, @intCast(viewports.len), @ptrCast(viewports.ptr));
    }

    pub fn cmdSetScissor(self: *CommandBuffer, first_scissor: u32, scissors: []const Rect2D) void {
        return device_dispatch.vkCmdSetScissor(self, first_scissor, @intCast(scissors.len), @ptrCast(scissors.ptr));
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
        return device_dispatch.vkCmdBindDescriptorSets(self, pipeline_bind_point, layout, first_set, @intCast(descriptor_sets.len), @ptrCast(descriptor_sets.ptr), @intCast(dynamic_offsets.len), @ptrCast(dynamic_offsets.ptr));
    }

    pub fn cmdBindIndexBuffer(self: *CommandBuffer, buffer: Buffer, offset: DeviceSize, index_type: IndexType) void {
        return device_dispatch.vkCmdBindIndexBuffer(self, buffer, offset, index_type);
    }

    pub fn cmdBindVertexBuffers(self: *CommandBuffer, first_binding: u32, buffers: []const Buffer, offsets: []const DeviceSize) void {
        return device_dispatch.vkCmdBindVertexBuffers(self, first_binding, @intCast(buffers.len), @ptrCast(buffers.ptr), @ptrCast(offsets.ptr));
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
        return device_dispatch.vkCmdCopyBuffer(self, src_buffer, dst_buffer, @intCast(regions.len), @ptrCast(regions.ptr));
    }

    pub fn cmdCopyImage(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_image: Image, dst_image_layout: ImageLayout, regions: []const ImageCopy) void {
        return device_dispatch.vkCmdCopyImage(self, src_image, src_image_layout, dst_image, dst_image_layout, @intCast(regions.len), @ptrCast(regions.ptr));
    }

    pub fn cmdBlitImage(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_image: Image, dst_image_layout: ImageLayout, regions: []const ImageBlit, filter: Filter) void {
        return device_dispatch.vkCmdBlitImage(self, src_image, src_image_layout, dst_image, dst_image_layout, @intCast(regions.len), @ptrCast(regions.ptr), filter);
    }

    pub fn cmdCopyBufferToImage(self: *CommandBuffer, src_buffer: Buffer, dst_image: Image, dst_image_layout: ImageLayout, regions: []const BufferImageCopy) void {
        return device_dispatch.vkCmdCopyBufferToImage(self, src_buffer, dst_image, dst_image_layout, @intCast(regions.len), @ptrCast(regions.ptr));
    }

    pub fn cmdCopyImageToBuffer(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_buffer: Buffer, regions: []const BufferImageCopy) void {
        return device_dispatch.vkCmdCopyImageToBuffer(self, src_image, src_image_layout, dst_buffer, @intCast(regions.len), @ptrCast(regions.ptr));
    }

    pub fn cmdUpdateBuffer(self: *CommandBuffer, dst_buffer: Buffer, dst_offset: DeviceSize, data_size: DeviceSize, data: []const void) void {
        return device_dispatch.vkCmdUpdateBuffer(self, dst_buffer, dst_offset, data_size, @ptrCast(data.ptr));
    }

    pub fn cmdFillBuffer(self: *CommandBuffer, dst_buffer: Buffer, dst_offset: DeviceSize, size: DeviceSize, data: u32) void {
        return device_dispatch.vkCmdFillBuffer(self, dst_buffer, dst_offset, size, data);
    }

    pub fn cmdClearColorImage(self: *CommandBuffer, image: Image, image_layout: ImageLayout, color: *const ClearColorValue, ranges: []const ImageSubresourceRange) void {
        return device_dispatch.vkCmdClearColorImage(self, image, image_layout, color, @intCast(ranges.len), @ptrCast(ranges.ptr));
    }

    pub fn cmdClearDepthStencilImage(self: *CommandBuffer, image: Image, image_layout: ImageLayout, depth_stencil: *const ClearDepthStencilValue, ranges: []const ImageSubresourceRange) void {
        return device_dispatch.vkCmdClearDepthStencilImage(self, image, image_layout, depth_stencil, @intCast(ranges.len), @ptrCast(ranges.ptr));
    }

    pub fn cmdClearAttachments(self: *CommandBuffer, attachments: []const ClearAttachment, rects: []const ClearRect) void {
        return device_dispatch.vkCmdClearAttachments(self, @intCast(attachments.len), @ptrCast(attachments.ptr), @intCast(rects.len), @ptrCast(rects.ptr));
    }

    pub fn cmdResolveImage(self: *CommandBuffer, src_image: Image, src_image_layout: ImageLayout, dst_image: Image, dst_image_layout: ImageLayout, regions: []const ImageResolve) void {
        return device_dispatch.vkCmdResolveImage(self, src_image, src_image_layout, dst_image, dst_image_layout, @intCast(regions.len), @ptrCast(regions.ptr));
    }

    pub fn cmdSetEvent(self: *CommandBuffer, event: Event, stage_mask: PipelineStageFlags) void {
        return device_dispatch.vkCmdSetEvent(self, event, stage_mask);
    }

    pub fn cmdResetEvent(self: *CommandBuffer, event: Event, stage_mask: PipelineStageFlags) void {
        return device_dispatch.vkCmdResetEvent(self, event, stage_mask);
    }

    pub fn cmdWaitEvents(self: *CommandBuffer, events: []const Event, src_stage_mask: PipelineStageFlags, dst_stage_mask: PipelineStageFlags, memory_barriers: []const MemoryBarrier, buffer_memory_barriers: []const BufferMemoryBarrier, image_memory_barriers: []const ImageMemoryBarrier) void {
        return device_dispatch.vkCmdWaitEvents(self, @intCast(events.len), @ptrCast(events.ptr), src_stage_mask, dst_stage_mask, @intCast(memory_barriers.len), @ptrCast(memory_barriers.ptr), @intCast(buffer_memory_barriers.len), @ptrCast(buffer_memory_barriers.ptr), @intCast(image_memory_barriers.len), @ptrCast(image_memory_barriers.ptr));
    }

    pub fn cmdPipelineBarrier(self: *CommandBuffer, src_stage_mask: PipelineStageFlags, dst_stage_mask: PipelineStageFlags, dependency_flags: DependencyFlags, memory_barriers: []const MemoryBarrier, buffer_memory_barriers: []const BufferMemoryBarrier, image_memory_barriers: []const ImageMemoryBarrier) void {
        return device_dispatch.vkCmdPipelineBarrier(self, src_stage_mask, dst_stage_mask, dependency_flags, @intCast(memory_barriers.len), @ptrCast(memory_barriers.ptr), @intCast(buffer_memory_barriers.len), @ptrCast(buffer_memory_barriers.ptr), @intCast(image_memory_barriers.len), @ptrCast(image_memory_barriers.ptr));
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
        return device_dispatch.vkCmdPushConstants(self, layout, stage_flags, offset, @intCast(values.len), @ptrCast(values.ptr));
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
        return device_dispatch.vkCmdExecuteCommands(self, @intCast(command_buffers.len), @ptrCast(command_buffers.ptr));
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
        return device_dispatch.vkCmdSetViewportWithCount(self, @intCast(viewports.len), @ptrCast(viewports.ptr));
    }

    pub fn cmdSetScissorWithCount(self: *CommandBuffer, scissors: []const Rect2D) void {
        return device_dispatch.vkCmdSetScissorWithCount(self, @intCast(scissors.len), @ptrCast(scissors.ptr));
    }

    pub fn cmdBindVertexBuffers2(self: *CommandBuffer, first_binding: u32, buffers: []const Buffer, offsets: []const DeviceSize, sizes: []const DeviceSize, strides: []const DeviceSize) void {
        return device_dispatch.vkCmdBindVertexBuffers2(self, first_binding, @intCast(buffers.len), @ptrCast(buffers.ptr), @ptrCast(offsets.ptr), @ptrCast(sizes.ptr), @ptrCast(strides.ptr));
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
        return device_dispatch.vkCmdWaitEvents2(self, @intCast(events.len), @ptrCast(events.ptr), @ptrCast(dependency_infos.ptr));
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
