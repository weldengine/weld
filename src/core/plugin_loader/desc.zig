//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! M0.2 / E6 — fundamental C types for the Tier 3 plugin API and
//! the plugin descriptor.
//!
//! Layout consistent with `engine-c-api.md` §2 (fundamental types) + §3
//! (plugin lifecycle). The types are `extern` or aliases of C
//! integers — ABI-compatible with plugins compiled in C / C++ /
//! Rust / etc. via the `include/weld_api.h` header (generated in
//! Phase 3, brief § Out-of-scope).
//!
//! All declarations are **frozen final signatures** in the sense
//! of the C0.5 partial freeze (cf. brief § Scope). No runtime
//! wiring — `Loader` only loads the `.so` / `.dll`, reads the
//! descriptor, and logs the declared capabilities. Runtime
//! enforcement of capabilities (filesystem, network, threading)
//! is Phase 3 (cf. brief § Out-of-scope).

const std = @import("std");

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9). This semver
/// triple IS the PluginLoader's `*_PROTOCOL_VERSION` axis — the C0.5
/// versioning rule reuses it rather than minting a separate constant
/// (MAJOR = binary break, MINOR = additive, PATCH = fix).
/// Major version of the Weld plugin API. Incremented on every
/// binary break (function removal / rename, signature change,
/// struct layout change). Cf. `engine-c-api.md` §1.1.
pub const WELD_API_VERSION_MAJOR: u32 = 0;
/// Minor version. Incremented on every binary-compatible
/// addition (new function at the end of the table, new field
/// at the end of a struct).
pub const WELD_API_VERSION_MINOR: u32 = 1;
/// Patch version. Incremented for bug fixes without surface
/// change.
pub const WELD_API_VERSION_PATCH: u32 = 0;

// -- ABI-stable scalar types (cf. engine-c-api.md §2.1) ------------

/// Opaque entity handle, ABI-equivalent to `uint64_t`. Encodes
/// `index` (low 32 bits) + `generation` (high 32 bits).
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

// -- Math types (cf. engine-c-api.md §2.2) ----------------------------

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

// -- String view + slice (cf. engine-c-api.md §2.3 + §2.4) ------------

/// Non-owning UTF-8 view. ABI = `struct { const char* ptr;
/// uint32_t len; }`. Not guaranteed NUL-terminated.
pub const WeldStr = extern struct {
    ptr: ?[*]const u8 = null,
    len: u32 = 0,

    /// Builds a `WeldStr` from a Zig slice. The caller is
    /// responsible for the lifetime of the pointed-to buffer.
    pub fn fromSlice(s: []const u8) WeldStr {
        return .{ .ptr = s.ptr, .len = @intCast(s.len) };
    }

    /// Zig view over the `WeldStr`. Empty slice if `ptr == null`.
    pub fn slice(self: WeldStr) []const u8 {
        if (self.ptr) |p| return p[0..self.len];
        return &.{};
    }
};

/// View over an arbitrary array (`const void* ptr; uint32_t
/// count; uint32_t stride;`). Used for batched returns.
pub const WeldSlice = extern struct {
    ptr: ?*const anyopaque = null,
    count: u32 = 0,
    stride: u32 = 0,
};

// -- Opaque handles (cf. engine-c-api.md §2.5) ------------------------

/// Opaque handle to the ECS `World`. The plugin receives the
/// pointer via `WeldAPI.world` and passes it to ECS callbacks.
pub const WeldWorldHandle = ?*anyopaque;
/// Opaque handle to an ECS query built by
/// `WeldEcsAPI.query_create`.
pub const WeldQueryHandle = ?*anyopaque;
/// Opaque handle to a Weld allocator.
pub const WeldAllocatorHandle = ?*anyopaque;
/// Opaque handle to the editor context (`null` in runtime
/// mode without an editor).
pub const WeldEditorCtxHandle = ?*anyopaque;

// -- Error codes (cf. engine-c-api.md §2.6) --------------------------

/// Result of a plugin API operation. `0 == WELD_OK`,
/// negative reserved for future errors.
pub const WeldResult = enum(c_int) {
    /// Operation succeeded.
    WELD_OK = 0,
    /// Resource not found (dead entity, stale handle,
    /// unregistered component, etc.).
    WELD_ERR_NOT_FOUND = 1,
    /// Attempt to add a resource that is already present.
    WELD_ERR_ALREADY_EXISTS = 2,
    /// Invalid `WeldEntity` (generation mismatch).
    WELD_ERR_INVALID_ENTITY = 3,
    /// Unknown `WeldComponentId`.
    WELD_ERR_INVALID_COMPONENT = 4,
    /// Unknown `WeldResourceId`.
    WELD_ERR_INVALID_RESOURCE = 5,
    /// Type mismatch (between expected signature and provided
    /// data).
    WELD_ERR_TYPE_MISMATCH = 6,
    /// Allocation failed (allocator exhausted).
    WELD_ERR_OUT_OF_MEMORY = 7,
    /// Capability not declared in `WeldPluginCaps`.
    WELD_ERR_PERMISSION_DENIED = 8,
    /// Tier 1 service requested but not loaded (graceful
    /// degradation on the plugin side).
    WELD_ERR_SERVICE_UNAVAILABLE = 9,
    /// Incompatible API version.
    WELD_ERR_VERSION_MISMATCH = 10,
    /// Feature declared but not yet wired — M0.2 returns this
    /// code for 100% of the callbacks of the 7 sub-APIs
    /// (cf. brief § Out-of-scope, Phase 3 wiring).
    WELD_ERR_NOT_IMPLEMENTED = 11,
};

// -- Plugin capabilities (cf. engine-c-api.md §3.2) -------------------

/// Capabilities declared by the plugin at load time. M0.2 READS
/// these declarations and logs them; NO runtime check is
/// performed — enforcement (refusing `component_get` on a
/// component not declared in `reads_components`, etc.) is
/// Phase 3 (brief § Out-of-scope).
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

// -- Plugin lifecycle callbacks (cf. engine-c-api.md §3.3) ------------

/// Plugin lifecycle callbacks. All optional (`null` =
/// ignored). The M0.2 stub plugin leaves all callbacks `null`.
///
/// The callbacks receive `*const anyopaque` rather than the
/// concrete `*const WeldAPI` (defined in `api.zig`) — it is the
/// opaque pointer to the API table that the plugin downcasts at
/// entry via `@ptrCast`. This avoids the cyclic dependency
/// `desc.zig ↔ api.zig` while preserving the ABI signature
/// (at the C level, all pointers are `void*`).
pub const WeldPluginCallbacks = extern struct {
    /// Called once at `loadPlugin`. The plugin registers its
    /// components / resources / systems / events here.
    on_load: ?*const fn (api: *const anyopaque) callconv(.c) WeldResult = null,
    /// Called after ALL plugins are loaded. The plugin can now
    /// query the services of the other modules.
    on_init: ?*const fn (api: *const anyopaque) callconv(.c) WeldResult = null,
    /// Called every frame (only if the plugin declared it).
    /// Most plugins don't need it — they use ECS systems.
    on_update: ?*const fn (api: *const anyopaque, dt: f32) callconv(.c) void = null,
    /// Called at `unloadPlugin`. The plugin frees its internal
    /// resources (ECS components are managed by the engine).
    on_shutdown: ?*const fn (api: *const anyopaque) callconv(.c) void = null,
};

// -- Plugin descriptor (cf. engine-c-api.md §3.1) ---------------------

/// Descriptor returned by the plugin's single entry point
/// (`weld_plugin_entry`). Identity + capabilities + callbacks.
pub const WeldPluginDesc = extern struct {
    /// Short plugin name (`"advanced-animation-framework"`).
    name: WeldStr = .{},
    /// Name displayed by the editor (`"Advanced Animation Framework"`).
    display_name: WeldStr = .{},
    /// Plugin semver version (`"1.2.0"`).
    version: WeldStr = .{},
    /// Minimum supported `WELD_API_VERSION_MAJOR`. The loader
    /// refuses to load if this value exceeds the major version
    /// compiled into Weld (`error.ApiVersionTooNew`).
    api_version_min: u32 = 0,
    _pad: u32 = 0,
    /// Declared capabilities (cf. `WeldPluginCaps`).
    caps: WeldPluginCaps = .{},
    /// Lifecycle callbacks (cf. `WeldPluginCallbacks`).
    callbacks: WeldPluginCallbacks = .{},
};

/// Signature of the single entry point exported by the plugin.
/// The loader resolves `dlsym("weld_plugin_entry")` and calls
/// this function with an opaque pointer to the runtime `WeldAPI`
/// (cf. `api.zig` for the concrete type). As with the
/// callbacks, the plugin downcasts `*const anyopaque → *const
/// WeldAPI` at entry.
pub const WeldPluginEntryFn = *const fn (api: *const anyopaque) callconv(.c) *const WeldPluginDesc;
