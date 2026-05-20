//! Etch AST — tabular SoA `AstArena` per `etch-ast-ir.md` §3.2.
//!
//! Design notes (S3):
//! - One `MultiArrayList(Item|Stmt|Expr|TypeNode)` per category. Each entry
//!   carries `(kind, data_index, span)`. Rich variants (`ComponentDecl`,
//!   `RuleDecl`, `BinaryExpr`, ...) live in dedicated side slabs reached
//!   via `data_index`.
//! - `NodeId = packed struct(u32) { category: u4, index: u28 }`. Indexes
//!   the MultiArrayList for `category`. `NodeId.zero` means "absent".
//! - `extra: ArrayList(u32)` holds flat ranges referenced by rich items
//!   (e.g. statement lists inside a rule body, fields list inside a
//!   component declaration). Each reference is a `(start, len)` pair on
//!   the side slab.
//! - `StringPool` interns identifier names and string literal contents.
//! - `AnnotationMap`: hash table keyed by `NodeId` → `AnnotationSpan`
//!   (range in `annot_pool`).
//! - `comment_spans` is a parallel slab — not attached to NodeIds in S3,
//!   kept for Phase 0.2 trivia attachment.
//! - `StableId` is absent (left at zero). The brief defers it to Phase 2
//!   when the editor injects `@id("uuid")`.
//!
//! Kind enums declare every EBNF v0.6 variant for API stability. S3 only
//! produces a subset; call sites switching on a kind enum must terminate
//! with `else => @panic("unsupported in S3")` per the brief.

const std = @import("std");
const token_mod = @import("token.zig");

const SourceSpan = token_mod.SourceSpan;

// ─────────────────────────────── NodeId ─────────────────────────────────

/// Open enum so Phase 0.2+ can add categories (patterns, etc.) without
/// breaking the packed `NodeId` layout.
pub const NodeCategory = enum(u4) {
    item,
    stmt,
    expr,
    type_node,
    _,
};

/// Compact 32-bit handle into the `AstArena`: 4-bit `NodeCategory` +
/// 28-bit index. Used as the universal pointer between AST nodes.
pub const NodeId = packed struct(u32) {
    category: NodeCategory,
    index: u28,

    pub const none: NodeId = .{ .category = .item, .index = 0x0FFFFFFF };

    pub inline fn isNone(self: NodeId) bool {
        return std.meta.eql(self, none);
    }

    pub inline fn raw(self: NodeId) u32 {
        return @bitCast(self);
    }
};

// ─────────────────────────────── StringPool ─────────────────────────────

/// Interned-string handle inside the `AstArena`'s `StringPool`. Id 0
/// is reserved for the empty string ("absent").
pub const StringId = u32;

/// Deduplicating interner. Identifier names and string literal contents
/// share a single pool keyed by byte equality. Strings are stored in
/// individual allocations so the slices remain stable across calls —
/// the hash map's keys are owned slices, not pointers into a moving
/// ArrayList. The empty string is reserved at id 0 so `StringId(0)`
/// means "absent" for fields that may be unset.
pub const StringPool = struct {
    /// Each entry is a heap-allocated slice. `slices[id]` returns the
    /// canonical bytes for `StringId(id)`. Index 0 is the empty string.
    slices: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Maps canonical bytes → StringId.
    map: std.StringHashMapUnmanaged(StringId) = .empty,

    pub fn init(gpa: std.mem.Allocator) !StringPool {
        var pool: StringPool = .{};
        // `intern` arms two errdefers on its own internals (`gpa.free(owned)`
        // and `slices.pop()`) which roll back the per-call mutations. They
        // do not, however, release the spare *capacity* of `slices` or
        // `map` once one of them has grown. If the very first `intern`
        // call fails after `slices.append` succeeded but before `map.put`
        // completes, the unfreed slab capacity leaks. Guard the whole
        // init with a top-level errdefer so partial state never escapes.
        errdefer pool.deinit(gpa);
        _ = try pool.intern(gpa, "");
        return pool;
    }

    pub fn deinit(self: *StringPool, gpa: std.mem.Allocator) void {
        for (self.slices.items) |s| gpa.free(s);
        self.slices.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn intern(self: *StringPool, gpa: std.mem.Allocator, s: []const u8) !StringId {
        if (self.map.get(s)) |existing| return existing;
        const owned = try gpa.dupe(u8, s);
        errdefer gpa.free(owned);
        const id: StringId = @intCast(self.slices.items.len);
        try self.slices.append(gpa, owned);
        errdefer _ = self.slices.pop();
        try self.map.put(gpa, owned, id);
        return id;
    }

    pub fn slice(self: *const StringPool, id: StringId) []const u8 {
        if (id >= self.slices.items.len) return &[_]u8{};
        return self.slices.items[id];
    }
};

// ─────────────────────────────── Kinds ──────────────────────────────────

/// Every EBNF v0.6 top-level construct. S3 produces only the marked
/// variants; the others are reserved for additive extension.
pub const ItemKind = enum {
    // S3
    component_decl,
    resource_decl,
    rule_decl,
    // Reserved
    import_decl,
    fn_decl,
    struct_decl,
    enum_decl,
    trait_decl,
    impl_decl,
    event_decl,
    tags_decl,
    const_decl,
    type_alias,
    behavior_decl,
    routine_decl,
    quest_decl,
    dialogue_decl,
    ability_decl,
    effect_decl,
    shader_decl,
    widget_decl,
    theme_decl,
    motion_decl,
    locale_decl,
    anim_graph_decl,
    audio_graph_decl,
    audio_score_decl,
    sequence_decl,
    data_decl,
    scene_decl,
    prefab_decl,
    input_mapping_decl,
    test_decl,
    override_decl,
};

/// Closed enum of statement kinds reachable from an Etch rule body.
/// `// S3` variants are implemented; the others are reserved for
/// later milestones and rejected at parse-time in S3.
pub const StmtKind = enum {
    // S3
    let_stmt,
    assign_stmt,
    expr_stmt,
    // Reserved
    const_stmt,
    type_alias,
    if_stmt,
    for_stmt,
    while_stmt,
    loop_stmt,
    match_stmt,
    return_stmt,
    emit_stmt,
    try_catch_stmt,
    throw_stmt,
    assert_stmt,
    break_stmt,
    continue_stmt,
    await_stmt,
    race_stmt,
    sync_stmt,
    branch_stmt,
    spawn_stmt,
    timer_stmt,
    quantize_stmt,
    tag_mutation_stmt,
};

/// Closed enum of expression kinds. `// S3` variants are implemented;
/// the others are reserved for later milestones.
pub const ExprKind = enum {
    // S3
    int_lit,
    float_lit,
    bool_lit,
    string_lit,
    ident,
    field_access,
    method_get, // entity.get(T)
    method_get_mut, // entity.get_mut(T)
    binary,
    unary,
    paren,
    // Reserved
    duration_lit,
    time_lit,
    color_lit,
    none_lit,
    some_lit,
    path,
    self_expr,
    tag_path,
    struct_lit,
    array_lit,
    map_lit,
    tuple_lit,
    cast,
    range,
    index,
    method_call,
    fn_call,
    if_expr,
    match_expr,
    block_expr,
    closure,
    await_expr,
    throw_expr,
};

/// Closed enum of type-node kinds the parser can produce.
pub const TypeNodeKind = enum {
    // S3
    named,
    // Reserved
    path,
    generic,
    array,
    slice,
    map_type,
    set_type,
    tuple,
    function,
    self,
    optional,
    trait_bound,
};

// ─────────────────────────────── Binary / Unary opcodes ─────────────────

/// Closed enum of the S3 binary operators. `add`/`sub`/`mul`/`div`/`rem`
/// for arithmetic, `eq`/`neq`/`lt`/`gt`/`le`/`ge` for comparison, plus
/// short-circuit `logical_and`/`logical_or`.
pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    eq,
    neq,
    lt,
    gt,
    le,
    ge,
    logical_and,
    logical_or,
};

/// Closed enum of the S3 prefix unary operators.
pub const UnaryOp = enum {
    neg, // -x
    logical_not, // not x
};

/// Closed enum of assignment-style operators inside an `AssignStmt`.
pub const AssignOp = enum {
    assign, // =
    add_assign, // +=
    sub_assign, // -=
    mul_assign, // *=
    div_assign, // /=
    rem_assign, // %=
};

// ─────────────────────────────── Side-slab data ─────────────────────────

/// A field of a component or resource declaration. Fields are stored in
/// `arena.fields` and referenced by `(start, len)` from the parent's side
/// slab entry.
pub const Field = struct {
    name: StringId,
    type_node: NodeId,
    default_value: NodeId, // NodeId.none if absent
    annotations_extra: u32, // start in `annot_pool`
    annotations_len: u32,
};

/// Side-slab entry for a `component` declaration: name + range into
/// `arena.fields` + annotation range.
pub const ComponentDecl = struct {
    name: StringId,
    fields_start: u32, // index into `arena.fields`
    fields_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Side-slab entry for a `resource` declaration. Same shape as
/// `ComponentDecl`; kept separate to preserve the AST-level distinction.
pub const ResourceDecl = struct {
    name: StringId,
    fields_start: u32,
    fields_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

const RuleParam = struct {
    name: StringId,
    type_node: NodeId,
};

/// Side-slab entry for a `rule` declaration: params, optional `when`
/// clause, body statement range, and annotation range.
pub const RuleDecl = struct {
    name: StringId,
    params_start: u32, // index into `arena.rule_params`
    params_len: u32,
    /// Index into `arena.when_nodes`; `none_when` if absent.
    when_root: u32,
    body_start: u32, // index into `arena.extra` (list of StmtId raw values)
    body_len: u32,
    annotations_extra: u32,
    annotations_len: u32,

    pub const none_when: u32 = std.math.maxInt(u32);
};

/// `when` clause AST. Conditions form a binary tree of `and`/`or`/`not`
/// composed with leaf clauses (`has`, `has_with_filter`, `resource`,
/// `resource_changed`).
pub const WhenNodeKind = enum {
    logical_and,
    logical_or,
    logical_not,
    has, // entity has T
    has_with_filter, // entity has T { field == value }
    resource, // resource T
    resource_changed, // resource T changed
};

/// Side-slab entry for one node of the `when` boolean tree. Composite
/// nodes (`and`/`or`/`not`) link to child indices; leaf nodes carry
/// the entity/type/filter triplet.
pub const WhenNode = struct {
    kind: WhenNodeKind,
    /// Leaf: identifier (`entity` name) for entity-based; unused for
    /// resource-based. Carries the StringId or 0.
    entity_name: StringId,
    /// Component or resource type name (S3 lexes types as TYPE_IDENT,
    /// the type-checker resolves against builtin + declared).
    type_name: StringId,
    /// For `has_with_filter`: field name + filter value expression.
    field_name: StringId,
    filter_value: NodeId, // NodeId.none if absent
    /// Children for `and` / `or` / `not`. `lhs` always set, `rhs` only
    /// for `and` / `or`.
    lhs: u32, // index into when_nodes
    rhs: u32,
    span: SourceSpan,

    pub const no_child: u32 = std.math.maxInt(u32);
};

/// Side-slab entry for a `let`/`mut` statement.
pub const LetStmt = struct {
    name: StringId,
    is_mut: bool,
    type_annotation: NodeId, // NodeId.none if absent
    value: NodeId, // expr
};

/// Side-slab entry for an assignment statement (`=`/`+=`/`-=`/...).
pub const AssignStmt = struct {
    target: NodeId, // expr — must be ident or field_access chain
    op: AssignOp,
    value: NodeId, // expr
};

const BinaryExpr = struct {
    op: BinaryOp,
    lhs: NodeId,
    rhs: NodeId,
};

const UnaryExpr = struct {
    op: UnaryOp,
    operand: NodeId,
};

/// Side-slab entry for a `receiver.field` access expression.
pub const FieldAccessExpr = struct {
    receiver: NodeId,
    field_name: StringId,
};

const MethodGetExpr = struct {
    receiver: NodeId,
    type_name: StringId,
};

const NamedTypeNode = struct {
    name: StringId,
};

/// Annotation stored in `annot_pool`. `args_start`/`args_len` refer to
/// a flat range in `arena.annot_args` (`AnnotationArg` entries).
pub const Annotation = struct {
    /// Builtin AnnotationKind when matched; `.custom` carries the name as
    /// `custom_name` and is accepted by the S3 parser without applicability
    /// validation (deferred Phase 0.2).
    kind: AnnotationKind,
    /// Name as written (for `.custom` and round-trip pretty-print).
    name: StringId,
    args_start: u32,
    args_len: u32,
    span: SourceSpan,
};

/// One argument of an `Annotation`. Positional args have `name = 0`;
/// named args carry the identifier. Value is always an expression node.
pub const AnnotationArg = struct {
    /// 0 for positional args; otherwise the named argument's identifier.
    name: StringId,
    value: NodeId, // expr
};

/// Builtin annotation set. Covers `@phase`, `@priority`, `@run_on`,
/// `@pause_group`, `@config`, `@state`, `@transient`, `@save`, `@unit`,
/// `@range`, `@hidden`, `@readonly`, `@requires`, `@storage`,
/// `@replicated`, `@networked`, `@id`, `@loc` plus a `.custom` fallback
/// for unknown names (S3 accepts unknown annotations without erroring;
/// applicability validation is deferred Phase 0.2).
pub const AnnotationKind = enum {
    custom,
    phase,
    priority,
    run_on,
    pause_group,
    config,
    state,
    transient,
    save,
    unit,
    range,
    hidden,
    readonly,
    requires,
    storage,
    replicated,
    networked,
    id,
    loc,

    pub fn fromName(name: []const u8) AnnotationKind {
        if (std.mem.eql(u8, name, "phase")) return .phase;
        if (std.mem.eql(u8, name, "priority")) return .priority;
        if (std.mem.eql(u8, name, "run_on")) return .run_on;
        if (std.mem.eql(u8, name, "pause_group")) return .pause_group;
        if (std.mem.eql(u8, name, "config")) return .config;
        if (std.mem.eql(u8, name, "state")) return .state;
        if (std.mem.eql(u8, name, "transient")) return .transient;
        if (std.mem.eql(u8, name, "save")) return .save;
        if (std.mem.eql(u8, name, "unit")) return .unit;
        if (std.mem.eql(u8, name, "range")) return .range;
        if (std.mem.eql(u8, name, "hidden")) return .hidden;
        if (std.mem.eql(u8, name, "readonly")) return .readonly;
        if (std.mem.eql(u8, name, "requires")) return .requires;
        if (std.mem.eql(u8, name, "storage")) return .storage;
        if (std.mem.eql(u8, name, "replicated")) return .replicated;
        if (std.mem.eql(u8, name, "networked")) return .networked;
        if (std.mem.eql(u8, name, "id")) return .id;
        if (std.mem.eql(u8, name, "loc")) return .loc;
        return .custom;
    }
};

// ─────────────────────────────── MultiArrayList entries ─────────────────

const Item = struct {
    kind: ItemKind,
    data: u32,
    span: SourceSpan,
};

const Stmt = struct {
    kind: StmtKind,
    data: u32,
    span: SourceSpan,
};

const Expr = struct {
    kind: ExprKind,
    data: u32,
    span: SourceSpan,
};

const TypeNode = struct {
    kind: TypeNodeKind,
    data: u32,
    span: SourceSpan,
};

// ─────────────────────────────── AstArena ───────────────────────────────

/// Tabular SoA arena holding the whole Etch AST in column form.
/// Allocated once per parse; freed via `deinit` after consumers have
/// finished. All `NodeId`s in the API refer into this arena.
pub const AstArena = struct {
    items: std.MultiArrayList(Item) = .empty,
    stmts: std.MultiArrayList(Stmt) = .empty,
    exprs: std.MultiArrayList(Expr) = .empty,
    type_nodes: std.MultiArrayList(TypeNode) = .empty,

    extra: std.ArrayListUnmanaged(u32) = .empty,
    strings: StringPool = .{},

    // Side slabs.
    fields: std.ArrayListUnmanaged(Field) = .empty,
    component_decls: std.ArrayListUnmanaged(ComponentDecl) = .empty,
    resource_decls: std.ArrayListUnmanaged(ResourceDecl) = .empty,
    rule_decls: std.ArrayListUnmanaged(RuleDecl) = .empty,
    rule_params: std.ArrayListUnmanaged(RuleParam) = .empty,
    when_nodes: std.ArrayListUnmanaged(WhenNode) = .empty,

    let_stmts: std.ArrayListUnmanaged(LetStmt) = .empty,
    assign_stmts: std.ArrayListUnmanaged(AssignStmt) = .empty,

    binary_exprs: std.ArrayListUnmanaged(BinaryExpr) = .empty,
    unary_exprs: std.ArrayListUnmanaged(UnaryExpr) = .empty,
    field_accesses: std.ArrayListUnmanaged(FieldAccessExpr) = .empty,
    method_gets: std.ArrayListUnmanaged(MethodGetExpr) = .empty,
    named_types: std.ArrayListUnmanaged(NamedTypeNode) = .empty,

    // Annotation storage.
    annotations: std.AutoHashMapUnmanaged(NodeId, AnnotationSpan) = .empty,
    annot_pool: std.ArrayListUnmanaged(Annotation) = .empty,
    annot_args: std.ArrayListUnmanaged(AnnotationArg) = .empty,

    /// Parallel slab — not attached to NodeIds in S3.
    comment_spans: std.ArrayListUnmanaged(SourceSpan) = .empty,

    pub const AnnotationSpan = struct {
        start: u32,
        len: u32,
    };

    pub fn init(gpa: std.mem.Allocator) !AstArena {
        var arena: AstArena = .{};
        arena.strings = try StringPool.init(gpa);
        return arena;
    }

    pub fn deinit(self: *AstArena, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.stmts.deinit(gpa);
        self.exprs.deinit(gpa);
        self.type_nodes.deinit(gpa);
        self.extra.deinit(gpa);
        self.strings.deinit(gpa);
        self.fields.deinit(gpa);
        self.component_decls.deinit(gpa);
        self.resource_decls.deinit(gpa);
        self.rule_decls.deinit(gpa);
        self.rule_params.deinit(gpa);
        self.when_nodes.deinit(gpa);
        self.let_stmts.deinit(gpa);
        self.assign_stmts.deinit(gpa);
        self.binary_exprs.deinit(gpa);
        self.unary_exprs.deinit(gpa);
        self.field_accesses.deinit(gpa);
        self.method_gets.deinit(gpa);
        self.named_types.deinit(gpa);
        self.annotations.deinit(gpa);
        self.annot_pool.deinit(gpa);
        self.annot_args.deinit(gpa);
        self.comment_spans.deinit(gpa);
    }

    // ─── Add helpers ────────────────────────────────────────────────────

    pub fn addItem(self: *AstArena, gpa: std.mem.Allocator, kind: ItemKind, data: u32, span: SourceSpan) !NodeId {
        const idx: u28 = @intCast(self.items.len);
        try self.items.append(gpa, .{ .kind = kind, .data = data, .span = span });
        return .{ .category = .item, .index = idx };
    }

    pub fn addStmt(self: *AstArena, gpa: std.mem.Allocator, kind: StmtKind, data: u32, span: SourceSpan) !NodeId {
        const idx: u28 = @intCast(self.stmts.len);
        try self.stmts.append(gpa, .{ .kind = kind, .data = data, .span = span });
        return .{ .category = .stmt, .index = idx };
    }

    pub fn addExpr(self: *AstArena, gpa: std.mem.Allocator, kind: ExprKind, data: u32, span: SourceSpan) !NodeId {
        const idx: u28 = @intCast(self.exprs.len);
        try self.exprs.append(gpa, .{ .kind = kind, .data = data, .span = span });
        return .{ .category = .expr, .index = idx };
    }

    pub fn addTypeNode(self: *AstArena, gpa: std.mem.Allocator, kind: TypeNodeKind, data: u32, span: SourceSpan) !NodeId {
        const idx: u28 = @intCast(self.type_nodes.len);
        try self.type_nodes.append(gpa, .{ .kind = kind, .data = data, .span = span });
        return .{ .category = .type_node, .index = idx };
    }

    pub fn addNamedType(self: *AstArena, gpa: std.mem.Allocator, name: StringId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.named_types.items.len);
        try self.named_types.append(gpa, .{ .name = name });
        return try self.addTypeNode(gpa, .named, idx, span);
    }

    pub fn addBinary(self: *AstArena, gpa: std.mem.Allocator, op: BinaryOp, lhs: NodeId, rhs: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.binary_exprs.items.len);
        try self.binary_exprs.append(gpa, .{ .op = op, .lhs = lhs, .rhs = rhs });
        return try self.addExpr(gpa, .binary, idx, span);
    }

    pub fn addUnary(self: *AstArena, gpa: std.mem.Allocator, op: UnaryOp, operand: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.unary_exprs.items.len);
        try self.unary_exprs.append(gpa, .{ .op = op, .operand = operand });
        return try self.addExpr(gpa, .unary, idx, span);
    }

    pub fn addFieldAccess(self: *AstArena, gpa: std.mem.Allocator, receiver: NodeId, field_name: StringId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.field_accesses.items.len);
        try self.field_accesses.append(gpa, .{ .receiver = receiver, .field_name = field_name });
        return try self.addExpr(gpa, .field_access, idx, span);
    }

    pub fn addMethodGet(self: *AstArena, gpa: std.mem.Allocator, kind: ExprKind, receiver: NodeId, type_name: StringId, span: SourceSpan) !NodeId {
        std.debug.assert(kind == .method_get or kind == .method_get_mut);
        const idx: u32 = @intCast(self.method_gets.items.len);
        try self.method_gets.append(gpa, .{ .receiver = receiver, .type_name = type_name });
        return try self.addExpr(gpa, kind, idx, span);
    }

    pub fn addLetStmt(self: *AstArena, gpa: std.mem.Allocator, let: LetStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.let_stmts.items.len);
        try self.let_stmts.append(gpa, let);
        return try self.addStmt(gpa, .let_stmt, idx, span);
    }

    pub fn addAssignStmt(self: *AstArena, gpa: std.mem.Allocator, assign: AssignStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.assign_stmts.items.len);
        try self.assign_stmts.append(gpa, assign);
        return try self.addStmt(gpa, .assign_stmt, idx, span);
    }

    pub fn addExprStmt(self: *AstArena, gpa: std.mem.Allocator, expr: NodeId, span: SourceSpan) !NodeId {
        return try self.addStmt(gpa, .expr_stmt, expr.raw(), span);
    }

    // ─── Accessors ──────────────────────────────────────────────────────

    pub fn itemKind(self: *const AstArena, id: NodeId) ItemKind {
        std.debug.assert(id.category == .item);
        return self.items.items(.kind)[id.index];
    }

    pub fn itemSpan(self: *const AstArena, id: NodeId) SourceSpan {
        std.debug.assert(id.category == .item);
        return self.items.items(.span)[id.index];
    }

    pub fn itemData(self: *const AstArena, id: NodeId) u32 {
        std.debug.assert(id.category == .item);
        return self.items.items(.data)[id.index];
    }

    pub fn stmtKind(self: *const AstArena, id: NodeId) StmtKind {
        std.debug.assert(id.category == .stmt);
        return self.stmts.items(.kind)[id.index];
    }

    pub fn stmtSpan(self: *const AstArena, id: NodeId) SourceSpan {
        std.debug.assert(id.category == .stmt);
        return self.stmts.items(.span)[id.index];
    }

    pub fn stmtData(self: *const AstArena, id: NodeId) u32 {
        std.debug.assert(id.category == .stmt);
        return self.stmts.items(.data)[id.index];
    }

    pub fn exprKind(self: *const AstArena, id: NodeId) ExprKind {
        std.debug.assert(id.category == .expr);
        return self.exprs.items(.kind)[id.index];
    }

    pub fn exprSpan(self: *const AstArena, id: NodeId) SourceSpan {
        std.debug.assert(id.category == .expr);
        return self.exprs.items(.span)[id.index];
    }

    pub fn exprData(self: *const AstArena, id: NodeId) u32 {
        std.debug.assert(id.category == .expr);
        return self.exprs.items(.data)[id.index];
    }

    pub fn typeNodeKind(self: *const AstArena, id: NodeId) TypeNodeKind {
        std.debug.assert(id.category == .type_node);
        return self.type_nodes.items(.kind)[id.index];
    }

    pub fn typeNodeSpan(self: *const AstArena, id: NodeId) SourceSpan {
        std.debug.assert(id.category == .type_node);
        return self.type_nodes.items(.span)[id.index];
    }

    pub fn typeNodeData(self: *const AstArena, id: NodeId) u32 {
        std.debug.assert(id.category == .type_node);
        return self.type_nodes.items(.data)[id.index];
    }

    pub fn isEmpty(self: *const AstArena) bool {
        return self.items.len == 0;
    }
};

// ─────────────────────────────── tests ──────────────────────────────────

test "NodeId encodes category and index round-trip" {
    const id: NodeId = .{ .category = .expr, .index = 0x1234567 };
    try std.testing.expectEqual(NodeCategory.expr, id.category);
    try std.testing.expectEqual(@as(u28, 0x1234567), id.index);

    const r = id.raw();
    const decoded: NodeId = @bitCast(r);
    try std.testing.expectEqual(id.category, decoded.category);
    try std.testing.expectEqual(id.index, decoded.index);
}

test "StringPool interns identical identifiers to the same StringId" {
    const gpa = std.testing.allocator;
    var pool = try StringPool.init(gpa);
    defer pool.deinit(gpa);

    const a = try pool.intern(gpa, "Health");
    const b = try pool.intern(gpa, "Health");
    const c = try pool.intern(gpa, "Armor");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expectEqualStrings("Health", pool.slice(a));
    try std.testing.expectEqualStrings("Armor", pool.slice(c));

    // The empty string is reserved at id 0.
    try std.testing.expectEqual(@as(StringId, 0), try pool.intern(gpa, ""));
}

test "AstArena adds an int literal and retrieves its span and kind" {
    const gpa = std.testing.allocator;
    var arena = try AstArena.init(gpa);
    defer arena.deinit(gpa);

    const id = try arena.addExpr(gpa, .int_lit, 42, .{ .byte_start = 0, .byte_end = 2 });
    try std.testing.expectEqual(ExprKind.int_lit, arena.exprKind(id));
    try std.testing.expectEqual(@as(u32, 42), arena.exprData(id));
    const span = arena.exprSpan(id);
    try std.testing.expectEqual(@as(u32, 0), span.byte_start);
    try std.testing.expectEqual(@as(u32, 2), span.byte_end);
}

test "AstArena spans align with passed-in byte offsets" {
    const gpa = std.testing.allocator;
    var arena = try AstArena.init(gpa);
    defer arena.deinit(gpa);

    const id_a = try arena.addExpr(gpa, .int_lit, 1, .{ .byte_start = 10, .byte_end = 12 });
    const id_b = try arena.addExpr(gpa, .int_lit, 2, .{ .byte_start = 13, .byte_end = 15 });
    try std.testing.expectEqual(@as(u32, 10), arena.exprSpan(id_a).byte_start);
    try std.testing.expectEqual(@as(u32, 13), arena.exprSpan(id_b).byte_start);
}

test "AnnotationKind.fromName recognises builtin names" {
    try std.testing.expectEqual(AnnotationKind.phase, AnnotationKind.fromName("phase"));
    try std.testing.expectEqual(AnnotationKind.range, AnnotationKind.fromName("range"));
    try std.testing.expectEqual(AnnotationKind.custom, AnnotationKind.fromName("totally_unknown"));
}
