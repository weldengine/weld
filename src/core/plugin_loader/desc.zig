//! FROZEN — see engine-phase-0-criteria.md C0.5. Every declaration below is.
//!
//! `extern` or C integer aliases throughout, so a plugin built in any language
//! matching that ABI links against them.

const std = @import("std");

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// THIS SEMVER TRIPLE IS THE LOADER'S PROTOCOL VERSION — no separate constant is
/// minted. MAJOR is a binary break, MINOR an additive change, PATCH a fix.
pub const WELD_API_VERSION_MAJOR: u32 = 0;
/// Minor version: a binary-compatible addition at the end of a table or struct.
pub const WELD_API_VERSION_MINOR: u32 = 1;
/// Patch version: a fix with no surface change.
pub const WELD_API_VERSION_PATCH: u32 = 0;

/// `index` in the low 32 bits, `generation` in the high 32.
pub const WeldEntity = u64;
/// Opaque asset handle, ABI-equivalent to `uint64_t`.
pub const WeldAssetHandle = u64;
/// Component type identifier, ABI-equivalent to `uint32_t`.
pub const WeldComponentId = u32;
/// Resource type identifier, ABI-equivalent to `uint32_t`.
pub const WeldResourceId = u32;
/// Event type identifier, ABI-equivalent to `uint32_t`.
pub const WeldEventId = u32;
/// ECS system identifier, ABI-equivalent to `uint32_t`.
pub const WeldSystemId = u32;
/// Tier 1 service identifier, ABI-equivalent to `uint32_t`.
pub const WeldServiceId = u32;
/// Compact hierarchical tag, ABI-equivalent to `uint64_t`.
pub const WeldTagId = u64;

/// Sentinel "no entity" (cf. `engine-c-api.md` §2.1).
pub const WELD_ENTITY_NULL: WeldEntity = 0;

/// 2-component float vector. ABI = `struct { float x, y; }`.
pub const WeldVec2 = extern struct { x: f32 = 0, y: f32 = 0 };
/// 3-component float vector.
pub const WeldVec3 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
/// 4-component float vector.
pub const WeldVec4 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 0 };
/// Quaternion (x, y, z, w).
pub const WeldQuat = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0, w: f32 = 1 };
/// 3×3 column-major matrix.
pub const WeldMat3 = extern struct { m: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
/// 4×4 column-major matrix.
pub const WeldMat4 = extern struct { m: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
/// RGBA float color (linear space).
pub const WeldColor = extern struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };

/// Non-owning UTF-8 view, NOT guaranteed NUL-terminated.
pub const WeldStr = extern struct {
    ptr: ?[*]const u8 = null,
    len: u32 = 0,

    /// THE CALLER owns the lifetime of the pointed-to buffer.
    pub fn fromSlice(s: []const u8) WeldStr {
        return .{ .ptr = s.ptr, .len = @intCast(s.len) };
    }

    /// Zig view over the `WeldStr`. Empty slice if `ptr == null`.
    pub fn slice(self: WeldStr) []const u8 {
        if (self.ptr) |p| return p[0..self.len];
        return &.{};
    }
};

/// `const void* ptr; uint32_t count; uint32_t stride;` — for batched returns.
pub const WeldSlice = extern struct {
    ptr: ?*const anyopaque = null,
    count: u32 = 0,
    stride: u32 = 0,
};

/// Received through `WeldAPI.world` and passed back to the ECS callbacks.
pub const WeldWorldHandle = ?*anyopaque;
/// Built by `WeldEcsAPI.query_create`.
pub const WeldQueryHandle = ?*anyopaque;
/// Opaque handle to a Weld allocator.
pub const WeldAllocatorHandle = ?*anyopaque;
/// `null` in runtime mode without an editor.
pub const WeldEditorCtxHandle = ?*anyopaque;

/// `0 == WELD_OK`; negative is reserved.
pub const WeldResult = enum(c_int) {
    WELD_OK = 0,
    /// A dead entity, a stale handle, an unregistered component.
    WELD_ERR_NOT_FOUND = 1,
    WELD_ERR_ALREADY_EXISTS = 2,
    WELD_ERR_INVALID_ENTITY = 3,
    WELD_ERR_INVALID_COMPONENT = 4,
    WELD_ERR_INVALID_RESOURCE = 5,
    /// Between the expected signature and the data provided.
    WELD_ERR_TYPE_MISMATCH = 6,
    WELD_ERR_OUT_OF_MEMORY = 7,
    WELD_ERR_PERMISSION_DENIED = 8,
    /// Declared but not loaded — the plugin degrades gracefully.
    WELD_ERR_SERVICE_UNAVAILABLE = 9,
    WELD_ERR_VERSION_MISMATCH = 10,
    /// What every callback of the seven sub-APIs returns today.
    WELD_ERR_NOT_IMPLEMENTED = 11,
};

/// Declared at load time and LOGGED, never enforced: nothing refuses a
/// `component_get` on a component absent from `reads_components`.
pub const WeldPluginCaps = extern struct {
    // ECS
    reads_components: ?[*]const WeldStr = null,
    reads_components_count: u32 = 0,
    writes_components: ?[*]const WeldStr = null,
    writes_components_count: u32 = 0,
    reads_resources: ?[*]const WeldStr = null,
    reads_resources_count: u32 = 0,
    writes_resources: ?[*]const WeldStr = null,
    writes_resources_count: u32 = 0,

    // Required / optional services
    required_services: ?[*]const WeldStr = null,
    required_services_count: u32 = 0,
    optional_services: ?[*]const WeldStr = null,
    optional_services_count: u32 = 0,

    // Platform — manual review if any of these flags is true.
    needs_filesystem: bool = false,
    needs_network: bool = false,
    needs_threading: bool = false,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
};

/// Lifecycle callbacks, all optional — `null` is ignored.
///
/// They take `*const anyopaque` and not `*const WeldAPI`, which would be a cyclic
/// `desc.zig ↔ api.zig` dependency; the plugin downcasts at entry, and at the C
/// level every pointer is `void*` anyway.
pub const WeldPluginCallbacks = extern struct {
    /// Once, at `loadPlugin`: the plugin registers its own declarations here.
    on_load: ?*const fn (api: *const anyopaque) callconv(.c) WeldResult = null,
    /// After ALL plugins are loaded, so other modules' services are reachable.
    on_init: ?*const fn (api: *const anyopaque) callconv(.c) WeldResult = null,
    /// Every frame, and only if declared — most plugins use ECS systems instead.
    on_update: ?*const fn (api: *const anyopaque, dt: f32) callconv(.c) void = null,
    /// At `unloadPlugin`: its own resources only, the engine owning the components.
    on_shutdown: ?*const fn (api: *const anyopaque) callconv(.c) void = null,
};

/// Returned by `weld_plugin_entry`: identity, capabilities, callbacks.
pub const WeldPluginDesc = extern struct {
    name: WeldStr = .{},
    display_name: WeldStr = .{},
    version: WeldStr = .{},
    /// Above Weld's own major version, the loader REFUSES with `ApiVersionTooNew`.
    api_version_min: u32 = 0,
    _pad: u32 = 0,
    caps: WeldPluginCaps = .{},
    callbacks: WeldPluginCallbacks = .{},
};

/// Resolved by `dlsym("weld_plugin_entry")` and called with an opaque pointer to
/// the runtime `WeldAPI`, which the plugin downcasts at entry.
pub const WeldPluginEntryFn = *const fn (api: *const anyopaque) callconv(.c) *const WeldPluginDesc;
