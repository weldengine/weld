//! S3 Etch type-checker — two passes over an `AstArena` produced by the
//! parser. Pass 1 collects top-level symbols (component / resource / rule)
//! and validates field declarations against the S3 builtin type set.
//! Pass 2 resolves the `when` clauses and rule bodies — checking ECS
//! access rules, expression types, and const-evaluable defaults.
//!
//! Behaviour mirrors `briefs/S3-etch-parser-subset.md` Scope /
//! "Type-checker — pass 1 (collect)" and "pass 2 (resolve / check)".
//! Diagnostics use the codes listed in `briefs/S3-etch-parser-subset.md`
//! Scope / Diagnostics typed API.

const std = @import("std");
const ast_mod = @import("ast.zig");
const diag_mod = @import("diagnostics.zig");
const tags_mod = @import("tags.zig");
const token_mod = @import("token.zig");

const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;
const Diagnostic = diag_mod.Diagnostic;
const DiagnosticCode = diag_mod.DiagnosticCode;
const SourceSpan = token_mod.SourceSpan;
const StringId = ast_mod.StringId;

/// Closed enum of Etch primitive types known to the S3 type-checker.
pub const BuiltinType = enum {
    int_,
    float_,
    bool_,
    i32_,
    u32_,
    f32_,
    f64_,
    entity,
    vec3,
    color,
    duration,

    pub fn isNumeric(self: BuiltinType) bool {
        return switch (self) {
            .int_, .float_, .i32_, .u32_, .f32_, .f64_ => true,
            else => false,
        };
    }

    pub fn isInteger(self: BuiltinType) bool {
        return switch (self) {
            .int_, .i32_, .u32_ => true,
            else => false,
        };
    }

    pub fn isFloat(self: BuiltinType) bool {
        return switch (self) {
            .float_, .f32_, .f64_ => true,
            else => false,
        };
    }

    pub fn fromName(name: []const u8) ?BuiltinType {
        if (std.mem.eql(u8, name, "int")) return .int_;
        if (std.mem.eql(u8, name, "float")) return .float_;
        if (std.mem.eql(u8, name, "bool")) return .bool_;
        if (std.mem.eql(u8, name, "i32")) return .i32_;
        if (std.mem.eql(u8, name, "u32")) return .u32_;
        if (std.mem.eql(u8, name, "f32")) return .f32_;
        if (std.mem.eql(u8, name, "f64")) return .f64_;
        if (std.mem.eql(u8, name, "Entity")) return .entity;
        if (std.mem.eql(u8, name, "Vec3")) return .vec3;
        if (std.mem.eql(u8, name, "Color")) return .color;
        if (std.mem.eql(u8, name, "Duration")) return .duration;
        return null;
    }
};

/// Fixed-array carrier for `ResolvedType.array_fixed`: builtin element type +
/// compile-time length. E1 collections hold **builtin primitive** elements
/// only (collections of components / structs are E2); a non-builtin element
/// resolves the whole collection type to `unknown`.
pub const ArrayFixedInfo = struct { elem: BuiltinType, len: u64 };
/// Map carrier for `ResolvedType.map_t`: builtin key + value types (E1).
pub const MapInfo = struct { key: BuiltinType, value: BuiltinType };

/// `ResolvedType` is the type-checker's internal type representation.
pub const ResolvedType = union(enum) {
    builtin: BuiltinType,
    component: StringId, // user-declared component type name
    resource: StringId, // user-declared resource type name
    /// `start..end` range; payload is the (integer) element type (M0.8 v0.6
    /// foundations). Only consumed by `for-in` in E1.
    range: BuiltinType,
    /// `T[N]` fixed-size array (M0.8 collections). Element + compile-time len.
    array_fixed: ArrayFixedInfo,
    /// `T[]` dynamic array / slice (M0.8 collections). Slicing a fixed or
    /// dynamic array yields this.
    array_dyn: BuiltinType,
    /// `[K: V]` map (M0.8 collections).
    map_t: MapInfo,
    /// `Set<T>` set (M0.8 collections).
    set_t: BuiltinType,
    /// A closure value (M0.8 closures). Payload is the closure-expression
    /// `NodeId`; the return type is inferred lazily at each call site (params
    /// bound to the argument types in the caller's scope).
    closure: NodeId,
    /// A `struct` value (M0.8 E2 block 3). Payload is the struct type name. A
    /// struct is a by-value type (not registered with the world); its fields
    /// and inherent methods resolve by name through the symbol table.
    struct_t: StringId,
    /// A C-like `enum` value (M0.8 E2 block 3 tranche B). Payload is the enum
    /// type name; variants resolve by name against the declaration.
    enum_t: StringId,
    /// A generic type variable in scope (M0.8 E2 block 4). Payload is the type-
    /// parameter name. Opaque within a generic body (operations are permissive,
    /// like `unknown`); resolved to a concrete type by inference at the call site.
    generic: StringId,
    /// `T?` optional of a builtin-scalar payload (M0.8 E2 block 5). Non-builtin
    /// payloads (`struct?` / `enum?`) are deferred — they resolve to `.unknown`
    /// (the optional-ness is not tracked; permissive). `if let` / `while let`
    /// unwrap this to the payload builtin.
    optional: BuiltinType,
    /// Type unknown / unresolved. Used as the fallback after a diagnostic
    /// has been emitted; subsequent checks treat `unknown` as wildcard to
    /// avoid cascade errors.
    unknown,

    pub fn eql(a: ResolvedType, b: ResolvedType) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .builtin => |bt| bt == b.builtin,
            .component => |id| id == b.component,
            .resource => |id| id == b.resource,
            .range => |bt| bt == b.range,
            .array_fixed => |info| info.elem == b.array_fixed.elem and info.len == b.array_fixed.len,
            .array_dyn => |elem| elem == b.array_dyn,
            .map_t => |info| info.key == b.map_t.key and info.value == b.map_t.value,
            .set_t => |elem| elem == b.set_t,
            .closure => |node| std.meta.eql(node, b.closure),
            .struct_t => |id| id == b.struct_t,
            .enum_t => |id| id == b.enum_t,
            .generic => |id| id == b.generic,
            .optional => |bt| bt == b.optional,
            .unknown => true,
        };
    }

    /// The element type produced by indexing or iterating this collection,
    /// or `null` if the type is not an indexable/iterable collection.
    pub fn elementType(self: ResolvedType) ?BuiltinType {
        return switch (self) {
            .array_fixed => |info| info.elem,
            .array_dyn => |elem| elem,
            .set_t => |elem| elem,
            else => null,
        };
    }
};

/// Symbol entry in the file-local symbol table built by pass 1.
pub const SymbolKind = enum { component, resource, rule, type_alias, fn_, struct_, enum_, trait_, event_ };

const Symbol = struct {
    kind: SymbolKind,
    name: StringId,
    item_id: NodeId,
};

/// Compose the `methods` map key from a type name and a method name (M0.8 E2
/// block 3). Both are interned `StringId`s; packing into a `u64` gives a
/// collision-free key for the inherent-method lookup.
fn methodKey(type_name: StringId, method_name: StringId) u64 {
    return (@as(u64, type_name) << 32) | @as(u64, method_name);
}

/// Target categories the annotation-applicability check distinguishes
/// (M0.8 D-S3-annot-applicability). E1 had `component` / `resource` / `rule`
/// items and their `field`s; `function` joins with top-level `fn` (E2). No
/// builtin annotation in the current catalogue applies to a `function` (the
/// fn-targeting `@native` / `@shader_fn` are not modelled yet), so only
/// `@custom` is accepted there; `event` joins with the `event` construct
/// (M0.8 E3); other construct targets arrive with their constructs.
const AnnotTarget = enum { component, resource, rule, field, function, event };

/// Whether a builtin annotation kind is valid on `target`
/// (cf. `etch-resolver-types.md` §13.2 + `etch-reference-part3.md` §1-§10).
/// `.custom` is accepted everywhere (plugin-registered, schema validated
/// Phase 3). `@networked` targets `event` (M0.8 E3, `etch-grammar.md` §18.2).
/// `@loc` → expression returns `false` on every current target.
fn annotationAppliesTo(kind: ast_mod.AnnotationKind, target: AnnotTarget) bool {
    return switch (kind) {
        .custom => true,
        .save => target == .component or target == .resource,
        .requires, .storage => target == .component,
        .config, .state => target == .resource,
        .transient => target == .resource or target == .field,
        .phase, .priority, .run_on, .pause_group => target == .rule,
        .id => target == .rule,
        .unit, .range, .hidden, .readonly, .replicated => target == .field,
        .networked => target == .event,
        .loc => false,
    };
}

/// S3 type-checker — runs pass 1 (symbol collection) then pass 2
/// (type resolution + body validation) against an `AstArena`,
/// accumulating diagnostics in a caller-owned list.
pub const TypeChecker = struct {
    gpa: std.mem.Allocator,
    arena: *AstArena,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    /// Symbol table keyed by interned name `StringId`.
    symbols: std.AutoHashMapUnmanaged(StringId, Symbol) = .empty,
    /// Inherent `impl` methods (M0.8 E2 block 3), keyed by `methodKey(type_name,
    /// method_name)` → index into `arena.impl_methods`. Drives the inherent
    /// (kind 1, `etch-resolver-types.md §5.1`) dispatch of `recv.method()` and
    /// the associated-fn dispatch of `Type.assoc()`.
    methods: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Trait impls (`impl Trait for Type [when …]`, M0.8 E2 block 3 tranche C),
    /// in declaration order. The kind-2 trait dispatch (`etch-resolver-types.md
    /// §5.2`) scans this for the receiver type, AFTER inherent (§5.5 order).
    trait_impls: std.ArrayListUnmanaged(TraitImplEntry) = .empty,
    /// Generic type-parameter names currently in scope (M0.8 E2 block 4). Set
    /// while checking a generic `fn` / `impl` / `struct` / `enum` body so a
    /// type annotation naming a param resolves to `.generic` rather than an
    /// undefined symbol. Cleared (save/restore) at the construct boundary.
    generic_scope: std.AutoHashMapUnmanaged(StringId, void) = .empty,
    /// Declared return type of the `fn` / method currently being checked (M0.8
    /// E2), used to type a `return expr` body statement against. `null` outside
    /// a body; `.unit` for a void fn (no `-> type`).
    current_fn_return: ?ResolvedType = null,
    /// Merged global tag table (M0.8 E3, `etch-validation-ecs.md` §5.2), built
    /// between pass 1 and pass 2 from every `tags { ... }` block. `null` until
    /// `buildTags` runs. Pass 2 (tag-op when-conditions / `tag_path` operands,
    /// landed in the query-operator commit) resolves paths against it.
    tag_table: ?tags_mod.TagTable = null,

    /// One `impl Trait for Type [when …]` (M0.8 E2 block 3 tranche C).
    /// `methods_start`/`methods_len` index `arena.impl_methods` (the
    /// impl-provided methods); `when_root` is `RuleDecl.none_when` for an
    /// unconditional impl.
    pub const TraitImplEntry = struct {
        trait_name: StringId,
        type_name: StringId,
        when_root: u32,
        methods_start: u32,
        methods_len: u32,
        span: SourceSpan,
    };

    pub fn deinit(self: *TypeChecker) void {
        self.symbols.deinit(self.gpa);
        self.methods.deinit(self.gpa);
        self.trait_impls.deinit(self.gpa);
        self.generic_scope.deinit(self.gpa);
        if (self.tag_table) |*t| t.deinit(self.gpa);
    }

    /// Build the merged global tag table (M0.8 E3) between pass 1 and pass 2
    /// (`etch-validation-ecs.md` §5.2). Surfaces `E0831`/`E0832` during
    /// construction; the resolved table backs the tag-op when-conditions and
    /// `tag_path` operands checked in pass 2 (query-operator commit).
    fn buildTags(self: *TypeChecker) !void {
        self.tag_table = try tags_mod.TagTable.build(self.gpa, self.arena, self.diagnostics, tags_mod.default_max_tags);
    }

    pub fn check(gpa: std.mem.Allocator, arena: *AstArena, diagnostics: *std.ArrayListUnmanaged(Diagnostic)) !void {
        var tc: TypeChecker = .{
            .gpa = gpa,
            .arena = arena,
            .diagnostics = diagnostics,
        };
        defer tc.deinit();
        try tc.pass1Collect();
        try tc.validateTypeAliases();
        try tc.validateImpls();
        try tc.buildTags();
        try tc.pass2Resolve();
    }

    /// Validate every `type Name = Type` alias once all symbols are known
    /// (M0.8 v0.6 foundations): the alias must ultimately resolve to a
    /// builtin primitive or a declared component/resource. A cyclic or
    /// dangling alias surfaces as E0102 on the alias's target.
    fn validateTypeAliases(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .type_alias) continue;
            const decl = self.arena.type_alias_decls.items[datas[i]];
            const ultimate = self.arena.resolveTypeAliasName(decl.name);
            const uname = self.arena.strings.slice(ultimate);
            if (BuiltinType.fromName(uname) != null) continue;
            if (self.symbols.get(ultimate)) |sym| {
                if (sym.kind == .component or sym.kind == .resource) continue;
            }
            try self.emit(.undefined_symbol, .error_, self.arena.typeNodeSpan(decl.target), "type alias '{s}' does not resolve to a known type", .{self.arena.strings.slice(decl.name)});
        }
    }

    // ─── Pass 1 ──────────────────────────────────────────────────────────

    fn pass1Collect(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        const spans = self.arena.items.items(.span);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            const item_id: NodeId = .{ .category = .item, .index = i };
            const kind = kinds[i];
            const data = datas[i];
            const span = spans[i];
            switch (kind) {
                .component_decl => {
                    const decl = self.arena.component_decls.items[data];
                    try self.registerSymbol(.component, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .component);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, true);
                },
                .resource_decl => {
                    const decl = self.arena.resource_decls.items[data];
                    try self.registerSymbol(.resource, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .resource);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, false);
                },
                .event_decl => {
                    // An `event` is a POD struct of fields (M0.8 E3,
                    // `etch-grammar.md` §5.10; ABI §3.1). Register the symbol,
                    // validate `@networked` applicability, and enforce the same
                    // POD-scalar field surface as component/resource (`true` =
                    // component-style POD wording).
                    const decl = self.arena.event_decls.items[data];
                    try self.registerSymbol(.event_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .event);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, true);
                },
                .rule_decl => {
                    const decl = self.arena.rule_decls.items[data];
                    try self.registerSymbol(.rule, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .rule);
                },
                .fn_decl => {
                    const decl = self.arena.fn_decls.items[data];
                    try self.registerSymbol(.fn_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .function);
                },
                .struct_decl => {
                    // A `struct` is a by-value type (M0.8 E2 block 3). Register
                    // the name and validate fields. Block-3 struct fields are
                    // builtin scalars (the same surface as component/resource
                    // fields); nested-struct / string fields are deferred.
                    const decl = self.arena.struct_decls.items[data];
                    try self.registerSymbol(.struct_, decl.name, item_id, span);
                    // Generic params (M0.8 E2 block 4) in scope so a field typed
                    // by a param (`min: T`) is accepted as a generic field.
                    try self.addGenerics(decl.generics_start, decl.generics_len);
                    defer self.removeGenerics(decl.generics_start, decl.generics_len);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, false);
                },
                .enum_decl => {
                    // A C-like `enum` is a value type (M0.8 E2 block 3 tranche
                    // B). Register the name; validate the variant set is
                    // non-empty and free of duplicate variant names.
                    const decl = self.arena.enum_decls.items[data];
                    try self.registerSymbol(.enum_, decl.name, item_id, span);
                    try self.validateEnumVariants(decl, span);
                },
                .trait_decl => {
                    // Register the trait name (M0.8 E2 block 3 tranche C). Its
                    // methods (abstract + defaults) are looked up on demand from
                    // the `TraitDecl` via the symbol for dispatch / E0214.
                    const decl = self.arena.trait_decls.items[data];
                    try self.registerSymbol(.trait_, decl.name, item_id, span);
                },
                .impl_decl => {
                    // Inherent impl (`impl Type`, §5.1) → the `methods` map;
                    // trait impl (`impl Trait for Type`, §5.2) → `trait_impls`.
                    // Bodies are checked in pass 2 (`checkImplMethod`).
                    const impl = self.arena.impl_decls.items[data];
                    if (impl.trait_name == 0) {
                        try self.collectImplMethods(impl, span);
                    } else {
                        try self.trait_impls.append(self.gpa, .{
                            .trait_name = impl.trait_name,
                            .type_name = impl.type_name,
                            .when_root = impl.when_root,
                            .methods_start = impl.methods_start,
                            .methods_len = impl.methods_len,
                            .span = span,
                        });
                    }
                },
                .type_alias => {
                    // Register the alias name so it collides with a same-named
                    // component/resource/rule (E0101); the target is validated
                    // in `validateTypeAliases` once all symbols are known.
                    const decl = self.arena.type_alias_decls.items[data];
                    try self.registerSymbol(.type_alias, decl.name, item_id, span);
                },
                else => {}, // forward-compatible: unknown items ignored
            }
        }
    }

    fn registerSymbol(self: *TypeChecker, kind: SymbolKind, name: StringId, item_id: NodeId, span: SourceSpan) !void {
        const gop = try self.symbols.getOrPut(self.gpa, name);
        if (gop.found_existing) {
            const name_slice = self.arena.strings.slice(name);
            try self.emit(.duplicate_symbol, .error_, span, "duplicate top-level symbol '{s}'", .{name_slice});
            return;
        }
        gop.value_ptr.* = .{ .kind = kind, .name = name, .item_id = item_id };
    }

    /// Index an inherent `impl`'s methods into the `methods` map (M0.8 E2 block
    /// 3, §5.1). Order-independent — the target type need not be declared yet
    /// (top-level decls come in any order); the target is validated separately
    /// in `validateImpls` once all symbols are known. A method name colliding
    /// with another inherent method on the same type is E0101 (the inherent
    /// `AmbiguousInherentMethod` of §7.5, reusing the duplicate-symbol code).
    fn collectImplMethods(self: *TypeChecker, impl: ast_mod.ImplDecl, span: SourceSpan) !void {
        var i: u32 = 0;
        while (i < impl.methods_len) : (i += 1) {
            const m_idx = impl.methods_start + i;
            const method = self.arena.impl_methods.items[m_idx];
            const gop = try self.methods.getOrPut(self.gpa, methodKey(impl.type_name, method.name));
            if (gop.found_existing) {
                try self.emit(.duplicate_symbol, .error_, span, "duplicate method '{s}' on type '{s}'", .{ self.arena.strings.slice(method.name), self.arena.strings.slice(impl.type_name) });
            } else {
                gop.value_ptr.* = m_idx;
            }
        }
    }

    /// Validate every `impl`'s target type once all symbols are known (M0.8 E2
    /// block 3) — the target must be a declared `struct` / `component` /
    /// `resource`. Coherence / orphan rules (§7.4) and trait impls arrive in
    /// tranche C.
    fn validateImpls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        const spans = self.arena.items.items(.span);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .impl_decl) continue;
            const impl = self.arena.impl_decls.items[datas[i]];
            const tname = self.arena.strings.slice(impl.type_name);
            if (impl.trait_name == 0) {
                // Inherent impl (§5.1): target is a declared struct / component /
                // resource. No coherence (§7.5).
                if (self.symbols.get(impl.type_name)) |sym| {
                    if (sym.kind != .struct_ and sym.kind != .component and sym.kind != .resource) {
                        try self.emit(.undefined_symbol, .error_, spans[i], "impl target '{s}' is not a struct, component, or resource", .{tname});
                    }
                } else {
                    try self.emit(.undefined_symbol, .error_, spans[i], "impl target type '{s}' is not declared", .{tname});
                }
            } else {
                try self.validateTraitImpl(impl, spans[i]);
            }
        }
    }

    /// Validate one `impl Trait for Type [when …]` (M0.8 E2 block 3 tranche C,
    /// `etch-resolver-types.md §7.2/§7.4`). Checks: the trait is declared; the
    /// orphan rule (§7.4 — trait OR type local to this module); every abstract
    /// trait method is provided (E0214, else the trait must supply a default);
    /// the target type is a struct / component / resource / `Entity`.
    fn validateTraitImpl(self: *TypeChecker, impl: ast_mod.ImplDecl, span: SourceSpan) !void {
        const trait_slice = self.arena.strings.slice(impl.trait_name);
        const type_slice = self.arena.strings.slice(impl.type_name);

        // The trait must be a declared `trait`.
        const trait_sym = self.symbols.get(impl.trait_name);
        const trait_local = trait_sym != null and trait_sym.?.kind == .trait_;
        if (!trait_local) {
            try self.emit(.undefined_symbol, .error_, span, "trait '{s}' is not declared", .{trait_slice});
            return; // nothing further provable without the trait
        }

        // The target type must be a local struct / component / resource, or the
        // builtin `Entity` (the conditional-impl receiver, §7.3).
        const type_sym = self.symbols.get(impl.type_name);
        const type_is_entity = std.mem.eql(u8, type_slice, "Entity");
        const type_local = type_sym != null and (type_sym.?.kind == .struct_ or type_sym.?.kind == .component or type_sym.?.kind == .resource or type_sym.?.kind == .enum_);
        if (!type_local and !type_is_entity) {
            try self.emit(.undefined_symbol, .error_, span, "trait-impl target '{s}' is not a struct, component, resource, or Entity", .{type_slice});
        }

        // Orphan rule (§7.4): trait OR type local to the impl's module. In M0.8
        // (single module) the trait is always local, so this holds — the check
        // is structural for the cross-module future.
        if (!trait_local and !type_local) {
            try self.emit(.orphan_impl, .error_, span, "orphan impl: neither trait '{s}' nor type '{s}' is defined in this module", .{ trait_slice, type_slice });
        }

        // E0214: every abstract trait method (no default body) must be provided.
        const tdecl = self.arena.trait_decls.items[self.arena.itemData(trait_sym.?.item_id)];
        var m: u32 = 0;
        while (m < tdecl.methods_len) : (m += 1) {
            const tmethod = self.arena.impl_methods.items[tdecl.methods_start + m];
            if (tmethod.has_body) continue; // default-bodied → optional
            if (!self.implProvidesMethod(impl, tmethod.name)) {
                try self.emit(.incomplete_trait_impl, .error_, span, "impl of trait '{s}' for '{s}' is missing method '{s}'", .{ trait_slice, type_slice, self.arena.strings.slice(tmethod.name) });
            }
        }
    }

    /// `true` if `impl` provides a method named `name` (M0.8 E2 block 3 tranche
    /// C).
    fn implProvidesMethod(self: *TypeChecker, impl: ast_mod.ImplDecl, name: StringId) bool {
        var m: u32 = 0;
        while (m < impl.methods_len) : (m += 1) {
            if (self.arena.impl_methods.items[impl.methods_start + m].name == name) return true;
        }
        return false;
    }

    /// Validate an `enum`'s variant set (M0.8 E2 block 3 tranche B): non-empty,
    /// no duplicate variant names. The grammar already guarantees ≥1 variant,
    /// so the duplicate check is the substantive one (E0101).
    fn validateEnumVariants(self: *TypeChecker, decl: ast_mod.EnumDecl, span: SourceSpan) !void {
        var i: u32 = 0;
        while (i < decl.variants_len) : (i += 1) {
            const vi = self.arena.enum_variants.items[decl.variants_start + i];
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                if (self.arena.enum_variants.items[decl.variants_start + j].name == vi.name) {
                    try self.emit(.duplicate_symbol, .error_, span, "duplicate enum variant '{s}' on enum '{s}'", .{ self.arena.strings.slice(vi.name), self.arena.strings.slice(decl.name) });
                    break;
                }
            }
        }
    }

    /// Look up the declaration-order index of `variant` within the enum named
    /// `enum_name` (M0.8 E2 block 3 tranche B), or `null` if `enum_name` is not
    /// a declared enum or has no such variant.
    fn enumVariantIndex(self: *TypeChecker, enum_name: StringId, variant: StringId) ?u32 {
        const decl = self.enumDecl(enum_name) orelse return null;
        var i: u32 = 0;
        while (i < decl.variants_len) : (i += 1) {
            if (self.arena.enum_variants.items[decl.variants_start + i].name == variant) return i;
        }
        return null;
    }

    /// The `EnumDecl` for `enum_name`, or `null` if it is not a declared enum.
    fn enumDecl(self: *TypeChecker, enum_name: StringId) ?ast_mod.EnumDecl {
        const sym = self.symbols.get(enum_name) orelse return null;
        if (sym.kind != .enum_) return null;
        return self.arena.enum_decls.items[self.arena.itemData(sym.item_id)];
    }

    /// Resolve an inherent method `(type_name, method_name)` to its `FnDecl`
    /// (M0.8 E2 block 3, §5.1), or `null` if no such method exists.
    fn lookupMethod(self: *TypeChecker, type_name: StringId, method_name: StringId) ?ast_mod.FnDecl {
        const idx = self.methods.get(methodKey(type_name, method_name)) orelse return null;
        return self.arena.impl_methods.items[idx];
    }

    fn validateFieldsInDecl(self: *TypeChecker, fields_start: u32, fields_len: u32, is_component: bool) !void {
        // Field name uniqueness within parent: collect into a small set.
        var seen: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer seen.deinit(self.gpa);

        var i: u32 = 0;
        while (i < fields_len) : (i += 1) {
            const field = self.arena.fields.items[fields_start + i];
            const fname = self.arena.strings.slice(field.name);

            // Field-level annotation applicability (M0.8 D-S3-annot-applicability).
            try self.validateAnnotations(field.annotations_extra, field.annotations_len, .field);

            // Check uniqueness.
            const gop = try seen.getOrPut(self.gpa, field.name);
            if (gop.found_existing) {
                const span = self.arena.typeNodeSpan(field.type_node);
                try self.emit(.duplicate_symbol, .error_, span, "duplicate field '{s}'", .{fname});
            }

            // Collection / composite field types (`T[]`, `[K: V]`, `Set<T>`,
            // and fixed `T[N]`) are not part of the E1 component/resource
            // surface — fields stay scalar POD. Reject anything non-named here
            // rather than mis-indexing the `named_types` slab (M0.8 collections
            // land as locals, not fields).
            const tspan = self.arena.typeNodeSpan(field.type_node);
            if (self.arena.typeNodeKind(field.type_node) != .named) {
                try self.emit(.undefined_symbol, .error_, tspan, "collection / composite field types are not supported in E1 — component and resource fields must be scalar POD", .{});
                continue;
            }
            const named_idx = self.arena.typeNodeData(field.type_node);
            const named = self.arena.named_types.items[named_idx];
            // A field typed by an in-scope generic param (`min: T`, M0.8 E2
            // block 4) is a generic field — accepted (type-erased). Only structs
            // are generic; component / resource fields never reach this branch.
            if (self.generic_scope.contains(named.name)) continue;
            const resolved_name = self.arena.resolveTypeAliasName(named.name);
            const tname = self.arena.strings.slice(resolved_name);

            if (BuiltinType.fromName(tname) == null) {
                // Try user-declared component or resource.
                if (self.symbols.get(resolved_name)) |sym| {
                    if (sym.kind == .rule) {
                        try self.emit(.undefined_symbol, .error_, tspan, "type '{s}' is not a component, resource, or builtin", .{tname});
                    }
                    // A field of component-typed or resource-typed value is
                    // still not in the S3 POD builtin set — reject as
                    // unsupported. The brief enforces builtin POD only.
                    try self.emit(.undefined_symbol, .error_, tspan, "type '{s}' is not in the S3 POD builtin set", .{tname});
                } else if (std.mem.eql(u8, tname, "string")) {
                    // `string` rejected on components per brief §POD; for
                    // resources `string` is also out of the S3 builtin set
                    // (resources POD-enforced via the same builtin table).
                    if (is_component) {
                        try self.emit(.undefined_symbol, .error_, tspan, "type 'string' is rejected on components in S3 (POD enforcement)", .{});
                    } else {
                        try self.emit(.undefined_symbol, .error_, tspan, "type 'string' is not in the S3 builtin set", .{});
                    }
                } else {
                    try self.emit(.undefined_symbol, .error_, tspan, "unknown type '{s}'", .{tname});
                }
            }

            // Default value type check + const-evaluability.
            if (!field.default_value.isNone()) {
                try self.checkFieldDefault(field.default_value, field.type_node);
            }
        }
    }

    /// Validate annotation applicability for a `(start, len)` range in
    /// `annot_pool` against the target the annotations decorate (M0.8
    /// D-S3-annot-applicability, cf. `etch-resolver-types.md` §13). Emits
    /// `E0502 AnnotationMisapplied` per offending builtin annotation;
    /// `.custom` (plugin) annotations are accepted on any target.
    /// Argument-schema validation (E0503/E0504) is a separate §13 concern,
    /// out of this debt's scope.
    fn validateAnnotations(self: *TypeChecker, start: u32, len: u32, target: AnnotTarget) !void {
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const annot = self.arena.annot_pool.items[start + i];
            if (!annotationAppliesTo(annot.kind, target)) {
                try self.emit(.annotation_misapplied, .error_, annot.span, "annotation '@{s}' is not valid on a {s}", .{ self.arena.strings.slice(annot.name), @tagName(target) });
            }
        }
    }

    fn checkFieldDefault(self: *TypeChecker, value: NodeId, type_node: NodeId) !void {
        // Const-evaluability check.
        if (!isConstEvaluable(self.arena, value)) {
            try self.emit(.not_const_evaluable, .error_, self.arena.exprSpan(value), "field default value must be a constant expression (literal, arithmetic on literals, or parenthesized)", .{});
            return;
        }
        const declared = self.namedTypeToResolved(type_node);
        const actual = self.synthExpr(value, null);
        if (declared == .builtin and actual == .builtin) {
            if (!self.literalTypeFits(declared.builtin, value, actual.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(value), "default value type does not match declared field type", .{});
            }
        }
        // If declared isn't builtin (e.g. unknown), we already emitted a
        // diagnostic during field-type resolution — skip cascade.
    }

    /// Polymorphic int / float literal rule (cf. `etch-reference-part1.md`
    /// §4.3). When the declared context type is given and the value is a
    /// literal of the same numeric family (int family → any integer
    /// builtin, float family → any float builtin), the literal fits. All
    /// other forms require exact equality (no implicit numeric coercion).
    fn literalTypeFits(self: *TypeChecker, declared: BuiltinType, actual_expr: NodeId, actual: BuiltinType) bool {
        if (declared == actual) return true;
        const kind = self.arena.exprKind(actual_expr);
        if (kind == .int_lit and actual == .int_ and declared.isInteger()) return true;
        if (kind == .float_lit and actual == .float_ and declared.isFloat()) return true;
        // Negative literals via unary minus on a literal also fit when the
        // operand is a matching numeric literal.
        if (kind == .unary) {
            const un = self.arena.unary_exprs.items[self.arena.exprData(actual_expr)];
            if (un.op == .neg) {
                const inner_kind = self.arena.exprKind(un.operand);
                if (inner_kind == .int_lit and actual == .int_ and declared.isInteger()) return true;
                if (inner_kind == .float_lit and actual == .float_ and declared.isFloat()) return true;
            }
        }
        return false;
    }

    /// Resolve a type node to a `ResolvedType`. Despite the historical name it
    /// dispatches on the node kind: `.named` resolves through the alias chain
    /// to a builtin / component / resource; the collection kinds (`.array` /
    /// `.slice` / `.map_type` / `.set_type`, M0.8) resolve their element /
    /// key / value to a builtin (E1 collections carry builtin elements only —
    /// a non-builtin element resolves the whole type to `unknown`).
    fn namedTypeToResolved(self: *TypeChecker, type_node: NodeId) ResolvedType {
        switch (self.arena.typeNodeKind(type_node)) {
            .named => {
                const named_idx = self.arena.typeNodeData(type_node);
                const named = self.arena.named_types.items[named_idx];
                // A type-parameter name in scope resolves to a generic variable
                // (M0.8 E2 block 4), checked before alias / builtin / symbol.
                if (self.generic_scope.contains(named.name)) return .{ .generic = named.name };
                // Resolve through any top-level `type` alias chain first (M0.8).
                const resolved_name = self.arena.resolveTypeAliasName(named.name);
                const tname = self.arena.strings.slice(resolved_name);
                if (BuiltinType.fromName(tname)) |bt| return .{ .builtin = bt };
                if (self.symbols.get(resolved_name)) |sym| {
                    return switch (sym.kind) {
                        .component => .{ .component = resolved_name },
                        .resource => .{ .resource = resolved_name },
                        .struct_ => .{ .struct_t = resolved_name },
                        .enum_ => .{ .enum_t = resolved_name },
                        else => .unknown,
                    };
                }
                return .unknown;
            },
            .generic => {
                // `Foo<T, …>` generic type application (M0.8 E2 block 4). The
                // type arguments are erased (no monomorphisation in M0.8); the
                // result is the base type. A generic param name as the base
                // (e.g. `T<…>`, unusual) resolves to the variable.
                const gt = self.arena.generic_type_nodes.items[self.arena.typeNodeData(type_node)];
                if (self.generic_scope.contains(gt.name)) return .{ .generic = gt.name };
                if (self.symbols.get(gt.name)) |sym| {
                    return switch (sym.kind) {
                        .struct_ => .{ .struct_t = gt.name },
                        .enum_ => .{ .enum_t = gt.name },
                        else => .unknown,
                    };
                }
                return .unknown;
            },
            .array => {
                const at = self.arena.array_types.items[self.arena.typeNodeData(type_node)];
                const elem = self.namedTypeToResolved(at.elem);
                if (elem != .builtin) return .unknown;
                const len = self.constArrayLen(at.size) orelse return .unknown;
                return .{ .array_fixed = .{ .elem = elem.builtin, .len = len } };
            },
            .slice => {
                const at = self.arena.array_types.items[self.arena.typeNodeData(type_node)];
                const elem = self.namedTypeToResolved(at.elem);
                if (elem != .builtin) return .unknown;
                return .{ .array_dyn = elem.builtin };
            },
            .map_type => {
                const mt = self.arena.map_types.items[self.arena.typeNodeData(type_node)];
                const k = self.namedTypeToResolved(mt.key);
                const v = self.namedTypeToResolved(mt.value);
                if (k != .builtin or v != .builtin) return .unknown;
                return .{ .map_t = .{ .key = k.builtin, .value = v.builtin } };
            },
            .set_type => {
                const st = self.arena.set_types.items[self.arena.typeNodeData(type_node)];
                const elem = self.namedTypeToResolved(st.elem);
                if (elem != .builtin) return .unknown;
                return .{ .set_t = elem.builtin };
            },
            .optional => {
                // `T?` (M0.8 E2 block 5). The payload type-node is stored as the
                // type-node data. A builtin-scalar payload → `.optional(bt)`;
                // a non-builtin payload (`struct?`/`enum?`) is deferred → `.unknown`.
                const payload_node: NodeId = @bitCast(self.arena.typeNodeData(type_node));
                const payload = self.namedTypeToResolved(payload_node);
                if (payload != .builtin) return .unknown;
                return .{ .optional = payload.builtin };
            },
            else => return .unknown,
        }
    }

    /// Const-fold a fixed-array size node to its `u64` length. E1 accepts a
    /// bare integer literal (`int[8]`); a more general const expression is a
    /// later refinement, so anything else returns `null` (→ `unknown` type).
    fn constArrayLen(self: *TypeChecker, size_node: NodeId) ?u64 {
        if (size_node.isNone()) return null;
        if (self.arena.exprKind(size_node) != .int_lit) return null;
        const text = self.arena.strings.slice(self.arena.exprData(size_node));
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    // ─── Pass 2 ──────────────────────────────────────────────────────────

    fn pass2Resolve(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            const kind = kinds[i];
            const data = datas[i];
            switch (kind) {
                .rule_decl => try self.checkRule(self.arena.rule_decls.items[data]),
                .fn_decl => try self.checkFn(self.arena.fn_decls.items[data]),
                .impl_decl => try self.checkImpl(self.arena.impl_decls.items[data]),
                else => {},
            }
        }
    }

    /// Type-check every method of an inherent `impl` (M0.8 E2 block 3). Each
    /// method is checked like a `fn`, with `self` bound (for `self` / `mut self`
    /// receivers) to the impl's target type so `self.field` / `self.method()`
    /// resolve. Associated fns (`self_kind == .none`) bind no receiver.
    fn checkImpl(self: *TypeChecker, impl: ast_mod.ImplDecl) !void {
        // The receiver type for `self`: the impl's target. A declared struct →
        // `.struct_t`; a component / resource → their resolved type; the builtin
        // `Entity` (a trait impl `impl Trait for Entity`) → `.entity`; anything
        // else (validateImpls already flagged it) → `unknown`.
        const self_type: ResolvedType = if (self.symbols.get(impl.type_name)) |sym| switch (sym.kind) {
            .struct_ => .{ .struct_t = impl.type_name },
            .component => .{ .component = impl.type_name },
            .resource => .{ .resource = impl.type_name },
            else => ResolvedType.unknown,
        } else if (std.mem.eql(u8, self.arena.strings.slice(impl.type_name), "Entity"))
            .{ .builtin = .entity }
        else
            ResolvedType.unknown;

        // Impl-level generics (`impl<T> …`, M0.8 E2 block 4) are in scope for
        // every method body.
        try self.addGenerics(impl.generics_start, impl.generics_len);
        defer self.removeGenerics(impl.generics_start, impl.generics_len);

        var i: u32 = 0;
        while (i < impl.methods_len) : (i += 1) {
            try self.checkImplMethod(self.arena.impl_methods.items[impl.methods_start + i], self_type, impl.when_root);
        }
    }

    /// Type-check one `impl` method body (M0.8 E2 block 3). Mirrors `checkFn`
    /// but, when the method takes a `self` receiver, binds `self` to the impl's
    /// target type first so the body's `self.field` / `self.method()` resolve.
    /// A conditional trait impl's `when` (`impl Trait for Entity when self has
    /// H`, tranche C) is folded into the method's accessible-component set so
    /// `self.get(H)` / `self.get_mut(H)` are allowed in the body (§7.3).
    fn checkImplMethod(self: *TypeChecker, decl: ast_mod.FnDecl, self_type: ResolvedType, when_root: u32) !void {
        var ctx: RuleCtx = .{};
        defer ctx.deinit(self.gpa);

        // The method's own generics (M0.8 E2 block 4) — additive to the impl's
        // (already in scope via `checkImpl`).
        try self.addGenerics(decl.generics_start, decl.generics_len);
        defer self.removeGenerics(decl.generics_start, decl.generics_len);

        if (decl.self_kind != .none) {
            const self_id = try self.arena.strings.intern(self.gpa, "self");
            try ctx.locals.put(self.gpa, self_id, .{ .type_ = self_type, .is_mut = decl.self_kind == .by_mut });
        }
        if (when_root != ast_mod.RuleDecl.none_when) try self.collectWhen(&ctx, when_root);

        var i: u32 = 0;
        while (i < decl.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[decl.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            if (ptype == .unknown) {
                try self.emit(.undefined_symbol, .error_, self.arena.typeNodeSpan(p.type_node), "unknown or unsupported parameter type on method '{s}'", .{self.arena.strings.slice(decl.name)});
            }
            try ctx.locals.put(self.gpa, p.name, .{ .type_ = ptype, .is_mut = false });
        }

        const ret_t: ResolvedType = if (decl.return_type.isNone())
            ResolvedType.unknown
        else
            self.namedTypeToResolved(decl.return_type);
        const saved_ret = self.current_fn_return;
        self.current_fn_return = ret_t;
        defer self.current_fn_return = saved_ret;

        var s: u32 = 0;
        while (s < decl.body_len) : (s += 1) {
            try self.checkStmt(&ctx, @bitCast(self.arena.extra.items[decl.body_start + s]));
        }

        if (!decl.value.isNone()) {
            const vt = self.synthExpr(decl.value, &ctx);
            if (!decl.return_type.isNone() and ret_t == .builtin and vt == .builtin and !self.literalTypeFits(ret_t.builtin, decl.value, vt.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(decl.value), "method '{s}' body value type does not match its declared return type", .{self.arena.strings.slice(decl.name)});
            }
        }
    }

    /// Per-rule context: components accessible via `entity.get(T)` and
    /// resources accessible via `get(T)` (without receiver) as derived
    /// from the `when` clause.
    const RuleCtx = struct {
        components_in_when: std.AutoHashMapUnmanaged(StringId, void) = .empty,
        resources_in_when: std.AutoHashMapUnmanaged(StringId, void) = .empty,
        /// Local variables in the rule body, keyed by name.
        locals: std.AutoHashMapUnmanaged(StringId, Local) = .empty,

        pub const Local = struct { type_: ResolvedType, is_mut: bool };

        pub fn deinit(self: *RuleCtx, gpa: std.mem.Allocator) void {
            self.components_in_when.deinit(gpa);
            self.resources_in_when.deinit(gpa);
            self.locals.deinit(gpa);
        }
    };

    fn checkRule(self: *TypeChecker, rule: ast_mod.RuleDecl) !void {
        var ctx: RuleCtx = .{};
        defer ctx.deinit(self.gpa);

        // Resolve rule params.
        var i: u32 = 0;
        while (i < rule.params_len) : (i += 1) {
            const p = self.arena.rule_params.items[rule.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            if (ptype == .unknown) {
                if (self.arena.typeNodeKind(p.type_node) == .named) {
                    const tname_idx = self.arena.typeNodeData(p.type_node);
                    const tname = self.arena.strings.slice(self.arena.named_types.items[tname_idx].name);
                    try self.emit(.undefined_symbol, .error_, self.arena.typeNodeSpan(p.type_node), "unknown type '{s}' on rule parameter", .{tname});
                } else {
                    try self.emit(.undefined_symbol, .error_, self.arena.typeNodeSpan(p.type_node), "unsupported parameter type in E1 (rule parameters must be scalar or Entity)", .{});
                }
            }
            try ctx.locals.put(self.gpa, p.name, .{ .type_ = ptype, .is_mut = false });
        }

        // Validate when-clause and collect accessible component/resource types.
        if (rule.when_root != ast_mod.RuleDecl.none_when) {
            try self.collectWhen(&ctx, rule.when_root);
        }

        // Walk the body statements.
        var s: u32 = 0;
        while (s < rule.body_len) : (s += 1) {
            const stmt_raw = self.arena.extra.items[rule.body_start + s];
            const stmt_id: NodeId = @bitCast(stmt_raw);
            try self.checkStmt(&ctx, stmt_id);
        }
    }

    /// Type-check a top-level `fn` body (M0.8 E2 call mechanism). Binds params
    /// as locals (no `when` clause / no entity context), records the declared
    /// return type for `return` / trailing-value checks, walks the body run,
    /// then checks the trailing block value (the implicit return) against the
    /// declared return type. `async` bodies are checked the same way (their
    /// interpretation is E3); the `throws` marker does not change body checking.
    /// Bring a construct's generic type parameters into scope (M0.8 E2 block 4)
    /// so their names resolve to `.generic` inside the body. Balanced by
    /// `removeGenerics`.
    fn addGenerics(self: *TypeChecker, start: u32, len: u32) !void {
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            try self.generic_scope.put(self.gpa, self.arena.generic_params.items[start + i].name, {});
        }
    }

    fn removeGenerics(self: *TypeChecker, start: u32, len: u32) void {
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            _ = self.generic_scope.remove(self.arena.generic_params.items[start + i].name);
        }
    }

    fn checkFn(self: *TypeChecker, decl: ast_mod.FnDecl) !void {
        var ctx: RuleCtx = .{};
        defer ctx.deinit(self.gpa);

        // Generic params (M0.8 E2 block 4) in scope for the whole signature + body.
        try self.addGenerics(decl.generics_start, decl.generics_len);
        defer self.removeGenerics(decl.generics_start, decl.generics_len);

        var i: u32 = 0;
        while (i < decl.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[decl.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            if (ptype == .unknown) {
                try self.emit(.undefined_symbol, .error_, self.arena.typeNodeSpan(p.type_node), "unknown or unsupported parameter type on function '{s}'", .{self.arena.strings.slice(decl.name)});
            }
            try ctx.locals.put(self.gpa, p.name, .{ .type_ = ptype, .is_mut = false });
        }

        // Declared return type drives `return` / trailing-value checks. A void
        // fn (no `-> type`) records `.unknown` — return values aren't strictly
        // checked against void in block 2.
        const ret_t: ResolvedType = if (decl.return_type.isNone())
            ResolvedType.unknown
        else
            self.namedTypeToResolved(decl.return_type);
        const saved_ret = self.current_fn_return;
        self.current_fn_return = ret_t;
        defer self.current_fn_return = saved_ret;

        var s: u32 = 0;
        while (s < decl.body_len) : (s += 1) {
            const stmt_raw = self.arena.extra.items[decl.body_start + s];
            const stmt_id: NodeId = @bitCast(stmt_raw);
            try self.checkStmt(&ctx, stmt_id);
        }

        // The trailing block value is the implicit return — check it against the
        // declared return type (E0200, consistent with the closure-call path).
        if (!decl.value.isNone()) {
            const vt = self.synthExpr(decl.value, &ctx);
            if (!decl.return_type.isNone() and ret_t == .builtin and vt == .builtin and !self.literalTypeFits(ret_t.builtin, decl.value, vt.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(decl.value), "function '{s}' body value type does not match its declared return type", .{self.arena.strings.slice(decl.name)});
            }
        }
    }

    fn collectWhen(self: *TypeChecker, ctx: *RuleCtx, idx: u32) !void {
        const node = self.arena.when_nodes.items[idx];
        switch (node.kind) {
            .logical_and, .logical_or => {
                try self.collectWhen(ctx, node.lhs);
                try self.collectWhen(ctx, node.rhs);
            },
            .logical_not => {
                try self.collectWhen(ctx, node.lhs);
            },
            .has, .has_with_filter => {
                const tname_slice = self.arena.strings.slice(node.type_name);
                if (self.symbols.get(node.type_name)) |sym| {
                    if (sym.kind != .component) {
                        try self.emit(.unknown_component_in_when, .error_, node.span, "'has' clause requires a component, '{s}' is a {s}", .{ tname_slice, @tagName(sym.kind) });
                    } else {
                        try ctx.components_in_when.put(self.gpa, node.type_name, {});
                    }
                } else {
                    try self.emit(.unknown_component_in_when, .error_, node.span, "unknown component '{s}' in when clause", .{tname_slice});
                }
                if (node.kind == .has_with_filter) {
                    // Validate field exists on component with compatible type.
                    try self.checkFieldFilter(node);
                }
            },
            .resource, .resource_changed => {
                const tname_slice = self.arena.strings.slice(node.type_name);
                if (self.symbols.get(node.type_name)) |sym| {
                    if (sym.kind != .resource) {
                        try self.emit(.resource_expected_in_when, .error_, node.span, "'resource' clause requires a resource, '{s}' is a {s}", .{ tname_slice, @tagName(sym.kind) });
                    } else {
                        try ctx.resources_in_when.put(self.gpa, node.type_name, {});
                    }
                } else {
                    try self.emit(.resource_expected_in_when, .error_, node.span, "unknown resource '{s}' in when clause", .{tname_slice});
                }
            },
            .tag_filter => {
                // `entity has_tag .path` (M0.8 E3, `etch-validation-ecs.md`
                // §7.2). Validate each operand path against the global tag
                // table; an unknown path is E1212 (the `when`-context tag code).
                const tf = self.arena.tag_filters.items[node.aux];
                var oi: u32 = 0;
                while (oi < tf.operand_len) : (oi += 1) {
                    const path_node = self.arena.tag_operands.items[tf.operand_start + oi];
                    try self.validateTagPath(path_node, tf.op);
                }
            },
        }
    }

    /// Validate one tag operand path against the global tag table (M0.8 E3,
    /// `etch-validation-ecs.md` §5.4-5.5 / §7.2). An unknown path is `E1212
    /// UnknownTag`; `has_tag` / `has_no_tag` additionally require a leaf (a
    /// namespace operand is only meaningful for the multi operators, where it
    /// expands to a category mask).
    fn validateTagPath(self: *TypeChecker, path_node: NodeId, op: ast_mod.TagOp) !void {
        const tp = self.arena.tag_paths.items[self.arena.exprData(path_node)];
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);
        var i: u32 = 0;
        while (i < tp.segs_len) : (i += 1) {
            if (i > 0) try buf.append(self.gpa, '.');
            try buf.appendSlice(self.gpa, self.arena.strings.slice(self.arena.tag_path_segs.items[tp.segs_start + i]));
        }
        const table = self.tag_table orelse return;
        const entry = table.lookup(buf.items);
        if (entry == null) {
            try self.emit(.unknown_tag, .error_, self.arena.exprSpan(path_node), "unknown tag path '.{s}' in when clause", .{buf.items});
            return;
        }
        if ((op == .has_tag or op == .has_no_tag) and !entry.?.is_leaf) {
            try self.emit(.unknown_tag, .error_, self.arena.exprSpan(path_node), "'{s}' is a tag namespace; '{s}' requires a single leaf tag", .{ buf.items, @tagName(op) });
        }
    }

    fn checkFieldFilter(self: *TypeChecker, node: ast_mod.WhenNode) !void {
        // `entity has T { field == value }` — verify field on T and value type.
        const comp_sym = self.symbols.get(node.type_name) orelse return;
        if (comp_sym.kind != .component) return;
        const comp_data = self.arena.itemData(comp_sym.item_id);
        const comp_decl = self.arena.component_decls.items[comp_data];
        var f_i: u32 = 0;
        var found: ?ast_mod.Field = null;
        while (f_i < comp_decl.fields_len) : (f_i += 1) {
            const f = self.arena.fields.items[comp_decl.fields_start + f_i];
            if (f.name == node.field_name) {
                found = f;
                break;
            }
        }
        if (found == null) {
            const fname = self.arena.strings.slice(node.field_name);
            const tname = self.arena.strings.slice(node.type_name);
            try self.emit(.invalid_field_filter, .error_, node.span, "component '{s}' has no field '{s}'", .{ tname, fname });
            return;
        }
        const declared = self.namedTypeToResolved(found.?.type_node);
        const actual = self.synthExpr(node.filter_value, null);
        if (declared == .builtin and actual == .builtin and !declared.eql(actual)) {
            try self.emit(.invalid_field_filter, .error_, node.span, "field filter type does not match field declared type", .{});
        }
    }

    fn checkStmt(self: *TypeChecker, ctx: *RuleCtx, stmt_id: NodeId) !void {
        const kind = self.arena.stmtKind(stmt_id);
        const data = self.arena.stmtData(stmt_id);
        switch (kind) {
            .let_stmt => {
                const let = self.arena.let_stmts.items[data];
                var declared: ?ResolvedType = null;
                if (!let.type_annotation.isNone()) {
                    declared = self.namedTypeToResolved(let.type_annotation);
                }
                const inferred = self.synthExpr(let.value, ctx);
                const final = if (declared) |d| blk: {
                    if (d == .builtin and inferred == .builtin and !self.literalTypeFits(d.builtin, let.value, inferred.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(let.value), "let initializer type does not match declared type", .{});
                    }
                    break :blk d;
                } else inferred;
                // A binding to `entity.get_mut(T)` aliases the mutable
                // component reference, so the local inherits mutability
                // even when written `let h = ...` without `mut`.
                const value_is_get_mut = self.arena.exprKind(let.value) == .method_get_mut;
                try ctx.locals.put(self.gpa, let.name, .{ .type_ = final, .is_mut = let.is_mut or value_is_get_mut });
            },
            .assign_stmt => {
                const assign = self.arena.assign_stmts.items[data];
                // Target must be either a mut local, or a field via get_mut.
                const target_kind = self.arena.exprKind(assign.target);
                if (target_kind == .ident) {
                    const name_id = self.arena.exprData(assign.target);
                    if (ctx.locals.get(name_id)) |local| {
                        if (!local.is_mut) {
                            const span = self.arena.exprSpan(assign.target);
                            try self.emit(.type_mismatch, .error_, span, "cannot assign to immutable binding (use 'let mut')", .{});
                        }
                        const rhs_type = self.synthExpr(assign.value, ctx);
                        if (local.type_ == .builtin and rhs_type == .builtin and !self.literalTypeFits(local.type_.builtin, assign.value, rhs_type.builtin)) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(assign.value), "assignment value type does not match binding type", .{});
                        }
                    } else {
                        const name = self.arena.strings.slice(name_id);
                        try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(assign.target), "unknown binding '{s}'", .{name});
                    }
                } else if (target_kind == .field_access) {
                    // Walk down: assignment is valid if the chain ends at
                    // either `entity.get_mut(T)` directly or an ident
                    // whose local binding is mutable (e.g. one bound via
                    // `let h = entity.get_mut(T)`).
                    const ok = isAssignTargetReachable(self.arena, ctx, assign.target);
                    if (!ok) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(assign.target), "assignment target field must be accessed via entity.get_mut(T) or a mutable binding", .{});
                    }
                    // Synthesize the field type and check the value matches it.
                    const lhs_type = self.synthExpr(assign.target, ctx);
                    const rhs_type = self.synthExpr(assign.value, ctx);
                    if (lhs_type == .builtin and rhs_type == .builtin and !self.literalTypeFits(lhs_type.builtin, assign.value, rhs_type.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(assign.value), "assignment value type does not match field type", .{});
                    }
                } else {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(assign.target), "unsupported assignment target in S3 rule body", .{});
                }
            },
            .expr_stmt => {
                const expr_id: NodeId = @bitCast(data);
                _ = self.synthExpr(expr_id, ctx);
            },
            .assert_stmt => {
                // `assert(cond[, msg])` — the condition must be bool (M0.8
                // v0.6 foundations, `etch-reference-part1.md` §10.3).
                const a = self.arena.assert_stmts.items[data];
                const cond_t = self.synthExpr(a.cond, ctx);
                if (cond_t != .builtin or cond_t.builtin != .bool_) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(a.cond), "assert condition must be a bool expression", .{});
                }
            },
            .for_stmt => {
                // `for v in iterable { body }` — E1 iterates ranges; the loop
                // variable binds to the range's integer element type, then the
                // body is checked with it in scope (M0.8 v0.6 foundations).
                const f = self.arena.for_stmts.items[data];
                const iter_t = self.synthExpr(f.iterable, ctx);
                if (iter_t == .map_t) {
                    // `for k, v in m` — two bindings: key then value (M0.8
                    // collections). A single-binding map for-in is rejected.
                    const mi = iter_t.map_t;
                    if (f.index_name == 0) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(f.iterable), "map for-in binds two variables (for k, v in m)", .{});
                    } else {
                        try ctx.locals.put(self.gpa, f.index_name, .{ .type_ = .{ .builtin = mi.value }, .is_mut = false });
                    }
                    try ctx.locals.put(self.gpa, f.var_name, .{ .type_ = .{ .builtin = mi.key }, .is_mut = false });
                } else {
                    var elem_t: ResolvedType = ResolvedType.unknown;
                    if (iter_t == .range) {
                        elem_t = .{ .builtin = iter_t.range };
                    } else if (iter_t.elementType()) |bt| {
                        // Array / slice iteration binds the element type (M0.8).
                        elem_t = .{ .builtin = bt };
                    } else if (iter_t != .unknown) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(f.iterable), "for-in iterable must be a range, array, or map in E1", .{});
                    }
                    if (f.index_name != 0) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(f.iterable), "this for-in binds a single loop variable", .{});
                    }
                    try ctx.locals.put(self.gpa, f.var_name, .{ .type_ = elem_t, .is_mut = false });
                }
                var i: u32 = 0;
                while (i < f.body_len) : (i += 1) {
                    const body_stmt: NodeId = @bitCast(self.arena.extra.items[f.body_start + i]);
                    try self.checkStmt(ctx, body_stmt);
                }
            },
            .while_stmt => {
                // `while cond { body }` (M0.8 control flow) — bool condition.
                // `while let x = <optional> { body }` (M0.8 E2 block 5) — `x`
                // binds the optional's payload in the body scope each iteration.
                const wh = self.arena.while_stmts.items[data];
                const cond_t = self.synthExpr(wh.cond, ctx);
                if (wh.let_binding != 0) {
                    const payload = try self.optionalPayload(cond_t, self.arena.exprSpan(wh.cond), "while let");
                    try ctx.locals.put(self.gpa, wh.let_binding, .{ .type_ = payload, .is_mut = false });
                } else if (cond_t == .builtin and cond_t.builtin != .bool_) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(wh.cond), "while condition must be a bool expression", .{});
                }
                var i: u32 = 0;
                while (i < wh.body_len) : (i += 1) {
                    try self.checkStmt(ctx, @bitCast(self.arena.extra.items[wh.body_start + i]));
                }
                if (wh.let_binding != 0) _ = ctx.locals.remove(wh.let_binding);
            },
            .break_stmt => {
                // `break [label] [value]` (M0.8 loop/break). Type the value if
                // present; loop-membership / label validity is permissive in E1.
                const b = self.arena.break_stmts.items[data];
                if (!b.value.isNone()) _ = self.synthExpr(b.value, ctx);
            },
            .continue_stmt => {},
            .throw_stmt => {
                // `throw expression` (M0.8 error handling) — type the value. E1
                // throws an arbitrary value (the `Error` struct type arrives
                // with struct/enum in E2).
                const t = self.arena.throw_stmts.items[data];
                _ = self.synthExpr(t.value, ctx);
            },
            .try_catch_stmt => {
                // `try { ... } catch err { ... }` (M0.8 error handling). Check
                // both bodies; the caught binding's type is dynamic in E1
                // (the thrown value type is not statically tracked), so it is
                // bound as `unknown`.
                const tc = self.arena.try_catch_stmts.items[data];
                var i: u32 = 0;
                while (i < tc.try_len) : (i += 1) {
                    try self.checkStmt(ctx, @bitCast(self.arena.extra.items[tc.try_start + i]));
                }
                try ctx.locals.put(self.gpa, tc.catch_name, .{ .type_ = ResolvedType.unknown, .is_mut = false });
                i = 0;
                while (i < tc.catch_len) : (i += 1) {
                    try self.checkStmt(ctx, @bitCast(self.arena.extra.items[tc.catch_start + i]));
                }
            },
            .return_stmt => {
                // `return [expr]` (M0.8 E2 call mechanism). Type the value (if
                // any) against the enclosing fn's declared return type (E0200,
                // consistent with the closure-call / trailing-value checks). A
                // bare `return` is valid in a void fn; a `return` with no
                // enclosing fn (e.g. a rule body) is permissive.
                const value: NodeId = @bitCast(data);
                if (!value.isNone()) {
                    const vt = self.synthExpr(value, ctx);
                    if (self.current_fn_return) |ret| {
                        if (ret == .builtin and vt == .builtin and !self.literalTypeFits(ret.builtin, value, vt.builtin)) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(value), "return value type does not match the declared return type", .{});
                        }
                    }
                }
            },
            .emit_stmt => {
                // `emit EventType { field: value, … }` (M0.8 E3,
                // `etch-grammar.md` §4.1 + §5.10). The target must be a declared
                // `event`; each field initializer must name a field on the event
                // and type-match it (mirrors `synthStructLit`). The payload is
                // enqueued at runtime (interp dynamic event store / codegen
                // `world.event_bus.emit`).
                const em = self.arena.emit_stmts.items[data];
                const sym = self.symbols.get(em.event_type);
                if (sym == null or sym.?.kind != .event_) {
                    try self.emit(.undefined_symbol, .error_, self.arena.stmtSpan(stmt_id), "'{s}' is not a declared event", .{self.arena.strings.slice(em.event_type)});
                } else {
                    const decl = self.arena.event_decls.items[self.arena.itemData(sym.?.item_id)];
                    var i: u32 = 0;
                    while (i < em.fields_len) : (i += 1) {
                        const flit = self.arena.struct_lit_fields.items[em.fields_start + i];
                        var declared: ?ResolvedType = null;
                        var f_i: u32 = 0;
                        while (f_i < decl.fields_len) : (f_i += 1) {
                            const f = self.arena.fields.items[decl.fields_start + f_i];
                            if (f.name == flit.name) {
                                declared = self.namedTypeToResolved(f.type_node);
                                break;
                            }
                        }
                        const actual = self.synthExpr(flit.value, ctx);
                        if (declared) |d| {
                            if (d == .builtin and actual == .builtin and !self.literalTypeFits(d.builtin, flit.value, actual.builtin)) {
                                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(flit.value), "emit field '{s}' value type does not match its declared type", .{self.arena.strings.slice(flit.name)});
                            }
                        } else {
                            try self.emit(.invalid_field_filter, .error_, self.arena.stmtSpan(stmt_id), "event '{s}' has no field '{s}'", .{ self.arena.strings.slice(em.event_type), self.arena.strings.slice(flit.name) });
                        }
                    }
                }
            },
            else => {},
        }
    }

    // ─── Expression typing ───────────────────────────────────────────────

    const TypeError = std.mem.Allocator.Error;

    fn synthExpr(self: *TypeChecker, id: NodeId, ctx_opt: ?*RuleCtx) ResolvedType {
        return self.synthExprE(id, ctx_opt) catch ResolvedType.unknown;
    }

    fn synthExprE(self: *TypeChecker, id: NodeId, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const kind = self.arena.exprKind(id);
        const data = self.arena.exprData(id);
        switch (kind) {
            .int_lit => return .{ .builtin = .int_ },
            .float_lit => return .{ .builtin = .float_ },
            .bool_lit => return .{ .builtin = .bool_ },
            .string_lit => return ResolvedType.unknown,
            .tag_path => return ResolvedType.unknown, // enum-variant shorthand; type unknown in S3
            // `none` (M0.8 E2 block 5): an optional with an unknown payload —
            // typed by the binding annotation / context (e.g. `let o: int? = none`).
            .none_lit => return ResolvedType.unknown,
            // `some(x)`: an optional of `x`'s type. Builtin-scalar payload →
            // `.optional(bt)`; a non-builtin payload (`some(struct)`) is deferred.
            .some_lit => {
                const inner: NodeId = @bitCast(data);
                const inner_t = try self.synthExprE(inner, ctx_opt);
                if (inner_t == .builtin) return .{ .optional = inner_t.builtin };
                return ResolvedType.unknown;
            },
            .ident => {
                const name_id: StringId = data;
                if (ctx_opt) |ctx| {
                    if (ctx.locals.get(name_id)) |local| return local.type_;
                }
                try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(id), "unknown identifier '{s}'", .{self.arena.strings.slice(name_id)});
                return ResolvedType.unknown;
            },
            .field_access => {
                const fa = self.arena.field_accesses.items[data];
                // Enum value `Difficulty.hard` (M0.8 E2 block 3 tranche B): a
                // `.path` receiver naming a declared enum + a variant field.
                // Resolved here (a bare type is not field-accessible otherwise).
                if (self.arena.exprKind(fa.receiver) == .path) {
                    const path_name = self.arena.exprData(fa.receiver);
                    if (self.enumDecl(path_name) != null) {
                        if (self.enumVariantIndex(path_name, fa.field_name) == null) {
                            try self.emit(.enum_variant_not_found, .error_, self.arena.exprSpan(id), "enum '{s}' has no variant '{s}'", .{ self.arena.strings.slice(path_name), self.arena.strings.slice(fa.field_name) });
                            return ResolvedType.unknown;
                        }
                        return .{ .enum_t = path_name };
                    }
                }
                const receiver_type = try self.synthExprE(fa.receiver, ctx_opt);
                return self.lookupFieldType(receiver_type, fa.field_name, self.arena.exprSpan(id));
            },
            .method_get, .method_get_mut => {
                const mg = self.arena.method_gets.items[data];
                const tname = self.arena.strings.slice(mg.type_name);

                // Receiver-less `get(T)` / `get_mut(T)` — resource access
                // (D-S3-resource-receiver). `T` must name a resource; a
                // component here is the symmetric E0301 error.
                if (mg.receiver.isNone()) {
                    if (self.symbols.get(mg.type_name)) |sym| {
                        if (sym.kind == .component) {
                            try self.emit(.resource_expected_component_given, .error_, self.arena.exprSpan(id), "'{s}' is a component — receiver-less get(...) accesses a resource; use entity.get({s})", .{ tname, tname });
                            return ResolvedType.unknown;
                        }
                        if (sym.kind != .resource) {
                            try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(id), "'{s}' is not a resource", .{tname});
                            return ResolvedType.unknown;
                        }
                    } else {
                        try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(id), "unknown resource '{s}'", .{tname});
                        return ResolvedType.unknown;
                    }
                    if (ctx_opt) |ctx| {
                        if (!ctx.resources_in_when.contains(mg.type_name)) {
                            try self.emit(.resource_expected_in_when, .error_, self.arena.exprSpan(id), "resource '{s}' is not accessible — add it to the rule's when clause", .{tname});
                        }
                    }
                    return .{ .resource = mg.type_name };
                }

                // Receiver form `entity.get(T)` — component access.
                const receiver_type = try self.synthExprE(mg.receiver, ctx_opt);
                if (receiver_type != .builtin or receiver_type.builtin != .entity) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "get / get_mut requires an Entity receiver", .{});
                    return ResolvedType.unknown;
                }
                // `T` must be a component; a resource here is the symmetric
                // E0302 error (resource access drops the receiver).
                if (self.symbols.get(mg.type_name)) |sym| {
                    if (sym.kind == .resource) {
                        try self.emit(.component_expected_resource_given, .error_, self.arena.exprSpan(id), "'{s}' is a resource — entity.get(...) accesses a component; use get({s})", .{ tname, tname });
                        return ResolvedType.unknown;
                    }
                }
                if (ctx_opt) |ctx| {
                    if (!ctx.components_in_when.contains(mg.type_name)) {
                        try self.emit(.unknown_component_in_when, .error_, self.arena.exprSpan(id), "component '{s}' is not accessible — add it to the rule's when clause", .{tname});
                    }
                }
                return .{ .component = mg.type_name };
            },
            .binary => return try self.synthBinary(id, data, ctx_opt),
            .unary => return try self.synthUnary(id, data, ctx_opt),
            .match_expr => return try self.synthMatch(id, data, ctx_opt),
            .range => {
                // `start..end` / `start..=end` — both bounds must be the same
                // integer type (M0.8 v0.6 foundations). Result is a range over
                // that integer element type.
                const r = self.arena.ranges.items[data];
                const start_t = try self.synthExprE(r.start, ctx_opt);
                const end_t = try self.synthExprE(r.end, ctx_opt);
                if (start_t == .unknown or end_t == .unknown) return ResolvedType.unknown;
                if (start_t == .builtin and end_t == .builtin and start_t.builtin.isInteger() and end_t.builtin.isInteger()) {
                    if (!ResolvedType.eql(start_t, end_t)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "range bounds must have the same integer type", .{});
                        return ResolvedType.unknown;
                    }
                    return .{ .range = start_t.builtin };
                }
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "range bounds must be integers", .{});
                return ResolvedType.unknown;
            },
            .cast => {
                // `operand as Type` (M0.8 v0.6 foundations). The S3 subset
                // permits numeric-scalar → numeric-scalar conversions only;
                // the result type is the (numeric) target. Casts to or from a
                // non-numeric type are rejected (E0200).
                const c = self.arena.casts.items[data];
                const operand_t = try self.synthExprE(c.operand, ctx_opt);
                const target_t = self.namedTypeToResolved(c.type_node);
                if (target_t != .builtin or !target_t.builtin.isNumeric()) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "cast target must be a numeric primitive type ('as' converts between numbers in the S3 subset)", .{});
                    return ResolvedType.unknown;
                }
                if (operand_t == .builtin and !operand_t.builtin.isNumeric()) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "cast operand must be a numeric primitive", .{});
                    return ResolvedType.unknown;
                }
                return target_t;
            },
            .array_lit => return try self.synthArrayLit(id, data, ctx_opt),
            .map_lit => return try self.synthMapLit(id, data, ctx_opt),
            .index => return try self.synthIndex(id, data, ctx_opt),
            .closure => return .{ .closure = id },
            .fn_call => return try self.synthCall(id, data, ctx_opt),
            .struct_lit => return try self.synthStructLit(id, data, ctx_opt),
            .method_call => return try self.synthMethodCall(id, data, ctx_opt),
            .loop_expr => return try self.synthLoop(data, ctx_opt),
            .block_expr => return try self.synthBlock(data, ctx_opt),
            .if_expr => return try self.synthIf(id, data, ctx_opt),
            .paren => unreachable, // parser doesn't emit a paren node — it returns the inner expr
            else => return ResolvedType.unknown,
        }
    }

    /// Type an array literal (M0.8 collections). `[a, b, c]` (and `[v; n]`)
    /// without an annotation infers a **fixed** array of the unified builtin
    /// element type; an empty `[]` stays `unknown` so the `let`'s annotation
    /// supplies the type. E1 arrays carry builtin primitive elements only.
    fn synthArrayLit(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const al = self.arena.array_lits.items[data];
        if (al.is_fill) {
            const elem_id: NodeId = @bitCast(self.arena.extra.items[al.elements_start]);
            const elem_t = try self.synthExprE(elem_id, ctx_opt);
            const count_t = try self.synthExprE(al.fill_count, ctx_opt);
            if (count_t == .builtin and !count_t.builtin.isInteger()) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(al.fill_count), "array fill count must be an integer", .{});
            }
            if (elem_t != .builtin) {
                if (elem_t != .unknown) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "array elements must be a builtin primitive in E1", .{});
                return ResolvedType.unknown;
            }
            const len = self.constArrayLen(al.fill_count) orelse 0;
            return .{ .array_fixed = .{ .elem = elem_t.builtin, .len = len } };
        }
        if (al.elements_len == 0) return ResolvedType.unknown; // empty: type from annotation
        var elem_bt: ?BuiltinType = null;
        var i: u32 = 0;
        while (i < al.elements_len) : (i += 1) {
            const e: NodeId = @bitCast(self.arena.extra.items[al.elements_start + i]);
            const et = try self.synthExprE(e, ctx_opt);
            if (et != .builtin) {
                if (et != .unknown) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(e), "array elements must be a builtin primitive in E1", .{});
                return ResolvedType.unknown;
            }
            if (elem_bt) |bt| {
                if (!self.literalTypeFits(bt, e, et.builtin)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(e), "array elements must all have the same type", .{});
                }
            } else elem_bt = et.builtin;
        }
        return .{ .array_fixed = .{ .elem = elem_bt.?, .len = al.elements_len } };
    }

    /// Type a map literal (M0.8 collections). `[k: v, ...]` infers a map whose
    /// key / value are the unified builtin types of the entries. E1 maps carry
    /// builtin key / value types — a non-builtin (e.g. a `string` key, which is
    /// not a builtin in E1) leaves the literal `unknown` (the interpreter still
    /// builds it from the runtime values; precise string-keyed map typing is a
    /// later refinement). Empty `[:]` stays `unknown` so the annotation types it.
    fn synthMapLit(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        _ = id;
        const ml = self.arena.map_lits.items[data];
        if (ml.entries_len == 0) return ResolvedType.unknown; // empty: type from annotation
        var key_bt: ?BuiltinType = null;
        var val_bt: ?BuiltinType = null;
        var all_builtin = true;
        var i: u32 = 0;
        while (i < ml.entries_len) : (i += 1) {
            const entry = self.arena.map_entries.items[ml.entries_start + i];
            const kt = try self.synthExprE(entry.key, ctx_opt);
            const vt = try self.synthExprE(entry.value, ctx_opt);
            if (kt != .builtin or vt != .builtin) {
                all_builtin = false;
                continue;
            }
            if (key_bt) |kb| {
                if (!self.literalTypeFits(kb, entry.key, kt.builtin)) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(entry.key), "map keys must all have the same type", .{});
            } else key_bt = kt.builtin;
            if (val_bt) |vb| {
                if (!self.literalTypeFits(vb, entry.value, vt.builtin)) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(entry.value), "map values must all have the same type", .{});
            } else val_bt = vt.builtin;
        }
        if (!all_builtin or key_bt == null or val_bt == null) return ResolvedType.unknown;
        return .{ .map_t = .{ .key = key_bt.?, .value = val_bt.? } };
    }

    /// Type a `loop { body }` expression (M0.8 loop/break). The body statements
    /// are checked, and the loop's value is the type of a top-level `break`
    /// value (permissive: `unknown` when none — a labeled break out of a nested
    /// loop is typed only through execution, the interpreter being the
    /// reference; the assignment site treats `unknown` as a wildcard).
    fn synthLoop(self: *TypeChecker, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const lp = self.arena.loop_exprs.items[data];
        if (ctx_opt) |ctx| {
            var i: u32 = 0;
            while (i < lp.body_len) : (i += 1) {
                const stmt: NodeId = @bitCast(self.arena.extra.items[lp.body_start + i]);
                try self.checkStmt(ctx, stmt);
            }
        }
        var i: u32 = 0;
        while (i < lp.body_len) : (i += 1) {
            const stmt: NodeId = @bitCast(self.arena.extra.items[lp.body_start + i]);
            if (self.arena.stmtKind(stmt) == .break_stmt) {
                const b = self.arena.break_stmts.items[self.arena.stmtData(stmt)];
                if (!b.value.isNone()) return self.synthExpr(b.value, ctx_opt);
            }
        }
        return ResolvedType.unknown;
    }

    /// Type a block expression `{ stmts; value }` (M0.8 control flow). The body
    /// statements are checked in order, then the block's type is the trailing
    /// value's type (or `unknown` ≈ unit when value-less). Locals declared in
    /// the block use the flat per-rule locals map — lexical scoping is a later
    /// refinement (consistent with E1; the interpreter is the reference).
    fn synthBlock(self: *TypeChecker, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const blk = self.arena.block_exprs.items[data];
        if (ctx_opt) |ctx| {
            var i: u32 = 0;
            while (i < blk.body_len) : (i += 1) {
                const stmt: NodeId = @bitCast(self.arena.extra.items[blk.body_start + i]);
                try self.checkStmt(ctx, stmt);
            }
        }
        if (blk.value.isNone()) return ResolvedType.unknown;
        return try self.synthExprE(blk.value, ctx_opt);
    }

    /// Type an `if` expression (M0.8 control flow). The condition must be
    /// `bool`; the then / else branches (block expressions, `else if` chaining
    /// through a nested `if`) must unify to one result type. An `if` with no
    /// `else` has no value (`unknown` ≈ unit) — valid only in statement
    /// position (the type-checker does not separately reject a value-position
    /// else-less `if`; the codegen surfaces it as `UnsupportedConstruct`).
    fn synthIf(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const ife = self.arena.if_exprs.items[data];
        const cond_t = try self.synthExprE(ife.cond, ctx_opt);
        if (ife.let_binding != 0) {
            // `if let x = <optional>` (M0.8 E2 block 5): the cond must be an
            // optional; `x` binds its payload in the then-block scope.
            const payload = try self.optionalPayload(cond_t, self.arena.exprSpan(ife.cond), "if let");
            if (ctx_opt) |ctx| try ctx.locals.put(self.gpa, ife.let_binding, .{ .type_ = payload, .is_mut = false });
            const then_t = try self.synthExprE(ife.then_block, ctx_opt);
            if (ctx_opt) |ctx| _ = ctx.locals.remove(ife.let_binding);
            if (ife.else_branch.isNone()) return ResolvedType.unknown;
            const else_t = try self.synthExprE(ife.else_branch, ctx_opt);
            if (then_t == .builtin and else_t == .builtin and !ResolvedType.eql(then_t, else_t)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "if branches must yield the same type", .{});
            }
            return then_t;
        }
        if (cond_t == .builtin and cond_t.builtin != .bool_) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(ife.cond), "if condition must be a bool expression", .{});
        }
        const then_t = try self.synthExprE(ife.then_block, ctx_opt);
        if (ife.else_branch.isNone()) return ResolvedType.unknown;
        const else_t = try self.synthExprE(ife.else_branch, ctx_opt);
        if (then_t == .builtin and else_t == .builtin and !ResolvedType.eql(then_t, else_t)) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "if branches must yield the same type", .{});
        }
        return then_t;
    }

    /// The payload type unwrapped by `if let` / `while let` (M0.8 E2 block 5).
    /// `.optional(bt)` → the payload builtin; `.unknown` (e.g. a bare `none`,
    /// or a deferred non-scalar optional) → `.unknown` (permissive). A
    /// non-optional scrutinee is an error.
    fn optionalPayload(self: *TypeChecker, cond_t: ResolvedType, span: SourceSpan, comptime form: []const u8) TypeError!ResolvedType {
        return switch (cond_t) {
            .optional => |bt| .{ .builtin = bt },
            .unknown => ResolvedType.unknown,
            else => blk: {
                try self.emit(.type_mismatch, .error_, span, "'" ++ form ++ "' requires an optional (T?) value", .{});
                break :blk ResolvedType.unknown;
            },
        };
    }

    /// Type a call expression (M0.8 closures). E1 only resolves calls whose
    /// callee is a closure: arity is checked, then the body is typed for the
    /// return with the parameters bound (to their annotation, else the argument
    /// type) in the caller's scope. Calls on non-closures are an error
    /// (function / method calls arrive with fn / impl in E2).
    fn synthCall(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const call = self.arena.call_exprs.items[data];

        // Free-function call (M0.8 E2): a callee that is a plain identifier
        // naming a top-level `fn` (and not shadowed by a local binding) is the
        // §4.2 rule — synth the signature, check arity + arg types, result is
        // the declared return type. The other three dispatch kinds need `impl`
        // (block 3) or the service registry (Level B), so block 2 ships free
        // calls; method-call dispatch follows in block 3.
        if (self.arena.exprKind(call.callee) == .ident) {
            const callee_name = self.arena.exprData(call.callee);
            const shadowed = if (ctx_opt) |ctx| ctx.locals.contains(callee_name) else false;
            if (!shadowed) {
                if (self.symbols.get(callee_name)) |sym| {
                    if (sym.kind == .fn_) {
                        return try self.synthFreeFnCall(id, call, sym.item_id, ctx_opt);
                    }
                }
            }
        }

        const callee_t = try self.synthExprE(call.callee, ctx_opt);
        if (callee_t != .closure) {
            if (callee_t != .unknown) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "call target is not callable in E1 (only closures can be called)", .{});
            return ResolvedType.unknown;
        }
        const ce = self.arena.closure_exprs.items[self.arena.exprData(callee_t.closure)];
        if (ce.params_len != call.args_len) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "closure called with {d} argument(s), expected {d}", .{ call.args_len, ce.params_len });
            return ResolvedType.unknown;
        }
        const ctx = ctx_opt orelse return ResolvedType.unknown;
        var i: u32 = 0;
        while (i < ce.params_len) : (i += 1) {
            const p = self.arena.closure_params.items[ce.params_start + i];
            const arg: NodeId = @bitCast(self.arena.extra.items[call.args_start + i]);
            const arg_t = try self.synthExprE(arg, ctx_opt);
            var ptype = arg_t;
            if (!p.type_node.isNone()) {
                ptype = self.namedTypeToResolved(p.type_node);
                if (ptype == .builtin and arg_t == .builtin and !self.literalTypeFits(ptype.builtin, arg, arg_t.builtin)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "closure argument type does not match the parameter type", .{});
                }
            }
            try ctx.locals.put(self.gpa, p.name, .{ .type_ = ptype, .is_mut = false });
        }
        const ret = try self.synthExprE(ce.body, ctx_opt);
        // Remove the parameter bindings (E1 closures don't collide their params
        // with outer locals in practice; a save/restore is a later refinement).
        i = 0;
        while (i < ce.params_len) : (i += 1) {
            const p = self.arena.closure_params.items[ce.params_start + i];
            _ = ctx.locals.remove(p.name);
        }
        return ret;
    }

    /// Type a free-function call `f(args)` to a top-level `fn` (M0.8 E2). Checks
    /// arity then each argument against the declared parameter type; the result
    /// is the declared return type (`unknown` for a void fn). Diagnostics reuse
    /// E0200 (TypeMismatch), consistent with the sibling closure-call path.
    fn synthFreeFnCall(self: *TypeChecker, id: NodeId, call: ast_mod.CallExpr, item_id: NodeId, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const decl = self.arena.fn_decls.items[self.arena.itemData(item_id)];
        if (decl.params_len != call.args_len) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "function '{s}' called with {d} argument(s), expected {d}", .{ self.arena.strings.slice(decl.name), call.args_len, decl.params_len });
            return if (decl.return_type.isNone()) ResolvedType.unknown else self.namedTypeToResolved(decl.return_type);
        }
        if (decl.generics_len > 0) return try self.synthGenericFnCall(id, call, decl, ctx_opt);
        var i: u32 = 0;
        while (i < decl.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[decl.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            const arg: NodeId = @bitCast(self.arena.extra.items[call.args_start + i]);
            const arg_t = try self.synthExprE(arg, ctx_opt);
            if (ptype == .builtin and arg_t == .builtin and !self.literalTypeFits(ptype.builtin, arg, arg_t.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "argument type does not match the parameter type of function '{s}'", .{self.arena.strings.slice(decl.name)});
            }
        }
        return if (decl.return_type.isNone()) ResolvedType.unknown else self.namedTypeToResolved(decl.return_type);
    }

    /// Type a call to a generic `fn` (M0.8 E2 block 4, `etch-resolver-types.md`
    /// §6.3/§6.4). Type arguments are inferred structurally from the value
    /// arguments (E0603 if a parameter can't be inferred, E0604 on inconsistent
    /// inference); each inferred type is bound-checked (E0601); the return type
    /// is the declared return with the inferred substitution applied. The
    /// monomorphisation instance table (§6.2) drives the Phase-2 codegen
    /// lowering — there is no consumer in the M0.8 direct AST→Zig path, so the
    /// resolver computes the substitution per call without persisting it.
    fn synthGenericFnCall(self: *TypeChecker, id: NodeId, call: ast_mod.CallExpr, decl: ast_mod.FnDecl, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        var subst: std.AutoHashMapUnmanaged(StringId, ResolvedType) = .empty;
        defer subst.deinit(self.gpa);

        var i: u32 = 0;
        while (i < decl.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[decl.params_start + i];
            const arg: NodeId = @bitCast(self.arena.extra.items[call.args_start + i]);
            const arg_t = try self.synthExprE(arg, ctx_opt);
            try self.unifyGeneric(decl, p.type_node, arg_t, &subst, self.arena.exprSpan(arg));
        }

        var gi: u32 = 0;
        while (gi < decl.generics_len) : (gi += 1) {
            const gp = self.arena.generic_params.items[decl.generics_start + gi];
            const inferred = subst.get(gp.name);
            if (inferred == null) {
                try self.emit(.generic_type_annotation_required, .error_, self.arena.exprSpan(id), "cannot infer type parameter '{s}' of '{s}' from the arguments", .{ self.arena.strings.slice(gp.name), self.arena.strings.slice(decl.name) });
                continue;
            }
            try self.checkGenericBounds(gp, inferred.?, self.arena.exprSpan(id));
        }

        if (decl.return_type.isNone()) return ResolvedType.unknown;
        return self.substituteGeneric(decl, decl.return_type, &subst);
    }

    /// `true` if `name` is a generic parameter of `decl` (M0.8 E2 block 4).
    fn isGenericParamOf(self: *TypeChecker, decl: ast_mod.FnDecl, name: StringId) bool {
        var i: u32 = 0;
        while (i < decl.generics_len) : (i += 1) {
            if (self.arena.generic_params.items[decl.generics_start + i].name == name) return true;
        }
        return false;
    }

    /// Structurally match a formal parameter type-node against an actual argument
    /// type, binding generic variables into `subst` (M0.8 E2 block 4, §6.4).
    /// Handles a bare param `T` and an element-of `T[]` / `T[N]`; deeper nesting
    /// is not inferred in M0.8 (leaves the param unbound → E0603 if unresolved).
    fn unifyGeneric(self: *TypeChecker, decl: ast_mod.FnDecl, formal: NodeId, actual: ResolvedType, subst: *std.AutoHashMapUnmanaged(StringId, ResolvedType), span: SourceSpan) TypeError!void {
        switch (self.arena.typeNodeKind(formal)) {
            .named => {
                const named = self.arena.named_types.items[self.arena.typeNodeData(formal)];
                if (!self.isGenericParamOf(decl, named.name)) return; // concrete formal — no binding
                if (actual == .unknown) return; // don't pin a param to a post-error unknown
                if (subst.get(named.name)) |prev| {
                    if (!ResolvedType.eql(prev, actual)) {
                        try self.emit(.inconsistent_generic_inference, .error_, span, "type parameter '{s}' is inferred as two different types", .{self.arena.strings.slice(named.name)});
                    }
                } else {
                    try subst.put(self.gpa, named.name, actual);
                }
            },
            .array, .slice => {
                const at = self.arena.array_types.items[self.arena.typeNodeData(formal)];
                const elem: ?ResolvedType = switch (actual) {
                    .array_fixed => |info| .{ .builtin = info.elem },
                    .array_dyn => |e| .{ .builtin = e },
                    else => null,
                };
                if (elem) |ea| try self.unifyGeneric(decl, at.elem, ea, subst, span);
            },
            else => {}, // generic_type / map / set — not inferred in M0.8
        }
    }

    /// Apply the inferred substitution to a declared return type-node (M0.8 E2
    /// block 4). A bare param `T` → its inferred type (or `.generic` if still
    /// unbound); `T[]` → a dynamic array of the substituted element; otherwise
    /// the ordinary resolution.
    fn substituteGeneric(self: *TypeChecker, decl: ast_mod.FnDecl, node: NodeId, subst: *std.AutoHashMapUnmanaged(StringId, ResolvedType)) ResolvedType {
        switch (self.arena.typeNodeKind(node)) {
            .named => {
                const named = self.arena.named_types.items[self.arena.typeNodeData(node)];
                if (self.isGenericParamOf(decl, named.name)) {
                    return subst.get(named.name) orelse ResolvedType{ .generic = named.name };
                }
                return self.namedTypeToResolved(node);
            },
            .slice => {
                const at = self.arena.array_types.items[self.arena.typeNodeData(node)];
                const e = self.substituteGeneric(decl, at.elem, subst);
                if (e == .builtin) return .{ .array_dyn = e.builtin };
                return ResolvedType.unknown;
            },
            else => return self.namedTypeToResolved(node),
        }
    }

    /// Check an inferred type argument against a parameter's bounds (M0.8 E2
    /// block 4, §6.5). `component` / `resource` require the RTTI category;
    /// `trait` requires an `impl Trait for <actual>` in the compilation set;
    /// `event` is unsatisfiable until events land (E3). E0601 otherwise.
    fn checkGenericBounds(self: *TypeChecker, gp: ast_mod.GenericParam, actual: ResolvedType, span: SourceSpan) TypeError!void {
        var bi: u32 = 0;
        while (bi < gp.bounds_len) : (bi += 1) {
            const b = self.arena.generic_bounds.items[gp.bounds_start + bi];
            const ok = switch (b.kind) {
                .component => actual == .component,
                .resource => actual == .resource,
                .event => false, // `event` bound needs the `event` keyword (E3)
                .trait_ => blk: {
                    const tn = typeNameOfResolved(actual) orelse break :blk false;
                    break :blk self.typeImplementsTrait(tn, b.trait_name);
                },
            };
            if (!ok) {
                try self.emit(.bound_not_satisfied, .error_, span, "type argument for '{s}' does not satisfy its bound", .{self.arena.strings.slice(gp.name)});
            }
        }
    }

    /// `true` if an `impl <trait_name> for <type_name>` exists (M0.8 E2 block 4).
    fn typeImplementsTrait(self: *TypeChecker, type_name: StringId, trait_name: StringId) bool {
        for (self.trait_impls.items) |entry| {
            if (entry.type_name == type_name and entry.trait_name == trait_name) return true;
        }
        return false;
    }

    /// Type a struct literal `T { f: v, … }` (M0.8 E2 block 3). `T` must name a
    /// declared struct; each provided field must exist on it with a matching
    /// value type. Fields may be omitted (the codegen / interpreter fill the
    /// struct's declared defaults). The result type is `.struct_t = T`. The
    /// anonymous `.{ … }` form (deferred) carries `type_name == 0`.
    fn synthStructLit(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const sl = self.arena.struct_lits.items[data];
        const sym = self.symbols.get(sl.type_name);
        if (sym == null or sym.?.kind != .struct_) {
            try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(id), "'{s}' is not a struct type", .{self.arena.strings.slice(sl.type_name)});
            return ResolvedType.unknown;
        }
        const decl = self.arena.struct_decls.items[self.arena.itemData(sym.?.item_id)];
        var i: u32 = 0;
        while (i < sl.fields_len) : (i += 1) {
            const flit = self.arena.struct_lit_fields.items[sl.fields_start + i];
            // Locate the field on the struct declaration.
            var declared: ?ResolvedType = null;
            var f_i: u32 = 0;
            while (f_i < decl.fields_len) : (f_i += 1) {
                const f = self.arena.fields.items[decl.fields_start + f_i];
                if (f.name == flit.name) {
                    declared = self.namedTypeToResolved(f.type_node);
                    break;
                }
            }
            const actual = try self.synthExprE(flit.value, ctx_opt);
            if (declared) |d| {
                if (d == .builtin and actual == .builtin and !self.literalTypeFits(d.builtin, flit.value, actual.builtin)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(flit.value), "struct-literal field '{s}' value type does not match its declared type", .{self.arena.strings.slice(flit.name)});
                }
            } else {
                try self.emit(.invalid_field_filter, .error_, self.arena.exprSpan(id), "struct '{s}' has no field '{s}'", .{ self.arena.strings.slice(sl.type_name), self.arena.strings.slice(flit.name) });
            }
        }
        return .{ .struct_t = sl.type_name };
    }

    /// The user type name carried by a struct / component / resource type, or
    /// `null` for builtins / collections (no user methods in M0.8 E2 block 3 —
    /// builtin/stdlib methods like `Vec3.length` are §5.3, out of scope).
    fn typeNameOfResolved(rt: ResolvedType) ?StringId {
        return switch (rt) {
            .struct_t => |n| n,
            .component => |n| n,
            .resource => |n| n,
            .enum_t => |n| n,
            else => null,
        };
    }

    /// Type a method call `recv.method(args)` / `Type.assoc(args)` (M0.8 E2
    /// block 3). Associated-fn dispatch when the receiver is a bare type path
    /// (`Type.assoc()`, `self_kind == .none`). Instance dispatch follows the
    /// strict order of `etch-resolver-types.md §5.5`: inherent (§5.1) → trait
    /// (§5.2) → builtin/service (§5.3-5.4, out of M0.8 block-3 core). A trait
    /// receiver may be a struct / component / resource or `Entity`; a `mut self`
    /// call on an immutable receiver is E0220 (§7.6); a conditional trait impl's
    /// `when` must be provable from the calling rule's `when` (E0215, §7.3).
    /// Diagnostics reuse E0200 for method-not-found (the dedicated E0201 is an
    /// additive follow-up).
    fn synthMethodCall(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const mc = self.arena.method_calls.items[data];
        const method_slice = self.arena.strings.slice(mc.method_name);

        // Associated-fn dispatch: the receiver is a bare type name (`.path`).
        if (self.arena.exprKind(mc.receiver) == .path) {
            const type_name = self.arena.exprData(mc.receiver);
            const method = self.lookupMethod(type_name, mc.method_name) orelse {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "no associated function '{s}' on type '{s}'", .{ method_slice, self.arena.strings.slice(type_name) });
                return ResolvedType.unknown;
            };
            if (method.self_kind != .none) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "'{s}' is a method (takes self) — call it as a receiver method 'value.{s}(...)'", .{ method_slice, method_slice });
                return ResolvedType.unknown;
            }
            return try self.checkMethodArgs(id, mc, method, ctx_opt);
        }

        // Instance dispatch (`etch-resolver-types.md §5.5` strict order: inherent
        // → trait → builtin → service). The receiver type name is the user type
        // for a struct / component / resource, or `Entity` for a builtin entity
        // (the conditional-trait-impl receiver).
        const recv_t = try self.synthExprE(mc.receiver, ctx_opt);
        const type_name: StringId = typeNameOfResolved(recv_t) orelse blk: {
            if (recv_t == .builtin and recv_t.builtin == .entity) {
                break :blk self.arena.strings.find("Entity") orelse {
                    // No `Entity` interned ⇒ no trait impl targets it.
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "no method '{s}' on an Entity (no trait impl in scope)", .{method_slice});
                    return ResolvedType.unknown;
                };
            }
            if (recv_t != .unknown) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "method call '{s}' on a value with no methods (builtin / collection methods are not supported here)", .{method_slice});
            return ResolvedType.unknown;
        };

        // Step 1 — inherent method (§5.1).
        if (self.lookupMethod(type_name, mc.method_name)) |method| {
            if (method.self_kind == .none) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "'{s}' is an associated function (no self) — call it as '{s}.{s}(...)'", .{ method_slice, self.arena.strings.slice(type_name), method_slice });
                return ResolvedType.unknown;
            }
            try self.checkMutSelfReceiver(method, mc, ctx_opt);
            return try self.checkMethodArgs(id, mc, method, ctx_opt);
        }

        // Step 2 — trait method (§5.2), after inherent.
        if (try self.findTraitMethod(type_name, mc.method_name, self.arena.exprSpan(id))) |disp| {
            // Conditional impl (§7.3): the `when` conditions must be provable
            // from the calling rule's `when` (E0215 otherwise).
            if (!self.traitImplConditionsProven(disp.when_root, ctx_opt)) {
                try self.emit(.conditional_impl_condition_not_proven, .error_, self.arena.exprSpan(id), "conditional impl method '{s}' requires components the calling context does not guarantee — add the matching 'when ... has' to the rule", .{method_slice});
            }
            try self.checkMutSelfReceiver(disp.method, mc, ctx_opt);
            return try self.checkMethodArgs(id, mc, disp.method, ctx_opt);
        }

        // Steps 3-4 (builtin / service) are §5.3-5.4 — out of M0.8 block-3 core.
        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "no method '{s}' on type '{s}'", .{ method_slice, self.arena.strings.slice(type_name) });
        return ResolvedType.unknown;
    }

    /// One resolved trait-dispatch candidate (M0.8 E2 block 3 tranche C): the
    /// `FnDecl` to call (impl-provided or trait default) + the impl's `when_root`
    /// (for the §7.3 conditional proof).
    const TraitDispatch = struct { method: ast_mod.FnDecl, when_root: u32 };

    /// Find the trait method `method_name` on `type_name` (`etch-resolver-types.md
    /// §5.2`). Scans `trait_impls` for the type; a candidate is an impl-provided
    /// method or, failing that, the trait's default-bodied method. >1 distinct
    /// candidate ⇒ E0211 AmbiguousTraitMethod (the first is returned to avoid a
    /// cascade). M0.8 simplification: multiple conditional impls of the same
    /// trait also surface as E0211 (the §7.3 most-specific-wins / E0216 tie-break
    /// is a refinement — flagged for review).
    fn findTraitMethod(self: *TypeChecker, type_name: StringId, method_name: StringId, span: SourceSpan) TypeError!?TraitDispatch {
        var found: ?TraitDispatch = null;
        var count: u32 = 0;
        for (self.trait_impls.items) |entry| {
            if (entry.type_name != type_name) continue;
            var resolved: ?ast_mod.FnDecl = null;
            var k: u32 = 0;
            while (k < entry.methods_len) : (k += 1) {
                const mth = self.arena.impl_methods.items[entry.methods_start + k];
                if (mth.name == method_name) {
                    resolved = mth;
                    break;
                }
            }
            if (resolved == null) resolved = self.traitDefaultMethod(entry.trait_name, method_name);
            if (resolved) |mth| {
                count += 1;
                if (found == null) found = .{ .method = mth, .when_root = entry.when_root };
            }
        }
        if (count > 1) {
            try self.emit(.ambiguous_trait_method, .error_, span, "ambiguous trait method '{s}' — implemented by more than one trait/impl for this type", .{self.arena.strings.slice(method_name)});
        }
        return found;
    }

    /// The trait's default-bodied method `method_name`, or `null` (M0.8 E2 block
    /// 3 tranche C).
    fn traitDefaultMethod(self: *TypeChecker, trait_name: StringId, method_name: StringId) ?ast_mod.FnDecl {
        const sym = self.symbols.get(trait_name) orelse return null;
        if (sym.kind != .trait_) return null;
        const tdecl = self.arena.trait_decls.items[self.arena.itemData(sym.item_id)];
        var m: u32 = 0;
        while (m < tdecl.methods_len) : (m += 1) {
            const tm = self.arena.impl_methods.items[tdecl.methods_start + m];
            if (tm.name == method_name and tm.has_body) return tm;
        }
        return null;
    }

    /// Prove a conditional trait impl's `when` (§7.3). Unconditional ⇒ always
    /// proven; otherwise every `has C` the impl requires must be in the calling
    /// rule's guaranteed component set (`ctx.components_in_when`). Outside a rule
    /// context, or for an `or`/`not`/resource condition (not provable in M0.8),
    /// the proof fails (conservative).
    fn traitImplConditionsProven(self: *TypeChecker, when_root: u32, ctx_opt: ?*RuleCtx) bool {
        if (when_root == ast_mod.RuleDecl.none_when) return true;
        const ctx = ctx_opt orelse return false;
        return self.requiredComponentsProven(when_root, ctx);
    }

    fn requiredComponentsProven(self: *TypeChecker, idx: u32, ctx: *RuleCtx) bool {
        const node = self.arena.when_nodes.items[idx];
        return switch (node.kind) {
            .has, .has_with_filter => ctx.components_in_when.contains(node.type_name),
            .logical_and => self.requiredComponentsProven(node.lhs, ctx) and self.requiredComponentsProven(node.rhs, ctx),
            else => false, // or / not / resource conditions are not provable in M0.8
        };
    }

    /// E0220 (`etch-resolver-types.md §7.6`): a `mut self` method called on an
    /// immutable receiver. A struct bound by `let` (not `let mut`) is immutable;
    /// `let mut` / a `get_mut` ref is mutable. Skipped without a rule context.
    fn checkMutSelfReceiver(self: *TypeChecker, method: ast_mod.FnDecl, mc: ast_mod.MethodCall, ctx_opt: ?*RuleCtx) !void {
        if (method.self_kind != .by_mut) return;
        const ctx = ctx_opt orelse return;
        if (!isAssignTargetReachable(self.arena, ctx, mc.receiver)) {
            try self.emit(.immutable_receiver_for_mut_self, .error_, self.arena.exprSpan(mc.receiver), "cannot call a 'mut self' method on an immutable receiver (bind it with 'let mut')", .{});
        }
    }

    /// Check a method/associated-fn call's argument count + types against the
    /// resolved `method` (M0.8 E2 block 3) and return its declared return type.
    /// `self` is not part of the argument list (it is the receiver).
    fn checkMethodArgs(self: *TypeChecker, id: NodeId, mc: ast_mod.MethodCall, method: ast_mod.FnDecl, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const ret: ResolvedType = if (method.return_type.isNone()) ResolvedType.unknown else self.namedTypeToResolved(method.return_type);
        if (method.params_len != mc.args_len) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "method '{s}' called with {d} argument(s), expected {d}", .{ self.arena.strings.slice(mc.method_name), mc.args_len, method.params_len });
            return ret;
        }
        var i: u32 = 0;
        while (i < method.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[method.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start + i]);
            const arg_t = try self.synthExprE(arg, ctx_opt);
            if (ptype == .builtin and arg_t == .builtin and !self.literalTypeFits(ptype.builtin, arg, arg_t.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "argument type does not match the parameter type of method '{s}'", .{self.arena.strings.slice(mc.method_name)});
            }
        }
        return ret;
    }

    /// Type an index / slice access (M0.8 collections). A range index
    /// (`arr[0..3]`) yields a dynamic-array slice of the element type; a scalar
    /// index (`arr[i]`) yields the element type. The index must be an integer.
    fn synthIndex(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const ix = self.arena.index_exprs.items[data];
        const recv_t = try self.synthExprE(ix.receiver, ctx_opt);
        if (self.arena.exprKind(ix.index) == .range) {
            _ = try self.synthExprE(ix.index, ctx_opt); // type-check the bounds
            const elem = recv_t.elementType() orelse {
                if (recv_t != .unknown) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "cannot slice a non-array value", .{});
                return ResolvedType.unknown;
            };
            return .{ .array_dyn = elem };
        }
        const idx_t = try self.synthExprE(ix.index, ctx_opt);
        switch (recv_t) {
            .array_fixed => |info| {
                if (idx_t == .builtin and !idx_t.builtin.isInteger()) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(ix.index), "array index must be an integer", .{});
                return .{ .builtin = info.elem };
            },
            .array_dyn => |elem| {
                if (idx_t == .builtin and !idx_t.builtin.isInteger()) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(ix.index), "array index must be an integer", .{});
                return .{ .builtin = elem };
            },
            .unknown => return ResolvedType.unknown,
            else => {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "cannot index a non-collection value", .{});
                return ResolvedType.unknown;
            },
        }
    }

    /// Type a `match` expression (M0.8 v0.6 foundations,
    /// `etch-resolver-types.md` §line 328 + §12.4). The scrutinee type gates
    /// literal-pattern compatibility; all arm bodies must unify to one
    /// result type; the arm set must be exhaustive (E1230 otherwise).
    fn synthMatch(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const m = self.arena.match_exprs.items[data];
        const scrut_t = try self.synthExprE(m.scrutinee, ctx_opt);

        var result_t: ?ResolvedType = null;
        var has_catch_all = false;
        var saw_true = false;
        var saw_false = false;

        // Enum scrutinee: track covered variants for exhaustiveness (E1230,
        // `etch-resolver-types.md §12.4` — all variants ⇒ exhaustive).
        const enum_name: ?StringId = if (scrut_t == .enum_t) scrut_t.enum_t else null;
        var covered: std.ArrayListUnmanaged(bool) = .empty;
        defer covered.deinit(self.gpa);
        if (enum_name) |en| {
            if (self.enumDecl(en)) |d| try covered.appendNTimes(self.gpa, false, d.variants_len);
        }

        var i: u32 = 0;
        while (i < m.arms_len) : (i += 1) {
            const arm = self.arena.match_arms.items[m.arms_start + i];
            switch (arm.pattern_kind) {
                .wildcard, .binding => has_catch_all = true,
                .literal => {
                    const lit: NodeId = @bitCast(arm.pattern_payload);
                    const lit_t = try self.synthExprE(lit, ctx_opt);
                    if (scrut_t == .builtin and lit_t == .builtin and !self.literalTypeFits(scrut_t.builtin, lit, lit_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(lit), "match pattern literal type does not match the scrutinee type", .{});
                    }
                    if (scrut_t == .builtin and scrut_t.builtin == .bool_ and self.arena.exprKind(lit) == .bool_lit) {
                        const s = self.arena.strings.slice(self.arena.exprData(lit));
                        if (std.mem.eql(u8, s, "true")) saw_true = true;
                        if (std.mem.eql(u8, s, "false")) saw_false = true;
                    }
                },
                .enum_variant => {
                    const pat = self.arena.enum_pattern_payloads.items[arm.pattern_payload];
                    if (enum_name) |en| {
                        // A qualified `Type.variant` pattern must name the
                        // scrutinee's enum.
                        if (pat.type_name != 0 and pat.type_name != en) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arm.body), "enum-variant pattern names enum '{s}' but the scrutinee is '{s}'", .{ self.arena.strings.slice(pat.type_name), self.arena.strings.slice(en) });
                        } else if (self.enumVariantIndex(en, pat.variant)) |vidx| {
                            if (vidx < covered.items.len) covered.items[vidx] = true;
                        } else {
                            try self.emit(.enum_variant_not_found, .error_, self.arena.exprSpan(arm.body), "enum '{s}' has no variant '{s}'", .{ self.arena.strings.slice(en), self.arena.strings.slice(pat.variant) });
                        }
                    } else if (scrut_t != .unknown) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arm.body), "enum-variant pattern used on a non-enum scrutinee", .{});
                    }
                },
            }
            const body_t = try self.synthExprE(arm.body, ctx_opt);
            if (result_t == null) {
                result_t = body_t;
            } else if (result_t.? == .builtin and body_t == .builtin and !ResolvedType.eql(result_t.?, body_t)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arm.body), "match arms must all yield the same type", .{});
            }
        }

        if (!has_catch_all) {
            const bool_exhaustive = scrut_t == .builtin and scrut_t.builtin == .bool_ and saw_true and saw_false;
            var enum_exhaustive = false;
            if (enum_name != null) {
                enum_exhaustive = covered.items.len > 0;
                for (covered.items) |c| {
                    if (!c) enum_exhaustive = false;
                }
            }
            if (!bool_exhaustive and !enum_exhaustive) {
                try self.emit(.non_exhaustive_match, .error_, self.arena.exprSpan(id), "non-exhaustive match: add a '_' arm or cover every case", .{});
            }
        }

        return result_t orelse ResolvedType.unknown;
    }

    fn synthBinary(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const bin = self.arena.binary_exprs.items[data];
        const lhs_t = try self.synthExprE(bin.lhs, ctx_opt);
        const rhs_t = try self.synthExprE(bin.rhs, ctx_opt);
        const span = self.arena.exprSpan(id);

        switch (bin.op) {
            .add, .sub, .mul, .div, .rem => {
                if (lhs_t == .builtin and rhs_t == .builtin) {
                    if (lhs_t.builtin.isInteger() and rhs_t.builtin.isInteger() and lhs_t.builtin == rhs_t.builtin) {
                        return lhs_t;
                    }
                    if (lhs_t.builtin.isFloat() and rhs_t.builtin.isFloat() and lhs_t.builtin == rhs_t.builtin) {
                        return lhs_t;
                    }
                    try self.emit(.type_mismatch, .error_, span, "arithmetic operands must have matching primitive type (no implicit coercion in S3)", .{});
                    return ResolvedType.unknown;
                }
                if (lhs_t == .unknown or rhs_t == .unknown) return ResolvedType.unknown;
                try self.emit(.type_mismatch, .error_, span, "arithmetic requires numeric primitive operands", .{});
                return ResolvedType.unknown;
            },
            .eq, .neq, .lt, .gt, .le, .ge => {
                if (lhs_t == .builtin and rhs_t == .builtin and lhs_t.builtin == rhs_t.builtin) {
                    return .{ .builtin = .bool_ };
                }
                if (lhs_t == .unknown or rhs_t == .unknown) return ResolvedType.unknown;
                try self.emit(.type_mismatch, .error_, span, "comparison requires matching primitive operands", .{});
                return ResolvedType.unknown;
            },
            .logical_and, .logical_or => {
                if (lhs_t == .builtin and lhs_t.builtin == .bool_ and rhs_t == .builtin and rhs_t.builtin == .bool_) {
                    return .{ .builtin = .bool_ };
                }
                if (lhs_t == .unknown or rhs_t == .unknown) return ResolvedType.unknown;
                try self.emit(.type_mismatch, .error_, span, "logical operators require bool operands", .{});
                return ResolvedType.unknown;
            },
        }
    }

    fn synthUnary(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const un = self.arena.unary_exprs.items[data];
        const operand_t = try self.synthExprE(un.operand, ctx_opt);
        const span = self.arena.exprSpan(id);
        switch (un.op) {
            .neg => {
                if (operand_t == .builtin and (operand_t.builtin.isInteger() or operand_t.builtin.isFloat())) {
                    return operand_t;
                }
                if (operand_t == .unknown) return ResolvedType.unknown;
                try self.emit(.type_mismatch, .error_, span, "unary minus requires numeric operand", .{});
                return ResolvedType.unknown;
            },
            .logical_not => {
                if (operand_t == .builtin and operand_t.builtin == .bool_) return .{ .builtin = .bool_ };
                if (operand_t == .unknown) return ResolvedType.unknown;
                try self.emit(.type_mismatch, .error_, span, "'not' requires bool operand", .{});
                return ResolvedType.unknown;
            },
        }
    }

    fn lookupFieldType(self: *TypeChecker, receiver_type: ResolvedType, field_name: StringId, span: SourceSpan) !ResolvedType {
        switch (receiver_type) {
            .component => |name_id| {
                const sym = self.symbols.get(name_id) orelse return ResolvedType.unknown;
                const decl = self.arena.component_decls.items[self.arena.itemData(sym.item_id)];
                var i: u32 = 0;
                while (i < decl.fields_len) : (i += 1) {
                    const f = self.arena.fields.items[decl.fields_start + i];
                    if (f.name == field_name) return self.namedTypeToResolved(f.type_node);
                }
                try self.emit(.invalid_field_filter, .error_, span, "field '{s}' does not exist on component '{s}'", .{ self.arena.strings.slice(field_name), self.arena.strings.slice(name_id) });
                return ResolvedType.unknown;
            },
            .resource => |name_id| {
                const sym = self.symbols.get(name_id) orelse return ResolvedType.unknown;
                const decl = self.arena.resource_decls.items[self.arena.itemData(sym.item_id)];
                var i: u32 = 0;
                while (i < decl.fields_len) : (i += 1) {
                    const f = self.arena.fields.items[decl.fields_start + i];
                    if (f.name == field_name) return self.namedTypeToResolved(f.type_node);
                }
                try self.emit(.invalid_field_filter, .error_, span, "field '{s}' does not exist on resource '{s}'", .{ self.arena.strings.slice(field_name), self.arena.strings.slice(name_id) });
                return ResolvedType.unknown;
            },
            .struct_t => |name_id| {
                // Field of a `struct` value (M0.8 E2 block 3) — e.g. `self.x`
                // inside a method or `v.x` on a struct local.
                const sym = self.symbols.get(name_id) orelse return ResolvedType.unknown;
                const decl = self.arena.struct_decls.items[self.arena.itemData(sym.item_id)];
                var i: u32 = 0;
                while (i < decl.fields_len) : (i += 1) {
                    const f = self.arena.fields.items[decl.fields_start + i];
                    if (f.name == field_name) return self.namedTypeToResolved(f.type_node);
                }
                try self.emit(.invalid_field_filter, .error_, span, "field '{s}' does not exist on struct '{s}'", .{ self.arena.strings.slice(field_name), self.arena.strings.slice(name_id) });
                return ResolvedType.unknown;
            },
            .builtin, .range, .array_fixed, .array_dyn, .map_t, .set_t, .closure, .enum_t, .generic, .optional, .unknown => return ResolvedType.unknown,
        }
    }

    // ─── Diagnostic emit ─────────────────────────────────────────────────

    fn emit(self: *TypeChecker, code: DiagnosticCode, severity: diag_mod.Severity, span: SourceSpan, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.diagnostics.append(self.gpa, .{
            .code = code,
            .severity = severity,
            .primary_span = span,
            .primary_message = message,
        });
    }
};

// ─── Helpers reachable from tests ───────────────────────────────────────

/// Return `true` if the expression at `id` can be folded to a value
/// at type-check time (literals + arithmetic/comparison/logic on
/// const-evaluable operands). Drives the `component` default-value
/// admissibility check in the S3 type-checker.
pub fn isConstEvaluable(arena: *const AstArena, id: NodeId) bool {
    const kind = arena.exprKind(id);
    return switch (kind) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .tag_path => true,
        .binary => blk: {
            const bin = arena.binary_exprs.items[arena.exprData(id)];
            // Arithmetic / comparison / logic on const-evaluable args is OK.
            // The S3 brief restricts defaults to "literals + arithmetic on
            // literals + parenthesized" — we allow comparison/logic too as
            // long as both sides are const-evaluable; the brief's intent is
            // to keep defaults compile-time, and these operations are.
            break :blk isConstEvaluable(arena, bin.lhs) and isConstEvaluable(arena, bin.rhs);
        },
        .unary => blk: {
            const un = arena.unary_exprs.items[arena.exprData(id)];
            break :blk isConstEvaluable(arena, un.operand);
        },
        else => false,
    };
}

fn isAssignTargetReachable(arena: *const AstArena, ctx: *TypeChecker.RuleCtx, id: NodeId) bool {
    var cur = id;
    while (true) {
        const k = arena.exprKind(cur);
        switch (k) {
            .field_access => {
                const fa = arena.field_accesses.items[arena.exprData(cur)];
                cur = fa.receiver;
            },
            .method_get_mut => return true,
            .method_get => return false,
            .ident => {
                const name_id = arena.exprData(cur);
                if (ctx.locals.get(name_id)) |local| return local.is_mut;
                return false;
            },
            else => return false,
        }
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const parser_mod = @import("parser.zig");

/// Bundle returned by the convenience `parseAndCheck` test helper —
/// owns the arena, the parse diagnostics slice, and the type-check
/// diagnostics list.
pub const CheckOutcome = struct {
    ast: AstArena,
    parse_diags: []Diagnostic,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    pub fn deinit(self: *CheckOutcome, gpa: std.mem.Allocator) void {
        for (self.parse_diags) |*d| d.deinit(gpa);
        gpa.free(self.parse_diags);
        for (self.diagnostics.items) |*d| d.deinit(gpa);
        self.diagnostics.deinit(gpa);
        self.ast.deinit(gpa);
    }
};

fn parseAndCheck(gpa: std.mem.Allocator, source: []const u8) !CheckOutcome {
    var pr = try parser_mod.parse(gpa, source);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    try TypeChecker.check(gpa, &pr.ast, &diags);
    return .{ .ast = pr.ast, .parse_diags = pr.diagnostics, .diagnostics = diags };
}

fn expectAnyCode(diagnostics: []const Diagnostic, code: DiagnosticCode) !void {
    for (diagnostics) |d| if (d.code == code) return;
    return error.DiagnosticCodeNotEmitted;
}

fn expectNoCode(diagnostics: []const Diagnostic, code: DiagnosticCode) !void {
    for (diagnostics) |d| if (d.code == code) return error.DiagnosticCodeUnexpectedlyEmitted;
}

test "type-checker emits E0101 on duplicate component declaration" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\component Health { max: float = 100.0 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .duplicate_symbol);
}

test "type-checker emits E0102 on field referencing unknown type" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: NotAType = 0 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .undefined_symbol);
}

test "type-checker emits E0200 on arithmetic between int and float without cast" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\rule tick(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let x = 1 + 2.0
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .type_mismatch);
}

test "type-checker emits E1101 on non-const default value" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = some_var }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .not_const_evaluable);
}

test "type-checker emits E0502 when an annotation is applied to the wrong target (D-S3-annot-applicability)" {
    const gpa = std.testing.allocator;

    // `@config` is resource-only — on a component it must be flagged.
    var on_component = try parseAndCheck(gpa,
        \\@config
        \\component Health { current: float = 100.0 }
    );
    defer on_component.deinit(gpa);
    try expectAnyCode(on_component.diagnostics.items, .annotation_misapplied);

    // `@replicated` is field-only — on a component it must be flagged.
    var item_only = try parseAndCheck(gpa,
        \\@replicated(predicted)
        \\component Predicted { flag: bool = false }
    );
    defer item_only.deinit(gpa);
    try expectAnyCode(item_only.diagnostics.items, .annotation_misapplied);

    // Control — every annotation here sits on a valid target, so no E0502.
    var ok = try parseAndCheck(gpa,
        \\@config
        \\resource GameConfig { max_players: i32 = 8 }
        \\@phase(.update)
        \\rule tick(entity: Entity)
        \\  when entity has Tag
        \\{
        \\}
        \\component Tag {
        \\  @hidden
        \\  flag: bool = false
        \\  @replicated(predicted)
        \\  net: bool = false
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .annotation_misapplied);
}

test "type-checker emits E0301/E0302 on get receiver/kind mismatch (D-S3-resource-receiver)" {
    const gpa = std.testing.allocator;

    // Receiver-less `get(Health)` where Health is a component → E0301.
    var bare_on_component = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\rule tick(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let h = get(Health)
        \\}
    );
    defer bare_on_component.deinit(gpa);
    try expectAnyCode(bare_on_component.diagnostics.items, .resource_expected_component_given);

    // `entity.get(Score)` where Score is a resource → E0302.
    var receiver_on_resource = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\resource Score { points: i32 = 0 }
        \\rule tick(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let s = entity.get(Score)
        \\}
    );
    defer receiver_on_resource.deinit(gpa);
    try expectAnyCode(receiver_on_resource.diagnostics.items, .component_expected_resource_given);

    // Control — receiver-less `get_mut(R)` on a resource present in the when
    // clause is valid; neither E0301 nor E0302 fires.
    var ok = try parseAndCheck(gpa,
        \\resource Score { points: i32 = 0 }
        \\rule tick()
        \\  when resource Score
        \\{
        \\  let s = get_mut(Score)
        \\  s.points += 1
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .resource_expected_component_given);
    try expectNoCode(ok.diagnostics.items, .component_expected_resource_given);
}

test "type-checker emits E1213 on receiver-less get of a resource absent from the when clause (D-S3-resource-receiver)" {
    const gpa = std.testing.allocator;
    // `get(Score)` is valid only when Score is in the when clause.
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\resource Score { points: i32 = 0 }
        \\rule tick(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let s = get(Score)
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .resource_expected_in_when);
}

test "for-in requires an integer range iterable (M0.8 ranges + for-in)" {
    const gpa = std.testing.allocator;

    // Valid integer range for-in → no type error.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let mut s = 0
        \\  for i in 0..3 { s += i }
        \\  entity.get_mut(C).out = s
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // Non-range iterable → E0200.
    var not_range = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  for i in 5 { let x = i }
        \\}
    );
    defer not_range.deinit(gpa);
    try expectAnyCode(not_range.diagnostics.items, .type_mismatch);

    // Non-integer range bounds → E0200.
    var float_range = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  for i in 0.0..3.0 { let x = i }
        \\}
    );
    defer float_range.deinit(gpa);
    try expectAnyCode(float_range.diagnostics.items, .type_mismatch);
}

test "match exhaustiveness and arm typing (M0.8 match foundation)" {
    const gpa = std.testing.allocator;

    // Exhaustive via wildcard → no exhaustiveness or typing error.
    var ok = try parseAndCheck(gpa,
        \\component C { level: int = 0, out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let lvl = entity.get(C).level
        \\  entity.get_mut(C).out = match lvl { 0 => 10, 1 => 20, _ => 0 }
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .non_exhaustive_match);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // Non-exhaustive int match (no catch-all) → E1230.
    var bad = try parseAndCheck(gpa,
        \\component C { level: int = 0, out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let lvl = entity.get(C).level
        \\  entity.get_mut(C).out = match lvl { 0 => 10, 1 => 20 }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .non_exhaustive_match);

    // Bool match covering true and false → exhaustive without a wildcard.
    var boolean = try parseAndCheck(gpa,
        \\component C { flag: bool = false, out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let f = entity.get(C).flag
        \\  entity.get_mut(C).out = match f { true => 1, false => 0 }
        \\}
    );
    defer boolean.deinit(gpa);
    try expectNoCode(boolean.diagnostics.items, .non_exhaustive_match);

    // Arms yielding different types → E0200.
    var mixed = try parseAndCheck(gpa,
        \\component C { level: int = 0, out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let lvl = entity.get(C).level
        \\  let x = match lvl { 0 => 1, _ => true }
        \\}
    );
    defer mixed.deinit(gpa);
    try expectAnyCode(mixed.diagnostics.items, .type_mismatch);
}

test "enum match exhaustiveness and variant resolution (M0.8 E2 block 3 tranche B)" {
    const gpa = std.testing.allocator;

    // All variants covered (no `_`) → exhaustive (E1230 not emitted), no E0105.
    var ok = try parseAndCheck(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let d = Difficulty.hard
        \\  entity.get_mut(C).out = match d { Difficulty.easy => 1, .normal => 2, Difficulty.hard => 3 }
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .non_exhaustive_match);
    try expectNoCode(ok.diagnostics.items, .enum_variant_not_found);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // A missing variant without a `_` arm → E1230.
    var bad = try parseAndCheck(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let d = Difficulty.hard
        \\  entity.get_mut(C).out = match d { Difficulty.easy => 1, Difficulty.normal => 2 }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .non_exhaustive_match);

    // A partial cover with a `_` catch-all → exhaustive.
    var wild = try parseAndCheck(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let d = Difficulty.easy
        \\  entity.get_mut(C).out = match d { Difficulty.easy => 1, _ => 0 }
        \\}
    );
    defer wild.deinit(gpa);
    try expectNoCode(wild.diagnostics.items, .non_exhaustive_match);

    // An unknown variant → E0105 (both in a value form and a pattern).
    var unknown = try parseAndCheck(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let d = Difficulty.medium
        \\  entity.get_mut(C).out = match d { Difficulty.easy => 1, _ => 0 }
        \\}
    );
    defer unknown.deinit(gpa);
    try expectAnyCode(unknown.diagnostics.items, .enum_variant_not_found);
}

test "trait dispatch, E0220 mut-self receiver, E0214 incomplete impl (M0.8 E2 block 3 tranche C)" {
    const gpa = std.testing.allocator;

    // Trait method on a struct dispatches cleanly (no inherent method of that
    // name; trait wins at step 2). The default `doubled` calls the abstract
    // `base` the impl provides.
    var ok = try parseAndCheck(gpa,
        \\trait Doubler { fn base(self) -> int  fn doubled(self) -> int { self.base() * 2 } }
        \\struct N { v: int = 0 }
        \\impl Doubler for N { fn base(self) -> int { self.v } }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let n = N { v: 21 }
        \\  entity.get_mut(C).out = n.doubled()
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);
    try expectNoCode(ok.diagnostics.items, .incomplete_trait_impl);
    try expectNoCode(ok.diagnostics.items, .immutable_receiver_for_mut_self);

    // E0220: a `mut self` method on an immutable (`let`) receiver.
    var immut = try parseAndCheck(gpa,
        \\struct Cnt { v: int = 0 }
        \\impl Cnt { fn bump(mut self) { self.v += 1 } }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let c = Cnt { v: 0 }
        \\  c.bump()
        \\}
    );
    defer immut.deinit(gpa);
    try expectAnyCode(immut.diagnostics.items, .immutable_receiver_for_mut_self);

    // The same call on a `let mut` receiver is fine.
    var mut_ok = try parseAndCheck(gpa,
        \\struct Cnt { v: int = 0 }
        \\impl Cnt { fn bump(mut self) { self.v += 1 } }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let mut c = Cnt { v: 0 }
        \\  c.bump()
        \\}
    );
    defer mut_ok.deinit(gpa);
    try expectNoCode(mut_ok.diagnostics.items, .immutable_receiver_for_mut_self);

    // E0214: an impl missing an abstract trait method.
    var incomplete = try parseAndCheck(gpa,
        \\trait Damageable { fn take_damage(self, amount: int)  fn heal(self, amount: int) }
        \\struct Mob { hp: int = 0 }
        \\impl Damageable for Mob { fn take_damage(self, amount: int) {} }
    );
    defer incomplete.deinit(gpa);
    try expectAnyCode(incomplete.diagnostics.items, .incomplete_trait_impl);
}

test "conditional trait impl proof E0215 (M0.8 E2 block 3 tranche C §7.3)" {
    const gpa = std.testing.allocator;

    // A conditional impl `when self has Health` called from a rule whose `when`
    // does NOT guarantee Health → E0215.
    var not_proven = try parseAndCheck(gpa,
        \\trait Damageable { fn take_damage(self, amount: int) }
        \\component Health { current: int = 100 }
        \\component Marker { tag: int = 0 }
        \\impl Damageable for Entity when self has Health {
        \\  fn take_damage(self, amount: int) { self.get_mut(Health).current -= amount }
        \\}
        \\rule hit(entity: Entity) when entity has Marker {
        \\  entity.take_damage(10)
        \\}
    );
    defer not_proven.deinit(gpa);
    try expectAnyCode(not_proven.diagnostics.items, .conditional_impl_condition_not_proven);

    // The same call from a rule whose `when` guarantees Health → proven.
    var proven = try parseAndCheck(gpa,
        \\trait Damageable { fn take_damage(self, amount: int) }
        \\component Health { current: int = 100 }
        \\impl Damageable for Entity when self has Health {
        \\  fn take_damage(self, amount: int) { self.get_mut(Health).current -= amount }
        \\}
        \\rule hit(entity: Entity) when entity has Health {
        \\  entity.take_damage(10)
        \\}
    );
    defer proven.deinit(gpa);
    try expectNoCode(proven.diagnostics.items, .conditional_impl_condition_not_proven);
}

test "optional if let / while let binding + non-optional rejection (M0.8 E2 block 5)" {
    const gpa = std.testing.allocator;

    // `if let x = <int?>` binds `x` to the int payload; `x + 1` type-checks.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let o: int? = some(41)
        \\  entity.get_mut(C).out = if let x = o { x + 1 } else { 0 }
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // `if let` / `while let` on a non-optional scrutinee → E0200 (type mismatch).
    var bad = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let n = 5
        \\  if let x = n { entity.get_mut(C).out = x }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);

    // `while let` binds the payload in the body scope.
    var wl = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let mut acc = 0
        \\  let o: int? = some(3)
        \\  while let y = o { acc += y  break }
        \\  entity.get_mut(C).out = acc
        \\}
    );
    defer wl.deinit(gpa);
    try expectNoCode(wl.diagnostics.items, .type_mismatch);
}

test "generic fn inference + bounds (E0601/E0603/E0604, M0.8 E2 block 4)" {
    const gpa = std.testing.allocator;

    // `id<T>(x: T) -> T` inferred from the arg; no diagnostic, result is int.
    var ok = try parseAndCheck(gpa,
        \\fn id<T>(x: T) -> T { x }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  entity.get_mut(C).out = id(41)
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .generic_type_annotation_required);
    try expectNoCode(ok.diagnostics.items, .inconsistent_generic_inference);
    try expectNoCode(ok.diagnostics.items, .bound_not_satisfied);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // E0604: `T` inferred as two different types.
    var inconsistent = try parseAndCheck(gpa,
        \\fn pick<T>(a: T, b: T) -> T { a }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let x = pick(1, true)
        \\  entity.get_mut(C).out = 0
        \\}
    );
    defer inconsistent.deinit(gpa);
    try expectAnyCode(inconsistent.diagnostics.items, .inconsistent_generic_inference);

    // E0603: `T` appears only in the return — not inferable from the args.
    var uninferable = try parseAndCheck(gpa,
        \\fn make<T>() -> T { make() }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let x = make()
        \\  entity.get_mut(C).out = 0
        \\}
    );
    defer uninferable.deinit(gpa);
    try expectAnyCode(uninferable.diagnostics.items, .generic_type_annotation_required);

    // E0601: a trait-bounded param inferred to a type with no matching impl.
    var unbound = try parseAndCheck(gpa,
        \\trait Showable { fn show(self) -> int }
        \\struct Named { id: int = 0 }
        \\fn render<T: Showable>(t: T) -> int { 0 }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let n = Named { id: 1 }
        \\  let x = render(n)
        \\  entity.get_mut(C).out = 0
        \\}
    );
    defer unbound.deinit(gpa);
    try expectAnyCode(unbound.diagnostics.items, .bound_not_satisfied);

    // The same call satisfies the bound once `Named` implements the trait.
    var bound_ok = try parseAndCheck(gpa,
        \\trait Showable { fn show(self) -> int }
        \\struct Named { id: int = 0 }
        \\impl Showable for Named { fn show(self) -> int { self.id } }
        \\fn render<T: Showable>(t: T) -> int { 0 }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C {
        \\  let n = Named { id: 1 }
        \\  let x = render(n)
        \\  entity.get_mut(C).out = 0
        \\}
    );
    defer bound_ok.deinit(gpa);
    try expectNoCode(bound_ok.diagnostics.items, .bound_not_satisfied);

    // A generic struct's field typed by a param is accepted (no spurious error).
    var generic_struct = try parseAndCheck(gpa,
        \\struct Box<T> { value: T }
        \\component C { out: int = 0 }
        \\rule r(entity: Entity) when entity has C { entity.get_mut(C).out = 0 }
    );
    defer generic_struct.deinit(gpa);
    try expectNoCode(generic_struct.diagnostics.items, .undefined_symbol);
}

test "assert requires a bool condition (M0.8 assert foundation)" {
    const gpa = std.testing.allocator;

    // Non-bool assert condition → E0200.
    var bad = try parseAndCheck(gpa,
        \\resource R { n: i32 = 0 }
        \\rule r()
        \\  when resource R
        \\{
        \\  assert(1 + 2)
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);

    // Bool assert condition → no type error.
    var ok = try parseAndCheck(gpa,
        \\resource R { n: i32 = 0 }
        \\rule r()
        \\  when resource R
        \\{
        \\  assert(1 < 2)
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);
}

test "if requires a bool condition and unifies its branch types (M0.8 control flow)" {
    const gpa = std.testing.allocator;

    // Non-bool condition → E0200.
    var bad_cond = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let x = if 5 { 1 } else { 2 }
        \\  entity.get_mut(C).out = x
        \\}
    );
    defer bad_cond.deinit(gpa);
    try expectAnyCode(bad_cond.diagnostics.items, .type_mismatch);

    // Branches yielding different types → E0200.
    var bad_branch = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let x = if 1 < 2 { 1 } else { true }
        \\}
    );
    defer bad_branch.deinit(gpa);
    try expectAnyCode(bad_branch.diagnostics.items, .type_mismatch);

    // Valid bool condition + unified int branches → no type error.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let x = if 1 < 2 { 10 } else { 20 }
        \\  entity.get_mut(C).out = x
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);
}

test "while requires a bool condition (M0.8 control flow)" {
    const gpa = std.testing.allocator;

    // Non-bool while condition → E0200.
    var bad = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let mut i = 0
        \\  while i { i += 1 }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);

    // Bool while condition → no type error.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let mut i = 0
        \\  while i < 3 { i += 1 }
        \\  entity.get_mut(C).out = i
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);
}

test "type aliases resolve through to the underlying type (M0.8 type alias foundation)" {
    const gpa = std.testing.allocator;

    // `Meters` aliases `float` and is used as a field type and a cast target.
    var ok = try parseAndCheck(gpa,
        \\type Meters = float
        \\component Position { x: Meters = 0.0 }
        \\rule move(entity: Entity)
        \\  when entity has Position
        \\{
        \\  entity.get_mut(Position).x = 3 as Meters
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // An alias whose target names no known type → E0102.
    var bad = try parseAndCheck(gpa,
        \\type Bogus = NotAType
        \\component C { x: Bogus = 0 }
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .undefined_symbol);

    // An alias name colliding with a component name → E0101.
    var dup = try parseAndCheck(gpa,
        \\type Foo = int
        \\component Foo { x: int = 0 }
    );
    defer dup.deinit(gpa);
    try expectAnyCode(dup.diagnostics.items, .duplicate_symbol);
}

test "type-checker accepts numeric casts and rejects non-numeric ones (M0.8 cast foundation)" {
    const gpa = std.testing.allocator;

    // Numeric → numeric cast chain is accepted.
    var ok = try parseAndCheck(gpa,
        \\component C { x: float = 0.0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let y = 3 as f32
        \\  entity.get_mut(C).x = y as float
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // Cast target is not a numeric primitive → E0200.
    var bad_target = try parseAndCheck(gpa,
        \\component C { x: float = 0.0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let y = 3 as bool
        \\}
    );
    defer bad_target.deinit(gpa);
    try expectAnyCode(bad_target.diagnostics.items, .type_mismatch);

    // Cast operand is not numeric → E0200.
    var bad_operand = try parseAndCheck(gpa,
        \\component C { x: float = 0.0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let y = true as f32
        \\}
    );
    defer bad_operand.deinit(gpa);
    try expectAnyCode(bad_operand.diagnostics.items, .type_mismatch);
}

test "type-checker emits E1210 on rule when clause referencing unknown component" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\rule tick(entity: Entity)
        \\  when entity has NotAComponent
        \\{
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .unknown_component_in_when);
}

test "type-checker emits E1211 on field filter type mismatch" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\rule tick(entity: Entity)
        \\  when entity has Health { current == 5 }
        \\{
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .invalid_field_filter);
}

test "type-checker emits E1213 on resource clause referencing unknown resource" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\rule tick()
        \\  when resource NotAResource
        \\{
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .resource_expected_in_when);
}

test "type-checker rejects get/get_mut for components absent from when clause" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\component Armor { resistance: float = 0.0 }
        \\rule tick(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let a = entity.get(Armor)
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .unknown_component_in_when);
}

test "type-checker rule body let mut allows reassignment, immutable let does not" {
    const gpa = std.testing.allocator;
    var result_ok = try parseAndCheck(gpa,
        \\rule tick() {
        \\  let mut x = 0
        \\  x = 5
        \\}
    );
    defer result_ok.deinit(gpa);
    for (result_ok.diagnostics.items) |d| {
        try std.testing.expect(d.code != .type_mismatch);
    }

    var result_bad = try parseAndCheck(gpa,
        \\rule tick() {
        \\  let x = 0
        \\  x = 5
        \\}
    );
    defer result_bad.deinit(gpa);
    try expectAnyCode(result_bad.diagnostics.items, .type_mismatch);
}

test "type-checker accepts compound assignment += on numeric field via get_mut" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\rule heal(entity: Entity)
        \\  when entity has Health
        \\{
        \\  entity.get_mut(Health).current += 1.0
        \\}
    );
    defer result.deinit(gpa);
    if (result.parse_diags.len > 0) {
        std.debug.print("parse diag: {s}\n", .{result.parse_diags[0].primary_message});
        try std.testing.expect(false);
    }
    for (result.diagnostics.items) |d| {
        std.debug.print("diag {s}: {s}\n", .{ d.code.code(), d.primary_message });
    }
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "type-checker rejects string field on component (POD enforcement)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Bad { name: string }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .undefined_symbol);
}

test "type-checker accepts top-level declarations in any order via pass 1 / pass 2" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\rule tick(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let h = entity.get(Health)
        \\}
        \\component Health { current: float = 100.0 }
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "array literal element typing, indexing, and slicing (M0.8 collections)" {
    const gpa = std.testing.allocator;

    // Indexing a homogeneous array yields the element type — assigning it to
    // a matching field is clean.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let a = [10, 20, 30]
        \\  let s = a[0..2]
        \\  entity.get_mut(C).out = a[1] + s[0]
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // Heterogeneous elements (int + float) → E0200.
    var mixed = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let a = [1, 2.0]
        \\  entity.get_mut(C).out = a[0]
        \\}
    );
    defer mixed.deinit(gpa);
    try expectAnyCode(mixed.diagnostics.items, .type_mismatch);

    // Non-integer index → E0200.
    var bad_idx = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let a = [1, 2, 3]
        \\  let y = a[true]
        \\}
    );
    defer bad_idx.deinit(gpa);
    try expectAnyCode(bad_idx.diagnostics.items, .type_mismatch);

    // Indexing a non-collection → E0200.
    var not_coll = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let n = 5
        \\  let y = n[0]
        \\}
    );
    defer not_coll.deinit(gpa);
    try expectAnyCode(not_coll.diagnostics.items, .type_mismatch);

    // Collection field types are rejected (E1 components stay scalar POD).
    var coll_field = try parseAndCheck(gpa,
        \\component Bad { items: int[] }
    );
    defer coll_field.deinit(gpa);
    try expectAnyCode(coll_field.diagnostics.items, .undefined_symbol);
}

test "map literal typing and map for-in bindings (M0.8 collections)" {
    const gpa = std.testing.allocator;

    // A two-binding map for-in (`for k, v in m`) is clean.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let m = [1: 10, 2: 20]
        \\  for k, v in m { entity.get_mut(C).out += v }
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // A single-binding map for-in → E0200 (maps bind two variables).
    var single = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let m = [1: 10, 2: 20]
        \\  for k in m { entity.get_mut(C).out = k }
        \\}
    );
    defer single.deinit(gpa);
    try expectAnyCode(single.diagnostics.items, .type_mismatch);
}

test "closure call arity, return typing, and non-callable (M0.8 closures)" {
    const gpa = std.testing.allocator;

    // A closure returning int, called and assigned to an int field — clean.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let double = |x: int| x * 2
        \\  entity.get_mut(C).out = double(5)
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // Wrong arity → E0200.
    var arity = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let double = |x: int| x * 2
        \\  let y = double(1, 2)
        \\}
    );
    defer arity.deinit(gpa);
    try expectAnyCode(arity.diagnostics.items, .type_mismatch);

    // Calling a non-closure → E0200.
    var noncallable = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let n = 5
        \\  let y = n(3)
        \\}
    );
    defer noncallable.deinit(gpa);
    try expectAnyCode(noncallable.diagnostics.items, .type_mismatch);
}

test "free-function call arity, arg, and return typing (M0.8 E2)" {
    const gpa = std.testing.allocator;

    // A top-level fn returning int, called and assigned to an int field — clean.
    var ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\fn double(x: int) -> int { x * 2 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  entity.get_mut(C).out = double(21)
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);

    // Wrong arity → E0200.
    var arity = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\fn double(x: int) -> int { x * 2 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let y = double(1, 2)
        \\}
    );
    defer arity.deinit(gpa);
    try expectAnyCode(arity.diagnostics.items, .type_mismatch);

    // Argument type mismatch (float arg to an int param) → E0200.
    var argty = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\fn double(x: int) -> int { x * 2 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let y = double(1.5)
        \\}
    );
    defer argty.deinit(gpa);
    try expectAnyCode(argty.diagnostics.items, .type_mismatch);

    // Body value type does not match the declared return type → E0200.
    var retty = try parseAndCheck(gpa,
        \\fn bad(x: int) -> bool { x * 2 }
    );
    defer retty.deinit(gpa);
    try expectAnyCode(retty.diagnostics.items, .type_mismatch);
}

test "struct inherent methods: dispatch, struct literal, and error cases (M0.8 E2 block 3)" {
    const gpa = std.testing.allocator;

    // Valid: an associated fn builds the struct via a literal, an instance
    // method reads it — clean.
    var ok = try parseAndCheck(gpa,
        \\struct V2 { x: int = 0, y: int = 0 }
        \\impl V2 {
        \\  fn sum(self) -> int { self.x + self.y }
        \\  fn make(a: int, b: int) -> V2 { V2 { x: a, y: b } }
        \\}
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let v = V2.make(3, 4)
        \\  entity.get_mut(Acc).out = v.sum()
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .type_mismatch);
    try expectNoCode(ok.diagnostics.items, .undefined_symbol);

    // No such method on the type → E0200.
    var no_method = try parseAndCheck(gpa,
        \\struct V2 { x: int = 0 }
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let v = V2 { x: 1 }
        \\  entity.get_mut(Acc).out = v.nope()
        \\}
    );
    defer no_method.deinit(gpa);
    try expectAnyCode(no_method.diagnostics.items, .type_mismatch);

    // Calling an associated fn through an instance receiver → E0200.
    var wrong_kind = try parseAndCheck(gpa,
        \\struct V2 { x: int = 0 }
        \\impl V2 { fn make() -> V2 { V2 { x: 1 } } }
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let v = V2 { x: 1 }
        \\  entity.get_mut(Acc).out = v.make().x
        \\}
    );
    defer wrong_kind.deinit(gpa);
    try expectAnyCode(wrong_kind.diagnostics.items, .type_mismatch);

    // Struct literal naming a field the struct does not have → E1211.
    var bad_field = try parseAndCheck(gpa,
        \\struct V2 { x: int = 0 }
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let v = V2 { z: 1 }
        \\}
    );
    defer bad_field.deinit(gpa);
    try expectAnyCode(bad_field.diagnostics.items, .invalid_field_filter);

    // `impl` on an undeclared type → E0102.
    var no_target = try parseAndCheck(gpa,
        \\impl Ghost { fn f(self) -> int { 0 } }
    );
    defer no_target.deinit(gpa);
    try expectAnyCode(no_target.diagnostics.items, .undefined_symbol);

    // Argument-count mismatch on an associated fn → E0200.
    var arity = try parseAndCheck(gpa,
        \\struct V2 { x: int = 0 }
        \\impl V2 { fn make(a: int) -> V2 { V2 { x: a } } }
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let v = V2.make(1, 2)
        \\}
    );
    defer arity.deinit(gpa);
    try expectAnyCode(arity.diagnostics.items, .type_mismatch);
}

test "type-checker validates event declaration + emit (M0.8 E3)" {
    const gpa = std.testing.allocator;

    // Clean: a declared event emitted with matching fields → no diagnostics.
    var ok = try parseAndCheck(gpa,
        \\event Damage { amount: int = 0, crit: bool = false }
        \\component Health { current: float = 100.0 }
        \\rule deal(entity: Entity)
        \\  when entity has Health
        \\{
        \\  emit Damage { amount: 5, crit: true }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // Emitting an undeclared event → E0102 (undefined_symbol).
    var unknown_evt = try parseAndCheck(gpa,
        \\rule r() { emit Ghost { x: 1 } }
    );
    defer unknown_evt.deinit(gpa);
    try expectAnyCode(unknown_evt.diagnostics.items, .undefined_symbol);

    // Emitting a field the event does not declare → E1211 (invalid_field_filter).
    var bad_field = try parseAndCheck(gpa,
        \\event Damage { amount: int = 0 }
        \\rule r() { emit Damage { nope: 1 } }
    );
    defer bad_field.deinit(gpa);
    try expectAnyCode(bad_field.diagnostics.items, .invalid_field_filter);

    // `emit`-ing a non-event (a component) → E0102 (not a declared event).
    var not_event = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\rule r() { emit Health { current: 1.0 } }
    );
    defer not_event.deinit(gpa);
    try expectAnyCode(not_event.diagnostics.items, .undefined_symbol);
}

test "type-checker validates @networked on event, rejects @config on event (M0.8 E3)" {
    const gpa = std.testing.allocator;

    // `@networked` is valid on an event (`etch-grammar.md` §18.2) → no E0502.
    var net = try parseAndCheck(gpa,
        \\@networked
        \\event Hit { amount: int = 0 }
    );
    defer net.deinit(gpa);
    try expectNoCode(net.diagnostics.items, .annotation_misapplied);

    // `@config` (resource-only) on an event → E0502 AnnotationMisapplied.
    var misapplied = try parseAndCheck(gpa,
        \\@config
        \\event Hit { amount: int = 0 }
    );
    defer misapplied.deinit(gpa);
    try expectAnyCode(misapplied.diagnostics.items, .annotation_misapplied);
}

test "type-checker validates tag-filter when conditions (M0.8 E3)" {
    const gpa = std.testing.allocator;

    // Valid: a declared leaf path in a `has_tag` filter → no E1212.
    var ok = try parseAndCheck(gpa,
        \\tags { character { status { alive, stunned } } }
        \\component Health { current: float = 100.0 }
        \\rule r(entity: Entity) when entity has Health and entity has_tag .character.status.stunned { }
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .unknown_tag);

    // Unknown tag path → E1212 UnknownTag.
    var unknown = try parseAndCheck(gpa,
        \\tags { character { status { alive } } }
        \\rule r(entity: Entity) when entity has_tag .character.status.frozen { }
    );
    defer unknown.deinit(gpa);
    try expectAnyCode(unknown.diagnostics.items, .unknown_tag);

    // A namespace where `has_tag` requires a leaf → E1212.
    var ns = try parseAndCheck(gpa,
        \\tags { character { status { alive } } }
        \\rule r(entity: Entity) when entity has_tag .character.status { }
    );
    defer ns.deinit(gpa);
    try expectAnyCode(ns.diagnostics.items, .unknown_tag);

    // `has_any_tag` accepts a category namespace (mask) → no E1212.
    var cat = try parseAndCheck(gpa,
        \\tags { character { status { alive, stunned } } }
        \\rule r(entity: Entity) when entity has_any_tag .character.status { }
    );
    defer cat.deinit(gpa);
    try expectNoCode(cat.diagnostics.items, .unknown_tag);
}
