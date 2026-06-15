//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! M0.2 / E6 — `WeldAPI` table + 7 sub-APIs with stub
//! implementations.
//!
//! All signatures are **frozen final** in the sense of the
//! C0.5 partial freeze (cf. brief § Scope). No callback actually
//! wires the Zig Tier 0 — every function that returns
//! `WeldResult` returns `WELD_ERR_NOT_IMPLEMENTED`, `void`
//! functions are no-ops, and functions returning a
//! pointer / int return `null` / `0`. The runtime wiring is
//! Phase 3 (cf. brief § Out-of-scope).
//!
//! Layout consistent with `engine-c-api.md` §4 (main table) +
//! §5 to §11 (sub-APIs). The `api_stub_test.zig` test enumerates
//! each callback and checks the return code — any callback
//! that does not honor the stub contract is detected.

const std = @import("std");
const desc = @import("desc.zig");

const WeldResult = desc.WeldResult;
const WeldEntity = desc.WeldEntity;
const WeldAssetHandle = desc.WeldAssetHandle;
const WeldComponentId = desc.WeldComponentId;
const WeldResourceId = desc.WeldResourceId;
const WeldEventId = desc.WeldEventId;
const WeldSystemId = desc.WeldSystemId;
const WeldServiceId = desc.WeldServiceId;
const WeldTagId = desc.WeldTagId;
const WeldStr = desc.WeldStr;
const WeldSlice = desc.WeldSlice;
const WeldVec2 = desc.WeldVec2;
const WeldVec3 = desc.WeldVec3;
const WeldColor = desc.WeldColor;
const WeldWorldHandle = desc.WeldWorldHandle;
const WeldQueryHandle = desc.WeldQueryHandle;
const WeldAllocatorHandle = desc.WeldAllocatorHandle;
const WeldEditorCtxHandle = desc.WeldEditorCtxHandle;

// =============================================================
// FieldDesc (cf. engine-c-api.md §5.3) — per-field metadata
// passed to `component_register` / `resource_register` /
// `event_register`. Mirror of the RTTI `FieldDesc` (E1).
// =============================================================

/// Discriminant tag of a `WeldFieldDesc`. Mirrors `rtti.FieldKind`
/// (E1) at the C ABI boundary — extended with `WELD_FIELD_*` variants
/// the C-side editor inspector / serializer can dispatch on.
pub const WeldFieldType = enum(c_int) {
    WELD_FIELD_F32,
    WELD_FIELD_F64,
    WELD_FIELD_I8,
    WELD_FIELD_I16,
    WELD_FIELD_I32,
    WELD_FIELD_I64,
    WELD_FIELD_U8,
    WELD_FIELD_U16,
    WELD_FIELD_U32,
    WELD_FIELD_U64,
    WELD_FIELD_BOOL,
    WELD_FIELD_VEC2,
    WELD_FIELD_VEC3,
    WELD_FIELD_VEC4,
    WELD_FIELD_QUAT,
    WELD_FIELD_MAT3,
    WELD_FIELD_MAT4,
    WELD_FIELD_COLOR,
    WELD_FIELD_ENTITY,
    WELD_FIELD_ASSET_HANDLE,
    WELD_FIELD_ENUM,
    WELD_FIELD_FIXED_ARRAY,
};

/// Per-field metadata passed to `component_register`,
/// `resource_register`, `event_register`. C-ABI mirror of
/// `rtti.FieldDesc` (E1) with extra editor hints (`range_min/max`,
/// `tooltip`, `group`).
pub const WeldFieldDesc = extern struct {
    name: WeldStr = .{},
    field_type: WeldFieldType = .WELD_FIELD_F32,
    offset: u32 = 0,
    count: u32 = 1,
    unit: WeldStr = .{},
    range_min: f32 = std.math.nan(f32),
    range_max: f32 = std.math.nan(f32),
    tooltip: WeldStr = .{},
    group: WeldStr = .{},
};

// =============================================================
// Resource lifecycle (cf. engine-c-api.md §6) — mirror of
// rtti.Lifecycle (E1).
// =============================================================

/// Lifecycle tag declared at `resource_register`. Mirror of
/// `rtti.Lifecycle` (E1) — drives the serialization / replication
/// policy (`@config` / `@state` / `@transient`).
pub const WeldResourceLifecycle = enum(c_int) {
    WELD_RESOURCE_CONFIG,
    WELD_RESOURCE_STATE,
    WELD_RESOURCE_TRANSIENT,
};

// =============================================================
// Query chunk + callback (cf. engine-c-api.md §5.4-5.5).
// =============================================================

/// Contiguous slice of entities matching a query, surfaced to the
/// `WeldQueryCallback`. SoA component arrays are addressable via
/// `components[i][slot]` with `component_sizes[i]` driving the
/// stride.
pub const WeldQueryChunk = extern struct {
    entities: ?[*]const WeldEntity = null,
    count: u32 = 0,
    components: ?[*]?*anyopaque = null,
    component_sizes: ?[*]const u32 = null,
};

/// Callback fired by `query_each` for every matching chunk.
pub const WeldQueryCallback = *const fn (chunk: *const WeldQueryChunk, user_data: ?*anyopaque) callconv(.c) void;

// =============================================================
// System phase (cf. engine-c-api.md §5.6).
// =============================================================

/// Scheduler phase a system runs in. Mirrors the engine's internal
/// `Phase` enum (cf. `engine-c-api.md §5.6`).
pub const WeldSystemPhase = enum(c_int) {
    WELD_PHASE_PRE_UPDATE = 0,
    WELD_PHASE_FIXED_UPDATE = 1,
    WELD_PHASE_UPDATE = 2,
    WELD_PHASE_POST_UPDATE = 3,
    WELD_PHASE_LATE_UPDATE = 4,
    WELD_PHASE_PRE_RENDER = 5,
};

// =============================================================
// Event callback (cf. engine-c-api.md §7).
// =============================================================

/// Callback fired by `event.subscribe` for every emitted event of
/// the subscribed type.
pub const WeldEventCallback = *const fn (event_id: WeldEventId, payload: *const anyopaque, user_data: ?*anyopaque) callconv(.c) void;

// =============================================================
// Job callback (cf. engine-c-api.md §11).
// =============================================================

/// Callback submitted to `platform.job_submit`.
pub const WeldJobFn = *const fn (user_data: ?*anyopaque) callconv(.c) void;

// =============================================================
// Editor draw callbacks (cf. engine-c-api.md §10).
// =============================================================

/// Draw callback for a `panel_register`-ed custom editor panel.
pub const WeldPanelDrawFn = *const fn (ctx: WeldEditorCtxHandle, user_data: ?*anyopaque) callconv(.c) void;
/// Draw callback for an `inspector_register`-ed custom component inspector.
pub const WeldInspectorDrawFn = *const fn (ctx: WeldEditorCtxHandle, entity: WeldEntity, comp: WeldComponentId, component_data: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void;
/// Draw callback for a `gizmo_register`-ed viewport gizmo.
pub const WeldGizmoDrawFn = *const fn (ctx: WeldEditorCtxHandle, entity: WeldEntity, user_data: ?*anyopaque) callconv(.c) void;
/// Action callback for a `menu_register`-ed menu entry.
pub const WeldMenuActionFn = *const fn (user_data: ?*anyopaque) callconv(.c) void;

/// Discriminant tag for `WeldNodePort` (visual scripting graph node
/// I/O type — cf. `engine-c-api.md §10`).
pub const WeldPortType = enum(c_int) {
    WELD_PORT_FLOAT,
    WELD_PORT_VEC3,
    WELD_PORT_COLOR,
    WELD_PORT_ENTITY,
    WELD_PORT_BOOL,
    WELD_PORT_POSE,
    WELD_PORT_ANY,
};

/// One input or output port of a visual-scripting graph node
/// registered via `graph_node_register`.
pub const WeldNodePort = extern struct {
    name: WeldStr = .{},
    port_type: WeldPortType = .WELD_PORT_ANY,
};

// =============================================================
// Stub bodies — each returns the "not wired" default.
// Factored by return type to minimize noise.
// =============================================================

fn stubResult() callconv(.c) WeldResult {
    return .WELD_ERR_NOT_IMPLEMENTED;
}

fn stubVoid() callconv(.c) void {}

// =============================================================
// WeldEcsAPI (cf. engine-c-api.md §5).
// =============================================================

/// ECS sub-API table (cf. `engine-c-api.md §5`). Every callback is
/// currently a stub returning `WELD_ERR_NOT_IMPLEMENTED` / null / 0
/// / false — the real wiring is Phase 3 (cf. brief §Out-of-scope).
pub const WeldEcsAPI = extern struct {
    // --- Entities ---
    entity_spawn: *const fn (world: WeldWorldHandle) callconv(.c) WeldEntity = stub_entity_spawn,
    entity_destroy: *const fn (world: WeldWorldHandle, entity: WeldEntity) callconv(.c) void = stub_entity_destroy,
    entity_is_alive: *const fn (world: WeldWorldHandle, entity: WeldEntity) callconv(.c) bool = stub_entity_is_alive,
    entity_count: *const fn (world: WeldWorldHandle) callconv(.c) u32 = stub_entity_count,

    // --- Components ---
    component_register: *const fn (
        world: WeldWorldHandle,
        name: WeldStr,
        size: u32,
        alignment: u32,
        fields: ?[*]const WeldFieldDesc,
        field_count: u32,
    ) callconv(.c) WeldComponentId = stub_component_register,
    component_find: *const fn (world: WeldWorldHandle, name: WeldStr) callconv(.c) WeldComponentId = stub_component_find,
    component_add: *const fn (world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId, data: *const anyopaque) callconv(.c) WeldResult = stub_component_add,
    component_remove: *const fn (world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) WeldResult = stub_component_remove,
    component_has: *const fn (world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) bool = stub_component_has,
    component_get: *const fn (world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) ?*const anyopaque = stub_component_get,
    component_get_mut: *const fn (world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) ?*anyopaque = stub_component_get_mut,

    // --- Queries ---
    query_create: *const fn (
        world: WeldWorldHandle,
        include: ?[*]const WeldComponentId,
        include_count: u32,
        exclude: ?[*]const WeldComponentId,
        exclude_count: u32,
    ) callconv(.c) WeldQueryHandle = stub_query_create,
    query_destroy: *const fn (query: WeldQueryHandle) callconv(.c) void = stub_query_destroy,
    query_each: *const fn (query: WeldQueryHandle, callback: WeldQueryCallback, user_data: ?*anyopaque) callconv(.c) void = stub_query_each,
    query_count: *const fn (query: WeldQueryHandle) callconv(.c) u32 = stub_query_count,

    // --- Systems ---
    system_register: *const fn (
        world: WeldWorldHandle,
        name: WeldStr,
        phase: WeldSystemPhase,
        priority: i32,
        callback: WeldQueryCallback,
        user_data: ?*anyopaque,
        reads: ?[*]const WeldComponentId,
        reads_count: u32,
        writes: ?[*]const WeldComponentId,
        writes_count: u32,
    ) callconv(.c) WeldSystemId = stub_system_register,
    system_unregister: *const fn (world: WeldWorldHandle, system: WeldSystemId) callconv(.c) void = stub_system_unregister,
    system_set_enabled: *const fn (world: WeldWorldHandle, system: WeldSystemId, enabled: bool) callconv(.c) void = stub_system_set_enabled,

    // --- Tags ---
    tag_find: *const fn (world: WeldWorldHandle, path: WeldStr) callconv(.c) WeldTagId = stub_tag_find,
    tag_add: *const fn (world: WeldWorldHandle, entity: WeldEntity, tag: WeldTagId) callconv(.c) void = stub_tag_add,
    tag_remove: *const fn (world: WeldWorldHandle, entity: WeldEntity, tag: WeldTagId) callconv(.c) void = stub_tag_remove,
    tag_has: *const fn (world: WeldWorldHandle, entity: WeldEntity, tag: WeldTagId) callconv(.c) bool = stub_tag_has,
    tag_has_any: *const fn (world: WeldWorldHandle, entity: WeldEntity, tags: ?[*]const WeldTagId, count: u32) callconv(.c) bool = stub_tag_has_any,
    tag_has_all: *const fn (world: WeldWorldHandle, entity: WeldEntity, tags: ?[*]const WeldTagId, count: u32) callconv(.c) bool = stub_tag_has_all,
};

fn stub_entity_spawn(world: WeldWorldHandle) callconv(.c) WeldEntity {
    _ = world;
    return desc.WELD_ENTITY_NULL;
}
fn stub_entity_destroy(world: WeldWorldHandle, entity: WeldEntity) callconv(.c) void {
    _ = world;
    _ = entity;
}
fn stub_entity_is_alive(world: WeldWorldHandle, entity: WeldEntity) callconv(.c) bool {
    _ = world;
    _ = entity;
    return false;
}
fn stub_entity_count(world: WeldWorldHandle) callconv(.c) u32 {
    _ = world;
    return 0;
}
fn stub_component_register(world: WeldWorldHandle, name: WeldStr, size: u32, alignment: u32, fields: ?[*]const WeldFieldDesc, field_count: u32) callconv(.c) WeldComponentId {
    _ = world;
    _ = name;
    _ = size;
    _ = alignment;
    _ = fields;
    _ = field_count;
    return 0;
}
fn stub_component_find(world: WeldWorldHandle, name: WeldStr) callconv(.c) WeldComponentId {
    _ = world;
    _ = name;
    return 0;
}
fn stub_component_add(world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId, data: *const anyopaque) callconv(.c) WeldResult {
    _ = world;
    _ = entity;
    _ = comp;
    _ = data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_component_remove(world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) WeldResult {
    _ = world;
    _ = entity;
    _ = comp;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_component_has(world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) bool {
    _ = world;
    _ = entity;
    _ = comp;
    return false;
}
fn stub_component_get(world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) ?*const anyopaque {
    _ = world;
    _ = entity;
    _ = comp;
    return null;
}
fn stub_component_get_mut(world: WeldWorldHandle, entity: WeldEntity, comp: WeldComponentId) callconv(.c) ?*anyopaque {
    _ = world;
    _ = entity;
    _ = comp;
    return null;
}
fn stub_query_create(world: WeldWorldHandle, include: ?[*]const WeldComponentId, include_count: u32, exclude: ?[*]const WeldComponentId, exclude_count: u32) callconv(.c) WeldQueryHandle {
    _ = world;
    _ = include;
    _ = include_count;
    _ = exclude;
    _ = exclude_count;
    return null;
}
fn stub_query_destroy(query: WeldQueryHandle) callconv(.c) void {
    _ = query;
}
fn stub_query_each(query: WeldQueryHandle, callback: WeldQueryCallback, user_data: ?*anyopaque) callconv(.c) void {
    _ = query;
    _ = callback;
    _ = user_data;
}
fn stub_query_count(query: WeldQueryHandle) callconv(.c) u32 {
    _ = query;
    return 0;
}
fn stub_system_register(world: WeldWorldHandle, name: WeldStr, phase: WeldSystemPhase, priority: i32, callback: WeldQueryCallback, user_data: ?*anyopaque, reads: ?[*]const WeldComponentId, reads_count: u32, writes: ?[*]const WeldComponentId, writes_count: u32) callconv(.c) WeldSystemId {
    _ = world;
    _ = name;
    _ = phase;
    _ = priority;
    _ = callback;
    _ = user_data;
    _ = reads;
    _ = reads_count;
    _ = writes;
    _ = writes_count;
    return 0;
}
fn stub_system_unregister(world: WeldWorldHandle, system: WeldSystemId) callconv(.c) void {
    _ = world;
    _ = system;
}
fn stub_system_set_enabled(world: WeldWorldHandle, system: WeldSystemId, enabled: bool) callconv(.c) void {
    _ = world;
    _ = system;
    _ = enabled;
}
fn stub_tag_find(world: WeldWorldHandle, path: WeldStr) callconv(.c) WeldTagId {
    _ = world;
    _ = path;
    return 0;
}
fn stub_tag_add(world: WeldWorldHandle, entity: WeldEntity, tag: WeldTagId) callconv(.c) void {
    _ = world;
    _ = entity;
    _ = tag;
}
fn stub_tag_remove(world: WeldWorldHandle, entity: WeldEntity, tag: WeldTagId) callconv(.c) void {
    _ = world;
    _ = entity;
    _ = tag;
}
fn stub_tag_has(world: WeldWorldHandle, entity: WeldEntity, tag: WeldTagId) callconv(.c) bool {
    _ = world;
    _ = entity;
    _ = tag;
    return false;
}
fn stub_tag_has_any(world: WeldWorldHandle, entity: WeldEntity, tags: ?[*]const WeldTagId, count: u32) callconv(.c) bool {
    _ = world;
    _ = entity;
    _ = tags;
    _ = count;
    return false;
}
fn stub_tag_has_all(world: WeldWorldHandle, entity: WeldEntity, tags: ?[*]const WeldTagId, count: u32) callconv(.c) bool {
    _ = world;
    _ = entity;
    _ = tags;
    _ = count;
    return false;
}

// =============================================================
// WeldResourceAPI (cf. engine-c-api.md §6).
// =============================================================

/// Resources sub-API table (cf. `engine-c-api.md §6`). Stubbed in
/// M0.2 — wiring is Phase 3.
pub const WeldResourceAPI = extern struct {
    resource_register: *const fn (
        world: WeldWorldHandle,
        name: WeldStr,
        size: u32,
        alignment: u32,
        lifecycle: WeldResourceLifecycle,
        fields: ?[*]const WeldFieldDesc,
        field_count: u32,
    ) callconv(.c) WeldResourceId = stub_resource_register,
    resource_find: *const fn (world: WeldWorldHandle, name: WeldStr) callconv(.c) WeldResourceId = stub_resource_find,
    resource_set: *const fn (world: WeldWorldHandle, id: WeldResourceId, data: *const anyopaque) callconv(.c) WeldResult = stub_resource_set,
    resource_get: *const fn (world: WeldWorldHandle, id: WeldResourceId) callconv(.c) ?*const anyopaque = stub_resource_get,
    resource_get_mut: *const fn (world: WeldWorldHandle, id: WeldResourceId) callconv(.c) ?*anyopaque = stub_resource_get_mut,
    resource_has: *const fn (world: WeldWorldHandle, id: WeldResourceId) callconv(.c) bool = stub_resource_has,
    resource_remove: *const fn (world: WeldWorldHandle, id: WeldResourceId) callconv(.c) WeldResult = stub_resource_remove,
    resource_changed: *const fn (world: WeldWorldHandle, id: WeldResourceId, since_frame: u64) callconv(.c) bool = stub_resource_changed,
};

fn stub_resource_register(world: WeldWorldHandle, name: WeldStr, size: u32, alignment: u32, lifecycle: WeldResourceLifecycle, fields: ?[*]const WeldFieldDesc, field_count: u32) callconv(.c) WeldResourceId {
    _ = world;
    _ = name;
    _ = size;
    _ = alignment;
    _ = lifecycle;
    _ = fields;
    _ = field_count;
    return 0;
}
fn stub_resource_find(world: WeldWorldHandle, name: WeldStr) callconv(.c) WeldResourceId {
    _ = world;
    _ = name;
    return 0;
}
fn stub_resource_set(world: WeldWorldHandle, id: WeldResourceId, data: *const anyopaque) callconv(.c) WeldResult {
    _ = world;
    _ = id;
    _ = data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_resource_get(world: WeldWorldHandle, id: WeldResourceId) callconv(.c) ?*const anyopaque {
    _ = world;
    _ = id;
    return null;
}
fn stub_resource_get_mut(world: WeldWorldHandle, id: WeldResourceId) callconv(.c) ?*anyopaque {
    _ = world;
    _ = id;
    return null;
}
fn stub_resource_has(world: WeldWorldHandle, id: WeldResourceId) callconv(.c) bool {
    _ = world;
    _ = id;
    return false;
}
fn stub_resource_remove(world: WeldWorldHandle, id: WeldResourceId) callconv(.c) WeldResult {
    _ = world;
    _ = id;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_resource_changed(world: WeldWorldHandle, id: WeldResourceId, since_frame: u64) callconv(.c) bool {
    _ = world;
    _ = id;
    _ = since_frame;
    return false;
}

// =============================================================
// WeldEventAPI (cf. engine-c-api.md §7).
// =============================================================

/// Events sub-API table (cf. `engine-c-api.md §7`). Stubbed in M0.2
/// — wiring is Phase 3.
pub const WeldEventAPI = extern struct {
    event_register: *const fn (
        world: WeldWorldHandle,
        name: WeldStr,
        payload_size: u32,
        payload_alignment: u32,
        fields: ?[*]const WeldFieldDesc,
        field_count: u32,
    ) callconv(.c) WeldEventId = stub_event_register,
    event_find: *const fn (world: WeldWorldHandle, name: WeldStr) callconv(.c) WeldEventId = stub_event_find,
    event_emit: *const fn (world: WeldWorldHandle, event_id: WeldEventId, payload: *const anyopaque) callconv(.c) WeldResult = stub_event_emit,
    event_subscribe: *const fn (world: WeldWorldHandle, event_id: WeldEventId, callback: WeldEventCallback, user_data: ?*anyopaque) callconv(.c) WeldResult = stub_event_subscribe,
    event_unsubscribe: *const fn (world: WeldWorldHandle, event_id: WeldEventId, callback: WeldEventCallback) callconv(.c) WeldResult = stub_event_unsubscribe,
    event_read: *const fn (world: WeldWorldHandle, event_id: WeldEventId) callconv(.c) WeldSlice = stub_event_read,
};

fn stub_event_register(world: WeldWorldHandle, name: WeldStr, payload_size: u32, payload_alignment: u32, fields: ?[*]const WeldFieldDesc, field_count: u32) callconv(.c) WeldEventId {
    _ = world;
    _ = name;
    _ = payload_size;
    _ = payload_alignment;
    _ = fields;
    _ = field_count;
    return 0;
}
fn stub_event_find(world: WeldWorldHandle, name: WeldStr) callconv(.c) WeldEventId {
    _ = world;
    _ = name;
    return 0;
}
fn stub_event_emit(world: WeldWorldHandle, event_id: WeldEventId, payload: *const anyopaque) callconv(.c) WeldResult {
    _ = world;
    _ = event_id;
    _ = payload;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_event_subscribe(world: WeldWorldHandle, event_id: WeldEventId, callback: WeldEventCallback, user_data: ?*anyopaque) callconv(.c) WeldResult {
    _ = world;
    _ = event_id;
    _ = callback;
    _ = user_data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_event_unsubscribe(world: WeldWorldHandle, event_id: WeldEventId, callback: WeldEventCallback) callconv(.c) WeldResult {
    _ = world;
    _ = event_id;
    _ = callback;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_event_read(world: WeldWorldHandle, event_id: WeldEventId) callconv(.c) WeldSlice {
    _ = world;
    _ = event_id;
    return .{};
}

// =============================================================
// WeldServiceAPI (cf. engine-c-api.md §8).
// =============================================================

/// Inter-module service registry sub-API (cf. `engine-c-api.md §8`).
/// Stubbed in M0.2 — the registry itself is Phase 3.
pub const WeldServiceAPI = extern struct {
    service_get: *const fn (world: WeldWorldHandle, name: WeldStr) callconv(.c) ?*const anyopaque = stub_service_get,
    service_available: *const fn (world: WeldWorldHandle, name: WeldStr) callconv(.c) bool = stub_service_available,
};

fn stub_service_get(world: WeldWorldHandle, name: WeldStr) callconv(.c) ?*const anyopaque {
    _ = world;
    _ = name;
    return null;
}
fn stub_service_available(world: WeldWorldHandle, name: WeldStr) callconv(.c) bool {
    _ = world;
    _ = name;
    return false;
}

// =============================================================
// WeldMemoryAPI (cf. engine-c-api.md §9).
// =============================================================

/// Memory sub-API table (cf. `engine-c-api.md §9`) — exposes the
/// engine's allocator hierarchy + a pool factory. Stubbed in M0.2.
pub const WeldMemoryAPI = extern struct {
    get_frame_allocator: *const fn () callconv(.c) WeldAllocatorHandle = stub_get_frame_allocator,
    get_persistent_allocator: *const fn () callconv(.c) WeldAllocatorHandle = stub_get_persistent_allocator,
    get_scratch_allocator: *const fn () callconv(.c) WeldAllocatorHandle = stub_get_scratch_allocator,
    alloc: *const fn (allocator: WeldAllocatorHandle, size: u32, alignment: u32) callconv(.c) ?*anyopaque = stub_alloc,
    realloc: *const fn (allocator: WeldAllocatorHandle, ptr: ?*anyopaque, old_size: u32, new_size: u32, alignment: u32) callconv(.c) ?*anyopaque = stub_realloc,
    free: *const fn (allocator: WeldAllocatorHandle, ptr: ?*anyopaque, size: u32) callconv(.c) void = stub_free,
    create_pool: *const fn (element_size: u32, element_alignment: u32, initial_count: u32) callconv(.c) WeldAllocatorHandle = stub_create_pool,
    destroy_pool: *const fn (pool: WeldAllocatorHandle) callconv(.c) void = stub_destroy_pool,
};

fn stub_get_frame_allocator() callconv(.c) WeldAllocatorHandle {
    return null;
}
fn stub_get_persistent_allocator() callconv(.c) WeldAllocatorHandle {
    return null;
}
fn stub_get_scratch_allocator() callconv(.c) WeldAllocatorHandle {
    return null;
}
fn stub_alloc(allocator: WeldAllocatorHandle, size: u32, alignment: u32) callconv(.c) ?*anyopaque {
    _ = allocator;
    _ = size;
    _ = alignment;
    return null;
}
fn stub_realloc(allocator: WeldAllocatorHandle, ptr: ?*anyopaque, old_size: u32, new_size: u32, alignment: u32) callconv(.c) ?*anyopaque {
    _ = allocator;
    _ = ptr;
    _ = old_size;
    _ = new_size;
    _ = alignment;
    return null;
}
fn stub_free(allocator: WeldAllocatorHandle, ptr: ?*anyopaque, size: u32) callconv(.c) void {
    _ = allocator;
    _ = ptr;
    _ = size;
}
fn stub_create_pool(element_size: u32, element_alignment: u32, initial_count: u32) callconv(.c) WeldAllocatorHandle {
    _ = element_size;
    _ = element_alignment;
    _ = initial_count;
    return null;
}
fn stub_destroy_pool(pool: WeldAllocatorHandle) callconv(.c) void {
    _ = pool;
}

// =============================================================
// WeldEditorAPI (cf. engine-c-api.md §10).
// =============================================================

/// Editor sub-API table (cf. `engine-c-api.md §10`) — only callable
/// from the editor process. Stubbed in M0.2.
pub const WeldEditorAPI = extern struct {
    // --- Custom panels ---
    panel_register: *const fn (name: WeldStr, category: WeldStr, draw_fn: WeldPanelDrawFn, user_data: ?*anyopaque) callconv(.c) WeldResult = stub_panel_register,
    inspector_register: *const fn (comp: WeldComponentId, draw_fn: WeldInspectorDrawFn, user_data: ?*anyopaque) callconv(.c) WeldResult = stub_inspector_register,
    gizmo_register: *const fn (comp: WeldComponentId, draw_fn: WeldGizmoDrawFn, user_data: ?*anyopaque) callconv(.c) WeldResult = stub_gizmo_register,
    graph_node_register: *const fn (
        construct_type: WeldStr,
        node_name: WeldStr,
        category: WeldStr,
        inputs: ?[*]const WeldNodePort,
        input_count: u32,
        outputs: ?[*]const WeldNodePort,
        output_count: u32,
        user_data: ?*anyopaque,
    ) callconv(.c) WeldResult = stub_graph_node_register,
    menu_register: *const fn (path: WeldStr, action_fn: WeldMenuActionFn, user_data: ?*anyopaque) callconv(.c) WeldResult = stub_menu_register,

    // --- Editor draw primitives ---
    draw_text: *const fn (ctx: WeldEditorCtxHandle, text: WeldStr) callconv(.c) void = stub_draw_text,
    draw_label: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, value: WeldStr) callconv(.c) void = stub_draw_label,
    draw_button: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr) callconv(.c) bool = stub_draw_button,
    draw_checkbox: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, value: *bool) callconv(.c) bool = stub_draw_checkbox,
    draw_slider_float: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, value: *f32, min: f32, max: f32) callconv(.c) bool = stub_draw_slider_float,
    draw_slider_int: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, value: *i32, min: i32, max: i32) callconv(.c) bool = stub_draw_slider_int,
    draw_color_edit: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, color: *WeldColor) callconv(.c) bool = stub_draw_color_edit,
    draw_vec3_edit: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, value: *WeldVec3) callconv(.c) bool = stub_draw_vec3_edit,
    draw_dropdown: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, options: ?[*]const WeldStr, option_count: u32, selected: *i32) callconv(.c) bool = stub_draw_dropdown,
    draw_separator: *const fn (ctx: WeldEditorCtxHandle) callconv(.c) void = stub_draw_separator,
    draw_collapsible_begin: *const fn (ctx: WeldEditorCtxHandle, label: WeldStr, open: *bool) callconv(.c) void = stub_draw_collapsible_begin,
    draw_collapsible_end: *const fn (ctx: WeldEditorCtxHandle) callconv(.c) void = stub_draw_collapsible_end,
};

fn stub_panel_register(name: WeldStr, category: WeldStr, draw_fn: WeldPanelDrawFn, user_data: ?*anyopaque) callconv(.c) WeldResult {
    _ = name;
    _ = category;
    _ = draw_fn;
    _ = user_data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_inspector_register(comp: WeldComponentId, draw_fn: WeldInspectorDrawFn, user_data: ?*anyopaque) callconv(.c) WeldResult {
    _ = comp;
    _ = draw_fn;
    _ = user_data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_gizmo_register(comp: WeldComponentId, draw_fn: WeldGizmoDrawFn, user_data: ?*anyopaque) callconv(.c) WeldResult {
    _ = comp;
    _ = draw_fn;
    _ = user_data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_graph_node_register(construct_type: WeldStr, node_name: WeldStr, category: WeldStr, inputs: ?[*]const WeldNodePort, input_count: u32, outputs: ?[*]const WeldNodePort, output_count: u32, user_data: ?*anyopaque) callconv(.c) WeldResult {
    _ = construct_type;
    _ = node_name;
    _ = category;
    _ = inputs;
    _ = input_count;
    _ = outputs;
    _ = output_count;
    _ = user_data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_menu_register(path: WeldStr, action_fn: WeldMenuActionFn, user_data: ?*anyopaque) callconv(.c) WeldResult {
    _ = path;
    _ = action_fn;
    _ = user_data;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_draw_text(ctx: WeldEditorCtxHandle, text: WeldStr) callconv(.c) void {
    _ = ctx;
    _ = text;
}
fn stub_draw_label(ctx: WeldEditorCtxHandle, label: WeldStr, value: WeldStr) callconv(.c) void {
    _ = ctx;
    _ = label;
    _ = value;
}
fn stub_draw_button(ctx: WeldEditorCtxHandle, label: WeldStr) callconv(.c) bool {
    _ = ctx;
    _ = label;
    return false;
}
fn stub_draw_checkbox(ctx: WeldEditorCtxHandle, label: WeldStr, value: *bool) callconv(.c) bool {
    _ = ctx;
    _ = label;
    _ = value;
    return false;
}
fn stub_draw_slider_float(ctx: WeldEditorCtxHandle, label: WeldStr, value: *f32, min: f32, max: f32) callconv(.c) bool {
    _ = ctx;
    _ = label;
    _ = value;
    _ = min;
    _ = max;
    return false;
}
fn stub_draw_slider_int(ctx: WeldEditorCtxHandle, label: WeldStr, value: *i32, min: i32, max: i32) callconv(.c) bool {
    _ = ctx;
    _ = label;
    _ = value;
    _ = min;
    _ = max;
    return false;
}
fn stub_draw_color_edit(ctx: WeldEditorCtxHandle, label: WeldStr, color: *WeldColor) callconv(.c) bool {
    _ = ctx;
    _ = label;
    _ = color;
    return false;
}
fn stub_draw_vec3_edit(ctx: WeldEditorCtxHandle, label: WeldStr, value: *WeldVec3) callconv(.c) bool {
    _ = ctx;
    _ = label;
    _ = value;
    return false;
}
fn stub_draw_dropdown(ctx: WeldEditorCtxHandle, label: WeldStr, options: ?[*]const WeldStr, option_count: u32, selected: *i32) callconv(.c) bool {
    _ = ctx;
    _ = label;
    _ = options;
    _ = option_count;
    _ = selected;
    return false;
}
fn stub_draw_separator(ctx: WeldEditorCtxHandle) callconv(.c) void {
    _ = ctx;
}
fn stub_draw_collapsible_begin(ctx: WeldEditorCtxHandle, label: WeldStr, open: *bool) callconv(.c) void {
    _ = ctx;
    _ = label;
    _ = open;
}
fn stub_draw_collapsible_end(ctx: WeldEditorCtxHandle) callconv(.c) void {
    _ = ctx;
}

// =============================================================
// WeldPlatformAPI (cf. engine-c-api.md §11).
// =============================================================

/// Platform sub-API table (cf. `engine-c-api.md §11`) — filesystem,
/// time, jobs, logging, OS introspection. Stubbed in M0.2.
pub const WeldPlatformAPI = extern struct {
    file_read: *const fn (path: WeldStr, allocator: WeldAllocatorHandle, out_data: *?*anyopaque, out_size: *u32) callconv(.c) WeldResult = stub_file_read,
    file_write: *const fn (path: WeldStr, data: *const anyopaque, size: u32) callconv(.c) WeldResult = stub_file_write,
    file_exists: *const fn (path: WeldStr) callconv(.c) bool = stub_file_exists,
    time_now: *const fn () callconv(.c) f64 = stub_time_now,
    time_now_ns: *const fn () callconv(.c) u64 = stub_time_now_ns,
    job_submit: *const fn (fn_ptr: WeldJobFn, user_data: ?*anyopaque, priority: u32) callconv(.c) void = stub_job_submit,
    job_wait_all: *const fn () callconv(.c) void = stub_job_wait_all,
    log_info: *const fn (message: WeldStr) callconv(.c) void = stub_log_info,
    log_warn: *const fn (message: WeldStr) callconv(.c) void = stub_log_warn,
    log_error: *const fn (message: WeldStr) callconv(.c) void = stub_log_error,
    log_debug: *const fn (message: WeldStr) callconv(.c) void = stub_log_debug,
    os_name: *const fn () callconv(.c) WeldStr = stub_os_name,
    cpu_core_count: *const fn () callconv(.c) u32 = stub_cpu_core_count,
    total_memory_bytes: *const fn () callconv(.c) u64 = stub_total_memory_bytes,
};

fn stub_file_read(path: WeldStr, allocator: WeldAllocatorHandle, out_data: *?*anyopaque, out_size: *u32) callconv(.c) WeldResult {
    _ = path;
    _ = allocator;
    out_data.* = null;
    out_size.* = 0;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_file_write(path: WeldStr, data: *const anyopaque, size: u32) callconv(.c) WeldResult {
    _ = path;
    _ = data;
    _ = size;
    return .WELD_ERR_NOT_IMPLEMENTED;
}
fn stub_file_exists(path: WeldStr) callconv(.c) bool {
    _ = path;
    return false;
}
fn stub_time_now() callconv(.c) f64 {
    return 0;
}
fn stub_time_now_ns() callconv(.c) u64 {
    return 0;
}
fn stub_job_submit(fn_ptr: WeldJobFn, user_data: ?*anyopaque, priority: u32) callconv(.c) void {
    _ = fn_ptr;
    _ = user_data;
    _ = priority;
}
fn stub_job_wait_all() callconv(.c) void {}
fn stub_log_info(message: WeldStr) callconv(.c) void {
    _ = message;
}
fn stub_log_warn(message: WeldStr) callconv(.c) void {
    _ = message;
}
fn stub_log_error(message: WeldStr) callconv(.c) void {
    _ = message;
}
fn stub_log_debug(message: WeldStr) callconv(.c) void {
    _ = message;
}
fn stub_os_name() callconv(.c) WeldStr {
    return .{};
}
fn stub_cpu_core_count() callconv(.c) u32 {
    return 0;
}
fn stub_total_memory_bytes() callconv(.c) u64 {
    return 0;
}

// =============================================================
// WeldAPI — table principale (cf. engine-c-api.md §4).
// =============================================================

/// Top-level API table passed to `weld_plugin_entry`. Aggregates
/// the 7 sub-API tables plus the per-tick context (`world`, `dt`,
/// `frame`). Stubbed in M0.2 — every sub-API callback returns
/// `WELD_ERR_NOT_IMPLEMENTED`.
pub const WeldAPI = extern struct {
    /// ECS sub-API.
    ecs: *const WeldEcsAPI,
    /// Resources sub-API.
    resource: *const WeldResourceAPI,
    /// Events sub-API.
    event: *const WeldEventAPI,
    /// Memory sub-API.
    memory: *const WeldMemoryAPI,
    /// Services sub-API.
    service: *const WeldServiceAPI,
    /// Editor sub-API — `null` when the runtime runs without an
    /// editor (shipping mode). Plugins must test
    /// `api.editor != null` before calling.
    editor: ?*const WeldEditorAPI = null,
    /// Platform sub-API.
    platform: *const WeldPlatformAPI,

    // Per-frame metadata
    api_version: u32 = desc.WELD_API_VERSION_MAJOR,
    world: WeldWorldHandle = null,
    dt: f32 = 0,
    frame: u64 = 0,
};

// =============================================================
// Static stub instances — pre-built with the default stub
// functions. The `Loader` passes `&stub_api` to plugins in
// M0.2 (the real runtime wiring is Phase 3).
// =============================================================

/// ECS sub-API pre-built with the stubs.
pub const stub_ecs_api: WeldEcsAPI = .{};
/// Resources sub-API pre-built.
pub const stub_resource_api: WeldResourceAPI = .{};
/// Events sub-API pre-built.
pub const stub_event_api: WeldEventAPI = .{};
/// Memory sub-API pre-built.
pub const stub_memory_api: WeldMemoryAPI = .{};
/// Services sub-API pre-built.
pub const stub_service_api: WeldServiceAPI = .{};
/// Editor sub-API pre-built.
pub const stub_editor_api: WeldEditorAPI = .{};
/// Platform sub-API pre-built.
pub const stub_platform_api: WeldPlatformAPI = .{};

/// Stub API table used by `Loader.loadPlugin` in M0.2.
/// All callbacks return `WELD_ERR_NOT_IMPLEMENTED`,
/// `null`, `0`, `false` or are no-ops depending on their return
/// type. The runtime wiring of the 7 sub-APIs to the Zig
/// Tier 0 is Phase 3 (brief § Out-of-scope).
pub const stub_api: WeldAPI = .{
    .ecs = &stub_ecs_api,
    .resource = &stub_resource_api,
    .event = &stub_event_api,
    .memory = &stub_memory_api,
    .service = &stub_service_api,
    .editor = &stub_editor_api,
    .platform = &stub_platform_api,
};
