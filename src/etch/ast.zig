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

    /// Look up an already-interned string's id without inserting (M0.8 E2
    /// block 3). Returns `null` if `s` was never interned. Used by consumers
    /// that only hold a `*const AstArena` (e.g. the interpreter resolving the
    /// `self` receiver binding) and so cannot intern.
    pub fn find(self: *const StringPool, s: []const u8) ?StringId {
        return self.map.get(s);
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
    loop_expr,
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

/// Side-slab entry for an `event` declaration (M0.8 E3, `etch-grammar.md`
/// §5.10 `event_decl = "event" TYPE_IDENT "{" {annotated_field} "}"`). Same
/// shape as `ComponentDecl`/`ResourceDecl` — an event is a POD struct of
/// fields (ABI §3.1) consumed by `emit` and `@on_event` rules; kept separate
/// to preserve the AST-level distinction.
pub const EventDecl = struct {
    name: StringId,
    fields_start: u32,
    fields_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Side-slab entry for a `tags { ... }` hierarchical declaration (M0.8 E3,
/// `etch-grammar.md` §5.11 `tags_decl`). The hierarchy is stored flat and
/// parent-linked across `arena.tag_namespaces` + `arena.tag_leaves`, appended
/// in **pre-order** (the parser descends top-down). Pre-order append order is
/// exactly the depth-first + declaration order `etch-validation-ecs.md` §5.2
/// mandates for `bit_index` assignment, so a leaf's position in
/// `arena.tag_leaves` is its canonical bit_index ordering before the
/// cross-block merge performed by the global tag-table pass (`tags.zig`). A
/// `tags_decl` item records the `(start, len)` runs this block contributed.
pub const TagsDecl = struct {
    ns_start: u32, // into `arena.tag_namespaces`
    ns_len: u32,
    leaf_start: u32, // into `arena.tag_leaves`
    leaf_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// A namespace node in a `tags { }` hierarchy (`tag_namespace`, M0.8 E3).
/// Flat + parent-linked: `parent` indexes `arena.tag_namespaces` (the
/// enclosing namespace) or `no_parent` for a top-level namespace. Recorded in
/// pre-order (the parent is appended before its children).
pub const TagNamespace = struct {
    name: StringId,
    parent: u32,
    span: SourceSpan,

    pub const no_parent: u32 = std.math.maxInt(u32);
};

/// A leaf (concrete tag) in a `tags { }` hierarchy (`tag_leaf`, M0.8 E3).
/// `parent` indexes its enclosing namespace in `arena.tag_namespaces`. Leaves
/// are appended in pre-order = depth-first declaration order, so their order
/// in `arena.tag_leaves` mirrors the canonical `bit_index` ordering before the
/// cross-block merge (`tags.zig`).
pub const TagLeaf = struct {
    name: StringId,
    parent: u32,
    span: SourceSpan,
};

/// The five tag query operators (M0.8 E3, `etch-grammar.md` §3.2 `tag_op`,
/// `etch-validation-ecs.md` §5.4). `has_tag`/`has_no_tag` take a single tag;
/// `has_any_tag`/`has_all_tags`/`has_no_tags` take a list (or a category
/// namespace expanding to a mask).
pub const TagOp = enum { has_tag, has_no_tag, has_any_tag, has_all_tags, has_no_tags };

/// Side-slab entry for a `tag_path` expression (`TAG_PATH = "." IDENT {"."
/// IDENT}`, `etch-grammar.md` §1.3). The dotted segments are a `(start, len)`
/// run of `arena.tag_path_segs` (interned segment names). Produced only in tag
/// operand position (after a `tag_op`, or in a tag mutation) — never as a bare
/// primary, so there is no ambiguity with the `.variant` enum shorthand.
pub const TagPathExpr = struct {
    segs_start: u32,
    segs_len: u32,
};

/// Side-slab entry for a `tag_filter` `when` condition (`expression tag_op
/// tag_operand`, M0.8 E3, `etch-grammar.md` §6 l.945). The operand is a
/// `(start, len)` run of `arena.tag_operands` (each a `tag_path` expr NodeId):
/// length 1 for `has_tag`/`has_no_tag`, ≥1 for the multi operators (or a single
/// category path). Referenced from a `WhenNode` of kind `.tag_filter` via its
/// `aux` index.
pub const TagFilter = struct {
    op: TagOp,
    operand_start: u32,
    operand_len: u32,
};

/// `add_tag` vs `remove_tag` mutation (M0.8 E3, `etch-grammar.md` §4.4 l.697).
pub const TagMutationKind = enum { add, remove };

/// Side-slab entry for a `tag_mutation_stmt` (`expression "."
/// ("add_tag"|"remove_tag") "(" TAG_PATH ")"`, M0.8 E3, `etch-grammar.md`
/// §4.4). A deferred structural change (queued, applied at the tick boundary).
/// `receiver` is the entity expression; `path` is the `tag_path` operand. The
/// bare-`TYPE_IDENT` category operand form is deferred (a dotted path resolving
/// to a namespace already expresses a category — consistent with the query
/// operands).
pub const TagMutationStmt = struct {
    receiver: NodeId,
    kind: TagMutationKind,
    path: NodeId,
};

const RuleParam = struct {
    name: StringId,
    type_node: NodeId,
};

/// Side-slab entry for a top-level `type Name = Type` alias (M0.8 v0.6
/// foundations). `target` is the aliased type node (a `.type_node`).
pub const TypeAliasDecl = struct {
    name: StringId,
    target: NodeId,
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
    tag_filter, // entity has_tag .path (M0.8 E3) — `aux` indexes `tag_filters`
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
    /// Kind-specific auxiliary index. For `.tag_filter`: index into
    /// `arena.tag_filters` (M0.8 E3). Unused (0) for every other kind.
    aux: u32 = 0,
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

/// Side-slab entry for an `assert(cond[, "message"])` statement (M0.8 v0.6
/// foundations, `etch-reference-part1.md` §10.3). `message` is `0` when
/// absent. Debug builds panic on a false condition; release strips it.
pub const AssertStmt = struct {
    cond: NodeId, // expr — must be bool
    message: StringId, // 0 if no message literal
};

/// Side-slab entry for a `for IDENT [, IDENT] in iterable block` statement
/// (M0.8 v0.6 foundations, `etch-grammar.md` §621). `index_name` is `0`
/// when the optional second binding is absent. `body_start`/`body_len`
/// index a run of statement ids in `arena.extra` (same layout as a rule
/// body). E1 iterates ranges; array/map iterables arrive with collections.
pub const ForStmt = struct {
    var_name: StringId,
    index_name: StringId, // 0 if absent
    iterable: NodeId, // expr (a range in E1)
    body_start: u32,
    body_len: u32,
};

/// `while cond block` statement (M0.8 control flow, `etch-grammar.md` §4.1
/// l.622). `body_start`/`body_len` index a statement run in `arena.extra` (the
/// body has no value, like a loop body). M0.8 `while` is unlabeled; the
/// `while let` Optional-destructuring form lands with the Optional tranche.
pub const WhileStmt = struct {
    cond: NodeId,
    body_start: u32,
    body_len: u32,
    /// `while let <name> = <cond> { … }` (M0.8 E2 block 5): `cond` is an
    /// optional-typed expression, `let_binding` the name bound to its payload in
    /// the body each iteration. `0` for a plain `while cond`.
    let_binding: StringId = 0,
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

/// `operand as Type` cast expression (M0.8 v0.6 foundations). `type_node`
/// is a `.type_node` category id produced by `parseType`.
pub const CastExpr = struct {
    operand: NodeId,
    type_node: NodeId,
};

/// `start .. end` (exclusive) or `start ..= end` (inclusive) range
/// expression (M0.8 v0.6 foundations, `etch-grammar.md` §410-411).
pub const RangeExpr = struct {
    start: NodeId,
    end: NodeId,
    inclusive: bool,
};

/// Pattern kind for a `match` arm (M0.8 v0.6 foundations, E1 subset:
/// wildcard / literal / binding). Enum-variant, optional, tuple, and
/// struct-destructure patterns arrive with their types in later stages
/// (`etch-grammar.md` §pattern, `etch-reference-part1.md` §7.6).
pub const PatternKind = enum { wildcard, literal, binding, enum_variant };

/// One arm of a `match`. `pattern_kind` selects the meaning of
/// `pattern_payload`: `.literal` → a literal expr `NodeId` (raw bits) the
/// scrutinee is compared against; `.binding` → the bound `StringId`;
/// `.wildcard` → unused (0); `.enum_variant` → an index into
/// `arena.enum_pattern_payloads` (M0.8 E2 block 3 tranche B). `body` is the
/// arm's expression.
pub const MatchArm = struct {
    pattern_kind: PatternKind,
    pattern_payload: u32,
    body: NodeId,
};

/// Payload of an `.enum_variant` match pattern (M0.8 E2 block 3 tranche B,
/// `etch-grammar.md` §3.2 l.510-511). The shorthand `.easy` stores
/// `type_name = 0` (resolved type-driven from the scrutinee enum); the
/// qualified `Difficulty.easy` stores the explicit enum type name. `variant`
/// is the variant identifier.
pub const EnumPatternPayload = struct {
    type_name: StringId, // 0 = shorthand `.variant`
    variant: StringId,
};

/// `match scrutinee { arm, ... }` (M0.8 v0.6 foundations). Arms live in a
/// flat `(start, len)` range of `match_arms`.
pub const MatchExpr = struct {
    scrutinee: NodeId,
    arms_start: u32,
    arms_len: u32,
};

/// `[a, b, c]` (comma form) or `[v; n]` (fill form) array literal
/// (M0.8 collections, `etch-grammar.md` §493-494). For the comma form,
/// `elements_start`/`elements_len` index a run of expr `NodeId` raw values in
/// `arena.extra`. For the fill form `[v; n]`, `is_fill = true`, the single
/// element expr `v` sits at the run (`elements_len == 1`), and `fill_count`
/// is the count expression `n`.
pub const ArrayLitExpr = struct {
    elements_start: u32,
    elements_len: u32,
    is_fill: bool,
    fill_count: NodeId, // expr — only meaningful when is_fill
};

/// One `key: value` entry of a map literal.
pub const MapEntry = struct {
    key: NodeId,
    value: NodeId,
};

/// `[k: v, ...]` (entries) or `[:]` (empty) map literal (M0.8 collections,
/// `etch-grammar.md` §496-498). Entries live in a flat `(start, len)` range of
/// `arena.map_entries`.
pub const MapLitExpr = struct {
    entries_start: u32,
    entries_len: u32,
};

/// `receiver[index]` index / slice access (M0.8 collections, `etch-grammar.md`
/// postfix_op §425). When `index` is a `.range` expr the access is a slice;
/// otherwise it is a single-element index. The two are disambiguated at
/// resolve time from the index expression's kind.
pub const IndexExpr = struct {
    receiver: NodeId,
    index: NodeId,
};

/// `[label:] loop { body }` loop expression (M0.8 loop/break, `etch-grammar.md`
/// §522/§624). `label` is `0` when unlabeled. The body is a run of statement
/// ids in `arena.extra`; the loop's value is the operand of the `break` that
/// exits it (or `unit`).
pub const LoopExpr = struct {
    label: StringId,
    body_start: u32,
    body_len: u32,
};

/// `{ statement* [expression] }` block expression (M0.8 control flow,
/// `etch-grammar.md` §3.2 l.520 / §4.1 l.645). `body_start`/`body_len` index a
/// statement run in `arena.extra`; `value` is the trailing expression that is
/// the block's value (`NodeId.none` when value-less — Etch has no `;`, so the
/// last bare expression before `}` is the value). Used directly
/// (`let x = { ...; v }`), as `if`/`match` arm bodies, and as closure bodies.
pub const BlockExpr = struct {
    body_start: u32,
    body_len: u32,
    value: NodeId,
};

/// `if cond block {else if cond block} [else block]` if expression (M0.8
/// control flow, `etch-grammar.md` §3.2 l.500 / §4.1 l.618). The else-if chain
/// is encoded recursively: `else_branch` is `NodeId.none` (no `else`), a
/// `block_expr` (final `else { }`), or another `if_expr` (`else if ...`).
/// `then_block` is always a `block_expr`.
pub const IfExpr = struct {
    cond: NodeId,
    then_block: NodeId,
    else_branch: NodeId,
    /// `if let <name> = <cond> { … } [else { … }]` (M0.8 E2 block 5): `cond` is
    /// an optional-typed expression, `let_binding` the name bound to its payload
    /// in the then-block. `0` for a plain `if cond`.
    let_binding: StringId = 0,
};

/// `break [label] [value]` statement (M0.8 loop/break, `etch-grammar.md` §632).
/// `label` is `0` when unlabeled; `value` is `NodeId.none` when valueless.
pub const BreakStmt = struct {
    label: StringId,
    value: NodeId,
};

/// `throw expression` statement (M0.8 error handling, `etch-grammar.md` §641).
pub const ThrowStmt = struct {
    value: NodeId,
};

/// `try { ... } catch IDENT { ... }` statement (M0.8 error handling,
/// `etch-grammar.md` §640). Both bodies are statement runs in `arena.extra`
/// (they are statement blocks, not block expressions). `catch_name` is the
/// caught-value binding.
pub const TryCatchStmt = struct {
    try_start: u32,
    try_len: u32,
    catch_name: StringId,
    catch_start: u32,
    catch_len: u32,
};

/// `emit TYPE_IDENT "{" {field_init} "}"` statement (M0.8 E3, `etch-grammar.md`
/// §4.1 `emit_stmt` + §5.10). `event_type` is the emitted event; the field
/// initializers (`IDENT ":" expression`) live in a `(start, len)` run of
/// `arena.struct_lit_fields` (same shape as a struct literal — an event is a
/// POD struct of fields, ABI §3.1).
pub const EmitStmt = struct {
    event_type: StringId,
    fields_start: u32,
    fields_len: u32,
};

/// `|a, b| expr` closure (M0.8 closures, `etch-grammar.md` §524). Params are a
/// flat `(start, len)` range of `arena.closure_params`; the body is an
/// expression node. E1 closures take an expression body — a `{ block }` body
/// arrives with block expressions (loop/break tranche).
pub const ClosureExpr = struct {
    params_start: u32,
    params_len: u32,
    body: NodeId,
};

/// One closure parameter: name + optional type annotation (`NodeId.none` when
/// inferred from context, `etch-grammar.md` §526).
pub const ClosureParam = struct {
    name: StringId,
    type_node: NodeId,
};

/// `callee(args)` call expression (M0.8 closures, `etch-grammar.md` postfix_op
/// §424). Args are a run of expr `NodeId` raw values in `arena.extra`. E1
/// resolves calls whose callee is a closure-typed local; M0.8 E2 also resolves
/// a callee naming a top-level `fn` (free-function call).
pub const CallExpr = struct {
    callee: NodeId,
    args_start: u32,
    args_len: u32,
};

/// `receiver.method(args)` call expression (M0.8 E2 call mechanism,
/// `etch-grammar.md` postfix_op §421). Args are a run of expr `NodeId` raw
/// values in `arena.extra`. Block 2 produces the node (parser-testable); the
/// 4-kind method dispatch (`etch-resolver-types.md §5`) is exercised in block 3
/// once `impl` provides methods.
pub const MethodCall = struct {
    receiver: NodeId,
    method_name: StringId,
    args_start: u32,
    args_len: u32,
};

/// One `fn` parameter: name + type node (M0.8 E2 call mechanism,
/// `etch-grammar.md` §5.3 `regular_param`). Default values arrive with their
/// consumers (an E2 refinement). The `self` receiver is not a `FnParam` — it is
/// carried out-of-band on `FnDecl.self_kind` (M0.8 E2 block 3 `impl`).
pub const FnParam = struct {
    name: StringId,
    type_node: NodeId,
};

/// Method receiver shape (M0.8 E2 block 3 `impl`, `etch-grammar.md` §5.3
/// `self_param = [mut] self`). `none` for a free `fn` or an associated fn
/// (no receiver); `by_value` for `self`; `by_mut` for `mut self`. The receiver
/// type is the `impl`'s target type, resolved at dispatch — it is not stored on
/// the param list.
pub const SelfKind = enum { none, by_value, by_mut };

/// A generic bound on a type parameter (M0.8 E2 block 4, `etch-grammar.md`
/// §2.4 `trait_bound`). `trait_` names a declared trait (`trait_name`); the
/// `component` / `resource` / `event` markers are RTTI-category bounds
/// (`trait_name` unused, `0`).
pub const GenericBoundKind = enum { trait_, component, resource, event };

/// One bound (`T: Bound`) applied to a generic parameter (M0.8 E2 block 4).
pub const GenericBound = struct {
    kind: GenericBoundKind,
    trait_name: StringId = 0, // set only for `.trait_`
};

/// A generic type parameter (`etch-grammar.md` §2.4 `generic_param`). Bounds
/// (inline `<T: A + B>` and/or `where`-clause) live in a contiguous run of
/// `arena.generic_bounds`.
pub const GenericParam = struct {
    name: StringId,
    bounds_start: u32,
    bounds_len: u32,
};

/// A generic type application in *type* position (`Foo<T, U>`,
/// `etch-grammar.md` §270 `generic_type`). `args` are type-`NodeId`s in a run
/// of `arena.extra`. `Set<T>` / `Map<K,V>` keep their dedicated nodes; this is
/// every other `TYPE_IDENT "<" … ">"`.
pub const GenericTypeNode = struct {
    name: StringId,
    args_start: u32, // into `arena.extra` (type NodeIds)
    args_len: u32,
};

/// Side-slab entry for a top-level `fn` declaration (M0.8 E2 call mechanism,
/// `etch-grammar.md` §5.3). The body is a block: `body_start`/`body_len` index
/// a statement run in `arena.extra`, `value` is the trailing expression (the
/// implicit return value; `NodeId.none` when value-less). `return_type` is
/// `NodeId.none` for a void fn. `is_async` / `throws` carry the parsed effect
/// markers — `async` interpretation is E3 + its codegen Phase 2; a `throws`
/// fn's codegen folds into the E3 error-handling-codegen gate.
pub const FnDecl = struct {
    name: StringId,
    params_start: u32, // index into `arena.fn_params`
    params_len: u32,
    return_type: NodeId, // NodeId.none = void
    is_async: bool,
    throws: bool,
    body_start: u32, // index into `arena.extra` (statement run)
    body_len: u32,
    value: NodeId, // trailing block value (implicit return); NodeId.none if absent
    annotations_extra: u32,
    annotations_len: u32,
    /// Receiver shape (M0.8 E2 block 3). `.none` for a top-level `fn` and for an
    /// associated fn inside an `impl`; `.by_value` / `.by_mut` for a method.
    self_kind: SelfKind = .none,
    /// `false` for an abstract trait method (a `function_signature` with no
    /// body, M0.8 E2 block 3 tranche C); `true` for a fn / method / default-
    /// bodied trait method. When `false`, `body_start`/`body_len`/`value` are
    /// unused (the impl must provide the body).
    has_body: bool = true,
    /// Generic type parameters (M0.8 E2 block 4) — a run of `arena.generic_params`.
    /// `generics_len == 0` for a non-generic fn / method.
    generics_start: u32 = 0,
    generics_len: u32 = 0,
};

/// Side-slab entry for a `struct` declaration (M0.8 E2 block 3,
/// `etch-grammar.md` §5.7). Same shape as `ComponentDecl` — name + range into
/// `arena.fields` + annotation range — but a struct is a by-value type, not
/// registered with the world (no RTTI / archetype storage). Generics are
/// block 4 (a `<` after the name is rejected at parse time).
pub const StructDecl = struct {
    name: StringId,
    fields_start: u32, // index into `arena.fields`
    fields_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
    /// Generic type parameters (M0.8 E2 block 4) — run of `arena.generic_params`.
    generics_start: u32 = 0,
    generics_len: u32 = 0,
};

/// Side-slab entry for an `impl` block (M0.8 E2 block 3, `etch-grammar.md`
/// §5.9). `trait_name` is `0` for an inherent `impl Type { … }`; non-zero for
/// `impl Trait for Type { … }`. `when_root` indexes `arena.when_nodes`
/// (`none_when` if absent — a conditional impl `impl … when self has H`).
/// Methods live in a contiguous `(start, len)` run of `arena.impl_methods`
/// (each an `FnDecl` carrying its `self_kind`).
pub const ImplDecl = struct {
    type_name: StringId,
    trait_name: StringId, // 0 = inherent impl
    when_root: u32, // `RuleDecl.none_when` if absent
    methods_start: u32, // index into `arena.impl_methods`
    methods_len: u32,
    /// Generic type parameters (`impl<T> …`, M0.8 E2 block 4) — run of
    /// `arena.generic_params`. In scope for every method body.
    generics_start: u32 = 0,
    generics_len: u32 = 0,
};

/// Shape of an enum variant (M0.8 E2 block 3 tranche B, `etch-grammar.md`
/// §5.8). `c_like` (`easy`) is fully supported end-to-end; `struct_like`
/// (`Physical { amount: float }`) and `tuple_like` (`ok(T)`) are PARSED so the
/// grammar is accepted, but their construction + destructuring are deferred
/// (the post-Phase-1 advanced pattern set) — fail-loud in interp / codegen.
pub const EnumVariantShape = enum { c_like, struct_like, tuple_like };

/// One variant of an `enum` (M0.8 E2 block 3 tranche B). `data_start`/`data_len`
/// index `arena.fields` for `struct_like` variants and `arena.extra` (a run of
/// type `NodeId`s) for `tuple_like`; both are `0` for `c_like`.
pub const EnumVariant = struct {
    name: StringId,
    shape: EnumVariantShape,
    data_start: u32,
    data_len: u32,
};

/// Side-slab entry for an `enum` declaration (M0.8 E2 block 3 tranche B,
/// `etch-grammar.md` §5.8). Variants live in a `(start, len)` run of
/// `arena.enum_variants`. Generics (`<...>`) are block 4 (a `<` after the name
/// is rejected at parse time, like `struct`).
pub const EnumDecl = struct {
    name: StringId,
    variants_start: u32, // index into `arena.enum_variants`
    variants_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
    /// Generic type parameters (M0.8 E2 block 4) — run of `arena.generic_params`.
    generics_start: u32 = 0,
    generics_len: u32 = 0,
};

/// Side-slab entry for a `trait` declaration (M0.8 E2 block 3 tranche C,
/// `etch-grammar.md` §5.9). `trait_member = function_signature | function_decl`
/// — members live in a `(start, len)` run of `arena.impl_methods` (each an
/// `FnDecl`; an abstract member carries `has_body = false`, a default-bodied
/// one `has_body = true`). Generics (`<...>`) are block 4 (rejected at parse).
pub const TraitDecl = struct {
    name: StringId,
    methods_start: u32, // index into `arena.impl_methods`
    methods_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
    /// Generic type parameters (M0.8 E2 block 4) — run of `arena.generic_params`.
    generics_start: u32 = 0,
    generics_len: u32 = 0,
};

/// One field initializer of a struct literal (`IDENT ":" expression`,
/// `etch-grammar.md` §3.2 l.490). The spread form `.. expression` (data-table
/// inheritance, E4) is out of M0.8 scope.
pub const StructLitField = struct {
    name: StringId,
    value: NodeId, // expr
};

/// `TYPE_IDENT "{" [field_init …] "}"` struct literal (M0.8 E2 block 3,
/// `etch-grammar.md` §3.2 l.486). `type_name` is the explicit struct type; the
/// anonymous `.{ … }` form (which needs the expected type from context) is
/// deferred. Fields live in a `(start, len)` run of `arena.struct_lit_fields`.
pub const StructLitExpr = struct {
    type_name: StringId,
    fields_start: u32,
    fields_len: u32,
};

const NamedTypeNode = struct {
    name: StringId,
};

/// `T[N]` (fixed, `size` is a const expr) or `T[]` (dynamic, `size` is
/// `NodeId.none`) array type (M0.8 collections, `etch-grammar.md` §264). The
/// `.array` type-node kind carries a fixed size, `.slice` carries none — both
/// reach this slab through `data`.
pub const ArrayTypeNode = struct {
    elem: NodeId, // type_node
    size: NodeId, // expr (const) for T[N]; NodeId.none for T[]
};

/// `[K: V]` map type (M0.8 collections, `etch-grammar.md` §278).
pub const MapTypeNode = struct {
    key: NodeId, // type_node
    value: NodeId, // type_node
};

/// `Set<T>` set type (M0.8 collections, `etch-grammar.md` §270 generic_type
/// specialised to `Set`). `elem` is the element type-node.
pub const SetTypeNode = struct {
    elem: NodeId, // type_node
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
    event_decls: std.ArrayListUnmanaged(EventDecl) = .empty,
    tags_decls: std.ArrayListUnmanaged(TagsDecl) = .empty,
    tag_namespaces: std.ArrayListUnmanaged(TagNamespace) = .empty,
    tag_leaves: std.ArrayListUnmanaged(TagLeaf) = .empty,
    tag_paths: std.ArrayListUnmanaged(TagPathExpr) = .empty,
    tag_path_segs: std.ArrayListUnmanaged(StringId) = .empty,
    tag_filters: std.ArrayListUnmanaged(TagFilter) = .empty,
    tag_operands: std.ArrayListUnmanaged(NodeId) = .empty,
    tag_mutation_stmts: std.ArrayListUnmanaged(TagMutationStmt) = .empty,
    rule_decls: std.ArrayListUnmanaged(RuleDecl) = .empty,
    fn_decls: std.ArrayListUnmanaged(FnDecl) = .empty,
    struct_decls: std.ArrayListUnmanaged(StructDecl) = .empty,
    impl_decls: std.ArrayListUnmanaged(ImplDecl) = .empty,
    enum_decls: std.ArrayListUnmanaged(EnumDecl) = .empty,
    enum_variants: std.ArrayListUnmanaged(EnumVariant) = .empty,
    trait_decls: std.ArrayListUnmanaged(TraitDecl) = .empty,
    /// `impl` block methods, each an `FnDecl` carrying its `self_kind`. Stored
    /// here (not in `fn_decls`) so the free-fn index never mistakes a method
    /// for a top-level callable. `ImplDecl` references a `(start, len)` run.
    impl_methods: std.ArrayListUnmanaged(FnDecl) = .empty,
    type_alias_decls: std.ArrayListUnmanaged(TypeAliasDecl) = .empty,
    rule_params: std.ArrayListUnmanaged(RuleParam) = .empty,
    fn_params: std.ArrayListUnmanaged(FnParam) = .empty,
    when_nodes: std.ArrayListUnmanaged(WhenNode) = .empty,

    let_stmts: std.ArrayListUnmanaged(LetStmt) = .empty,
    assign_stmts: std.ArrayListUnmanaged(AssignStmt) = .empty,
    assert_stmts: std.ArrayListUnmanaged(AssertStmt) = .empty,

    binary_exprs: std.ArrayListUnmanaged(BinaryExpr) = .empty,
    unary_exprs: std.ArrayListUnmanaged(UnaryExpr) = .empty,
    field_accesses: std.ArrayListUnmanaged(FieldAccessExpr) = .empty,
    method_gets: std.ArrayListUnmanaged(MethodGetExpr) = .empty,
    casts: std.ArrayListUnmanaged(CastExpr) = .empty,
    ranges: std.ArrayListUnmanaged(RangeExpr) = .empty,
    match_exprs: std.ArrayListUnmanaged(MatchExpr) = .empty,
    match_arms: std.ArrayListUnmanaged(MatchArm) = .empty,
    enum_pattern_payloads: std.ArrayListUnmanaged(EnumPatternPayload) = .empty,
    for_stmts: std.ArrayListUnmanaged(ForStmt) = .empty,
    while_stmts: std.ArrayListUnmanaged(WhileStmt) = .empty,
    array_lits: std.ArrayListUnmanaged(ArrayLitExpr) = .empty,
    map_lits: std.ArrayListUnmanaged(MapLitExpr) = .empty,
    map_entries: std.ArrayListUnmanaged(MapEntry) = .empty,
    index_exprs: std.ArrayListUnmanaged(IndexExpr) = .empty,
    closure_exprs: std.ArrayListUnmanaged(ClosureExpr) = .empty,
    closure_params: std.ArrayListUnmanaged(ClosureParam) = .empty,
    call_exprs: std.ArrayListUnmanaged(CallExpr) = .empty,
    method_calls: std.ArrayListUnmanaged(MethodCall) = .empty,
    struct_lits: std.ArrayListUnmanaged(StructLitExpr) = .empty,
    struct_lit_fields: std.ArrayListUnmanaged(StructLitField) = .empty,
    loop_exprs: std.ArrayListUnmanaged(LoopExpr) = .empty,
    block_exprs: std.ArrayListUnmanaged(BlockExpr) = .empty,
    if_exprs: std.ArrayListUnmanaged(IfExpr) = .empty,
    break_stmts: std.ArrayListUnmanaged(BreakStmt) = .empty,
    throw_stmts: std.ArrayListUnmanaged(ThrowStmt) = .empty,
    try_catch_stmts: std.ArrayListUnmanaged(TryCatchStmt) = .empty,
    emit_stmts: std.ArrayListUnmanaged(EmitStmt) = .empty,
    named_types: std.ArrayListUnmanaged(NamedTypeNode) = .empty,
    array_types: std.ArrayListUnmanaged(ArrayTypeNode) = .empty,
    map_types: std.ArrayListUnmanaged(MapTypeNode) = .empty,
    set_types: std.ArrayListUnmanaged(SetTypeNode) = .empty,
    generic_type_nodes: std.ArrayListUnmanaged(GenericTypeNode) = .empty,
    generic_params: std.ArrayListUnmanaged(GenericParam) = .empty,
    generic_bounds: std.ArrayListUnmanaged(GenericBound) = .empty,

    // Annotation storage.
    annotations: std.AutoHashMapUnmanaged(NodeId, AnnotationSpan) = .empty,
    annot_pool: std.ArrayListUnmanaged(Annotation) = .empty,
    annot_args: std.ArrayListUnmanaged(AnnotationArg) = .empty,

    /// Plain `//` / `/* */` comment spans, source-ordered (M0.8 D-S3-trivia
    /// pool). `leading_comments` maps a top-level item NodeId to a
    /// `(start, len)` slice of this pool — the comments immediately
    /// preceding it.
    comment_spans: std.ArrayListUnmanaged(SourceSpan) = .empty,
    /// `///` doc-comment spans, source-ordered (M0.8 D-S3-doccomment pool).
    /// `doc_comments` maps a declaration NodeId to a slice of this pool.
    doc_comment_spans: std.ArrayListUnmanaged(SourceSpan) = .empty,
    /// Leading plain-comment trivia attached to a top-level item. Empty for
    /// items with no preceding comments. Finer-grained attachment (fields,
    /// in-body statements) is Phase 2 pretty-printer work — M0.8 attaches at
    /// the top-level declaration granularity (the meaningful case for doc
    /// comments and the testable mechanism for D-S3-trivia).
    leading_comments: std.AutoHashMapUnmanaged(NodeId, SpanRange) = .empty,
    /// Doc comments (`///`) attached to a top-level declaration node.
    doc_comments: std.AutoHashMapUnmanaged(NodeId, SpanRange) = .empty,

    pub const AnnotationSpan = struct {
        start: u32,
        len: u32,
    };

    /// `(start, len)` slice into a span pool (`comment_spans` for
    /// `leading_comments`, `doc_comment_spans` for `doc_comments`).
    pub const SpanRange = struct {
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
        self.event_decls.deinit(gpa);
        self.tags_decls.deinit(gpa);
        self.tag_namespaces.deinit(gpa);
        self.tag_leaves.deinit(gpa);
        self.tag_paths.deinit(gpa);
        self.tag_path_segs.deinit(gpa);
        self.tag_filters.deinit(gpa);
        self.tag_operands.deinit(gpa);
        self.tag_mutation_stmts.deinit(gpa);
        self.rule_decls.deinit(gpa);
        self.fn_decls.deinit(gpa);
        self.struct_decls.deinit(gpa);
        self.impl_decls.deinit(gpa);
        self.enum_decls.deinit(gpa);
        self.enum_variants.deinit(gpa);
        self.trait_decls.deinit(gpa);
        self.impl_methods.deinit(gpa);
        self.type_alias_decls.deinit(gpa);
        self.rule_params.deinit(gpa);
        self.fn_params.deinit(gpa);
        self.when_nodes.deinit(gpa);
        self.let_stmts.deinit(gpa);
        self.assign_stmts.deinit(gpa);
        self.assert_stmts.deinit(gpa);
        self.binary_exprs.deinit(gpa);
        self.unary_exprs.deinit(gpa);
        self.field_accesses.deinit(gpa);
        self.method_gets.deinit(gpa);
        self.casts.deinit(gpa);
        self.ranges.deinit(gpa);
        self.match_exprs.deinit(gpa);
        self.match_arms.deinit(gpa);
        self.enum_pattern_payloads.deinit(gpa);
        self.for_stmts.deinit(gpa);
        self.while_stmts.deinit(gpa);
        self.array_lits.deinit(gpa);
        self.map_lits.deinit(gpa);
        self.map_entries.deinit(gpa);
        self.index_exprs.deinit(gpa);
        self.closure_exprs.deinit(gpa);
        self.closure_params.deinit(gpa);
        self.call_exprs.deinit(gpa);
        self.method_calls.deinit(gpa);
        self.struct_lits.deinit(gpa);
        self.struct_lit_fields.deinit(gpa);
        self.loop_exprs.deinit(gpa);
        self.block_exprs.deinit(gpa);
        self.if_exprs.deinit(gpa);
        self.break_stmts.deinit(gpa);
        self.throw_stmts.deinit(gpa);
        self.try_catch_stmts.deinit(gpa);
        self.emit_stmts.deinit(gpa);
        self.named_types.deinit(gpa);
        self.array_types.deinit(gpa);
        self.map_types.deinit(gpa);
        self.set_types.deinit(gpa);
        self.generic_type_nodes.deinit(gpa);
        self.generic_params.deinit(gpa);
        self.generic_bounds.deinit(gpa);
        self.annotations.deinit(gpa);
        self.annot_pool.deinit(gpa);
        self.annot_args.deinit(gpa);
        self.comment_spans.deinit(gpa);
        self.doc_comment_spans.deinit(gpa);
        self.leading_comments.deinit(gpa);
        self.doc_comments.deinit(gpa);
    }

    // ─── Add helpers ────────────────────────────────────────────────────

    pub fn addItem(self: *AstArena, gpa: std.mem.Allocator, kind: ItemKind, data: u32, span: SourceSpan) !NodeId {
        const idx: u28 = @intCast(self.items.len);
        try self.items.append(gpa, .{ .kind = kind, .data = data, .span = span });
        return .{ .category = .item, .index = idx };
    }

    pub fn addTypeAlias(self: *AstArena, gpa: std.mem.Allocator, name: StringId, target: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.type_alias_decls.items.len);
        try self.type_alias_decls.append(gpa, .{ .name = name, .target = target });
        return try self.addItem(gpa, .type_alias, idx, span);
    }

    /// Resolve a type name through the top-level `type` alias chain to its
    /// ultimate underlying name (M0.8 v0.6 foundations). Returns `name`
    /// unchanged when it names no alias. Bounded by the alias count so a
    /// cyclic alias (`type A = B; type B = A`) terminates rather than
    /// looping — the type-checker reports the cycle as an unknown type.
    pub fn resolveTypeAliasName(self: *const AstArena, name: StringId) StringId {
        var current = name;
        var guard: usize = 0;
        const max = self.type_alias_decls.items.len + 1;
        outer: while (guard <= max) : (guard += 1) {
            for (self.type_alias_decls.items) |alias| {
                if (alias.name == current) {
                    const named = self.named_types.items[self.typeNodeData(alias.target)];
                    current = named.name;
                    continue :outer;
                }
            }
            break;
        }
        return current;
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

    pub fn addCast(self: *AstArena, gpa: std.mem.Allocator, operand: NodeId, type_node: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.casts.items.len);
        try self.casts.append(gpa, .{ .operand = operand, .type_node = type_node });
        return try self.addExpr(gpa, .cast, idx, span);
    }

    pub fn addRange(self: *AstArena, gpa: std.mem.Allocator, start: NodeId, end: NodeId, inclusive: bool, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.ranges.items.len);
        try self.ranges.append(gpa, .{ .start = start, .end = end, .inclusive = inclusive });
        return try self.addExpr(gpa, .range, idx, span);
    }

    pub fn addForStmt(self: *AstArena, gpa: std.mem.Allocator, for_stmt: ForStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.for_stmts.items.len);
        try self.for_stmts.append(gpa, for_stmt);
        return try self.addStmt(gpa, .for_stmt, idx, span);
    }

    pub fn addWhileStmt(self: *AstArena, gpa: std.mem.Allocator, while_stmt: WhileStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.while_stmts.items.len);
        try self.while_stmts.append(gpa, while_stmt);
        return try self.addStmt(gpa, .while_stmt, idx, span);
    }

    pub fn addMatch(self: *AstArena, gpa: std.mem.Allocator, scrutinee: NodeId, arms: []const MatchArm, span: SourceSpan) !NodeId {
        const arms_start: u32 = @intCast(self.match_arms.items.len);
        try self.match_arms.appendSlice(gpa, arms);
        const idx: u32 = @intCast(self.match_exprs.items.len);
        try self.match_exprs.append(gpa, .{ .scrutinee = scrutinee, .arms_start = arms_start, .arms_len = @intCast(arms.len) });
        return try self.addExpr(gpa, .match_expr, idx, span);
    }

    /// `elements` is a slice of `NodeId.raw()` values (the array's element
    /// expressions), bulk-appended to `arena.extra` as a contiguous run.
    pub fn addArrayLit(self: *AstArena, gpa: std.mem.Allocator, elements: []const u32, is_fill: bool, fill_count: NodeId, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(gpa, elements);
        const idx: u32 = @intCast(self.array_lits.items.len);
        try self.array_lits.append(gpa, .{
            .elements_start = start,
            .elements_len = @intCast(elements.len),
            .is_fill = is_fill,
            .fill_count = fill_count,
        });
        return try self.addExpr(gpa, .array_lit, idx, span);
    }

    pub fn addMapLit(self: *AstArena, gpa: std.mem.Allocator, entries: []const MapEntry, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.map_entries.items.len);
        try self.map_entries.appendSlice(gpa, entries);
        const idx: u32 = @intCast(self.map_lits.items.len);
        try self.map_lits.append(gpa, .{ .entries_start = start, .entries_len = @intCast(entries.len) });
        return try self.addExpr(gpa, .map_lit, idx, span);
    }

    pub fn addIndex(self: *AstArena, gpa: std.mem.Allocator, receiver: NodeId, index: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.index_exprs.items.len);
        try self.index_exprs.append(gpa, .{ .receiver = receiver, .index = index });
        return try self.addExpr(gpa, .index, idx, span);
    }

    /// `T[N]` (`size` an expr) or `T[]` (`size` is `NodeId.none`). The
    /// type-node kind is `.array` for the fixed form, `.slice` for the
    /// dynamic form; both reach `array_types` through `data`.
    pub fn addArrayType(self: *AstArena, gpa: std.mem.Allocator, elem: NodeId, size: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.array_types.items.len);
        try self.array_types.append(gpa, .{ .elem = elem, .size = size });
        const kind: TypeNodeKind = if (size.isNone()) .slice else .array;
        return try self.addTypeNode(gpa, kind, idx, span);
    }

    pub fn addMapType(self: *AstArena, gpa: std.mem.Allocator, key: NodeId, value: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.map_types.items.len);
        try self.map_types.append(gpa, .{ .key = key, .value = value });
        return try self.addTypeNode(gpa, .map_type, idx, span);
    }

    pub fn addSetType(self: *AstArena, gpa: std.mem.Allocator, elem: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.set_types.items.len);
        try self.set_types.append(gpa, .{ .elem = elem });
        return try self.addTypeNode(gpa, .set_type, idx, span);
    }

    /// `T?` optional type (M0.8 E2 block 5, `etch-grammar.md` §267
    /// `optional_type = type "?"`). The payload type-node is stored directly as
    /// the type-node `data` (no side slab).
    pub fn addOptionalType(self: *AstArena, gpa: std.mem.Allocator, payload: NodeId, span: SourceSpan) !NodeId {
        return try self.addTypeNode(gpa, .optional, payload.raw(), span);
    }

    /// `Foo<T, U>` generic type in type position (M0.8 E2 block 4,
    /// `etch-grammar.md` §270). `args` is a slice of type-`NodeId`s, bulk-
    /// appended to `arena.extra` as a contiguous run.
    pub fn addGenericType(self: *AstArena, gpa: std.mem.Allocator, name: StringId, args: []const NodeId, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        for (args) |a| try self.extra.append(gpa, a.raw());
        const idx: u32 = @intCast(self.generic_type_nodes.items.len);
        try self.generic_type_nodes.append(gpa, .{ .name = name, .args_start = start, .args_len = @intCast(args.len) });
        return try self.addTypeNode(gpa, .generic, idx, span);
    }

    pub fn addClosure(self: *AstArena, gpa: std.mem.Allocator, params: []const ClosureParam, body: NodeId, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.closure_params.items.len);
        try self.closure_params.appendSlice(gpa, params);
        const idx: u32 = @intCast(self.closure_exprs.items.len);
        try self.closure_exprs.append(gpa, .{ .params_start = start, .params_len = @intCast(params.len), .body = body });
        return try self.addExpr(gpa, .closure, idx, span);
    }

    /// `args` is a slice of `NodeId.raw()` values (the call arguments),
    /// bulk-appended to `arena.extra` as a contiguous run.
    pub fn addCall(self: *AstArena, gpa: std.mem.Allocator, callee: NodeId, args: []const u32, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(gpa, args);
        const idx: u32 = @intCast(self.call_exprs.items.len);
        try self.call_exprs.append(gpa, .{ .callee = callee, .args_start = start, .args_len = @intCast(args.len) });
        return try self.addExpr(gpa, .fn_call, idx, span);
    }

    /// `receiver.method(args)` (M0.8 E2 call mechanism). `args` is a slice of
    /// expr `NodeId.raw()` values, bulk-appended to `arena.extra`.
    pub fn addMethodCall(self: *AstArena, gpa: std.mem.Allocator, receiver: NodeId, method_name: StringId, args: []const u32, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(gpa, args);
        const idx: u32 = @intCast(self.method_calls.items.len);
        try self.method_calls.append(gpa, .{ .receiver = receiver, .method_name = method_name, .args_start = start, .args_len = @intCast(args.len) });
        return try self.addExpr(gpa, .method_call, idx, span);
    }

    /// Top-level `fn` declaration (M0.8 E2). The caller appends the params to
    /// `arena.fn_params` and the body run to `arena.extra` beforehand, passing
    /// their ranges in `decl`.
    pub fn addFnDecl(self: *AstArena, gpa: std.mem.Allocator, decl: FnDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.fn_decls.items.len);
        try self.fn_decls.append(gpa, decl);
        return try self.addItem(gpa, .fn_decl, idx, span);
    }

    /// `struct Name { fields }` (M0.8 E2 block 3). The caller appends the
    /// fields to `arena.fields` beforehand, passing the range in `decl`.
    pub fn addStructDecl(self: *AstArena, gpa: std.mem.Allocator, decl: StructDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.struct_decls.items.len);
        try self.struct_decls.append(gpa, decl);
        return try self.addItem(gpa, .struct_decl, idx, span);
    }

    /// `impl [Trait for] Type [when …] { methods }` (M0.8 E2 block 3). The
    /// caller appends the methods to `arena.impl_methods` beforehand, passing
    /// the range in `decl`.
    pub fn addImplDecl(self: *AstArena, gpa: std.mem.Allocator, decl: ImplDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.impl_decls.items.len);
        try self.impl_decls.append(gpa, decl);
        return try self.addItem(gpa, .impl_decl, idx, span);
    }

    /// `trait Name { members }` (M0.8 E2 block 3 tranche C). The caller appends
    /// the member `FnDecl`s to `arena.impl_methods` beforehand, passing the
    /// range in `decl`.
    pub fn addTraitDecl(self: *AstArena, gpa: std.mem.Allocator, decl: TraitDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.trait_decls.items.len);
        try self.trait_decls.append(gpa, decl);
        return try self.addItem(gpa, .trait_decl, idx, span);
    }

    /// `enum Name { variant, … }` (M0.8 E2 block 3 tranche B). The caller
    /// appends the variants to `arena.enum_variants` beforehand, passing the
    /// range in `decl`.
    pub fn addEnumDecl(self: *AstArena, gpa: std.mem.Allocator, decl: EnumDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.enum_decls.items.len);
        try self.enum_decls.append(gpa, decl);
        return try self.addItem(gpa, .enum_decl, idx, span);
    }

    /// `Type { f: v, … }` struct literal (M0.8 E2 block 3). `fields` is
    /// bulk-appended to `arena.struct_lit_fields` as a contiguous run.
    pub fn addStructLit(self: *AstArena, gpa: std.mem.Allocator, type_name: StringId, fields: []const StructLitField, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.struct_lit_fields.items.len);
        try self.struct_lit_fields.appendSlice(gpa, fields);
        const idx: u32 = @intCast(self.struct_lits.items.len);
        try self.struct_lits.append(gpa, .{ .type_name = type_name, .fields_start = start, .fields_len = @intCast(fields.len) });
        return try self.addExpr(gpa, .struct_lit, idx, span);
    }

    /// `return [expr]` (M0.8 E2). The value `NodeId` is stored directly in the
    /// statement's `data` (`NodeId.none` for a bare `return`), no side slab —
    /// same encoding as `expr_stmt`.
    pub fn addReturnStmt(self: *AstArena, gpa: std.mem.Allocator, value: NodeId, span: SourceSpan) !NodeId {
        return try self.addStmt(gpa, .return_stmt, value.raw(), span);
    }

    /// `body_start`/`body_len` index a statement run in `arena.extra` (the
    /// caller collects the body via `parseStmtRun`).
    pub fn addLoopExpr(self: *AstArena, gpa: std.mem.Allocator, label: StringId, body_start: u32, body_len: u32, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.loop_exprs.items.len);
        try self.loop_exprs.append(gpa, .{ .label = label, .body_start = body_start, .body_len = body_len });
        return try self.addExpr(gpa, .loop_expr, idx, span);
    }

    pub fn addBlockExpr(self: *AstArena, gpa: std.mem.Allocator, body_start: u32, body_len: u32, value: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.block_exprs.items.len);
        try self.block_exprs.append(gpa, .{ .body_start = body_start, .body_len = body_len, .value = value });
        return try self.addExpr(gpa, .block_expr, idx, span);
    }

    pub fn addIfExpr(self: *AstArena, gpa: std.mem.Allocator, cond: NodeId, then_block: NodeId, else_branch: NodeId, let_binding: StringId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.if_exprs.items.len);
        try self.if_exprs.append(gpa, .{ .cond = cond, .then_block = then_block, .else_branch = else_branch, .let_binding = let_binding });
        return try self.addExpr(gpa, .if_expr, idx, span);
    }

    pub fn addBreakStmt(self: *AstArena, gpa: std.mem.Allocator, label: StringId, value: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.break_stmts.items.len);
        try self.break_stmts.append(gpa, .{ .label = label, .value = value });
        return try self.addStmt(gpa, .break_stmt, idx, span);
    }

    /// `continue [label]` — the (interned) label id is stored directly in the
    /// statement's `data` (`0` when unlabeled); no side slab needed.
    pub fn addContinueStmt(self: *AstArena, gpa: std.mem.Allocator, label: StringId, span: SourceSpan) !NodeId {
        return try self.addStmt(gpa, .continue_stmt, label, span);
    }

    pub fn addThrowStmt(self: *AstArena, gpa: std.mem.Allocator, value: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.throw_stmts.items.len);
        try self.throw_stmts.append(gpa, .{ .value = value });
        return try self.addStmt(gpa, .throw_stmt, idx, span);
    }

    pub fn addEmitStmt(self: *AstArena, gpa: std.mem.Allocator, em: EmitStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.emit_stmts.items.len);
        try self.emit_stmts.append(gpa, em);
        return try self.addStmt(gpa, .emit_stmt, idx, span);
    }

    pub fn addTagMutationStmt(self: *AstArena, gpa: std.mem.Allocator, tm: TagMutationStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.tag_mutation_stmts.items.len);
        try self.tag_mutation_stmts.append(gpa, tm);
        return try self.addStmt(gpa, .tag_mutation_stmt, idx, span);
    }

    /// Build a `tag_path` expression node (M0.8 E3) from its interned dotted
    /// segments. The segments are copied into `tag_path_segs`; the node data
    /// indexes `tag_paths`.
    pub fn addTagPath(self: *AstArena, gpa: std.mem.Allocator, segs: []const StringId, span: SourceSpan) !NodeId {
        const segs_start: u32 = @intCast(self.tag_path_segs.items.len);
        try self.tag_path_segs.appendSlice(gpa, segs);
        const idx: u32 = @intCast(self.tag_paths.items.len);
        try self.tag_paths.append(gpa, .{ .segs_start = segs_start, .segs_len = @intCast(segs.len) });
        return try self.addExpr(gpa, .tag_path, idx, span);
    }

    pub fn addTryCatchStmt(self: *AstArena, gpa: std.mem.Allocator, tc: TryCatchStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.try_catch_stmts.items.len);
        try self.try_catch_stmts.append(gpa, tc);
        return try self.addStmt(gpa, .try_catch_stmt, idx, span);
    }

    pub fn addLetStmt(self: *AstArena, gpa: std.mem.Allocator, let: LetStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.let_stmts.items.len);
        try self.let_stmts.append(gpa, let);
        return try self.addStmt(gpa, .let_stmt, idx, span);
    }

    pub fn addAssertStmt(self: *AstArena, gpa: std.mem.Allocator, assert_stmt: AssertStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.assert_stmts.items.len);
        try self.assert_stmts.append(gpa, assert_stmt);
        return try self.addStmt(gpa, .assert_stmt, idx, span);
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

    /// Doc comments (`///`) attached to a declaration node, in source order,
    /// or an empty slice if none (M0.8 D-S3-doccomment / D-S3-trivia).
    pub fn docCommentsOf(self: *const AstArena, id: NodeId) []const SourceSpan {
        const r = self.doc_comments.get(id) orelse return &[_]SourceSpan{};
        return self.doc_comment_spans.items[r.start .. r.start + r.len];
    }

    /// Leading plain-comment trivia attached to a top-level item, in source
    /// order, or an empty slice if none (M0.8 D-S3-trivia).
    pub fn leadingCommentsOf(self: *const AstArena, id: NodeId) []const SourceSpan {
        const r = self.leading_comments.get(id) orelse return &[_]SourceSpan{};
        return self.comment_spans.items[r.start .. r.start + r.len];
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
