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
pub const SymbolKind = enum { component, resource, rule, type_alias };

const Symbol = struct {
    kind: SymbolKind,
    name: StringId,
    item_id: NodeId,
};

/// Target categories the annotation-applicability check distinguishes
/// (M0.8 D-S3-annot-applicability). At E1 only `component` / `resource` /
/// `rule` items and their `field`s exist; `event` and other construct
/// targets arrive with their constructs in later stages.
const AnnotTarget = enum { component, resource, rule, field };

/// Whether a builtin annotation kind is valid on `target`
/// (cf. `etch-resolver-types.md` §13.2 + `etch-reference-part3.md` §1-§10).
/// `.custom` is accepted everywhere (plugin-registered, schema validated
/// Phase 3). Annotations whose only valid target is a construct not present
/// at E1 (`@networked` → `event`, `@loc` → expression) return `false` on
/// every current target.
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
        .networked => false,
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

    pub fn deinit(self: *TypeChecker) void {
        self.symbols.deinit(self.gpa);
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
                .rule_decl => {
                    const decl = self.arena.rule_decls.items[data];
                    try self.registerSymbol(.rule, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .rule);
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
                // Resolve through any top-level `type` alias chain first (M0.8).
                const resolved_name = self.arena.resolveTypeAliasName(named.name);
                const tname = self.arena.strings.slice(resolved_name);
                if (BuiltinType.fromName(tname)) |bt| return .{ .builtin = bt };
                if (self.symbols.get(resolved_name)) |sym| {
                    return switch (sym.kind) {
                        .component => .{ .component = resolved_name },
                        .resource => .{ .resource = resolved_name },
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
                else => {},
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
                var elem_t: ResolvedType = ResolvedType.unknown;
                if (iter_t == .range) {
                    elem_t = .{ .builtin = iter_t.range };
                } else if (iter_t != .unknown) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(f.iterable), "for-in iterable must be a range in E1 (array/map iteration arrives with collections)", .{});
                }
                if (f.index_name != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(f.iterable), "a range for-in binds a single loop variable", .{});
                }
                try ctx.locals.put(self.gpa, f.var_name, .{ .type_ = elem_t, .is_mut = false });
                var i: u32 = 0;
                while (i < f.body_len) : (i += 1) {
                    const body_stmt: NodeId = @bitCast(self.arena.extra.items[f.body_start + i]);
                    try self.checkStmt(ctx, body_stmt);
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
            .index => return try self.synthIndex(id, data, ctx_opt),
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
            if (!bool_exhaustive) {
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
            .builtin, .range, .array_fixed, .array_dyn, .map_t, .set_t, .unknown => return ResolvedType.unknown,
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
