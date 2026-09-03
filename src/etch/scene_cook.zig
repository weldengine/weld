//! M1.0.4 — Etch-side `.scene.etch` cook driver (front-end).
//!
//! Consumes a parsed Etch program containing component/resource/enum
//! declarations plus exactly one `scene` construct, and produces the **neutral
//! cook model** (`weld_core.scene.format.CookModel`) the E2 writer serializes to
//! `.scene.bin`. World-free: it registers types into a standalone `Registry`
//! (RTTI only) and const-evaluates the scene's field values into raw component
//! bytes — it never instantiates a `World` (that is the M1.0.5 loader's job).
//!
//! Pipeline:
//!   1. Parse the source → AST.
//!   2. Register every `component`/`resource` declaration into a fresh
//!      `Registry` via the shared `interp.compileTypeDecl` path (refactored to
//!      take a `*Registry`, M1.0.4 deviation). Unsupported field types surface
//!      `error.InvalidProgram` as a clear cook diagnostic.
//!   3. Locate the single `scene`; reject `instance of` (M1.0.6 boundary).
//!   4. For each entity component-instance field and each `resources` field:
//!      resolve against `Registry.findField`, const-eval the value, encode via
//!      `ecs_bridge.writeValueAsBytes`. Resource `string` values are interned
//!      into the model's string table; enum values become the declaration-order
//!      `u32` discriminant.
//!   5. Resolve each entity `parent` name to the parent's UUID.
//!   6. Group entities by `ComponentSignature` and transpose per-entity blobs
//!      into per-archetype flat SoA columns.
//!
//! Tier discipline: this file (Etch side) imports `weld_core.scene`; the Tier-0
//! `src/core/scene/` never imports `weld_etch`. The writer input is raw bytes +
//! index tables — no Etch types cross into the model.

const std = @import("std");

const ast_mod = @import("ast.zig");
const interp = @import("interp.zig");
const types_mod = @import("types.zig");
const bridge_mod = @import("ecs_bridge.zig");
const value_mod = @import("value.zig");
// M1.0.6 E5 — `renderStmtRunAlloc` renders an extends prefab's on_attach/on_detach
// statement-runs to canonical Etch text (stored in the .prefab.bin hooks section).
const descriptor = @import("descriptor.zig");

const weld_core = @import("weld_core");
// M1.0.5 — persistent heap moved to Tier 0 (`src/core/memory`); reach it via weld_core.
const persistent = weld_core.memory.persistent;
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;
const FieldDesc = weld_core.ecs.registry.FieldDesc;
const FieldKind = weld_core.ecs.registry.FieldKind;
const archetype = weld_core.ecs.archetype;
const format = weld_core.scene.format;
// M1.0.6 E2 — `of` variant resolution reads the base prefab's cooked `.prefab.bin`
// back through the same zero-copy accessor the loader uses.
const accessor = weld_core.scene.accessor;
const validate = weld_core.scene.validate;

const AstArena = ast_mod.AstArena;
const StringId = ast_mod.StringId;
const NodeId = ast_mod.NodeId;
const Bridge = bridge_mod.Bridge;

/// Cook failures. Each is a clear diagnostic, never a panic (the brief's
/// "surface `error.InvalidProgram` … as a clear cook diagnostic"). A companion
/// human message is written through the `diag_out` out-parameter of `cook`.
pub const CookError = error{
    /// The source did not parse cleanly.
    ParseFailed,
    /// No top-level `scene` construct in the program.
    NoSceneConstruct,
    /// More than one `scene` construct (a `.scene.etch` holds exactly one).
    MultipleScenes,
    /// A component/resource field has a type the runtime registry rejects
    /// (`error.InvalidProgram`: e.g. `Vec3`/`Entity`/`AssetHandle`, or `string`
    /// on a component).
    UnsupportedFieldKind,
    /// A `component`/`resource` type name is declared twice.
    DuplicateType,
    /// A scene component/resource instance names a type that was never declared.
    UndeclaredType,
    /// A field name in an instance body is not a field of the resolved type.
    UnknownField,
    /// A `..spread` field appeared in a component/resource instance body.
    SpreadUnsupported,
    /// A field value expression is not constant-evaluable at cook time.
    NonConstValue,
    /// A value's type does not match the field's kind.
    TypeMismatch,
    /// A `uuid:`/`parent:` enum value referenced an unknown enum variant.
    UnknownEnumVariant,
    /// An entity declares no `uuid:`. Explicit, stable identity is required at
    /// cook time — auto-generating a UUID is the editor's job, not the cook's.
    MissingUuid,
    /// A `uuid:` string is not a valid canonical UUID.
    BadUuid,
    /// An entity `parent:` name does not match any entity in the scene.
    ParentNotFound,
    // ── M1.0.6 E2 — prefab cook (`cookPrefab`) ──
    /// No top-level `prefab` construct in a source cooked as a `.prefab.etch`.
    NoPrefabConstruct,
    /// More than one `prefab` construct (a `.prefab.etch` holds exactly one).
    MultiplePrefabs,
    /// A `scene` construct appeared in a source cooked as a `.prefab.etch`.
    SceneNotAllowedInPrefab,
    /// `on_attach`/`on_detach`/`requires` on a standalone or `of` prefab — those
    /// clauses are valid only with `extends` (`etch-grammar.md` §15 l.1653, §30.5).
    PrefabHookNotAllowed,
    /// `extends "X" requires C` where the base prefab `X` does not declare `C`
    /// (`etch-grammar.md` §15 l.1634 — validated against X's cooked `.prefab.bin`).
    RequiresNotSatisfied,
    /// An `extends` prefab's `on_attach`/`on_detach` body could not be rendered to
    /// canonical Etch text (a construct outside the descriptor renderer's surface).
    HookRenderFailed,
    /// `prefab "Y" of "X"` but the base `X.prefab.bin` could not be resolved
    /// (no resolver, or the resolver returned null for the base name).
    BasePrefabMissing,
    /// The resolved base `.prefab.bin` bytes failed `accessor.open`/`verifyHash`.
    BasePrefabCorrupt,
    /// A base prefab component's name is unknown to the variant's registry, or
    /// its on-disk size disagrees with the variant registry's layout.
    BaseSchemaMismatch,
    // ── M1.0.6 E3 — `instance of` flattening at scene cook ──
    /// `instance of "P"` where `P.prefab.bin` holds more than one entity. M1.0.6
    /// instantiates only single-entity prefabs: the instance supplies one uuid and
    /// the spec defines no remapping for a multi-entity prefab's internal uuids at
    /// instantiation (`engine-scene-serialization.md` §2/§5). Multi-entity
    /// instantiation (and its hierarchy) is a dedicated later milestone (D-D).
    MultiEntityInstanceUnsupported,
    /// A `Comp.field = value` per-field override targets a component the flattened
    /// instance does not carry (neither inherited from the prefab nor added by an
    /// earlier `Comp { … }` member of the same instance body).
    OverrideTargetMissing,
    /// An `Entity` field references an entity name absent from the scene (M1.0.6
    /// E4 — intra-scene only; cross-scene references are a future milestone).
    UnresolvedCrossRef,
    /// The entity's {base components} ∪ {active extensions' components} is not
    /// conflict-free (M1.1.1-HF4 — `E1797 ExtensionAdditiveConflict`). Three
    /// rejected forms: (a) two extensions declare the same component; (b) an
    /// extension declares a component already carried by the base (or an earlier
    /// extension); (c) the same extension is listed twice. The `extends` model is
    /// strictly additive — a conflict is rejected, never resolved by list order.
    /// Fatal cook error → guarantees `cooked ⇒ loadable` (runtime backstops:
    /// `error.ExtensionComponentConflict` for a/b, `error.ExtensionAlreadyActive`
    /// for c). See `engine-scene-serialization.md` (extension additive conflicts).
    ExtensionAdditiveConflict,
    OutOfMemory,
};

/// The cook's output: the neutral model plus the `Registry` it was cooked
/// against. The registry owns the type metadata (names/sizes/field offsets +
/// kinds) needed to interpret the model's raw component bytes — the AST is
/// freed by `cook`, so the registry, not the AST, is the model's schema source.
/// Caller owns both; `deinit` frees the model arena then the registry.
pub const Cooked = struct {
    model: format.CookModel,
    registry: Registry,

    pub fn deinit(self: *Cooked, gpa: std.mem.Allocator) void {
        self.model.deinit();
        self.registry.deinit(gpa);
        self.* = undefined;
    }
};

/// Cook an Etch source string into the neutral scene model + its registry, with
/// no prefab resolver — a scene that uses `instance of` errors `BasePrefabMissing`
/// (use `cookScene` with a resolver to flatten instances). On failure returns a
/// `CookError` and, if `diag_out` is non-null, sets it to a static message. No
/// `.scene.bin` is produced on failure.
pub fn cook(gpa: std.mem.Allocator, source: []const u8, diag_out: ?*[]const u8) CookError!Cooked {
    return cookScene(gpa, source, null, diag_out);
}

/// Cook a `.scene.etch` source, resolving each `instance of "P"` by flattening
/// `P.prefab.bin` (located through `base_resolver`) into the instance's entity:
/// the prefab's components are inherited and the instance's overrides applied
/// (M1.0.6 E3). `base_resolver` may be null for a scene with no instances; an
/// instance with a null/unknowing resolver errors `BasePrefabMissing`.
pub fn cookScene(
    gpa: std.mem.Allocator,
    source: []const u8,
    base_resolver: ?BaseResolver,
    diag_out: ?*[]const u8,
) CookError!Cooked {
    const parser = @import("parser.zig");
    var pr = parser.parse(gpa, source) catch return fail(diag_out, error.ParseFailed, "Etch parse failed (allocator error)");
    defer pr.deinit(gpa);
    if (pr.diagnostics.len > 0) return fail(diag_out, error.ParseFailed, "Etch parse failed");
    const ast = &pr.ast;

    var registry = Registry.init();
    errdefer registry.deinit(gpa);

    var b = Builder.init(gpa, ast, &registry);
    defer b.deinitScratch();
    errdefer b.arena.deinit();

    try b.registerDecls(diag_out);
    const scene_decl = try b.findScene(diag_out);
    const model = try b.build(scene_decl, base_resolver, diag_out);

    // `model` owns the cook arena by value — a copy of `b.arena` (build: `.arena =
    // self.arena`, scene_cook build return). A failing `toOwnedSlice` here is
    // already covered by `errdefer b.arena.deinit()` above: same buffers, freed
    // once. Do NOT add `errdefer model.deinit()` — it double-frees the aliased arena.
    return .{ .model = model, .registry = registry };
}

fn fail(diag_out: ?*[]const u8, err: CookError, msg: []const u8) CookError {
    if (diag_out) |d| d.* = msg;
    return err;
}

/// Resolves a referenced prefab name (the target of `of "X"`) to its already
/// cooked `.prefab.bin` bytes, or null if unknown. A `.prefab.bin` is the same
/// format as a `.scene.bin`, so a variant's base is read back through the
/// `accessor`. This is the cook-time prefab registry / path map (distinct from
/// Etch `import`, which is M1.0.7); the driver (`tools/scene_cook`) wires it to
/// the on-disk cook output, and tests wire it to an in-process byte buffer.
///
/// The resolved bytes must outlive the cook (mirror of `loader.zig`'s
/// `ExtensionResolver`): the additive-conflict check (fatal E1797) borrows them
/// as component-name map keys ACROSS resolves, so a resolver returning a
/// reused/temporary buffer would be a use-after-free.
pub const BaseResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    pub fn resolve(self: BaseResolver, name: []const u8) ?[]const u8 {
        return self.resolveFn(self.ctx, name);
    }
};

/// Cook a `.prefab.etch` source into the neutral model + its registry, the same
/// way `cook` handles `.scene.etch`. A prefab is a mini-scene (one `prefab`
/// construct, body = `{ entity_decl }`, no `resources`/`instance`), serialized to
/// the identical `.scene.bin` format.
///
/// Three forms (`etch-reference-part2.md` §30): a **standalone** prefab cooks its
/// entities directly; a **variant** `prefab "Y" of "X"` resolves `X`'s cooked
/// `.prefab.bin` via `base_resolver`, inherits all of X's flattened components,
/// and applies Y's per-entity overrides (field-merge on shared components, add on
/// new ones) — producing the fully flattened set. An **extension** `extends` is
/// rejected here (`error.ExtendsUnsupported`) — its cook is M1.0.6 E5.
///
/// `base_resolver` may be null for a standalone prefab; an `of` prefab requires
/// it. On failure returns a `CookError` and sets `diag_out` (if non-null).
pub fn cookPrefab(
    gpa: std.mem.Allocator,
    source: []const u8,
    base_resolver: ?BaseResolver,
    diag_out: ?*[]const u8,
) CookError!Cooked {
    const parser = @import("parser.zig");
    var pr = parser.parse(gpa, source) catch return fail(diag_out, error.ParseFailed, "Etch parse failed (allocator error)");
    defer pr.deinit(gpa);
    if (pr.diagnostics.len > 0) return fail(diag_out, error.ParseFailed, "Etch parse failed");
    const ast = &pr.ast;

    var registry = Registry.init();
    errdefer registry.deinit(gpa);

    var b = Builder.init(gpa, ast, &registry);
    defer b.deinitScratch();
    errdefer b.arena.deinit();

    try b.registerDecls(diag_out);
    const prefab_decl = try b.findPrefab(diag_out);
    const model = try b.buildPrefab(prefab_decl, base_resolver, diag_out);

    // `model` owns the cook arena by value — a copy of `b.arena` (buildPrefab:
    // `.arena = self.arena`). A failing `toOwnedSlice` here is already covered by
    // `errdefer b.arena.deinit()` above: same buffers, freed once. Do NOT add
    // `errdefer model.deinit()` — it double-frees the aliased arena.
    return .{ .model = model, .registry = registry };
}

// ── Builder ──────────────────────────────────────────────────────────────────

/// One in-progress entity, accumulated before archetype grouping. `comp_ids` is
/// sorted ascending and `comp_blobs[i]` is the `componentSize(comp_ids[i])`-byte
/// component blob for that entity (both in the model arena).
const EntityBuild = struct {
    name_idx: u32,
    uuid_idx: u32,
    parent_name: []const u8, // "" if root; resolved to a uuid index after all entities seen
    comp_ids: []ComponentId,
    comp_blobs: [][]u8,
};

/// An unresolved entity→entity reference recorded during the scene build phase
/// (M1.0.6 E4). The target is kept as a NAME (not yet resolved): a forward
/// reference may name an entity declared later, so `name → uuid` resolution waits
/// until `name_to_uuid_idx` is complete (the two-phase crossref pass). The source
/// entity's `uuid` ordinal is already known (its identity was interned before its
/// components were built).
const CrossRefPending = struct {
    source_uuid_idx: u32,
    component_id: ComponentId,
    field_offset: u32,
    target_name: []const u8,
};

const Builder = struct {
    gpa: std.mem.Allocator,
    ast: *const AstArena,
    registry: *Registry,
    arena: std.heap.ArenaAllocator,

    // Scratch (gpa-owned, freed by `deinitScratch`).
    bridge: Bridge,
    literals: std.ArrayListUnmanaged([*]u8) = .empty,
    string_map: std.StringHashMapUnmanaged(u32) = .empty,
    uuid_map: std.AutoHashMapUnmanaged([16]u8, u32) = .empty,
    name_to_uuid_idx: std.StringHashMapUnmanaged(u32) = .empty,

    // Model tables (arena-owned, become the CookModel slices).
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    uuids: std.ArrayListUnmanaged([16]u8) = .empty,

    // Cross-references (M1.0.6 E4): collected only for a scene cook
    // (`collect_crossrefs`), resolved name→uuid after all entities are built.
    // A prefab cook leaves `collect_crossrefs` false — its Entity slots stay
    // `dead` and emit no cross-ref entry.
    collect_crossrefs: bool = false,
    pendings: std.ArrayListUnmanaged(CrossRefPending) = .empty,

    // Active extensions (M1.0.6 E5, scene cook): per-entity `extensions:` clauses
    // → Entity Extensions Table + a deduplicated Prefab ID Table (extension names
    // as `strings` indices). `prefab_id_map` dedups a name's `strings` index → its
    // Prefab ID Table slot.
    ext_entries: std.ArrayListUnmanaged(format.ExtModelEntry) = .empty,
    prefab_id_table: std.ArrayListUnmanaged(u32) = .empty,
    prefab_id_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    fn init(gpa: std.mem.Allocator, ast: *const AstArena, registry: *Registry) Builder {
        return .{
            .gpa = gpa,
            .ast = ast,
            .registry = registry,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .bridge = Bridge.init(),
        };
    }

    /// Free everything NOT owned by the produced model: the bridge, the immortal
    /// persistent default blocks `compileTypeDecl` allocated, and the scratch
    /// hashmaps. The model arena is transferred to the caller (not freed here).
    fn deinitScratch(self: *Builder) void {
        for (self.literals.items) |block| persistent.destroy(self.gpa, block);
        self.literals.deinit(self.gpa);
        self.bridge.deinit(self.gpa);
        self.string_map.deinit(self.gpa);
        self.uuid_map.deinit(self.gpa);
        self.name_to_uuid_idx.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.uuids.deinit(self.gpa);
        self.pendings.deinit(self.gpa);
        self.ext_entries.deinit(self.gpa);
        self.prefab_id_table.deinit(self.gpa);
        self.prefab_id_map.deinit(self.gpa);
    }

    fn a(self: *Builder) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Pass A: register every `component`/`resource` declaration into the
    /// registry via the shared `interp.compileTypeDecl` path.
    fn registerDecls(self: *Builder, diag_out: ?*[]const u8) CookError!void {
        const kinds = self.ast.items.items(.kind);
        const datas = self.ast.items.items(.data);
        var i: usize = 0;
        while (i < self.ast.items.len) : (i += 1) {
            switch (kinds[i]) {
                .component_decl => {
                    const decl = self.ast.component_decls.items[datas[i]];
                    // The cook resolves the mode through the SAME resolver the
                    // interpreter uses (`interp.storageModeOf`). Its registry is
                    // a throwaway used for layout and size, and the on-disk
                    // format carries no mode (`engine-scene-serialization.md`
                    // §4) — but two registries built from one declaration that
                    // disagreed about it would be a divergence waiting for its
                    // first reader, and resolving costs one accessor call.
                    _ = self.registerOne(self.ast.strings.slice(decl.name), decl.fields_start, decl.fields_len, .component, types_mod.storageModeOf(self.ast, decl), diag_out) catch |e| return e;
                },
                .resource_decl => {
                    const decl = self.ast.resource_decls.items[datas[i]];
                    // `.table`: `@storage` is component-only, so a resource has
                    // no mode to read (mirror of `compileResource`).
                    _ = self.registerOne(self.ast.strings.slice(decl.name), decl.fields_start, decl.fields_len, .resource, .table, diag_out) catch |e| return e;
                },
                else => {},
            }
        }
    }

    fn registerOne(
        self: *Builder,
        name: []const u8,
        fields_start: u32,
        fields_len: u32,
        reg_kind: interp.RegKind,
        storage: weld_core.ecs.registry.StorageKind,
        diag_out: ?*[]const u8,
    ) CookError!ComponentId {
        return interp.compileTypeDecl(self.gpa, self.ast, self.registry, &self.bridge, name, fields_start, fields_len, reg_kind, storage, &self.literals) catch |e| switch (e) {
            error.InvalidProgram => fail(diag_out, error.UnsupportedFieldKind, "component/resource field has an unsupported type (only scalars, plus resource string/enum, are cookable)"),
            error.DuplicateComponent => fail(diag_out, error.DuplicateType, "component/resource type declared more than once"),
            else => error.OutOfMemory,
        };
    }

    /// Locate the single `scene` construct, erroring if there are zero or many.
    fn findScene(self: *Builder, diag_out: ?*[]const u8) CookError!ast_mod.SceneDecl {
        const kinds = self.ast.items.items(.kind);
        const datas = self.ast.items.items(.data);
        var found: ?ast_mod.SceneDecl = null;
        var i: usize = 0;
        while (i < self.ast.items.len) : (i += 1) {
            if (kinds[i] != .scene_decl) continue;
            if (found != null) return fail(diag_out, error.MultipleScenes, "more than one scene construct in the source");
            found = self.ast.scene_decls.items[datas[i]];
        }
        return found orelse fail(diag_out, error.NoSceneConstruct, "no scene construct in the source");
    }

    /// Locate the single `prefab` construct, erroring if there are zero or many,
    /// or if a `scene` construct is present (a `.prefab.etch` holds exactly one
    /// `prefab` and no `scene`). The M1.0.6 E2 twin of `findScene`.
    fn findPrefab(self: *Builder, diag_out: ?*[]const u8) CookError!ast_mod.PrefabDecl {
        const kinds = self.ast.items.items(.kind);
        const datas = self.ast.items.items(.data);
        var found: ?ast_mod.PrefabDecl = null;
        var i: usize = 0;
        while (i < self.ast.items.len) : (i += 1) {
            switch (kinds[i]) {
                .scene_decl => return fail(diag_out, error.SceneNotAllowedInPrefab, "a scene construct in a prefab source (.prefab.etch holds exactly one prefab)"),
                .prefab_decl => {
                    if (found != null) return fail(diag_out, error.MultiplePrefabs, "more than one prefab construct in the source");
                    found = self.ast.prefab_decls.items[datas[i]];
                },
                // M1.1.15.2 G1 — `service_decl` reaches this `else` and that is
                // the decision, not an oversight: a `service` exists only in a
                // `.d.etch` (`etch-grammar.md` §20.4), which is never a scene or
                // prefab source. The switch is `else`-terminated, so the
                // compiler could not have raised the question; it is answered
                // here instead.
                else => {},
            }
        }
        return found orelse fail(diag_out, error.NoPrefabConstruct, "no prefab construct in the source");
    }

    /// Build the full neutral model from the resolved scene. Direct entities cook
    /// from their component instances; `instance of "P"` children are flattened —
    /// the prefab's components are inherited from `P.prefab.bin` (via the resolver)
    /// and the instance's overrides applied (M1.0.6 E3).
    fn build(self: *Builder, scene_decl: ast_mod.SceneDecl, base_resolver: ?BaseResolver, diag_out: ?*[]const u8) CookError!format.CookModel {
        // Scene cook collects entity→entity cross-references (an `Entity` field's
        // slot is left `dead` and a pending reference recorded); a prefab cook does
        // not (it leaves `collect_crossrefs` false).
        self.collect_crossrefs = true;
        const children = self.ast.scene_children.items[scene_decl.children_start .. scene_decl.children_start + scene_decl.children_len];

        // Per-entity build, accumulating the name→uuid-index map for parent +
        // cross-reference resolution in a second pass.
        var entities: std.ArrayListUnmanaged(EntityBuild) = .empty;
        defer entities.deinit(self.gpa);
        for (children) |child| {
            var ext_start: u32 = 0;
            var ext_len: u32 = 0;
            const eb = switch (child.kind) {
                .entity => blk: {
                    const e = self.ast.scene_entities.items[child.index];
                    ext_start = e.extensions_start;
                    ext_len = e.extensions_len;
                    break :blk try self.buildEntity(e, diag_out);
                },
                .instance => blk: {
                    const inst = self.ast.scene_instances.items[child.index];
                    ext_start = inst.extensions_start;
                    ext_len = inst.extensions_len;
                    break :blk try self.buildInstanceEntity(inst, base_resolver, diag_out);
                },
            };
            try self.recordExtensions(eb.uuid_idx, ext_start, ext_len);
            // Additive-conflict gate (§30.5, M1.1.1-HF4): a FATAL cook error unless
            // the entity's {base components} ∪ {active extensions' components} is
            // conflict-free — three rejected forms: (a) two extensions declare the
            // same component, (b) an extension declares a component already carried
            // by the base (or an earlier extension), (c) the same extension is listed
            // twice. Strictly-additive `extends` reject, guaranteeing
            // `cooked ⇒ loadable`. Short-circuits on the first conflict.
            try self.detectExtensionConflicts(eb.comp_ids, ext_start, ext_len, base_resolver, diag_out);
            try entities.append(self.gpa, eb);
        }

        // Resolve `parent` names → parent uuid indices.
        for (entities.items) |*eb| {
            // (the parent index is stamped into the per-archetype EntityEntry below)
            if (eb.parent_name.len != 0 and self.name_to_uuid_idx.get(eb.parent_name) == null) {
                return fail(diag_out, error.ParentNotFound, "entity parent name does not match any entity in the scene");
            }
        }

        const archetypes = try self.groupArchetypes(entities.items);
        const resources = try self.buildResources(scene_decl, diag_out);
        const content_version = try self.sceneContentVersion(scene_decl, diag_out);
        const cross_refs = try self.resolveCrossRefs(diag_out);

        return .{
            .strings = try self.a().dupe([]const u8, self.strings.items),
            .uuids = try self.a().dupe([16]u8, self.uuids.items),
            .resources = resources,
            .archetypes = archetypes,
            .content_version = content_version,
            .cross_refs = cross_refs,
            .ext_entries = try self.a().dupe(format.ExtModelEntry, self.ext_entries.items),
            .prefab_id_table = try self.a().dupe(u32, self.prefab_id_table.items),
            .arena = self.arena,
        };
    }

    /// Record an entity's `extensions:` clause (M1.0.6 E5) into the Entity
    /// Extensions Table: intern each extension name (by name, D-B) into the model
    /// strings + the deduplicated Prefab ID Table, and append an `ExtModelEntry`
    /// keyed by the entity's uuid ordinal. No-op for an empty/absent clause.
    fn recordExtensions(self: *Builder, uuid_idx: u32, ext_start: u32, ext_len: u32) CookError!void {
        if (ext_len == 0) return;
        const ids = try self.a().alloc(u32, ext_len);
        var k: u32 = 0;
        while (k < ext_len) : (k += 1) {
            const name = self.ast.strings.slice(self.ast.scene_extensions.items[ext_start + k]);
            ids[k] = try self.prefabIdIndex(try self.internString(name));
        }
        try self.ext_entries.append(self.gpa, .{ .uuid = uuid_idx, .prefab_ids = ids });
    }

    /// Additive-conflict gate (§30.5, M1.1.1-HF4) — a FATAL cook error unless the
    /// set {entity base components} ∪ {each active extension's components} is
    /// conflict-free. The `extends` model is strictly additive; three forms are
    /// rejected (never resolved by list order), each a fatal `E1797
    /// ExtensionAdditiveConflict`:
    ///   (a) two active extensions declare the same component;
    ///   (b) an extension declares a component already carried by the base
    ///       (or an earlier extension);
    ///   (c) the same extension is listed twice in the `extensions:` clause.
    /// This guarantees `cooked ⇒ loadable` (runtime backstops:
    /// `error.ExtensionComponentConflict` for a/b, `error.ExtensionAlreadyActive`
    /// for c). Short-circuits on the FIRST conflict (no enumeration); the
    /// duplicate-extension form carries a distinct static message.
    ///
    /// Structure (two passes): form (c) is a PURE LEXICAL pass over the extension
    /// names, independent of any resolver — it fires even when `base_resolver` is
    /// null (the public `cook` entry), so a duplicate never cooks into a load-time
    /// `ExtensionAlreadyActive`. Forms (a)/(b) need each extension's component set
    /// (resolved through the SAME prefab path as `of`/`extends`), so they run only
    /// when a resolver is present and are UNIFIED by seeding `counts` with the
    /// entity's BASE components at 1 each: a component name reaching 2 is a conflict
    /// whether the earlier declarant was the base seed or another extension. No
    /// `ext_len < 2` early-out — a single extension can conflict with the base.
    /// Best-effort for a/b: an extension whose name does not resolve, whose bytes do
    /// not open, whose hash mismatches, or whose structure is invalid is SKIPPED
    /// (the runtime reject is the invariant backstop for the resolver-less path).
    /// See `engine-scene-serialization.md` (extension additive conflicts).
    fn detectExtensionConflicts(
        self: *Builder,
        base_comp_ids: []const ComponentId,
        ext_start: u32,
        ext_len: u32,
        base_resolver: ?BaseResolver,
        diag_out: ?*[]const u8,
    ) CookError!void {
        // Pass 1 — form (c): a PURE LEXICAL check, no resolver needed. The same
        // extension listed twice is a fatal conflict; running BEFORE the resolver
        // guard means `cook` (always a null resolver) still rejects it rather than
        // cooking a scene that fails at load with `ExtensionAlreadyActive`.
        {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(self.gpa);
            var k: u32 = 0;
            while (k < ext_len) : (k += 1) {
                const ext_name = self.ast.strings.slice(self.ast.scene_extensions.items[ext_start + k]);
                const gop = try seen.getOrPut(self.gpa, ext_name);
                if (gop.found_existing) return fail(diag_out, error.ExtensionAdditiveConflict, "the same extension is listed more than once in an entity's `extensions:` clause; the `extends` model is strictly additive — reject (E1797 ExtensionAdditiveConflict)");
            }
        }

        // Forms (a)/(b) need the extensions' component sets (the prefab path). Without
        // a resolver they cannot be checked here; the runtime reject is the backstop.
        const resolver = base_resolver orelse return;

        // Pass 2 — forms (a) ext-vs-ext and (b) ext-vs-base, UNIFIED: seed the base
        // components at 1 each, then count each extension's components; a name
        // reaching 2 is fatal. Extension names are unique here (pass 1 guaranteed it).
        // Base names borrow the registry (owned, live for the whole cook); extension
        // names borrow the resolver-owned bytes.
        var counts: std.StringHashMapUnmanaged(u32) = .empty;
        defer counts.deinit(self.gpa);
        for (base_comp_ids) |id| try counts.put(self.gpa, self.registry.componentName(id), 1);

        var k: u32 = 0;
        while (k < ext_len) : (k += 1) {
            const ext_name = self.ast.strings.slice(self.ast.scene_extensions.items[ext_start + k]);
            const bytes = resolver.resolve(ext_name) orelse continue;
            var acc = accessor.Accessor.open(bytes) catch continue;
            if (!acc.verifyHash()) continue;
            // P1#3 (HF3/R1 accessor contract): structurally validate BEFORE calling
            // any getter — a malformed-but-rehashed prefab (hash valid, structure
            // invalid) would otherwise panic on `schemaCount`/`schema` reads.
            validate.structure(acc.bytes, acc.header) catch continue;

            // Each component the extension declares (its `.prefab.bin` schema table;
            // names unique per prefab) bumps that name's distinct-declarant count.
            // Reaching 2 is the conflict — form (a) if the prior declarant was another
            // extension, form (b) if it was the base seed — a fatal cook error,
            // short-circuiting on the first. Keys borrow the accessor bytes
            // (resolver-owned, live for the whole cook) and compare by content.
            var ci: u32 = 0;
            while (ci < acc.schemaCount()) : (ci += 1) {
                const comp_name = acc.schema(ci).name;
                const gop = try counts.getOrPut(self.gpa, comp_name);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                if (gop.value_ptr.* == 2) return fail(diag_out, error.ExtensionAdditiveConflict, "a component is carried by more than one active declarant (base or extension) on an entity; the `extends` model is strictly additive — reject (E1797 ExtensionAdditiveConflict)");
            }
        }
    }

    /// The Prefab ID Table slot for a model-`strings` index, deduplicated.
    fn prefabIdIndex(self: *Builder, str_idx: u32) CookError!u32 {
        const gop = try self.prefab_id_map.getOrPut(self.gpa, str_idx);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.prefab_id_table.items.len);
            try self.prefab_id_table.append(self.gpa, str_idx);
        }
        return gop.value_ptr.*;
    }

    /// Phase 2 of the crossref pass: resolve every pending `target_name` against
    /// the now-complete `name_to_uuid_idx` (a reference can name an entity declared
    /// later in the scene), producing the model's `CrossRef` slice. A target that
    /// is not an entity of the scene → `error.UnresolvedCrossRef` (intra-scene
    /// only; cross-scene references are a future milestone).
    fn resolveCrossRefs(self: *Builder, diag_out: ?*[]const u8) CookError![]format.CrossRef {
        const out = try self.a().alloc(format.CrossRef, self.pendings.items.len);
        for (self.pendings.items, 0..) |p, i| {
            const target = self.name_to_uuid_idx.get(p.target_name) orelse
                return fail(diag_out, error.UnresolvedCrossRef, "Entity field references an entity name absent from the scene");
            out[i] = .{
                .source_uuid = p.source_uuid_idx,
                .component_id = p.component_id,
                .field_offset = p.field_offset,
                .target_uuid = target,
            };
        }
        return out;
    }

    /// Record a pending entity→entity reference for a `.entity_` field set to an
    /// entity-name string literal (the D-B by-name form; there is no `uuid "…"`
    /// form). The slot itself stays `EntityId.dead` — the side-table entry carries
    /// the target, resolved at load. No-op for a prefab cook (`!collect_crossrefs`):
    /// a prefab's Entity slots stay `dead` and emit no entry.
    fn recordCrossRefPending(self: *Builder, source_uuid_idx: u32, component_id: ComponentId, field_offset: u16, value_node: NodeId, diag_out: ?*[]const u8) CookError!void {
        if (!self.collect_crossrefs) return;
        if (self.ast.exprKind(value_node) != .string_lit)
            return fail(diag_out, error.TypeMismatch, "an Entity field value must be the target entity's name (a string literal)");
        try self.pendings.append(self.gpa, .{
            .source_uuid_idx = source_uuid_idx,
            .component_id = component_id,
            .field_offset = field_offset,
            .target_name = self.ast.strings.slice(self.ast.exprData(value_node)),
        });
    }

    /// Build the neutral model from a `prefab` construct (the M1.0.6 E2 twin of
    /// `build`). Standalone prefabs cook their entities directly; an `of` variant
    /// inherits the base prefab's flattened components (read from its cooked
    /// `.prefab.bin` via the accessor) then applies per-entity overrides. A prefab
    /// body is `{ entity_decl }` only — no `resources`/`instance` (§15 l.1624).
    fn buildPrefab(self: *Builder, pd: ast_mod.PrefabDecl, base_resolver: ?BaseResolver, diag_out: ?*[]const u8) CookError!format.CookModel {
        // `requires`/`on_attach`/`on_detach` are valid only with `extends` (§30.5).
        if (pd.relation != .extends and (pd.requires_len != 0 or pd.has_on_attach or pd.has_on_detach))
            return fail(diag_out, error.PrefabHookNotAllowed, "`requires`/`on_attach`/`on_detach` are valid only on an `extends` prefab");

        const prefab_entities = self.ast.scene_entities.items[pd.entities_start .. pd.entities_start + pd.entities_len];

        var entities: std.ArrayListUnmanaged(EntityBuild) = .empty;
        defer entities.deinit(self.gpa);

        if (pd.relation == .of) {
            const base_name = self.ast.strings.slice(pd.relation_target);
            const resolver = base_resolver orelse return fail(diag_out, error.BasePrefabMissing, "`of` variant cooked without a base-prefab resolver");
            const base_bytes = resolver.resolve(base_name) orelse return fail(diag_out, error.BasePrefabMissing, "`of` variant references a base prefab the resolver does not know");
            var acc = accessor.Accessor.open(base_bytes) catch return fail(diag_out, error.BasePrefabCorrupt, "base prefab .prefab.bin failed to open (magic/version)");
            if (!acc.verifyHash()) return fail(diag_out, error.BasePrefabCorrupt, "base prefab .prefab.bin content hash mismatch");
            try self.reconstructBase(acc, &entities, diag_out);
            try self.mergeVariantEntities(prefab_entities, &entities, diag_out);
        } else {
            // Standalone OR extends: the prefab's `entity { components }` block(s)
            // cook directly. For an extension, those are the components added on
            // activation; its hooks + `requires` are handled below.
            for (prefab_entities) |e| {
                const eb = try self.buildEntity(e, diag_out);
                try entities.append(self.gpa, eb);
            }
        }

        // Resolve parent names → uuid indices (same invariant as the scene path).
        for (entities.items) |*eb| {
            if (eb.parent_name.len != 0 and self.name_to_uuid_idx.get(eb.parent_name) == null)
                return fail(diag_out, error.ParentNotFound, "entity parent name does not match any entity in the prefab");
        }

        const archetypes = try self.groupArchetypes(entities.items);
        const content_version = try self.versionFromNode(pd.version, diag_out);
        const hooks = if (pd.relation == .extends) try self.buildExtendsHooks(pd, base_resolver, diag_out) else &[_]format.HookSet{};

        return .{
            .strings = try self.a().dupe([]const u8, self.strings.items),
            .uuids = try self.a().dupe([16]u8, self.uuids.items),
            .resources = &.{},
            .archetypes = archetypes,
            .content_version = content_version,
            .hooks = hooks,
            .arena = self.arena,
        };
    }

    /// Cook an `extends` prefab's hooks (M1.0.6 E5): validate `requires` against
    /// the base `X` (each required component must be present in `X.prefab.bin`),
    /// then render `on_attach`/`on_detach` to canonical Etch **text** (interned
    /// into the model strings; `null` if the hook is absent). Returns a one-element
    /// `HookSet` slice (`hook_count == 1` for an `extends` `.prefab.bin`).
    fn buildExtendsHooks(self: *Builder, pd: ast_mod.PrefabDecl, base_resolver: ?BaseResolver, diag_out: ?*[]const u8) CookError![]format.HookSet {
        try self.validateRequires(pd, base_resolver, diag_out);
        const hooks = try self.a().alloc(format.HookSet, 1);
        hooks[0] = .{
            .on_attach = if (pd.has_on_attach) try self.renderHook(pd.on_attach_start, pd.on_attach_len, diag_out) else null,
            .on_detach = if (pd.has_on_detach) try self.renderHook(pd.on_detach_start, pd.on_detach_len, diag_out) else null,
        };
        return hooks;
    }

    /// Render a hook statement-run to canonical Etch text and intern it into the
    /// model strings, returning its index. The loader (E6) re-parses this text.
    fn renderHook(self: *Builder, body_start: u32, body_len: u32, diag_out: ?*[]const u8) CookError!u32 {
        const text = descriptor.renderStmtRunAlloc(self.gpa, self.ast, body_start, body_len) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(diag_out, error.HookRenderFailed, "extension hook body could not be rendered to text"),
        };
        defer self.gpa.free(text);
        return self.internString(text);
    }

    /// Validate an `extends` prefab's `requires C1, C2, …`: each required component
    /// must be declared by the base `X` (`X.prefab.bin`, read via the resolver).
    /// `error.RequiresNotSatisfied` otherwise (`etch-grammar.md` §15 l.1634).
    fn validateRequires(self: *Builder, pd: ast_mod.PrefabDecl, base_resolver: ?BaseResolver, diag_out: ?*[]const u8) CookError!void {
        if (pd.requires_len == 0) return;
        const base_name = self.ast.strings.slice(pd.relation_target);
        const resolver = base_resolver orelse return fail(diag_out, error.BasePrefabMissing, "`extends … requires` needs a base-prefab resolver to validate against X");
        const base_bytes = resolver.resolve(base_name) orelse return fail(diag_out, error.BasePrefabMissing, "`extends` references a base prefab the resolver does not know");
        var acc = accessor.Accessor.open(base_bytes) catch return fail(diag_out, error.BasePrefabCorrupt, "base prefab .prefab.bin failed to open (magic/version)");
        if (!acc.verifyHash()) return fail(diag_out, error.BasePrefabCorrupt, "base prefab .prefab.bin content hash mismatch");
        var ri: u32 = 0;
        while (ri < pd.requires_len) : (ri += 1) {
            const req = self.ast.strings.slice(self.ast.prefab_requires.items[pd.requires_start + ri]);
            if (!baseHasComponent(acc, req)) return fail(diag_out, error.RequiresNotSatisfied, "`extends … requires` a component the base prefab does not declare");
        }
    }

    /// Reconstruct the base prefab's flattened entities from its cooked
    /// `.prefab.bin` (read via the accessor) as `EntityBuild`s, interning their
    /// names/uuids into the variant's model tables. Each on-disk schema **name**
    /// maps to the variant registry's `ComponentId` (`idOf`) and the column bytes
    /// copy verbatim — the variant inherits all of the base's components. Per
    /// entity, the column order is re-sorted to the variant registry's id order
    /// (the base file is sorted by the *base* registry's ids, which may differ).
    fn reconstructBase(self: *Builder, acc: accessor.Accessor, out: *std.ArrayListUnmanaged(EntityBuild), diag_out: ?*[]const u8) CookError!void {
        // Pass 1 — intern every base entity's name+uuid first: a parent ordinal
        // may point at an entity that lives in a later archetype block.
        var uuid_to_name_idx: std.AutoHashMapUnmanaged([16]u8, u32) = .empty;
        defer uuid_to_name_idx.deinit(self.gpa);
        var ai: u32 = 0;
        while (ai < acc.archetypeCount()) : (ai += 1) {
            const arch = acc.archetype(ai);
            var slot: usize = 0;
            while (slot < arch.entity_count) : (slot += 1) {
                const name_idx = try self.internString(arch.entityName(slot));
                const uuid_bytes = arch.entityUuid(slot).*;
                const uuid_idx = try self.internUuid(uuid_bytes);
                try self.name_to_uuid_idx.put(self.gpa, self.strings.items[name_idx], uuid_idx);
                try uuid_to_name_idx.put(self.gpa, uuid_bytes, name_idx);
            }
        }
        // Pass 2 — one EntityBuild per base entity (components + parent name).
        ai = 0;
        while (ai < acc.archetypeCount()) : (ai += 1) {
            const arch = acc.archetype(ai);
            // Map each column's on-disk schema → variant registry id + validate.
            const ids0 = try self.a().alloc(ComponentId, arch.component_count);
            var c: usize = 0;
            while (c < arch.component_count) : (c += 1) {
                const sch = acc.schema(arch.schemaIndex(c));
                const id = self.registry.idOf(sch.name) orelse return fail(diag_out, error.BaseSchemaMismatch, "base prefab uses a component the variant does not declare");
                if (self.registry.componentSize(id) != sch.size) return fail(diag_out, error.BaseSchemaMismatch, "base prefab component size disagrees with the variant registry layout");
                ids0[c] = id;
            }
            var slot: usize = 0;
            while (slot < arch.entity_count) : (slot += 1) {
                const ids = try self.a().dupe(ComponentId, ids0);
                const blobs = try self.a().alloc([]u8, arch.component_count);
                c = 0;
                while (c < arch.component_count) : (c += 1) blobs[c] = try self.a().dupe(u8, arch.componentSlot(c, slot));
                sortIdsBlobs(ids, blobs);

                const name_idx = try self.internString(arch.entityName(slot));
                const uuid_idx = try self.internUuid(arch.entityUuid(slot).*);
                const parent_ord = arch.entityParent(slot);
                const parent_name: []const u8 = if (parent_ord == format.no_parent) "" else blk: {
                    const pidx = uuid_to_name_idx.get(acc.uuidAt(parent_ord).*) orelse return fail(diag_out, error.BaseSchemaMismatch, "base prefab parent ordinal does not resolve to an entity");
                    break :blk self.strings.items[pidx];
                };
                try out.append(self.gpa, .{
                    .name_idx = name_idx,
                    .uuid_idx = uuid_idx,
                    .parent_name = parent_name,
                    .comp_ids = ids,
                    .comp_blobs = blobs,
                });
            }
        }
    }

    /// Apply each variant entity over the inherited base set: an entity whose name
    /// matches a base entity field-merges/adds its components onto it (identity —
    /// uuid/parent — stays the base's); an entity with a new name is appended as a
    /// fresh entity (its `uuid:` required, like a standalone).
    fn mergeVariantEntities(self: *Builder, variant_entities: []const ast_mod.SceneEntity, entities: *std.ArrayListUnmanaged(EntityBuild), diag_out: ?*[]const u8) CookError!void {
        for (variant_entities) |ve| {
            const vname = self.ast.strings.slice(ve.name);
            if (self.findEntityIdxByName(entities.items, vname)) |idx| {
                try self.applyVariantOverrides(&entities.items[idx], ve, diag_out);
            } else {
                try entities.append(self.gpa, try self.buildEntity(ve, diag_out));
            }
        }
    }

    fn findEntityIdxByName(self: *Builder, entities: []const EntityBuild, name: []const u8) ?usize {
        for (entities, 0..) |eb, i| {
            if (std.mem.eql(u8, self.strings.items[eb.name_idx], name)) return i;
        }
        return null;
    }

    /// Overlay a variant entity's component instances on an inherited base entity:
    /// a re-declared component the base already has is field-merged (base bytes +
    /// the variant's set fields); a component the base lacks is added (registry
    /// default + the variant's fields). Identity (uuid/parent) stays the base's.
    fn applyVariantOverrides(self: *Builder, eb: *EntityBuild, ve: ast_mod.SceneEntity, diag_out: ?*[]const u8) CookError!void {
        const instances = self.ast.component_instances.items[ve.components_start .. ve.components_start + ve.components_len];
        var ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ids.deinit(self.gpa);
        var blobs: std.ArrayListUnmanaged([]u8) = .empty;
        defer blobs.deinit(self.gpa);
        try ids.appendSlice(self.gpa, eb.comp_ids);
        try blobs.appendSlice(self.gpa, eb.comp_blobs);

        for (instances) |ci| {
            const type_name = self.ast.strings.slice(ci.type_name);
            const id = self.registry.idOf(type_name) orelse return fail(diag_out, error.UndeclaredType, "variant entity references an undeclared component type");
            if (indexOfId(ids.items, id)) |ci_idx| {
                // Prefab cook (`collect_crossrefs` false) → `source_uuid_idx` is
                // unused (Entity slots stay `dead`, no pending recorded).
                blobs.items[ci_idx] = try self.mergeComponentBlob(blobs.items[ci_idx], id, ci, eb.uuid_idx, diag_out);
            } else {
                try ids.append(self.gpa, id);
                try blobs.append(self.gpa, try self.buildComponentBlob(id, ci, eb.uuid_idx, diag_out));
            }
        }

        const new_ids = try self.a().dupe(ComponentId, ids.items);
        const new_blobs = try self.a().dupe([]u8, blobs.items);
        sortIdsBlobs(new_ids, new_blobs);
        eb.comp_ids = new_ids;
        eb.comp_blobs = new_blobs;
    }

    /// Copy `base_blob` and apply the variant instance's set fields over it (the
    /// variant override form is `Component { field: value }`; the
    /// `Component.field =` per-field form is scene-instance-only per the grammar).
    /// Components are POD scalar, so every field is a scalar encode.
    fn mergeComponentBlob(self: *Builder, base_blob: []const u8, id: ComponentId, ci: ast_mod.ComponentInstance, source_uuid_idx: u32, diag_out: ?*[]const u8) CookError![]u8 {
        const size = self.registry.componentSize(id);
        const blob = try self.a().alloc(u8, size);
        @memcpy(blob, base_blob);
        const fields = self.ast.struct_lit_fields.items[ci.fields_start .. ci.fields_start + ci.fields_len];
        for (fields) |slf| {
            if (slf.name == 0) return fail(diag_out, error.SpreadUnsupported, "`..spread` is not supported in a component instance");
            const fname = self.ast.strings.slice(slf.name);
            const fd = self.registry.findField(id, fname) orelse return fail(diag_out, error.UnknownField, "variant component instance sets a field the component does not declare");
            if (fd.kind == .entity_) {
                // Base slot is already `dead` (copied); record the reference. The
                // `Component.field =` per-field form is scene-instance-only, so a
                // variant body reaches Entity fields only via this `Comp { … }` form.
                try self.recordCrossRefPending(source_uuid_idx, id, fd.offset, slf.value, diag_out);
            } else {
                try self.encodeScalar(blob, fd, slf.value, diag_out);
            }
        }
        return blob;
    }

    /// Const-evaluate the scene's `version:` field to a `u16` (0 if absent). The
    /// authored content version is otherwise silently lost (it rides through to
    /// `SceneHeader.content_version`).
    fn sceneContentVersion(self: *Builder, scene_decl: ast_mod.SceneDecl, diag_out: ?*[]const u8) CookError!u16 {
        return self.versionFromNode(scene_decl.version, diag_out);
    }

    /// Const-evaluate a `version:` expression node to a `u16` (0 if `.none`).
    /// Shared by the scene cook and the prefab cook — the authored content
    /// version rides through to `SceneHeader.content_version` unchanged.
    fn versionFromNode(self: *Builder, version: NodeId, diag_out: ?*[]const u8) CookError!u16 {
        if (version.isNone()) return 0;
        const v = interp.evalConst(self.ast, version) catch return fail(diag_out, error.NonConstValue, "version must be a constant int");
        const x: i64 = switch (v) {
            .int_ => |n| n,
            else => return fail(diag_out, error.NonConstValue, "version must be an int"),
        };
        return std.math.cast(u16, x) orelse return fail(diag_out, error.NonConstValue, "version out of u16 range");
    }

    fn buildEntity(self: *Builder, e: ast_mod.SceneEntity, diag_out: ?*[]const u8) CookError!EntityBuild {
        const name = self.ast.strings.slice(e.name);
        const name_idx = try self.internString(name);
        const uuid_bytes = try self.parseEntityUuid(e.uuid, diag_out);
        const uuid_idx = try self.internUuid(uuid_bytes);
        // Record name→uuid for parent resolution (last writer wins on dup names;
        // names are unique within a scene per the spec).
        try self.name_to_uuid_idx.put(self.gpa, name, uuid_idx);

        const parent_name: []const u8 = if (e.parent == 0) "" else self.ast.strings.slice(e.parent);

        // Build the per-component blobs, then sort components ascending so the
        // entity's signature matches the archetype's canonical column order.
        const instances = self.ast.component_instances.items[e.components_start .. e.components_start + e.components_len];
        var ids = try self.a().alloc(ComponentId, instances.len);
        var blobs = try self.a().alloc([]u8, instances.len);
        for (instances, 0..) |ci, k| {
            const type_name = self.ast.strings.slice(ci.type_name);
            const id = self.registry.idOf(type_name) orelse return fail(diag_out, error.UndeclaredType, "entity references an undeclared component type");
            ids[k] = id;
            blobs[k] = try self.buildComponentBlob(id, ci, uuid_idx, diag_out);
        }
        // Sort (ids, blobs) together by id ascending (insertion sort — component
        // counts per entity are tiny). `archetype.sortComponentIds` sorts ids
        // alone; we must keep blobs paired, so sort both here.
        sortIdsBlobs(ids, blobs);

        return .{
            .name_idx = name_idx,
            .uuid_idx = uuid_idx,
            .parent_name = parent_name,
            .comp_ids = ids,
            .comp_blobs = blobs,
        };
    }

    /// Flatten an `instance of "P" "name" { … }` into one entity: inherit P's
    /// single entity's components (from `P.prefab.bin` via the resolver), then
    /// apply the instance body's overrides in declaration order — both forms
    /// (`Comp { field: value }` field-merge and `Comp.field = value` per-field) and
    /// added components. M1.0.6 instantiates only single-entity prefabs
    /// (`MultiEntityInstanceUnsupported` otherwise). The instance supplies the
    /// entity's name + uuid (the prefab's template uuid is discarded); instances
    /// are roots (the grammar's `instance_decl` has no `parent:`).
    fn buildInstanceEntity(self: *Builder, inst: ast_mod.SceneInstance, base_resolver: ?BaseResolver, diag_out: ?*[]const u8) CookError!EntityBuild {
        // Resolve + open the prefab first (structural availability before the
        // instance's own field-level validity).
        const prefab_name = self.ast.strings.slice(inst.prefab_name);
        const resolver = base_resolver orelse return fail(diag_out, error.BasePrefabMissing, "scene `instance of` cooked without a prefab resolver (no --prefab-dir?)");
        const base_bytes = resolver.resolve(prefab_name) orelse return fail(diag_out, error.BasePrefabMissing, "`instance of` references a prefab the resolver does not know");
        var acc = accessor.Accessor.open(base_bytes) catch return fail(diag_out, error.BasePrefabCorrupt, "instanced prefab .prefab.bin failed to open (magic/version)");
        if (!acc.verifyHash()) return fail(diag_out, error.BasePrefabCorrupt, "instanced prefab .prefab.bin content hash mismatch");

        // Identity next — cross-ref pendings recorded while applying the body need
        // the source entity's uuid ordinal (the instance's, not the prefab's).
        const name_idx = try self.internString(self.ast.strings.slice(inst.instance_name));
        const uuid_idx = try self.internUuid(try self.parseEntityUuid(inst.uuid, diag_out));
        try self.name_to_uuid_idx.put(self.gpa, self.strings.items[name_idx], uuid_idx);

        // Inherit the prefab's single entity's components (variant-registry ids).
        var ids: std.ArrayListUnmanaged(ComponentId) = .empty;
        defer ids.deinit(self.gpa);
        var blobs: std.ArrayListUnmanaged([]u8) = .empty;
        defer blobs.deinit(self.gpa);
        try self.flattenedPrefabComponents(acc, &ids, &blobs, diag_out);

        // Apply the instance body's overrides in declaration order.
        const members = self.ast.scene_instance_members.items[inst.members_start .. inst.members_start + inst.members_len];
        for (members) |m| switch (m.kind) {
            .component => {
                const ci = self.ast.component_instances.items[m.index];
                const id = self.registry.idOf(self.ast.strings.slice(ci.type_name)) orelse return fail(diag_out, error.UndeclaredType, "instance component references an undeclared component type");
                if (indexOfId(ids.items, id)) |idx| {
                    blobs.items[idx] = try self.mergeComponentBlob(blobs.items[idx], id, ci, uuid_idx, diag_out);
                } else {
                    try ids.append(self.gpa, id);
                    try blobs.append(self.gpa, try self.buildComponentBlob(id, ci, uuid_idx, diag_out));
                }
            },
            .field_override => {
                const fo = self.ast.field_overrides.items[m.index];
                const id = self.registry.idOf(self.ast.strings.slice(fo.type_name)) orelse return fail(diag_out, error.UndeclaredType, "instance field override references an undeclared component type");
                const idx = indexOfId(ids.items, id) orelse return fail(diag_out, error.OverrideTargetMissing, "per-field override targets a component the instance does not carry");
                const fname = self.ast.strings.slice(fo.field);
                const fd = self.registry.findField(id, fname) orelse return fail(diag_out, error.UnknownField, "per-field override sets a field the component does not declare");
                if (fd.kind == .entity_) {
                    // `Targeting.target = "Boss"` on an inherited Entity field →
                    // slot stays `dead`, record the reference (not `encodeScalar`).
                    try self.recordCrossRefPending(uuid_idx, id, fd.offset, fo.value, diag_out);
                } else {
                    try self.encodeScalar(blobs.items[idx], fd, fo.value, diag_out);
                }
            },
        };

        const comp_ids = try self.a().dupe(ComponentId, ids.items);
        const comp_blobs = try self.a().dupe([]u8, blobs.items);
        sortIdsBlobs(comp_ids, comp_blobs);

        return .{
            .name_idx = name_idx,
            .uuid_idx = uuid_idx,
            .parent_name = "",
            .comp_ids = comp_ids,
            .comp_blobs = comp_blobs,
        };
    }

    /// Extract a single-entity prefab's components from its `.prefab.bin`: each
    /// on-disk schema name → the scene registry's `ComponentId` (`idOf`, size
    /// validated), with the column bytes copied. Errors
    /// `MultiEntityInstanceUnsupported` if the prefab holds ≠ 1 entity. Appends
    /// into `ids`/`blobs` (unsorted; the caller sorts after applying overrides).
    fn flattenedPrefabComponents(self: *Builder, acc: accessor.Accessor, ids: *std.ArrayListUnmanaged(ComponentId), blobs: *std.ArrayListUnmanaged([]u8), diag_out: ?*[]const u8) CookError!void {
        var total: u32 = 0;
        var ai: u32 = 0;
        while (ai < acc.archetypeCount()) : (ai += 1) total += acc.archetype(ai).entity_count;
        if (total != 1) return fail(diag_out, error.MultiEntityInstanceUnsupported, "instancing a multi-entity prefab is not supported in M1.0.6 (single-entity only)");

        ai = 0;
        while (ai < acc.archetypeCount()) : (ai += 1) {
            const arch = acc.archetype(ai);
            if (arch.entity_count == 0) continue;
            var c: usize = 0;
            while (c < arch.component_count) : (c += 1) {
                const sch = acc.schema(arch.schemaIndex(c));
                const id = self.registry.idOf(sch.name) orelse return fail(diag_out, error.BaseSchemaMismatch, "instanced prefab uses a component the scene does not declare");
                if (self.registry.componentSize(id) != sch.size) return fail(diag_out, error.BaseSchemaMismatch, "instanced prefab component size disagrees with the scene registry layout");
                try ids.append(self.gpa, id);
                try blobs.append(self.gpa, try self.a().dupe(u8, arch.componentSlot(c, 0)));
            }
        }
    }

    /// Build one component blob (`componentSize` bytes) from the type defaults
    /// overridden by the instance's fields. Scalar fields encode in place; an
    /// `.entity_` field is NOT encoded — its slot keeps the default `EntityId.dead`
    /// and the reference is recorded as a pending cross-ref (`source_uuid_idx` =
    /// the owning entity's uuid ordinal). `string_`/`enum_` are resource-only, so
    /// components never reach those kinds here.
    fn buildComponentBlob(self: *Builder, id: ComponentId, ci: ast_mod.ComponentInstance, source_uuid_idx: u32, diag_out: ?*[]const u8) CookError![]u8 {
        const size = self.registry.componentSize(id);
        const blob = try self.a().alloc(u8, size);
        @memcpy(blob, self.registry.componentDefaultBytes(id));

        const fields = self.ast.struct_lit_fields.items[ci.fields_start .. ci.fields_start + ci.fields_len];
        for (fields) |slf| {
            if (slf.name == 0) return fail(diag_out, error.SpreadUnsupported, "`..spread` is not supported in a component instance");
            const fname = self.ast.strings.slice(slf.name);
            const fd = self.registry.findField(id, fname) orelse return fail(diag_out, error.UnknownField, "component instance sets a field the component does not declare");
            if (fd.kind == .entity_) {
                try self.recordCrossRefPending(source_uuid_idx, id, fd.offset, slf.value, diag_out);
            } else {
                try self.encodeScalar(blob, fd, slf.value, diag_out);
            }
        }
        return blob;
    }

    /// Encode a scalar field value into `blob` at `fd.offset`. Resource string /
    /// enum fields take their own paths (see `buildResources`); this is for the
    /// POD scalar kinds shared by components and resources.
    fn encodeScalar(self: *Builder, blob: []u8, fd: FieldDesc, value: NodeId, diag_out: ?*[]const u8) CookError!void {
        const slot = blob[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))];
        const v = interp.evalConst(self.ast, value) catch return fail(diag_out, error.NonConstValue, "field value is not constant at cook time");
        bridge_mod.writeValueAsBytes(fd.kind, slot, v) catch return fail(diag_out, error.TypeMismatch, "field value type does not match the field kind");
    }

    /// Group built entities by `ComponentSignature` (sorted ids) and transpose
    /// each archetype's per-entity blobs into flat N-element SoA columns.
    fn groupArchetypes(self: *Builder, entities: []const EntityBuild) CookError![]format.ArchetypeBlock {
        // Map signatureBytes → index into the building archetype list.
        var sig_to_idx: std.StringHashMapUnmanaged(usize) = .empty;
        defer sig_to_idx.deinit(self.gpa);
        // Per-archetype scratch: the list of entity indices that belong to it.
        var groups: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
        defer {
            for (groups.items) |*g| g.deinit(self.gpa);
            groups.deinit(self.gpa);
        }
        var sig_ids: std.ArrayListUnmanaged([]const ComponentId) = .empty;
        defer sig_ids.deinit(self.gpa);

        for (entities, 0..) |eb, ei| {
            const key = archetype.signatureBytes(eb.comp_ids);
            const gop = try sig_to_idx.getOrPut(self.gpa, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = groups.items.len;
                try groups.append(self.gpa, .empty);
                try sig_ids.append(self.gpa, eb.comp_ids);
            }
            try groups.items[gop.value_ptr.*].append(self.gpa, ei);
        }

        const blocks = try self.a().alloc(format.ArchetypeBlock, groups.items.len);
        for (groups.items, 0..) |group, gi| {
            const ids = sig_ids.items[gi];
            const n: u32 = @intCast(group.items.len);

            // SoA columns: column c = concat over entities of blob-for-ids[c].
            const columns = try self.a().alloc([]u8, ids.len);
            for (ids, 0..) |id, c| {
                const stride = self.registry.componentSize(id);
                const col = try self.a().alloc(u8, @as(usize, stride) * group.items.len);
                for (group.items, 0..) |ei, slot| {
                    const eb = entities[ei];
                    // The entity's blob for component `id` — find its position in
                    // the entity's (sorted) id list; same sort order as `ids`, so
                    // column index `c` maps to the entity's component index `c`.
                    @memcpy(col[slot * stride ..][0..stride], eb.comp_blobs[c]);
                }
                columns[c] = col;
            }

            const ents = try self.a().alloc(format.EntityEntry, group.items.len);
            for (group.items, 0..) |ei, slot| {
                const eb = entities[ei];
                const parent_idx: u32 = if (eb.parent_name.len == 0)
                    format.no_parent
                else
                    self.name_to_uuid_idx.get(eb.parent_name).?;
                ents[slot] = .{ .name = eb.name_idx, .uuid = eb.uuid_idx, .parent_uuid = parent_idx };
            }

            blocks[gi] = .{
                .component_ids = try self.a().dupe(ComponentId, ids),
                .entity_count = n,
                .columns = columns,
                .entities = ents,
            };
        }
        return blocks;
    }

    /// Build the resource entries from the scene's `resources { … }` block.
    fn buildResources(self: *Builder, scene_decl: ast_mod.SceneDecl, diag_out: ?*[]const u8) CookError![]format.ResourceEntry {
        const insts = self.ast.component_instances.items[scene_decl.resources_start .. scene_decl.resources_start + scene_decl.resources_len];
        const out = try self.a().alloc(format.ResourceEntry, insts.len);
        for (insts, 0..) |ci, ri| {
            const type_name = self.ast.strings.slice(ci.type_name);
            const id = self.registry.idOf(type_name) orelse return fail(diag_out, error.UndeclaredType, "resources block references an undeclared resource type");
            out[ri] = try self.buildResourceEntry(id, ci, diag_out);
        }
        return out;
    }

    fn buildResourceEntry(self: *Builder, id: ComponentId, ci: ast_mod.ComponentInstance, diag_out: ?*[]const u8) CookError!format.ResourceEntry {
        const size = self.registry.componentSize(id);
        const blob = try self.a().alloc(u8, size);
        @memcpy(blob, self.registry.componentDefaultBytes(id));

        // Apply the instance's overrides. Scalars/enums are written into `blob`;
        // string overrides are remembered (by field offset) so the string pass
        // below picks them up. Reject unknown/spread fields.
        const sl_fields = self.ast.struct_lit_fields.items[ci.fields_start .. ci.fields_start + ci.fields_len];
        for (sl_fields) |slf| {
            if (slf.name == 0) return fail(diag_out, error.SpreadUnsupported, "`..spread` is not supported in a resources block");
            const fname = self.ast.strings.slice(slf.name);
            const fd = self.registry.findField(id, fname) orelse return fail(diag_out, error.UnknownField, "resources block sets a field the resource does not declare");
            switch (fd.kind) {
                .string_ => {}, // handled in the string pass below (needs the override expr)
                .enum_ => try self.encodeEnum(blob, fd, slf.value, diag_out),
                else => try self.encodeScalar(blob, fd, slf.value, diag_out),
            }
        }

        // String pass: every `string_` field of the type must be materialized
        // (its default slot holds a process-local pointer, not serializable). The
        // effective bytes are the instance override if present, else the default
        // string the registration interned. Zero the slot and record the ref.
        var string_fields: std.ArrayListUnmanaged(format.StringFieldRef) = .empty;
        defer string_fields.deinit(self.gpa);
        for (self.registry.componentFields(id)) |fd| {
            if (fd.kind != .string_) continue;
            const override_node = self.findFieldOverride(ci, fd.name);
            const bytes = if (override_node) |node|
                try self.stringValueBytes(node, diag_out)
            else
                self.defaultStringBytes(id, fd.offset);
            const str_idx = try self.internString(bytes);
            // Zero the 16-byte slot in `blob` (the default copied a live pointer).
            @memset(blob[fd.offset .. fd.offset + @as(u16, @intCast(FieldKind.string_.sizeBytes()))], 0);
            try string_fields.append(self.gpa, .{ .offset = fd.offset, .str = str_idx });
        }

        return .{
            .schema_id = id,
            .data = blob,
            .string_fields = try self.a().dupe(format.StringFieldRef, string_fields.items),
        };
    }

    /// The instance's override expression for `field_name`, or null.
    fn findFieldOverride(self: *Builder, ci: ast_mod.ComponentInstance, field_name: []const u8) ?NodeId {
        const fields = self.ast.struct_lit_fields.items[ci.fields_start .. ci.fields_start + ci.fields_len];
        for (fields) |slf| {
            if (slf.name == 0) continue;
            if (std.mem.eql(u8, self.ast.strings.slice(slf.name), field_name)) return slf.value;
        }
        return null;
    }

    /// The UTF-8 bytes of a `string_lit` value expression.
    fn stringValueBytes(self: *Builder, node: NodeId, diag_out: ?*[]const u8) CookError![]const u8 {
        if (self.ast.exprKind(node) != .string_lit) return fail(diag_out, error.NonConstValue, "resource string field value must be a string literal");
        return self.ast.strings.slice(self.ast.exprData(node));
    }

    /// The default string bytes interned at registration: read the immortal
    /// `StringSlot` from the registry default bytes (ptr==0 ⇒ empty string).
    fn defaultStringBytes(self: *Builder, id: ComponentId, offset: u16) []const u8 {
        const defaults = self.registry.componentDefaultBytes(id);
        var ss: persistent.StringSlot = undefined;
        @memcpy(std.mem.asBytes(&ss), defaults[offset .. offset + @sizeOf(persistent.StringSlot)]);
        if (ss.ptr == 0) return "";
        const p: [*]const u8 = @ptrFromInt(ss.ptr);
        return p[0..ss.len];
    }

    /// Encode an enum field value (`.variant` tag_path) as its declaration-order
    /// `u32` discriminant.
    fn encodeEnum(self: *Builder, blob: []u8, fd: FieldDesc, value: NodeId, diag_out: ?*[]const u8) CookError!void {
        if (self.ast.exprKind(value) != .tag_path) return fail(diag_out, error.NonConstValue, "resource enum field value must be an enum variant");
        const variant = self.ast.exprData(value);
        const edecl = self.findEnumDecl(fd.enum_type_name_id) orelse return fail(diag_out, error.UnknownEnumVariant, "resource enum field references an unknown enum type");
        const idx = self.enumVariantIndex(edecl, variant) orelse return fail(diag_out, error.UnknownEnumVariant, "resource enum field references an unknown enum variant");
        const disc: u32 = idx;
        @memcpy(blob[fd.offset .. fd.offset + @sizeOf(u32)], std.mem.asBytes(&disc));
    }

    // ── enum AST lookup (free-fn twins of interp's compile-pass helpers) ──

    fn findEnumDecl(self: *Builder, name: StringId) ?ast_mod.EnumDecl {
        for (self.ast.enum_decls.items) |d| {
            if (d.name == name) return d;
        }
        return null;
    }

    fn enumVariantIndex(self: *Builder, edecl: ast_mod.EnumDecl, variant: StringId) ?u32 {
        var i: u32 = 0;
        while (i < edecl.variants_len) : (i += 1) {
            if (self.ast.enum_variants.items[edecl.variants_start + i].name == variant) return i;
        }
        return null;
    }

    // ── string / uuid interning (into the model arena) ──

    fn internString(self: *Builder, bytes: []const u8) CookError!u32 {
        if (self.string_map.get(bytes)) |idx| return idx;
        const owned = try self.a().dupe(u8, bytes);
        const idx: u32 = @intCast(self.strings.items.len);
        try self.strings.append(self.gpa, owned);
        try self.string_map.put(self.gpa, owned, idx);
        return idx;
    }

    fn internUuid(self: *Builder, bytes: [16]u8) CookError!u32 {
        if (self.uuid_map.get(bytes)) |idx| return idx;
        const idx: u32 = @intCast(self.uuids.items.len);
        try self.uuids.append(self.gpa, bytes);
        try self.uuid_map.put(self.gpa, bytes, idx);
        return idx;
    }

    /// Parse an entity `uuid:` string to 16 bytes. An absent `uuid:` is a cook
    /// error (`MissingUuid`): explicit identity is required, and the cook never
    /// auto-generates one (a random UUID would break the re-cook byte-identity
    /// guarantee; deterministic identity is the editor's responsibility).
    fn parseEntityUuid(self: *Builder, uuid_id: StringId, diag_out: ?*[]const u8) CookError![16]u8 {
        if (uuid_id == 0) return fail(diag_out, error.MissingUuid, "entity requires an explicit uuid");
        return parseUuid(self.ast.strings.slice(uuid_id)) orelse fail(diag_out, error.BadUuid, "entity uuid is not a valid canonical UUID");
    }
};

/// Whether the cooked base prefab `acc` declares a component named `name` (used
/// by `extends … requires` validation — scans the on-disk Schema Registry).
fn baseHasComponent(acc: accessor.Accessor, name: []const u8) bool {
    var i: u32 = 0;
    while (i < acc.schemaCount()) : (i += 1) {
        if (std.mem.eql(u8, acc.schema(i).name, name)) return true;
    }
    return false;
}

/// Index of `id` in `ids`, or null. Linear (component counts per entity are tiny).
fn indexOfId(ids: []const ComponentId, id: ComponentId) ?usize {
    for (ids, 0..) |x, i| if (x == id) return i;
    return null;
}

/// Insertion-sort `(ids, blobs)` jointly by `ids` ascending. Component counts
/// per entity are tiny, so insertion sort is both simplest and fastest.
fn sortIdsBlobs(ids: []ComponentId, blobs: [][]u8) void {
    var i: usize = 1;
    while (i < ids.len) : (i += 1) {
        const key_id = ids[i];
        const key_blob = blobs[i];
        var j = i;
        while (j > 0 and ids[j - 1] > key_id) : (j -= 1) {
            ids[j] = ids[j - 1];
            blobs[j] = blobs[j - 1];
        }
        ids[j] = key_id;
        blobs[j] = key_blob;
    }
}

/// Parse a canonical 36-char hyphenated UUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
/// into 16 bytes, or null on any malformation. Hex pairs map to bytes in order.
fn parseUuid(s: []const u8) ?[16]u8 {
    if (s.len != 36) return null;
    var out: [16]u8 = undefined;
    var oi: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (s[i] != '-') return null;
            i += 1;
            continue;
        }
        const hi = hexNibble(s[i]) orelse return null;
        const lo = hexNibble(s[i + 1]) orelse return null;
        out[oi] = (hi << 4) | lo;
        oi += 1;
        i += 2;
    }
    if (oi != 16) return null;
    return out;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ── tests ─────────────────────────────────────────────────────────────────

test "parseUuid round-trips a canonical UUID" {
    const u = parseUuid("7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e").?;
    try std.testing.expectEqual(@as(u8, 0x7b), u[0]);
    try std.testing.expectEqual(@as(u8, 0x4e), u[15]);
    try std.testing.expect(parseUuid("not-a-uuid") == null);
    try std.testing.expect(parseUuid("7b3e2f1a42a34f2b8c9da3f2b1c98d4e") == null); // no hyphens
}

const e1_fixture =
    \\component Position { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 }
    \\component Health { current: int = 100, max: int = 100 }
    \\enum Weather { clear, rain, storm }
    \\resource GameMode { max_players: int = 4, title: string = "arena", weather: Weather = .clear }
    \\scene "ArenaWave1" {
    \\  resources {
    \\    GameMode { max_players: 8, title: "wave1", weather: .storm }
    \\  }
    \\  entity "Spawner" {
    \\    uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e"
    \\    Position { x: 1.0, y: 2.0, z: 3.0 }
    \\  }
    \\  entity "Hero" {
    \\    uuid: "9c4f3a2b-1e7d-4a5c-b8e9-f4d2c3a1b5e6"
    \\    parent: "Spawner"
    \\    Position { x: 10.0, y: 0.0, z: 0.0 }
    \\    Health { current: 75, max: 100 }
    \\  }
    \\}
;

/// Decode the field `field_name` of an entity at `slot` in `block` to a Value
/// (scalar kinds only — the test's components are POD scalars).
fn decodeColumn(reg: *const Registry, block: format.ArchetypeBlock, id: ComponentId, field_name: []const u8, slot: usize) value_mod.Value {
    const col_idx = blk: {
        for (block.component_ids, 0..) |cid, c| if (cid == id) break :blk c;
        unreachable;
    };
    const fd = reg.findField(id, field_name).?;
    const stride = reg.componentSize(id);
    const slot_bytes = block.columns[col_idx][slot * stride ..][0..stride];
    const fb = slot_bytes[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))];
    return bridge_mod.readBytesAsValue(fd.kind, fb);
}

test "cook builds the neutral model from a scene (E1)" {
    const gpa = std.testing.allocator;
    var cooked = try cook(gpa, e1_fixture, null);
    defer cooked.deinit(gpa);

    const model = cooked.model;
    const reg = &cooked.registry;
    const pos = reg.idOf("Position").?;
    const health = reg.idOf("Health").?;
    const game_mode = reg.idOf("GameMode").?;

    // Two archetypes: [Position] (Spawner) and [Position, Health] (Hero).
    try std.testing.expectEqual(@as(usize, 2), model.archetypes.len);

    var solo: ?format.ArchetypeBlock = null; // [Position]
    var pair: ?format.ArchetypeBlock = null; // [Position, Health]
    for (model.archetypes) |blk| {
        if (blk.component_ids.len == 1) solo = blk else pair = blk;
    }
    const s = solo.?;
    const p = pair.?;

    // [Position] archetype — Spawner: one entity, x == 1.0, no parent.
    try std.testing.expectEqual(@as(u32, 1), s.entity_count);
    try std.testing.expectEqual(pos, s.component_ids[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), decodeColumn(reg, s, pos, "x", 0).float_, 1e-6);
    try std.testing.expectEqualStrings("Spawner", model.strings[s.entities[0].name]);
    try std.testing.expectEqual(format.no_parent, s.entities[0].parent_uuid);
    try std.testing.expectEqual(@as(u8, 0x7b), model.uuids[s.entities[0].uuid][0]);

    // [Position, Health] archetype — Hero: sorted ids, x == 10.0, current == 75,
    // parent UUID == Spawner's UUID.
    try std.testing.expectEqual(@as(u32, 1), p.entity_count);
    try std.testing.expect(p.component_ids[0] < p.component_ids[1]); // sorted ascending
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), decodeColumn(reg, p, pos, "x", 0).float_, 1e-6);
    try std.testing.expectEqual(@as(i64, 75), decodeColumn(reg, p, health, "current", 0).int_);
    try std.testing.expect(p.entities[0].parent_uuid != format.no_parent);
    try std.testing.expectEqual(@as(u8, 0x7b), model.uuids[p.entities[0].parent_uuid][0]); // Spawner's uuid

    // Resource GameMode: int override 8, enum .storm == discriminant 2, string "wave1".
    try std.testing.expectEqual(@as(usize, 1), model.resources.len);
    const res = model.resources[0];
    try std.testing.expectEqual(game_mode, res.schema_id);

    const mp = reg.findField(game_mode, "max_players").?;
    try std.testing.expectEqual(@as(i64, 8), bridge_mod.readBytesAsValue(.int_, res.data[mp.offset .. mp.offset + 8]).int_);

    const wf = reg.findField(game_mode, "weather").?;
    var disc: u32 = 0;
    @memcpy(std.mem.asBytes(&disc), res.data[wf.offset .. wf.offset + 4]);
    try std.testing.expectEqual(@as(u32, 2), disc); // .storm

    const tf = reg.findField(game_mode, "title").?;
    var title: ?[]const u8 = null;
    for (res.string_fields) |sf| if (sf.offset == tf.offset) {
        title = model.strings[sf.str];
    };
    try std.testing.expectEqualStrings("wave1", title.?);
}

// The cook's negative cases (instance-of / unsupported field kind / undeclared
// type / missing uuid / unknown field / bad uuid) live in
// `tests/scene/cook_errors_test.zig`.
