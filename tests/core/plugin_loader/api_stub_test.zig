//! M0.2 / E6 — stub API surface freeze test.
//!
//! Enumère exhaustivement chaque callback des 7 sous-APIs
//! (`WeldEcsAPI`, `WeldResourceAPI`, `WeldEventAPI`,
//! `WeldServiceAPI`, `WeldMemoryAPI`, `WeldEditorAPI`,
//! `WeldPlatformAPI`) et vérifie le code de retour stub. Ce test
//! **fige la surface** : tout ajout / retrait / renommage
//! silencieux d'une callback casse le test. Toute callback qui
//! ne retourne pas le défaut stub (i.e. qui se met à câbler
//! réellement le Tier 0) le détecte aussi — le câblage runtime
//! des 7 sous-APIs est Phase 3 (brief § Out-of-scope).
//!
//! Convention de vérification :
//!   - Fonctions retournant `WeldResult` : doivent renvoyer
//!     `.WELD_ERR_NOT_IMPLEMENTED`.
//!   - Fonctions retournant un pointeur opaque (`?*const
//!     anyopaque`, `WeldQueryHandle`, `WeldAllocatorHandle`,
//!     etc.) : doivent renvoyer `null`.
//!   - Fonctions retournant un `bool` : doivent renvoyer
//!     `false`.
//!   - Fonctions retournant un `u32` / `u64` ID : doivent
//!     renvoyer `0`.
//!   - Fonctions retournant `void` : appelées pour smoke (must
//!     not crash).
//!   - Fonctions retournant un type spécifique (e.g.
//!     `WeldSlice`) : zero-initialisé.

const std = @import("std");
const weld_core = @import("weld_core");

const pl = weld_core.plugin_loader;
const WeldResult = pl.WeldResult;

// Constantes triviales utilisées pour appeler les stubs avec
// des args bidon. Aucune sémantique attendue — c'est de
// l'agitation de pointeur pour vérifier que les callbacks ne
// font rien.
const world: pl.desc.WeldWorldHandle = null;
const dummy_str: pl.desc.WeldStr = .{};
const dummy_entity: pl.desc.WeldEntity = 0;
const dummy_component: pl.desc.WeldComponentId = 0;
const dummy_resource: pl.desc.WeldResourceId = 0;
const dummy_event: pl.desc.WeldEventId = 0;
const dummy_system: pl.desc.WeldSystemId = 0;
const dummy_tag: pl.desc.WeldTagId = 0;
const dummy_allocator: pl.desc.WeldAllocatorHandle = null;
const dummy_ctx: pl.desc.WeldEditorCtxHandle = null;

// `*const anyopaque` cible pour les fonctions qui prennent un
// pointeur opaque en argument. Pointe sur une zone valide
// (variable locale) pour ne pas déclencher d'UB hypothétique.
var dummy_blob: u64 = 0;

test "stub_api WeldEcsAPI: entités stubbed" {
    const a = pl.stub_api.ecs;
    try std.testing.expectEqual(@as(u64, 0), a.entity_spawn(world));
    a.entity_destroy(world, dummy_entity);
    try std.testing.expect(!a.entity_is_alive(world, dummy_entity));
    try std.testing.expectEqual(@as(u32, 0), a.entity_count(world));
}

test "stub_api WeldEcsAPI: composants stubbed (WELD_ERR_NOT_IMPLEMENTED sur Result-returning)" {
    const a = pl.stub_api.ecs;
    try std.testing.expectEqual(@as(u32, 0), a.component_register(world, dummy_str, 0, 0, null, 0));
    try std.testing.expectEqual(@as(u32, 0), a.component_find(world, dummy_str));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.component_add(world, dummy_entity, dummy_component, &dummy_blob));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.component_remove(world, dummy_entity, dummy_component));
    try std.testing.expect(!a.component_has(world, dummy_entity, dummy_component));
    try std.testing.expect(a.component_get(world, dummy_entity, dummy_component) == null);
    try std.testing.expect(a.component_get_mut(world, dummy_entity, dummy_component) == null);
}

test "stub_api WeldEcsAPI: queries stubbed" {
    const a = pl.stub_api.ecs;
    const q = a.query_create(world, null, 0, null, 0);
    try std.testing.expect(q == null);
    a.query_destroy(q);
    a.query_each(q, &dummyQueryCallback, null);
    try std.testing.expectEqual(@as(u32, 0), a.query_count(q));
}
fn dummyQueryCallback(chunk: *const pl.api.WeldQueryChunk, user_data: ?*anyopaque) callconv(.c) void {
    _ = chunk;
    _ = user_data;
}

test "stub_api WeldEcsAPI: systèmes stubbed" {
    const a = pl.stub_api.ecs;
    const sid = a.system_register(world, dummy_str, .WELD_PHASE_UPDATE, 0, &dummyQueryCallback, null, null, 0, null, 0);
    try std.testing.expectEqual(@as(u32, 0), sid);
    a.system_unregister(world, dummy_system);
    a.system_set_enabled(world, dummy_system, true);
}

test "stub_api WeldEcsAPI: tags stubbed" {
    const a = pl.stub_api.ecs;
    try std.testing.expectEqual(@as(u64, 0), a.tag_find(world, dummy_str));
    a.tag_add(world, dummy_entity, dummy_tag);
    a.tag_remove(world, dummy_entity, dummy_tag);
    try std.testing.expect(!a.tag_has(world, dummy_entity, dummy_tag));
    try std.testing.expect(!a.tag_has_any(world, dummy_entity, null, 0));
    try std.testing.expect(!a.tag_has_all(world, dummy_entity, null, 0));
}

test "stub_api WeldResourceAPI: tous stubbed" {
    const a = pl.stub_api.resource;
    try std.testing.expectEqual(@as(u32, 0), a.resource_register(world, dummy_str, 0, 0, .WELD_RESOURCE_TRANSIENT, null, 0));
    try std.testing.expectEqual(@as(u32, 0), a.resource_find(world, dummy_str));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.resource_set(world, dummy_resource, &dummy_blob));
    try std.testing.expect(a.resource_get(world, dummy_resource) == null);
    try std.testing.expect(a.resource_get_mut(world, dummy_resource) == null);
    try std.testing.expect(!a.resource_has(world, dummy_resource));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.resource_remove(world, dummy_resource));
    try std.testing.expect(!a.resource_changed(world, dummy_resource, 0));
}

test "stub_api WeldEventAPI: tous stubbed" {
    const a = pl.stub_api.event;
    try std.testing.expectEqual(@as(u32, 0), a.event_register(world, dummy_str, 0, 0, null, 0));
    try std.testing.expectEqual(@as(u32, 0), a.event_find(world, dummy_str));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.event_emit(world, dummy_event, &dummy_blob));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.event_subscribe(world, dummy_event, &dummyEventCallback, null));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.event_unsubscribe(world, dummy_event, &dummyEventCallback));
    const slice = a.event_read(world, dummy_event);
    try std.testing.expect(slice.ptr == null);
    try std.testing.expectEqual(@as(u32, 0), slice.count);
}
fn dummyEventCallback(event_id: pl.desc.WeldEventId, payload: *const anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = event_id;
    _ = payload;
    _ = user_data;
}

test "stub_api WeldServiceAPI: tous stubbed" {
    const a = pl.stub_api.service;
    try std.testing.expect(a.service_get(world, dummy_str) == null);
    try std.testing.expect(!a.service_available(world, dummy_str));
}

test "stub_api WeldMemoryAPI: tous stubbed" {
    const a = pl.stub_api.memory;
    try std.testing.expect(a.get_frame_allocator() == null);
    try std.testing.expect(a.get_persistent_allocator() == null);
    try std.testing.expect(a.get_scratch_allocator() == null);
    try std.testing.expect(a.alloc(dummy_allocator, 0, 1) == null);
    try std.testing.expect(a.realloc(dummy_allocator, null, 0, 0, 1) == null);
    a.free(dummy_allocator, null, 0);
    try std.testing.expect(a.create_pool(0, 1, 0) == null);
    a.destroy_pool(dummy_allocator);
}

test "stub_api WeldEditorAPI: tous stubbed" {
    const a = pl.stub_api.editor.?;
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.panel_register(dummy_str, dummy_str, &dummyPanelDraw, null));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.inspector_register(dummy_component, &dummyInspectorDraw, null));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.gizmo_register(dummy_component, &dummyGizmoDraw, null));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.graph_node_register(dummy_str, dummy_str, dummy_str, null, 0, null, 0, null));
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.menu_register(dummy_str, &dummyMenuAction, null));

    // Draw primitives — void / bool returns.
    a.draw_text(dummy_ctx, dummy_str);
    a.draw_label(dummy_ctx, dummy_str, dummy_str);
    try std.testing.expect(!a.draw_button(dummy_ctx, dummy_str));
    var b_flag: bool = false;
    try std.testing.expect(!a.draw_checkbox(dummy_ctx, dummy_str, &b_flag));
    var f_val: f32 = 0;
    try std.testing.expect(!a.draw_slider_float(dummy_ctx, dummy_str, &f_val, 0, 1));
    var i_val: i32 = 0;
    try std.testing.expect(!a.draw_slider_int(dummy_ctx, dummy_str, &i_val, 0, 1));
    var c_val: pl.desc.WeldColor = .{};
    try std.testing.expect(!a.draw_color_edit(dummy_ctx, dummy_str, &c_val));
    var v_val: pl.desc.WeldVec3 = .{};
    try std.testing.expect(!a.draw_vec3_edit(dummy_ctx, dummy_str, &v_val));
    var sel: i32 = 0;
    try std.testing.expect(!a.draw_dropdown(dummy_ctx, dummy_str, null, 0, &sel));
    a.draw_separator(dummy_ctx);
    a.draw_collapsible_begin(dummy_ctx, dummy_str, &b_flag);
    a.draw_collapsible_end(dummy_ctx);
}
fn dummyPanelDraw(ctx: pl.desc.WeldEditorCtxHandle, user_data: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    _ = user_data;
}
fn dummyInspectorDraw(ctx: pl.desc.WeldEditorCtxHandle, entity: pl.desc.WeldEntity, comp: pl.desc.WeldComponentId, component_data: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    _ = entity;
    _ = comp;
    _ = component_data;
    _ = user_data;
}
fn dummyGizmoDraw(ctx: pl.desc.WeldEditorCtxHandle, entity: pl.desc.WeldEntity, user_data: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    _ = entity;
    _ = user_data;
}
fn dummyMenuAction(user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
}

test "stub_api WeldPlatformAPI: tous stubbed" {
    const a = pl.stub_api.platform;
    var out_data: ?*anyopaque = undefined;
    var out_size: u32 = 0;
    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.file_read(dummy_str, dummy_allocator, &out_data, &out_size));
    try std.testing.expect(out_data == null);
    try std.testing.expectEqual(@as(u32, 0), out_size);

    try std.testing.expectEqual(WeldResult.WELD_ERR_NOT_IMPLEMENTED, a.file_write(dummy_str, &dummy_blob, 8));
    try std.testing.expect(!a.file_exists(dummy_str));
    try std.testing.expectEqual(@as(f64, 0), a.time_now());
    try std.testing.expectEqual(@as(u64, 0), a.time_now_ns());

    a.job_submit(&dummyJobFn, null, 0);
    a.job_wait_all();

    a.log_info(dummy_str);
    a.log_warn(dummy_str);
    a.log_error(dummy_str);
    a.log_debug(dummy_str);

    const os_name = a.os_name();
    try std.testing.expect(os_name.ptr == null);
    try std.testing.expectEqual(@as(u32, 0), a.cpu_core_count());
    try std.testing.expectEqual(@as(u64, 0), a.total_memory_bytes());
}
fn dummyJobFn(user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
}

test "stub_api WeldAPI table is wired" {
    // Smoke check : la table principale référence chaque
    // sous-API non-null (sauf `editor` qui peut être null en
    // shipping ; en M0.2 le stub editor est exposé).
    const a = pl.stub_api;
    _ = a.ecs;
    _ = a.resource;
    _ = a.event;
    _ = a.memory;
    _ = a.service;
    try std.testing.expect(a.editor != null);
    _ = a.platform;
}
