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
const bridge_mod = @import("ecs_bridge.zig");
const persistent = @import("persistent.zig");
const value_mod = @import("value.zig");

const weld_core = @import("weld_core");
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;
const FieldDesc = weld_core.ecs.registry.FieldDesc;
const FieldKind = weld_core.ecs.registry.FieldKind;
const archetype = weld_core.ecs.archetype;
const format = weld_core.scene.format;

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
    /// `instance of "Prefab"` — prefab flattening is owned by M1.0.6.
    InstanceOfUnsupported,
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
    /// A `uuid:` string is not a valid canonical UUID.
    BadUuid,
    /// An entity `parent:` name does not match any entity in the scene.
    ParentNotFound,
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

/// Cook an Etch source string into the neutral scene model + its registry.
/// On failure returns a `CookError` and, if `diag_out` is non-null, sets it to a
/// static human-readable message. No `.scene.bin` is produced on failure.
pub fn cook(gpa: std.mem.Allocator, source: []const u8, diag_out: ?*[]const u8) CookError!Cooked {
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
    const model = try b.build(scene_decl, diag_out);

    return .{ .model = model, .registry = registry };
}

fn fail(diag_out: ?*[]const u8, err: CookError, msg: []const u8) CookError {
    if (diag_out) |d| d.* = msg;
    return err;
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
                    _ = self.registerOne(self.ast.strings.slice(decl.name), decl.fields_start, decl.fields_len, .component, diag_out) catch |e| return e;
                },
                .resource_decl => {
                    const decl = self.ast.resource_decls.items[datas[i]];
                    _ = self.registerOne(self.ast.strings.slice(decl.name), decl.fields_start, decl.fields_len, .resource, diag_out) catch |e| return e;
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
        diag_out: ?*[]const u8,
    ) CookError!ComponentId {
        return interp.compileTypeDecl(self.gpa, self.ast, self.registry, &self.bridge, name, fields_start, fields_len, reg_kind, &self.literals) catch |e| switch (e) {
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

    /// Build the full neutral model from the resolved scene.
    fn build(self: *Builder, scene_decl: ast_mod.SceneDecl, diag_out: ?*[]const u8) CookError!format.CookModel {
        // Reject `instance of` up front (M1.0.6 owns prefab flattening).
        const children = self.ast.scene_children.items[scene_decl.children_start .. scene_decl.children_start + scene_decl.children_len];
        for (children) |child| {
            if (child.kind == .instance) return fail(diag_out, error.InstanceOfUnsupported, "`instance of` (prefab instances) is not cooked by M1.0.4 (owned by M1.0.6)");
        }

        // Per-entity build, accumulating the name→uuid-index map for parent
        // resolution in a second pass.
        var entities: std.ArrayListUnmanaged(EntityBuild) = .empty;
        defer entities.deinit(self.gpa);
        for (children) |child| {
            const e = self.ast.scene_entities.items[child.index];
            const eb = try self.buildEntity(e, diag_out);
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

        return .{
            .strings = try self.a().dupe([]const u8, self.strings.items),
            .uuids = try self.a().dupe([16]u8, self.uuids.items),
            .resources = resources,
            .archetypes = archetypes,
            .arena = self.arena,
        };
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
            blobs[k] = try self.buildComponentBlob(id, ci, diag_out);
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

    /// Build one component blob (`componentSize` bytes) from the type defaults
    /// overridden by the instance's fields. Components are POD-strict, so every
    /// field is a scalar — no `string_`/`enum_` slots to special-case here.
    fn buildComponentBlob(self: *Builder, id: ComponentId, ci: ast_mod.ComponentInstance, diag_out: ?*[]const u8) CookError![]u8 {
        const size = self.registry.componentSize(id);
        const blob = try self.a().alloc(u8, size);
        @memcpy(blob, self.registry.componentDefaultBytes(id));

        const fields = self.ast.struct_lit_fields.items[ci.fields_start .. ci.fields_start + ci.fields_len];
        for (fields) |slf| {
            if (slf.name == 0) return fail(diag_out, error.SpreadUnsupported, "`..spread` is not supported in a component instance");
            const fname = self.ast.strings.slice(slf.name);
            const fd = self.registry.findField(id, fname) orelse return fail(diag_out, error.UnknownField, "component instance sets a field the component does not declare");
            try self.encodeScalar(blob, fd, slf.value, diag_out);
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

    /// Parse an entity `uuid:` string to 16 bytes. Absent (`0`) ⇒ all-zero
    /// (deterministic; the cook never auto-generates a random UUID — that would
    /// break the re-cook byte-identity guarantee).
    fn parseEntityUuid(self: *Builder, uuid_id: StringId, diag_out: ?*[]const u8) CookError![16]u8 {
        if (uuid_id == 0) return std.mem.zeroes([16]u8);
        return parseUuid(self.ast.strings.slice(uuid_id)) orelse fail(diag_out, error.BadUuid, "entity uuid is not a valid canonical UUID");
    }
};

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

test "cook rejects instance of (M1.0.6 boundary)" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  instance of "Torch" "T1" { }
        \\}
    ;
    var msg: []const u8 = "";
    try std.testing.expectError(error.InstanceOfUnsupported, cook(gpa, src, &msg));
}

test "cook rejects an undeclared resource type" {
    const gpa = std.testing.allocator;
    const src =
        \\scene "S" {
        \\  resources { Bogus { x: 1 } }
        \\}
    ;
    try std.testing.expectError(error.UndeclaredType, cook(gpa, src, null));
}

test "cook rejects an unsupported component field kind" {
    const gpa = std.testing.allocator;
    const src =
        \\component Spin { axis: Vec3 = [0, 0, 0] }
        \\scene "S" {
        \\  entity "E" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" Spin { } }
        \\}
    ;
    try std.testing.expectError(error.UnsupportedFieldKind, cook(gpa, src, null));
}
