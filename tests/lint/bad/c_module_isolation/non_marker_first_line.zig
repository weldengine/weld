// regular line comment — first line lacks the generated-file marker

/// First-line marker is missing, so the @import("vk_c") below must
/// be flagged by c_module_isolation.
pub const vulkan = @import("vk_c");
