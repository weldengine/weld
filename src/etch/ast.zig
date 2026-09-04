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

/// Which grammatical subset an arena was parsed under (M1.1.15.2 G1,
/// `etch-grammar.md` §20.3). The mode is a property of the FILE, detected from
/// its extension by `parser.modeForPath`, and it is the only thing that
/// distinguishes a declaration file from a source file — `.d.etch` is not
/// another language, it is a reduced view of the same EBNF (§20).
///
/// It lives HERE and not in `parser.zig` because the parse is not the only
/// stage that needs it: `E1901` is decided after the parse, from the AST, and a
/// checker handed a bare arena has no other way to know which file it came from.
pub const ParseMode = enum {
    /// A standard `.etch` source file: the full grammar, every `fn` has a body.
    standard,
    /// A `.d.etch` declaration file: signatures and types with no bodies
    /// (§20.1). Two things change, and only two. Every `fn` becomes
    /// signature-only whatever its enclosing construct, and a `fn` that carries
    /// a body is refused AT ITS OPENING BRACE with `E1900` — the parser knows at
    /// the `{` that a body follows, and building one to reject it afterwards
    /// would manufacture an AST no downstream stage may see. The `service`
    /// construct becomes available here and here only (§20.4).
    ///
    /// What does NOT change here is `E1901`: the identity of a disallowed
    /// top-level construct is decided AFTER the parse, from the AST, by the
    /// type-checker (`etch-validation-ecs.md` §28, and the `scene_cook.zig`
    /// precedent). Giving it a parser path would duplicate a twenty-construct
    /// list that is already enumerable from `ItemKind`.
    declaration_file,
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
    /// `.d.etch`-only (M1.1.15.2 G1, `etch-grammar.md` §20.4). Never produced
    /// from a standard `.etch` — the parser refuses it there.
    service_decl,
};

/// Top-level declaration visibility (M1.0.8, `etch-grammar.md` §5.1
/// `visibility_modifier`, `etch-reference-part1.md` §1.3). Public by default;
/// `.private` is set by the parser when a `private` prefix precedes a
/// `declaration_body`. Consumed only by `buildExports` (cross-module access);
/// intra-module resolution ignores it (`etch-resolver-types.md` §10.1).
pub const Visibility = enum { public, private };

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
    /// Interpolated string literal `"a {expr} b"` (M0.8 E3-C tranche 1c,
    /// `etch-grammar.md` §1.4 `interpolation = "{" , expression , "}"`).
    /// Data indexes `string_interps`.
    string_interp,
    /// Localized text `@loc…` (§3.2 `loc_expr`, M0.8 E4 — item-10 ruling:
    /// STRUCTURAL parse only; the fingerprint/extraction model is E5 with
    /// `locale`). Types as `string`. Data indexes `loc_exprs`.
    loc_expr,
    /// Postfix tag query `expression tag_op tag_operand` (§3.2 `tag_expr`,
    /// M0.8 E4 — needed by B-construct conditions like quest `requires:
    /// player has_tag .x`). Parse + resolve (bool); EVALUATION is fail-loud
    /// in both backends (the negative-tag-op precedent — flagged bound).
    /// Data indexes `tag_query_exprs`.
    tag_query,
    /// Structural spawn `spawn(C1{…}, …)` / `spawn("Prefab")` (§3.2
    /// `structural_spawn`, M1.0.10). A statement-position expression: the v0.6
    /// no-body-handle decision (§4.5) means the type-checker rejects binding or
    /// using its result (M1.0.10 E2). Data indexes `spawn_structs`. Distinct
    /// from the async `spawn { }` task STATEMENT (§4.2 `spawn_stmt`,
    /// `StmtKind.spawn_stmt` since M1.0.12) — the keyword is shared, the token
    /// after `spawn` disambiguates; this node is only ever the `(` form.
    spawn_struct,
    /// `measure { block }` (M1.0.15, §17 erratum) — a wall-clock timing
    /// expression yielding a `Duration`. Data indexes `measure_exprs`. Valid only
    /// in a test body (E0910 elsewhere); determinism is preserved by confining
    /// the sole wall-clock surface to tests.
    measure_expr,
};

/// Closed enum of type-node kinds the parser can produce.
pub const TypeNodeKind = enum {
    // S3
    named,
    // Reserved
    path, // produced since M1.0.16 (qualified_path `alias.Member`, type position)
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
    coalesce, // a ?? b — null coalesce (M0.8 E3-C tranche 4, part1 §6.6)
};

/// Closed enum of the unary operators. `force_unwrap` is postfix in the
/// grammar but stores identically (operand + span).
pub const UnaryOp = enum {
    neg, // -x
    logical_not, // not x
    force_unwrap, // x! — panic if none (M0.8 E3-C tranche 4, part1 §6.6)
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

/// One `import_item` (`( IDENT | TYPE_IDENT ) [ "as" ( IDENT | TYPE_IDENT ) ]`,
/// `etch-grammar.md` §5.2, reconciled D-D). Imported items are mostly
/// `TYPE_IDENT` (`Vec3`, `Health`) but a bare `IDENT` (`gravity`) is equally
/// legal — the AST stores the interned name, so the token-kind distinction is a
/// parse concern (E3) and this shape accommodates both. `alias` is the optional
/// local-alias name (`as Y`), `0` when absent.
pub const ImportItem = struct {
    name: StringId, // imported item name (IDENT or TYPE_IDENT)
    alias: StringId, // local alias (`as Y`), 0 if absent
};

/// Side-slab entry for an `import` directive (M1.0.7, `etch-grammar.md` §5.2:
/// `import_decl = "import" module_path [ import_spec ]`). The module path is a
/// `(start, len)` run of `arena.import_path_segs` (≥1 IDENT segment, e.g.
/// `core`, `math` — the `tag_path_segs` precedent). `module_alias` carries the
/// `as m` whole-module alias (`0` when absent — a bare `import a.b` has implicit
/// alias = last path segment, derived at resolve). `items` is a run of
/// `arena.import_items` for the selective form (`import a.b { X, Y }`);
/// `items_len == 0` for the whole-module forms. The four grammar forms map to:
/// (1) `import a.b` → alias 0, items 0; (2) `import a.b { X, Y }` → items > 0;
/// (3) `import a.b as m` → module_alias set; (4) `import a.b { X as Y }` → items
/// with per-item alias. Module-alias qualified resolution (`m.Type`) is deferred
/// (D-F); E5 still records the alias binding so the later walk is purely additive.
pub const ImportDecl = struct {
    path_start: u32, // index into `arena.import_path_segs`
    path_len: u32, // ≥ 1
    module_alias: StringId, // `as m` alias (0 if absent or selective form)
    items_start: u32, // index into `arena.import_items`
    items_len: u32, // 0 for the whole-module forms (1 and 3)
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

/// Resolution of an event's designated `Entity` field for `await
/// entity_event` scoping (M1.0.14, `etch-reference-part1.md` §9.4): the field
/// annotated `@entity_target`, else the single `Entity`-typed field, else a
/// diagnostic condition. Produced by `AstArena.resolveEventEntityTarget` — the
/// single home of the designated-field policy, consumed by the type-checker
/// (to diagnose `E0908`/`E0909` at the `await` site) and by the interpreter
/// (to capture the field at suspension, where it always resolves — the program
/// has passed `weld check`).
pub const EntityTargetResolution = union(enum) {
    /// The designated field: its ordinal in the event's field run and its name.
    field: struct { index: u32, name: StringId },
    /// No `Entity`-typed field at all → `E0908 EventNotEntityScoped`.
    none_entity,
    /// Two or more `Entity` fields and no `@entity_target` → `E0909 AmbiguousEventEntityTarget`.
    ambiguous,
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

/// `@loc…` localized text (§3.2 `loc_expr`, M0.8 E4 — structural form
/// only). Fingerprint form: `@loc[:"meaning"][|"desc"][@@id.path]:"text"`
/// (`text` decoded; the optional metadata in `meaning` / `description` /
/// `custom_id`, 0 = absent). Key form (`is_key_form`): `@loc("key.path",
/// name: expr, …)` — `text` holds the key, args are a `struct_lit_fields`
/// run (named pairs).
pub const LocExpr = struct {
    text: StringId,
    meaning: StringId,
    description: StringId,
    custom_id: StringId,
    is_key_form: bool,
    args_start: u32,
    args_len: u32,
};

/// One dialogue line (`line ":" (STRING_LITERAL | loc_expr) [when]`,
/// §8.4 PATCHED — item 10).
pub const DialogueLine = struct {
    text: NodeId, // string_lit or loc_expr
    when_root: u32, // RuleDecl.none_when if absent
    span: SourceSpan,
};

/// One `speaker "id" { lines }` block (§8.4). Lines are a direct
/// contiguous `dialogue_lines` run (no nesting inside a speaker).
pub const DialogueSpeaker = struct {
    id: StringId, // decoded string literal
    lines_start: u32,
    lines_len: u32,
    span: SourceSpan,
};

/// One choice option (`(STRING | loc_expr) [when] "->" (IDENT | end)`).
pub const DialogueOption = struct {
    text: NodeId,
    when_root: u32,
    target: StringId, // 0 when `is_end`
    is_end: bool,
    span: SourceSpan,
};

/// One `choice { options }` block (§8.4). Options are a direct run of
/// `dialogue_options` (no nesting inside a choice).
pub const DialogueChoice = struct {
    options_start: u32,
    options_len: u32,
    span: SourceSpan,
};

/// One `emit … [when ecs_condition]` dialogue element (§8.4 PATCHED —
/// item 11: the trailing condition exists in dialogue-element position
/// ONLY, a single §6 condition, not a full clause).
pub const DialogueEmit = struct {
    stmt: NodeId, // emit stmt
    when_root: u32, // RuleDecl.none_when if absent
    span: SourceSpan,
};

/// One `-> target` transition (`end` or a branch label).
pub const DialogueGoto = struct {
    target: StringId, // 0 when `is_end`
    is_end: bool,
    span: SourceSpan,
};

/// Kind of one dialogue element (§8.4), declaration order preserved.
pub const DialogueElemKind = enum { speaker, choice, branch, emit, goto };

/// One dialogue element: `index` points into the kind's slab.
pub const DialogueElem = struct {
    kind: DialogueElemKind,
    index: u32,
};

/// One `branch IDENT { elements }` (§8.4) — elements recurse; the elems
/// run is buffered into `dialogue_elems`.
pub const DialogueBranch = struct {
    name: StringId,
    elems_start: u32,
    elems_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for a `dialogue` declaration (M0.8 E4 Level B, §8.4).
pub const DialogueDecl = struct {
    name: StringId,
    elems_start: u32,
    elems_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Kind of one ability property (`etch-grammar.md` §8.5 PATCHED, M0.8 E4
/// items 12-15 ruling: the grammar shape WINS over the validation-ecs §12
/// handler shape — E1585/W1580 are RESERVED, no handlers exist).
pub const AbilityPropKind = enum { cost, cooldown, tags_required, tags_blocked, custom };

/// One ability property. `cost` carries its `struct_literal_body` as a
/// `(start, len)` run of `arena.struct_lit_fields` encoded in `value` via
/// `cost_fields_start`/`cost_fields_len`; every other kind carries its
/// expression in `value`.
pub const AbilityProp = struct {
    kind: AbilityPropKind,
    name: StringId,
    /// Expression NodeId for every kind except `cost` (where it is `none`).
    value: NodeId,
    cost_fields_start: u32,
    cost_fields_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for an `ability` declaration (M0.8 E4 Level B, §8.5).
/// The embedded `rule` lives in `rule_decls` but is NOT a top-level item —
/// it is ability STRUCTURE (validated, never registered for ticking; the
/// Level-B contract). `no_rule` when absent.
pub const AbilityDecl = struct {
    name: StringId,
    props_start: u32,
    props_len: u32,
    rule_idx: u32,
    annotations_extra: u32,
    annotations_len: u32,

    pub const no_rule: u32 = std.math.maxInt(u32);
};

/// Postfix tag query expression (§3.2 `tag_expr`, M0.8 E4): a receiver +
/// a `tag_filters` entry (op + operand run, shared with the when-clause
/// encoding).
pub const TagQueryExpr = struct {
    receiver: NodeId,
    filter: u32, // index into `tag_filters`
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

/// Side-slab entry for a top-level `const` declaration (M1.0.8,
/// `etch-grammar.md` §4.1: `const_stmt = "const" ( IDENT | TYPE_IDENT ) ":"
/// type "=" const_expression`). `name` is the interned binding name (a
/// `SCREAMING_SNAKE_CASE` const lexes as `TYPE_IDENT`; both cases accepted).
/// `type_node` is the declared `: type` annotation (mandatory — no inference
/// on a const, part1 §3.5); `value` is the const expression, validated for
/// const-evaluability + type at resolve (E1101 / E0200). Top-level only.
pub const ConstDecl = struct {
    name: StringId,
    type_node: NodeId,
    value: NodeId,
};

/// Side-slab entry for a top-level `test` block (M1.0.8, `etch-grammar.md`
/// §17: `test_decl = "test" STRING_LITERAL block`). `name` is the interned
/// string-literal label; `body` is a `block_expr` NodeId (the reused
/// block/statement parser). M1.0.15 delivers execution: the body is
/// type-checked (sync context) and run by `test_runner.zig`. The annotation
/// range (`@tag`/`@skip`/`@only`) is preserved (M1.0.15 — M1.0.8 discarded it).
pub const TestDecl = struct {
    name: StringId,
    body: NodeId,
    annotations_extra: u32 = 0,
    annotations_len: u32 = 0,
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
    /// `async rule` (M0.8 E3 sub-slice B): the body may `await`, suspending the
    /// rule as a task that resumes a later tick. Interpreter-only (Option-A
    /// task-record); codegen rejects it (`UnsupportedConstruct`, Phase 2).
    is_async: bool = false,

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
    has_changed, // entity has T changed (M0.8 E3) — change-detection filter
    tag_filter, // entity has_tag .path (M0.8 E3) — `aux` indexes `tag_filters`
    has_expr_filter, // entity has T { expression } (M0.8 E4 — §6 general filter; `filter_value` is the expr, fields of T in scope)
    resource_filter, // resource T { expression } (M0.8 E4 — §6; fields of T in scope)
    expr_cond, // bare expression condition (M0.8 E4 — §6 last arm; `filter_value` is the expr)
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
    /// `recv?.field` (M0.8 E3-C tranche 4): short-circuits to `none` when the
    /// receiver is `none`. Out of the M0.8 subset (scalar optional payloads
    /// have no fields) — parsed so the resolver rejects it with a pointer.
    opt_chain: bool = false,
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
/// `optional_some` / `optional_none` are the `some(v)` / `none` optional
/// patterns (M0.8 E3-C tranche 4, part1 §7.6): `optional_some`'s payload is
/// the binding name `StringId`; `optional_none` carries no payload (0).
pub const PatternKind = enum { wildcard, literal, binding, enum_variant, optional_some, optional_none };

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

/// Interpolated string literal `"a {x} b {y} c"` (M0.8 E3-C tranche 1c).
/// `n_exprs` embedded expressions alternate with `n_exprs + 1` literal
/// segments (possibly empty): seg0 expr0 seg1 expr1 … segN. Segments are
/// escape-processed interned `StringId`s, a run of `n_exprs + 1` entries in
/// `arena.extra` at `segs_start`; the embedded expressions are a run of
/// `n_exprs` `NodeId`s at `exprs_start`.
pub const StringInterp = struct {
    segs_start: u32,
    exprs_start: u32,
    n_exprs: u32,
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

/// `measure { block }` expression (M1.0.15, `etch-grammar.md` §17 erratum). Same
/// storage shape as a `BlockExpr` (statement run + optional trailing value); a
/// distinct node kind so the type-checker gates it (Duration result, test-body
/// only → E0910) and the interpreter times the block on the wall clock.
pub const MeasureExpr = struct {
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

/// The suspension source of an `await` (M0.8 E3 sub-slice B, `etch-grammar.md`
/// §4.2 `await_target`). `wait`/`wait_unscaled`/`entity_event`/`global_event`
/// are contextual builtins recognised by name after `await` (not keywords);
/// `future` is the fall-through `await <expression>` form (awaiting a `Future`).
pub const AwaitTargetKind = enum {
    wait, // await wait(<ticks>) — M0.8 interp counts the arg in TICKS (no clock)
    wait_unscaled, // await wait_unscaled(<dur>) — needs a real clock → interp fail-loud (out of E3)
    entity_event, // await entity_event(<entity>, T)
    global_event, // await global_event(T)
    future, // await <expression> (Future) — T2, interp fail-loud in sub-slice B
};

/// `await <target>` expression (M0.8 E3 sub-slice B, `etch-grammar.md` §3.2
/// `await_expr` / §4.2 `await_stmt`). One node covers both the statement form
/// (`await target`, wrapped in an expr-stmt) and the value form. `arg_expr` is
/// the duration/tick expr (`wait`/`wait_unscaled`) or the awaited future
/// (`future`), else `NodeId.none`; `entity_expr` is the `entity_event` entity,
/// else `NodeId.none`; `event_type` is the event type name for the two event
/// forms, else `0`. `filter_start` / `filter_len` index a run of
/// `arena.struct_lit_fields` — the optional payload filter of the two event
/// forms (`entity_event` / `global_event`), each `IDENT : expression` an
/// equality predicate; `(0, 0)` when no filter body is present (M1.0.14,
/// `etch-grammar.md` §4.2).
pub const AwaitExpr = struct {
    target_kind: AwaitTargetKind,
    arg_expr: NodeId,
    entity_expr: NodeId,
    event_type: StringId,
    filter_start: u32,
    filter_len: u32,
};

/// One branch of a `race` / `sync` statement (M1.0.12 E2, `etch-grammar.md`
/// §4.2 `race_branch = [ "if" expression "=>" ] statement`). `cond` is
/// `NodeId.none` for an unconditional branch — a conditional branch's guard is
/// evaluated synchronously in the parent scope at construct entry (§9.5) and
/// decides whether the branch starts. `stmt` is the single branch statement
/// (commonly a block-expression statement `{ … }`).
pub const ConcurrencyBranch = struct {
    cond: NodeId,
    stmt: NodeId,
    span: SourceSpan,
};

/// `race "{" { race_branch } "}"` statement (M1.0.12 E2, `etch-grammar.md`
/// §4.2). Branches are a contiguous `(start, len)` run of
/// `arena.concurrency_branches`. First branch to complete wins; the losers are
/// canceled (§9.5 — execution M1.0.12 E4).
pub const RaceStmt = struct {
    branches_start: u32,
    branches_len: u32,
};

/// `sync "{" { sync_branch } "}"` statement (M1.0.12 E2, `etch-grammar.md`
/// §4.2). Same branch storage as `race`; the parent joins when ALL branches
/// complete (§9.6 — execution M1.0.12 E4).
pub const SyncStmt = struct {
    branches_start: u32,
    branches_len: u32,
};

/// `branch block` statement (M1.0.12 E2, `etch-grammar.md` §4.2
/// `branch_stmt`) — a fire-and-forget detached task; no handle, the parent can
/// neither await nor cancel it (§9.7 — execution M1.0.12 E5). The body is a
/// statement run in `arena.extra` (same layout as a rule body). Distinct from
/// the quest/dialogue `branch` sub-constructs, which are parsed inside their
/// own construct parsers and never reach statement position.
pub const BranchStmt = struct {
    body_start: u32,
    body_len: u32,
};

/// `[ "let" IDENT "=" ] "spawn" block` statement (M1.0.12 E2,
/// `etch-grammar.md` §4.2 `spawn_stmt`) — a detached task with a `TaskHandle`
/// (§9.8). `binding` is the `let` name (`0` when absent — the handle is
/// discarded); the binding is PART of the statement, not a `let_stmt` whose
/// initializer is a spawn. The body is a statement run in `arena.extra`.
/// Distinct from the structural `spawn ( … )` expression (§3.2
/// `structural_spawn` — `ExprKind.spawn_struct`); the two share the keyword,
/// disambiguated by the token after `spawn`.
pub const SpawnStmt = struct {
    binding: StringId,
    body_start: u32,
    body_len: u32,
};

/// Timer statement kind (M1.0.13 E2, `etch-grammar.md` §4.3 `timer_kind`).
pub const TimerKind = enum {
    /// `after(d) { }` — one-shot on the game clock (pausable, scaled).
    after,
    /// `every(d) { }` — repeating on the game clock (fixed period, no drift
    /// correction Phase 1).
    every,
    /// `after_unscaled(d) { }` — one-shot on the unscaled clock (fires under
    /// pause, ignores `time_scale`).
    after_unscaled,
};

/// `[ "let" IDENT "=" ] timer_kind "(" expression ")" block` statement
/// (M1.0.13 E2, `etch-grammar.md` §4.3 `timer_stmt`) — schedules a callback
/// on the runtime timer registry (§9.10: a timer is NOT a task; its body is a
/// synchronous context). `arg` is the Duration expression, evaluated once at
/// scheduling time (a full expression — not restricted to a literal, unlike
/// `await wait`). `binding` is the `let` name, typed `TimerHandle` (`0` when
/// absent — the handle is discarded); as with `SpawnStmt`, the binding is
/// PART of the statement, not a `let_stmt` whose initializer is a timer. The
/// body is a statement run in `arena.extra`. `quantize_stmt` stays a
/// payloadless placeholder — no struct, no arena list (its musical beat/bar
/// clock is assigned to a later Sequencer-adjacent milestone).
pub const TimerStmt = struct {
    kind: TimerKind,
    arg: NodeId,
    body_start: u32,
    body_len: u32,
    binding: StringId,
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
    /// Named-argument labels (M0.8 E4, §3.3 — item-16 ruling): a run of
    /// `call_arg_names` parallel to the args (`0` = positional), or
    /// `no_arg_names` when every argument is positional (the common case —
    /// zero storage, byte-identical to the pre-E4 representation).
    names_start: u32 = no_arg_names,
};

/// Sentinel for a call without named arguments.
pub const no_arg_names: u32 = std.math.maxInt(u32);

/// `receiver.method(args)` call expression (M0.8 E2 call mechanism,
/// `etch-grammar.md` postfix_op §421). Args are a run of expr `NodeId` raw
/// values in `arena.extra`. Block 2 produces the node (parser-testable); the
/// 4-kind method dispatch (`etch-resolver-types.md §5`) is exercised in block 3
/// once `impl` provides methods.
pub const MethodCall = struct {
    /// Named-argument labels (M0.8 E4, §3.3) — same encoding as `CallExpr`.
    names_start: u32 = no_arg_names,
    receiver: NodeId,
    method_name: StringId,
    args_start: u32,
    args_len: u32,
    /// `recv?.method(args)` (M0.8 E3-C tranche 4): the receiver is an
    /// optional — `none` short-circuits, `some(p)` dispatches the method on
    /// the payload and re-wraps the result in an optional.
    opt_chain: bool = false,
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

/// Side-slab entry for a `service` declaration (M1.1.15.2 G1,
/// `etch-grammar.md` §20.4: `service_decl = "service" IDENT "{"
/// { function_decl_no_body } "}"`).
///
/// **Structurally a `TraitDecl` minus generics**, and that is deliberate rather
/// than convenient: a service body is a run of bodyless `fn` signatures, which
/// is exactly what a trait body already is. The methods therefore live in the
/// SAME `arena.impl_methods` slab, each an `FnDecl` with `has_body = false` —
/// the field M0.8 minted for abstract trait methods. No new bodyless-fn
/// mechanism is introduced by this milestone.
///
/// The name is an `IDENT` (lowercase), not a `TYPE_IDENT`: a service is called
/// as `audio_player.play(...)`, so it occupies the value namespace, not the
/// type namespace. Generics are absent because §20.4 has no production for
/// them — the grammar shape wins.
pub const ServiceDecl = struct {
    name: StringId,
    methods_start: u32, // index into `arena.impl_methods`
    methods_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One field initializer of a struct literal (`IDENT ":" expression`,
/// `etch-grammar.md` §3.2 l.490). The spread form `".." expression` (§3.2
/// l.491, data-table inheritance) lands with E4 and is encoded as
/// `name == 0` with `value` holding the spread expression; it is parsed in
/// data-entry bodies only (general struct literals keep rejecting it — the
/// E2 deferral homed at the data table, see the M0.8 brief journal).
pub const StructLitField = struct {
    name: StringId, // 0 = spread entry (`..expr`)
    value: NodeId, // expr
};

/// `TYPE_IDENT "{" [field_init …] "}"` struct literal (M0.8 E2 block 3,
/// `etch-grammar.md` §3.2 l.486). `type_name` is the explicit struct type; the
/// anonymous `.{ … }` form (M0.8 E3-C tranche 8) carries `type_name == 0` and
/// resolves against the expected type from its context (check mode,
/// `etch-resolver-types.md` §4). Fields live in a `(start, len)` run of
/// `arena.struct_lit_fields`.
pub const StructLitExpr = struct {
    type_name: StringId,
    fields_start: u32,
    fields_len: u32,
};

/// `structural_spawn` (§3.2 l.552, M1.0.10): `spawn(C1 {…}, …)` (component
/// literals) or `spawn("Prefab")` (prefab name). Two forms, discriminated by
/// `is_prefab`:
///   • component-literal varargs — `is_prefab == false`; `args_start` /
///     `args_len` index a contiguous run of struct-lit `Expr` `NodeId.raw()`
///     values in `arena.extra` (each a `.struct_lit`), the `addArrayLit` run
///     convention.
///   • prefab name — `is_prefab == true`; `prefab_name` is the interned string
///     literal, `args_len == 0`. The prefab form parses + is recognized but is
///     REFUSED at type-check in Phase 1 (gating on the prefab runtime, E2).
/// No body handle is produced (v0.6 statement-only, §4.5) — the result is not a
/// usable value, which the type-checker enforces (E2).
pub const SpawnStructExpr = struct {
    is_prefab: bool,
    prefab_name: StringId = 0, // valid iff is_prefab
    args_start: u32 = 0, // index into `arena.extra` (struct-lit NodeIds); valid iff !is_prefab
    args_len: u32 = 0,
};

/// One entry of a `data` table (M0.8 E4, `etch-grammar.md` §14:
/// `data_entry = IDENT ":" struct_literal_body [","]`). The entry body is a
/// `(start, len)` run of `arena.struct_lit_fields` (spread fields carry
/// `name == 0`). `id_pascal` records that the id token was TYPE_IDENT-shaped
/// so validation can emit `E1768 IdInvalidFormat` (ids are snake_case IDENTs)
/// without re-lexing. `span` covers `id ... }` for entry-precise diagnostics.
pub const DataEntry = struct {
    id: StringId,
    id_pascal: bool,
    fields_start: u32, // index into `arena.struct_lit_fields`
    fields_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for a `data` table declaration (M0.8 E4 Level B,
/// `etch-grammar.md` §14: `data_decl = "data" TYPE_IDENT ":" TYPE_IDENT "{"
/// {data_entry} "}"`). `entry_type` is the shared entry type (a declared
/// `struct`); entries live in a `(start, len)` run of `arena.data_entries`.
pub const DataDecl = struct {
    name: StringId,
    entry_type: StringId,
    entry_type_span: SourceSpan,
    entries_start: u32, // index into `arena.data_entries`
    entries_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

// ── M0.8 E7 Level C — scene / prefab (`etch-grammar.md` §15) ──────────────
// Serialization-only (parse + validation + descriptor); runtime instantiation
// is M0.9 (`engine-scene-serialization.md`). `scene`/`prefab` are STRING-named
// (the `audio_score`/`theme` precedent — referenced by string, no symbol).

/// One `component_instance` (`TYPE_IDENT struct_literal_body`, §15 l.1609) —
/// used in entity bodies, instance bodies, and the `resources` block. Mirrors
/// `DataEntry`: a TYPE_IDENT-keyed body whose fields are a `(start, len)` run
/// of `arena.struct_lit_fields` (via `parseDataEntryBody`).
pub const ComponentInstance = struct {
    type_name: StringId, // TYPE_IDENT (component / resource type)
    fields_start: u32, // index into `arena.struct_lit_fields`
    fields_len: u32,
    span: SourceSpan,
};

/// One `component_field_override` (`TYPE_IDENT "." IDENT "=" expression`,
/// §15 l.1610) — `instance_decl` bodies only (the grammar's `entity_decl` body
/// is `{ component_instance }` with no override form; a prefab variant
/// re-declares whole components instead).
pub const FieldOverride = struct {
    type_name: StringId, // TYPE_IDENT (component)
    field: StringId, // IDENT
    value: NodeId, // expression (RHS)
    span: SourceSpan,
};

/// Kind of one `instance_decl` body member (`component_instance |
/// component_field_override`, §15 l.1606). The `QuestElem` discriminated-pointer
/// pattern — preserves declaration order across the two kinds.
pub const InstanceMemberKind = enum { component, field_override };
/// One `instance_decl` body member — a discriminated index into either
/// `arena.component_instances` or `arena.field_overrides` (declaration order).
pub const InstanceMember = struct {
    kind: InstanceMemberKind,
    index: u32, // into `arena.component_instances` | `arena.field_overrides`
};

/// One `entity_decl` (§15 l.1598) — used by BOTH `scene_decl` and `prefab_decl`.
/// `uuid`/`parent` are optional STRING_LITERALs (0 = absent). The name is
/// mandatory (grammar `entity STRING_LITERAL`; the doc's anonymous `entity {`
/// form is a shorthand — corpus uses legal forms). Components are a direct run
/// of `arena.component_instances` (the body closes before the next sibling — the
/// `SequenceTrack`→keyframes precedent).
pub const SceneEntity = struct {
    name: StringId, // STRING_LITERAL content
    uuid: StringId, // 0 if absent
    parent: StringId, // 0 if absent
    /// `extensions: [...]` clause (M1.0.6 E5) — a `(start, len)` run of
    /// `arena.scene_extensions` (active-extension prefab names, by name). Empty
    /// (len 0) if the clause is absent.
    extensions_start: u32,
    extensions_len: u32,
    components_start: u32, // index into `arena.component_instances`
    components_len: u32,
    span: SourceSpan,
};

/// One `instance_decl` (§15 l.1604): `instance of "Type" "Name" { … }`. Members
/// interleave `component_instance | component_field_override` → a buffered run of
/// `arena.scene_instance_members` (the `quest_elems` precedent — both kinds feed
/// shared pools).
pub const SceneInstance = struct {
    prefab_name: StringId, // STRING_LITERAL after `of`
    instance_name: StringId, // STRING_LITERAL
    uuid: StringId, // 0 if absent
    /// `extensions: [...]` clause (M1.0.6 E5) — a `(start, len)` run of
    /// `arena.scene_extensions` (active-extension prefab names, by name). Empty
    /// (len 0) if the clause is absent.
    extensions_start: u32,
    extensions_len: u32,
    members_start: u32, // index into `arena.scene_instance_members`
    members_len: u32,
    span: SourceSpan,
};

/// Kind of one top-level `scene` child (`entity_decl | instance_decl`, §15 l.1592).
pub const SceneChildKind = enum { entity, instance };
/// One top-level `scene` child — a discriminated index into either
/// `arena.scene_entities` or `arena.scene_instances` (declaration order).
pub const SceneChild = struct {
    kind: SceneChildKind,
    index: u32, // into `arena.scene_entities` | `arena.scene_instances`
};

/// Side-slab entry for a `scene` declaration (§15 l.1588). STRING-named.
/// `version` is the optional INT_LITERAL expr (`NodeId.none` if absent).
/// `metadata` is the optional `metadata: struct_literal_body` (a
/// `struct_lit_fields` run, valid iff `has_metadata`). `resources` is the
/// `resources { component_instance }` block (a `component_instances` run).
/// `children` interleave entity|instance → a buffered run of `arena.scene_children`.
pub const SceneDecl = struct {
    name: StringId, // STRING_LITERAL content
    name_span: SourceSpan,
    version: NodeId, // INT_LITERAL expr, `NodeId.none` if absent
    has_metadata: bool,
    metadata_start: u32, // struct_lit_fields run (valid iff has_metadata)
    metadata_len: u32,
    resources_start: u32, // index into `arena.component_instances`
    resources_len: u32,
    children_start: u32, // index into `arena.scene_children`
    children_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Prefab relation (§15 l.1629): `of` = exclusive variant (static inheritance),
/// `extends` = additive extension (dynamic composition). `none` when standalone.
/// `requires` / `on_attach` / `on_detach` are valid only with `extends` (l.1635 /
/// l.1640 / l.1645 — a VALIDATION, not parse).
pub const PrefabRelation = enum { none, of, extends };

/// Side-slab entry for a `prefab` declaration (§15 l.1618). STRING-named.
/// `relation` + `relation_target` carry `of "X"` / `extends "X"` (target 0 if
/// none). `requires` is a `(start, len)` run of `arena.prefab_requires`
/// (TYPE_IDENT StringIds — the `audio_score_targets` precedent). `entities` is a
/// direct run of `arena.scene_entities` (REUSED — the prefab body is
/// `{ entity_decl }`, no instances). `on_attach`/`on_detach` are optional
/// statement runs in `arena.extra` (the `parseStmtRun` precedent).
pub const PrefabDecl = struct {
    name: StringId, // STRING_LITERAL content
    name_span: SourceSpan,
    relation: PrefabRelation,
    relation_target: StringId, // STRING_LITERAL after of/extends (0 if none)
    requires_start: u32, // index into `arena.prefab_requires`
    requires_len: u32,
    version: NodeId, // INT_LITERAL expr, `NodeId.none` if absent
    has_metadata: bool,
    metadata_start: u32, // struct_lit_fields run (valid iff has_metadata)
    metadata_len: u32,
    entities_start: u32, // index into `arena.scene_entities`
    entities_len: u32,
    has_on_attach: bool,
    on_attach_start: u32, // statement run in `arena.extra`
    on_attach_len: u32,
    has_on_detach: bool,
    on_detach_start: u32, // statement run in `arena.extra`
    on_detach_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Side-slab entry for a `theme` declaration (M0.8 E5 Level B presentation,
/// `etch-grammar.md` §10.2: `theme_decl = "theme" STRING_LITERAL "{"
/// {theme_entry} "}"`, `theme_entry = IDENT ":" expression`). The grammar
/// shape WINS over the validation-ecs §16.1 typed-token shape (E5 ruling 1):
/// entries are `key: expression` pairs (a widget-kind → style mapping or a
/// global variable), the name is a string literal. Entries live in a
/// `(start, len)` run of `arena.theme_entries`.
pub const ThemeDecl = struct {
    name: StringId, // decoded STRING_LITERAL content
    name_span: SourceSpan, // for the E1640 ThemeEmpty diagnostic
    entries_start: u32, // index into `arena.theme_entries`
    entries_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `theme_entry` (`IDENT ":" expression`): a key bound to a value
/// expression, rendered canonically into the descriptor. M0.8 does not
/// resolve the value (no §16 code requires it — the typed-token shape with
/// types/defaults is the rejected validation-ecs shape; E1642/E1643 are
/// RESERVED, E5 ruling 1).
pub const ThemeEntry = struct {
    key: StringId,
    value: NodeId,
    span: SourceSpan,
};

/// Side-slab entry for a `motion` declaration (M0.8 E5 Level B presentation,
/// `etch-grammar.md` §10.3: `motion_decl = "motion" TYPE_IDENT "{"
/// [motion_states] motion_transitions "}"`). The grammar shape WINS (E5
/// ruling 2): the `states { … }` block is OPTIONAL (E1660 RESERVED — the
/// grammar makes it optional, so the relaxed ≥1 check would reject a
/// grammar-valid stateless motion), there is NO `initial` clause (E1667/E1668
/// RESERVED), and transitions are `source -> target : animator`. States and
/// transitions live in `(start, len)` runs of `arena.motion_states` /
/// `arena.motion_transitions` (fed only from motion context — motions do not
/// nest — so the runs stay contiguous).
pub const MotionDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan, // for the diagnostics
    states_start: u32, // index into `arena.motion_states`
    states_len: u32,
    transitions_start: u32, // index into `arena.motion_transitions`
    transitions_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `motion_state` (`IDENT ":" struct_literal_body`): a named set of
/// animatable property fields. Fields live in a contiguous run of
/// `arena.struct_lit_fields` (the data-entry body parser, reused). Field
/// values are STRUCTURAL — rendered canonically, never resolved/typed
/// (E1662 StateFieldTypeInvalid / E1663 StateFieldInconsistent RESERVED —
/// field typing + cross-state interpolation consistency are a Kinesis
/// Phase-1 semantic, not a declarative M0.8 validation; E5 ruling 2).
pub const MotionState = struct {
    name: StringId,
    fields_start: u32, // index into `arena.struct_lit_fields`
    fields_len: u32,
    span: SourceSpan,
};

/// One `motion_transition` (`(IDENT|"*") "->" (IDENT|"*") ":" motion_animator`,
/// §10.3). `source_wildcard` / `target_wildcard` mark the `*` form (the name
/// fields are then unused). `animator` indexes `arena.motion_animators` (the
/// top of a possibly recursive `stagger` chain).
pub const MotionTransition = struct {
    source: StringId, // valid iff !source_wildcard
    source_wildcard: bool, // "*"
    target: StringId, // valid iff !target_wildcard
    target_wildcard: bool, // "*"
    animator: u32, // index into `arena.motion_animators`
    span: SourceSpan,
};

/// Animator head kind (`etch-grammar.md` §10.3 `motion_animator`).
pub const MotionAnimatorKind = enum { animate, keyframes, stagger };

/// One `motion_animator` (RECURSIVE via `stagger`), §10.3:
///   `animate(expr [, expr])`                — duration + optional easing
///   `keyframes [ {kf} ] over expr [, expr]` — keyframes + over-duration + opt easing
///   `stagger(expr, motion_animator)`        — delay + inner animator (recursive)
/// Keyframes / easings stay at the descriptor (rendered to flat text) — E6
/// `anim_graph` is NOT prefigured (E5 ruling 3).
pub const MotionAnimator = struct {
    kind: MotionAnimatorKind,
    /// animate: duration ; keyframes: over-duration ; stagger: delay.
    duration: NodeId,
    /// optional easing (animate 2nd arg / keyframes trailing) — `NodeId.none` if absent.
    easing: NodeId,
    /// keyframes only: a `(start, len)` run of `arena.motion_keyframes`.
    keyframes_start: u32,
    keyframes_len: u32,
    /// stagger only: index into `arena.motion_animators` (the inner animator).
    inner: u32,
    span: SourceSpan,
};

/// One `motion_keyframe` (`expression ":" struct_literal_body`, §10.3): a
/// time point bound to a property body. Fields run in `arena.struct_lit_fields`.
pub const MotionKeyframe = struct {
    time: NodeId,
    fields_start: u32, // index into `arena.struct_lit_fields`
    fields_len: u32,
};

/// Side-slab entry for an `input_mapping` declaration (M0.8 E5 Level B STRICT
/// — NO input execution, `etch-grammar.md` §16: `input_mapping STRING_LITERAL
/// "{" {property} {action} {combo} "}"`). The grammar shape WINS (E5 ruling 7):
/// `context` is a PROPERTY (not a named block — E1802/W1801 RESERVED), priority
/// / consume_input are properties. STRING-named → no symbol (the theme
/// precedent). Properties are stored as 0/1 expression NodeIds; actions / combos
/// in `(start, len)` runs of their slabs.
pub const InputMappingDecl = struct {
    name: StringId, // decoded STRING_LITERAL content
    name_span: SourceSpan,
    context: NodeId, // TAG_PATH expr, `NodeId.none` if absent
    priority: NodeId, // expr (validated INT via E1806), `NodeId.none` if absent
    consume_input: NodeId, // BOOL expr (structural), `NodeId.none` if absent
    actions_start: u32, // index into `arena.input_actions`
    actions_len: u32,
    combos_start: u32, // index into `arena.input_combos`
    combos_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `input_action` (`"action" IDENT [":" type] "{" ["output" ":" type]
/// {input_bind} "}"`, §16). `type_name` / `output_name` are the interned type
/// TEXT (the type node's source span — `0` when absent). Binds run in
/// `arena.input_binds`.
pub const InputAction = struct {
    name: StringId,
    type_name: StringId, // `0` if no `: type`
    output_name: StringId, // `0` if no `output: type`
    binds_start: u32, // index into `arena.input_binds`
    binds_len: u32,
    span: SourceSpan,
};

/// One `input_bind` (`"bind" input_source [input_bind_options]`, §16).
/// `input_source = IDENT {"." IDENT}` is interned as its source TEXT
/// (e.g. `gamepad_left_stick.x`). The three options are 0/1 each:
/// `modifiers`/`triggers` are array_literal exprs (validated against the §16
/// catalogues, E1804/E1805), `output_mapping` is a closure (presence-marked in
/// the descriptor — the renderer rejects closures, the data-closure precedent).
pub const InputBind = struct {
    source: StringId, // input_source text
    modifiers: NodeId, // array_literal expr, `NodeId.none` if absent
    triggers: NodeId, // array_literal expr, `NodeId.none` if absent
    output_mapping: NodeId, // closure expr, `NodeId.none` if absent
    span: SourceSpan,
};

/// One `input_combo` (`"combo" IDENT ":" type "{" "sequence" ":" array_literal
/// "window" ":" expression "}"`, §16). The `sequence` elements are STRUCTURAL
/// input tokens — NOT action references (E1807 RESERVED, E5 ruling: the §16
/// shape has no action-ref form; the token catalogue = Input module Phase 1).
pub const InputCombo = struct {
    name: StringId,
    type_name: StringId, // interned type TEXT
    sequence: NodeId, // array_literal expr
    window: NodeId, // expr (validated positive duration via E1808)
    span: SourceSpan,
};

/// Side-slab entry for a `widget` declaration (M0.8 E5 Level B presentation,
/// `etch-grammar.md` §10.1: `widget_decl = "widget" TYPE_IDENT "(" [param_list]
/// ")" [when_clause] "{" ui_tree "}"`). TYPE_IDENT-named → it registers a
/// symbol (the motion precedent). The recursive `ui_tree` lives in a
/// `(start, len)` run of `arena.ui_elems`. `@screen` / `@worldspace` arrive as
/// `.custom` annotations (NOT in `AnnotationKind`) distinguished by name —
/// their mutual exclusivity is E1621; the placement annotation is OPTIONAL
/// (E1622 RESERVED, E5 ruling 9). `bind Component.field` has NO EBNF production
/// (E1623-E1628 DEFERRED, E5 ruling 10); `@loc` key resolution = extractor
/// tooling (E1627 vacuous, E5 ruling 5).
pub const WidgetDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan, // for the diagnostics
    when_root: u32, // RuleDecl.none_when if absent (for @worldspace, §10.1)
    params_start: u32, // index into `arena.widget_params`
    params_len: u32,
    tree_start: u32, // index into `arena.ui_elems` (the root ui_tree run)
    tree_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `widget` parameter (`IDENT ":" type`, §10.1 `param_list`). The type is
/// interned as its source TEXT (the input_mapping action/combo-type precedent);
/// widget params are structural (rendered into the descriptor, never resolved —
/// Level B).
pub const WidgetParam = struct {
    name: StringId,
    type_name: StringId, // interned type TEXT
};

/// Kind of one `ui_element` (§10.1: `ui_element = ui_widget_call |
/// ui_control_flow | statement`). `if_` / `for_` are the two control-flow forms
/// with `ui_tree` bodies; `match` (the third §10.1 control-flow form, whose
/// arms are standard `match_arm`s, NOT ui_trees) falls under `statement` since
/// it is an ordinary `match` expression.
pub const UiElemKind = enum { widget_call, if_, for_, statement };

/// One `ui_element`: `index` is interpreted per `kind`. For `.widget_call` /
/// `.if_` / `.for_` it indexes `arena.ui_widget_calls` / `arena.ui_ifs` /
/// `arena.ui_fors`; for `.statement` it is the raw `NodeId` of the statement
/// (`@bitCast`) — statements are already arena nodes, so no side slab is
/// needed (the dialogue `(kind, index)` cell, specialised for the stmt reuse).
pub const UiElem = struct {
    kind: UiElemKind,
    index: u32,
};

/// One `ui_widget_call` (`IDENT "(" [arg_list] ")" [ "{" ui_tree "}" ]`,
/// §10.1). `call` is a `.fn_call` expr node (callee path + positional/named
/// args, the shared call machinery); on-click closures among the args render
/// as the `<closure>` presence marker (the input_mapping `output_mapping`
/// precedent — the renderer rejects closures). The optional children block is a
/// `(start, len)` run of `arena.ui_elems` (`children_len == 0` → leaf call).
pub const UiWidgetCall = struct {
    call: NodeId,
    children_start: u32, // index into `arena.ui_elems`
    children_len: u32,
    span: SourceSpan,
};

/// One `ui_control_flow` `if` (`"if" expression "{" ui_tree "}" [ "else" "{"
/// ui_tree "}" ]`, §10.1). The then/else bodies are `(start, len)` runs of
/// `arena.ui_elems`; `else_len == 0` means no else branch.
pub const UiIf = struct {
    cond: NodeId,
    then_start: u32,
    then_len: u32,
    else_start: u32,
    else_len: u32,
    span: SourceSpan,
};

/// One `ui_control_flow` `for` (`"for" IDENT [ "," IDENT ] "in" expression "{"
/// ui_tree "}"`, §10.1). `index_name == 0` when the second binding is absent.
/// The body is a `(start, len)` run of `arena.ui_elems`.
pub const UiFor = struct {
    var_name: StringId,
    index_name: StringId, // `0` if no second binding
    iterable: NodeId,
    body_start: u32,
    body_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for a `locale` declaration (M0.8 E5 Level B presentation,
/// `etch-grammar.md` §10.4: `locale_decl = "locale" IDENT "{" {locale_entry}
/// "}"`, `locale_entry = STRING_LITERAL "=" STRING_LITERAL`). IDENT-named → it
/// registers a symbol. The `name` is the locale code (E1821 validates its
/// ISO-639 FORM, not an embedded table — E5 ruling 4). Fingerprint generation
/// is the `weld-extract-locale` tool's job (E5 ruling 5: deferred); ICU plurals
/// / interpolation are Phase 3 (E1823-E1825 deferred, E5 ruling 6). Entries
/// live in a `(start, len)` run of `arena.locale_entries`.
pub const LocaleDecl = struct {
    name: StringId, // IDENT (the locale code)
    name_span: SourceSpan, // for the E1820/E1821 diagnostics
    entries_start: u32, // index into `arena.locale_entries`
    entries_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `locale_entry` (`STRING_LITERAL "=" STRING_LITERAL`): a translation key
/// bound to its translated text. Both sides are decoded string-literal content
/// (the key is a fingerprint hash or a custom id; the value is the translation).
pub const LocaleEntry = struct {
    key: StringId,
    value: StringId,
    span: SourceSpan,
};

/// Side-slab entry for an `effect` declaration (M0.8 E6 Level B VFX,
/// `etch-grammar.md` §9.2: `effect_decl = "effect" TYPE_IDENT "{"
/// [params_block] {emitter_decl} {effect_event_handler} "}"`). VFX-only since
/// v0.6 (gameplay buffs moved to `data : EffectDef`). The optional
/// `params { annotated_field }` block lives in a `(start, len)` run of the
/// shared `arena.fields` (the component/resource field slab, reused via
/// `parseField`); emitters and event handlers live in their own runs.
pub const EffectDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan,
    params_start: u32, // index into `arena.fields`
    params_len: u32,
    emitters_start: u32, // index into `arena.effect_emitters`
    emitters_len: u32,
    handlers_start: u32, // index into `arena.effect_event_handlers`
    handlers_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `emitter_decl` (`"emitter" IDENT "{" {emitter_property} "}"`, §9.2).
/// `emitter_property = IDENT ":" expression` — bare name:expr pairs, STRICT
/// no-annotation (the grammar production has no annotation slot; the ability
/// ruling-15 precedent — the example's `@unit(.seconds) lifetime` is omitted,
/// KB-patch part2 §19 at close). Properties live in a `(start, len)` run of
/// `arena.struct_lit_fields` (name + value-expr, exactly `StructLitField`).
pub const EffectEmitter = struct {
    name: StringId, // IDENT
    props_start: u32, // index into `arena.struct_lit_fields`
    props_len: u32,
    span: SourceSpan,
};

/// One `effect_event_handler` (`"on" IDENT "." IDENT block`, §9.2): reacts to
/// a particle event (`on Debris.collision { … }`). `emitter` is the referenced
/// emitter name (E1604 EmitterRefNotFound checks it resolves within the
/// effect), `event` is the bare event ident (E1605 EmitterEventUnknown is
/// DEFERRED — the Ember event catalogue is not attached). The body is a
/// statement run in `arena.extra`, rendered to canonical text (never executed).
pub const EffectEventHandler = struct {
    emitter: StringId, // IDENT
    event: StringId, // IDENT
    body_start: u32, // statement run in `arena.extra`
    body_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for an `audio_graph` declaration (M0.8 E6 Level B audio,
/// `etch-grammar.md` §12.2: `audio_graph_decl = "audio_graph" TYPE_IDENT "{"
/// [params_block] {statement} audio_output "}"`; `audio_output = "output" "("
/// expression ")"`). The optional params block is a `(start, len)` run of the
/// shared `arena.fields`; the DSP node-building statements are a run of
/// `arena.extra` (rendered to canonical text, never executed); `output` is the
/// mandatory sink expression (its absence is a parse error — E1700/E1701 stay
/// RESERVED-with-variant, the structure makes "no output" / "multiple outputs"
/// impossible).
pub const AudioGraphDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan,
    params_start: u32, // index into `arena.fields`
    params_len: u32,
    body_start: u32, // statement run in `arena.extra`
    body_len: u32,
    output: NodeId, // the `output(expr)` sink expression
    annotations_extra: u32,
    annotations_len: u32,
};

/// Side-slab entry for an `audio_score` declaration (M0.8 E6 Level B audio,
/// `etch-grammar.md` §12.1: `audio_score_decl = "audio_score" STRING_LITERAL
/// "{" {audio_score_element} "}"`). STRING-named (the `theme`/`input_mapping`
/// precedent — referenced by string, NOT a symbol). `score_property`s
/// (`tempo`/`IDENT ":" expression`, STRICT no annotation — the ability
/// ruling-15 precedent) are a `(start, len)` run of `arena.struct_lit_fields`;
/// sections and stems live in their own runs.
pub const AudioScoreDecl = struct {
    name: StringId, // STRING_LITERAL content
    name_span: SourceSpan,
    props_start: u32, // score_property run in `arena.struct_lit_fields`
    props_len: u32,
    sections_start: u32, // index into `arena.audio_score_sections`
    sections_len: u32,
    stems_start: u32, // index into `arena.audio_score_stems`
    stems_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `score_section` (`"section" IDENT "{" {score_section_prop} "}"`, §12.1).
/// The plain `key ":" expression` props (clips / loop / intro / one_shot /
/// transition_points) are a `struct_lit_fields` run; `can_transition_to` is
/// parsed specially into a `(start, len)` run of `arena.audio_score_targets`
/// (section-name IDENTs — E1726 checks they resolve); `on_finish "->" IDENT`
/// is one more such target (`on_finish` valid iff `has_on_finish`). E1725
/// SectionDurationInvalid stays RESERVED (the grammar §12.1 shape has no
/// `duration` prop — the validation-ecs §20 `duration` is the earlier shape).
pub const AudioScoreSection = struct {
    name: StringId, // IDENT (section name)
    props_start: u32, // plain props run in `arena.struct_lit_fields`
    props_len: u32,
    can_transition_start: u32, // can_transition_to targets in `arena.audio_score_targets`
    can_transition_len: u32,
    on_finish: StringId, // `on_finish "->" IDENT` target (valid iff has_on_finish)
    has_on_finish: bool,
    span: SourceSpan,
};

/// One `score_stem` (`IDENT ":" struct_literal_body`, §12.1): a stem name bound
/// to a property body (`{ clip: "...", always_active: true }`). The body fields
/// are a `struct_lit_fields` run. E1724 StemActiveUnknown stays RESERVED (the
/// grammar §12.1 shape has no `stems_active` — sections reference via
/// `can_transition_to`, not a stem-activation list).
pub const AudioScoreStem = struct {
    name: StringId, // IDENT (stem name)
    body_start: u32, // struct_literal_body fields run in `arena.struct_lit_fields`
    body_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for a `sequence` declaration (M0.8 E6 Level B cinematic,
/// `etch-grammar.md` §13: `sequence_decl = "sequence" TYPE_IDENT "{"
/// {sequence_property} {sequence_track} "}"`). TYPE_IDENT-named (grammar wins —
/// both refs said STRING_LITERAL). `sequence_property`s (`IDENT ":" expression`,
/// e.g. `duration: 15.0` / `fps: 30.0`) are a BUFFERED `struct_lit_fields` run
/// (tracks also write that slab); `on_start` / `on_finish` are emit statements
/// (the §13 patched form, COMPLETE — both emit-only).
pub const SequenceDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan,
    props_start: u32, // sequence_property run in `arena.struct_lit_fields`
    props_len: u32,
    on_start: NodeId, // emit stmt (`NodeId.none` if absent)
    on_finish: NodeId, // emit stmt (`NodeId.none` if absent)
    tracks_start: u32, // index into `arena.sequence_tracks`
    tracks_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// One `sequence_track` (`"track" IDENT ["on" STRING_LITERAL] ":" TYPE_IDENT "{"
/// {sequence_keyframe} "}"`, §13). `track_type` ∈ the §21.2 catalogue (E1742);
/// the optional `on STRING` is the binding target (E1743 TrackTargetNotFound is
/// DEFERRED — scene/binding resolution is E7).
pub const SequenceTrack = struct {
    name: StringId, // IDENT (track name)
    target: StringId, // `on STRING` binding (valid iff has_target)
    has_target: bool,
    track_type: StringId, // TYPE_IDENT
    keyframes_start: u32, // index into `arena.sequence_keyframes`
    keyframes_len: u32,
    span: SourceSpan,
};

/// Kind of a `sequence_keyframe` value (`struct_literal_body | sequence_action`,
/// §13). `sequence_action = IDENT "(" [arg_list] ")" | emit_stmt | "play"
/// STRING_LITERAL`.
pub const SequenceKeyframeKind = enum { struct_body, call, emit, play };

/// One `sequence_keyframe` (`DURATION_LIT ":" (...)`, §13). `time` is the
/// DURATION_LIT expr (E1744 range / E1745 ordering use its parsed seconds).
pub const SequenceKeyframe = struct {
    time: NodeId, // DURATION_LIT expr
    kind: SequenceKeyframeKind,
    fields_start: u32, // `.struct_body`: struct_lit_fields run
    fields_len: u32,
    value: NodeId, // `.call`: fn_call expr ; `.emit`: emit stmt ; else `NodeId.none`
    play_path: StringId, // `.play`: the STRING_LITERAL content ; 0 otherwise
    span: SourceSpan,
};

/// Side-slab entry for an `anim_graph` declaration (M0.8 E6 Level B animation,
/// `etch-grammar.md` §11: `anim_graph_decl = "anim_graph" TYPE_IDENT "{"
/// [params_block] {anim_state} {anim_layer} "}"`). The grammar shape WINS (the
/// ratified 2-against-1 calls): transitions are STATE-NESTED (no `from`/
/// `duration`/`*` — `from` = the enclosing state, `initial` = first declared
/// state), layers carry only an `additive` flag (no `mask`/blend enum).
pub const AnimGraphDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan,
    params_start: u32, // index into `arena.fields`
    params_len: u32,
    states_start: u32, // index into `arena.anim_states`
    states_len: u32,
    layers_start: u32, // index into `arena.anim_layers`
    layers_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// The single animation-source body of an `anim_state` (E1682 requires exactly
/// one; E1683 rejects >1). `transition` / `on_finish` props are edges, not bodies.
pub const AnimBodyKind = enum { none, clip, blend_space_2d, motion_matching, chooser, warping, distance_matching };

/// One `anim_state` (`"state" IDENT "{" {anim_state_prop} "}"`, §11). Exactly one
/// body source + edges. `.clip` uses `clip_path` (+ `clip_loop`); the sub-block
/// bodies (`blend_space_2d`/`motion_matching`/`warping`/`distance_matching`) use a
/// `key: value` run in `arena.struct_lit_fields`; `.chooser` uses an
/// `arena.anim_chooser_rules` run.
pub const AnimState = struct {
    name: StringId, // IDENT
    body_kind: AnimBodyKind, // the LAST body source seen (the only one if body_count == 1)
    body_count: u32, // number of body-source props (E1682 == 0, E1683 > 1)
    clip_path: StringId, // `.clip`: the STRING_LITERAL content ; 0 otherwise
    clip_loop: bool, // `.clip`: trailing "loop"
    body_props_start: u32, // sub-block `key: value` run in `arena.struct_lit_fields`
    body_props_len: u32,
    chooser_start: u32, // `.chooser`: index into `arena.anim_chooser_rules`
    chooser_len: u32,
    transitions_start: u32, // index into `arena.anim_transitions`
    transitions_len: u32,
    on_finish: StringId, // `on_finish "->" IDENT` target ; valid iff has_on_finish
    has_on_finish: bool,
    span: SourceSpan,
};

/// One state-nested `transition "->" IDENT [when_clause]` (§11). `target` is the
/// destination state (E1689); `when_root` is the §6 when-clause (E1690 checks it
/// is bool over the params), `RuleDecl.none_when` if absent.
pub const AnimTransition = struct {
    target: StringId, // IDENT
    when_root: u32, // when_clause root (RuleDecl.none_when if absent)
    span: SourceSpan,
};

/// One `chooser_rule` (`"{" ["when" expression ","] "clip" ":" STRING "}"` or
/// `"{" "fallback" "," "clip" ":" STRING "}"`, §11). The `when` is a plain
/// EXPRESSION (not a when_clause); rendered structurally (E1686 clip-asset
/// validation is DEFERRED).
pub const AnimChooserRule = struct {
    when_expr: NodeId, // optional `when expression` (NodeId.none if fallback/absent)
    is_fallback: bool,
    clip: StringId, // the STRING_LITERAL content
};

/// One `anim_layer` (`"layer" IDENT ["additive"] "{" {anim_layer_prop} "}"`, §11).
/// The ratified shape: only the `additive` flag (no `mask`/blend enum — E1693/
/// E1694 RESERVED/DEFERRED).
pub const AnimLayer = struct {
    name: StringId, // IDENT
    additive: bool,
    props_start: u32, // index into `arena.anim_layer_props`
    props_len: u32,
    span: SourceSpan,
};

/// One `anim_layer_prop` (`"on" expression ":" "play" STRING ["on_bones" "(" …
/// ")"]`, §11). `on_bones` masks are a `(start, len)` run of `arena.anim_layer_bones`.
pub const AnimLayerProp = struct {
    condition: NodeId, // `"on" expression`
    clip: StringId, // `"play" STRING` content
    bones_start: u32, // index into `arena.anim_layer_bones`
    bones_len: u32,
};

/// One shader stage (`vertex_fn` / `fragment_fn`, `etch-grammar.md` §9.1:
/// `"vertex" "(" param_list ")" "->" type block`). Params live in a
/// `(start, len)` run of the shared `arena.rule_params` (the `name: type`
/// param shape); the body is a statement run in `arena.extra`, validated in
/// SHADER MODE (resolver §15) and rendered to canonical text (never executed —
/// SPIR-V emission is Phase 2+).
pub const ShaderStage = struct {
    params_start: u32, // index into `arena.rule_params`
    params_len: u32,
    return_type: NodeId, // the `-> type`
    body_start: u32, // statement run in `arena.extra`
    body_len: u32,
};

/// Side-slab entry for a `shader` declaration (M0.8 E6 Level B render,
/// `etch-grammar.md` §9.1: `shader_decl = "shader" TYPE_IDENT "{" [params_block]
/// [vertex_fn] fragment_fn "}"`). The ruling: NO compute stage (dropped); the
/// `fragment` stage is parser-mandatory, `vertex` optional. `params { … }`
/// (uniforms) live in `arena.fields` and are NOT shader-mode.
pub const ShaderDecl = struct {
    name: StringId, // TYPE_IDENT
    name_span: SourceSpan,
    params_start: u32, // index into `arena.fields`
    params_len: u32,
    has_vertex: bool,
    vertex: ShaderStage, // valid iff has_vertex
    fragment: ShaderStage,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Kind of one routine trigger alternative (M0.8 E4, `etch-grammar.md`
/// §8.2 `trigger_expr`): `at TIME_LITERAL` / `after IDENT` /
/// `on_event TYPE_IDENT`. `or`-chains are stored as a flat run of
/// alternatives in `arena.routine_triggers`.
pub const RoutineTriggerKind = enum { at_time, after_segment, on_event };

/// One routine trigger alternative. `value` holds, per kind: the interned
/// `DD:DD` time lexeme / the referenced segment name / the event type name.
pub const RoutineTrigger = struct {
    kind: RoutineTriggerKind,
    value: StringId,
    span: SourceSpan,
};

/// One `segment IDENT { trigger: … actions: … until: … }` of a routine
/// (M0.8 E4, §8.2 — the three clauses are mandatory, in that order).
/// Triggers and untils are `(start, len)` runs of `arena.routine_triggers`;
/// actions are a run of expression `NodeId` raw values in `arena.extra`
/// (each a call per `routine_action = IDENT "(" [arg_list] ")"`).
pub const RoutineSegment = struct {
    name: StringId,
    triggers_start: u32,
    triggers_len: u32,
    actions_start: u32, // index into `arena.extra`
    actions_len: u32,
    untils_start: u32,
    untils_len: u32,
    span: SourceSpan,
};

/// One `on_xxx -> target` routine interrupt (M0.8 E4, §8.2). `event_name`
/// is the full `on_…` identifier; `target` is a behavior name or the
/// `pause_segment` builtin (`is_pause`).
pub const RoutineInterrupt = struct {
    event_name: StringId,
    target: StringId,
    is_pause: bool,
    span: SourceSpan,
};

/// One quest property (`IDENT ":" expression` / `requires ":" expression`,
/// M0.8 E4, `etch-grammar.md` §8.3).
pub const QuestProperty = struct {
    name: StringId,
    is_requires: bool,
    value: NodeId, // expr
    span: SourceSpan,
};

/// Objective modifier set (§8.3 PATCHED, item-7 ruling: `"objective" ,
/// [ objective_modifier ] , [ IDENT ] , ":" , expression` — greedy
/// modifier-first).
pub const QuestObjectiveModifier = enum { none, main, optional };

/// One `objective [modifier] [label]: expression` (M0.8 E4, §8.3).
pub const QuestObjective = struct {
    modifier: QuestObjectiveModifier,
    label: StringId, // 0 = unlabeled
    value: NodeId, // expr
    span: SourceSpan,
};

/// Quest event-handler kinds (§8.3 PATCHED, item-8 ruling: the colon is
/// mandatory on every handler — `on_complete` harmonized on the
/// `on_start ":" ( emit_stmt | block )` form).
pub const QuestHandlerKind = enum { on_start, on_complete, on_fail };

/// The on_fail action set (§8.3 — terminal, parse-enforced; E1544 has no
/// post-parse case).
pub const QuestFailAction = enum { restart_stage, fail_quest, switch_branch };

/// One quest event handler (M0.8 E4, §8.3). `on_start`/`on_complete`:
/// `payload` is an emit statement (`payload_is_stmt`) or a block
/// expression. `on_fail`: `fail_cond -> fail_action [(fail_branch)]`.
pub const QuestHandler = struct {
    kind: QuestHandlerKind,
    payload: NodeId, // emit stmt / block expr; none for on_fail
    payload_is_stmt: bool,
    fail_cond: NodeId, // on_fail condition expr; none otherwise
    fail_action: QuestFailAction,
    fail_branch: StringId, // switch_branch target; 0 otherwise
    span: SourceSpan,
};

/// Kind of one stage element (§8.3 `quest_stage_element`). Elements keep
/// their DECLARATION ORDER across kinds via the `quest_elems` run.
pub const QuestElemKind = enum { objective, handler, branch, statement };

/// One stage element: `index` points into the kind's slab (`quest_objectives`
/// / `quest_handlers` / `quest_branches`) or is the raw statement NodeId.
pub const QuestElem = struct {
    kind: QuestElemKind,
    index: u32,
};

/// One `[async] stage IDENT { elements }` (M0.8 E4, §8.3). Elements are a
/// `(start, len)` run of `arena.quest_elems` (buffered — nested branch
/// stages interleave the pools otherwise).
pub const QuestStage = struct {
    name: StringId,
    is_async: bool,
    elems_start: u32,
    elems_len: u32,
    span: SourceSpan,
};

/// One `branch IDENT [when] { stages }` (M0.8 E4, §8.3). Stages are a run
/// of `arena.extra` indices into `arena.quest_stages` (buffered).
pub const QuestBranch = struct {
    name: StringId,
    when_root: u32, // RuleDecl.none_when if absent
    stages_start: u32, // index into `arena.extra`
    stages_len: u32,
    span: SourceSpan,
};

/// Side-slab entry for a `quest` declaration (M0.8 E4 Level B, §8.3).
/// Properties are a direct `quest_properties` run (parsed before any
/// stage, no nesting); top-level stages are an `arena.extra` index run.
pub const QuestDecl = struct {
    name: StringId,
    properties_start: u32,
    properties_len: u32,
    stages_start: u32, // index into `arena.extra`
    stages_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

/// Kind of one behavior-tree node (M0.8 E4, `etch-grammar.md` §8.1
/// PATCHED: `bt_leaf = bt_condition | bt_action` — item-1 ruling).
pub const BTNodeKind = enum { selector, sequence, condition, action };

/// One node of a behavior tree (M0.8 E4, §8.1). Composites carry an
/// optional when clause (`when_root`, `RuleDecl.none_when` if absent) and a
/// children run (`arena.extra`, indices into `arena.bt_nodes`). Leaves
/// carry a payload: `condition: expression`; `action: ( let_stmt |
/// expression | emit_stmt )` (item-2 ruling — `payload_is_stmt` marks the
/// statement forms). The cross-action binding scope of an action `let` is
/// pinned by Cortex Phase 1+ (M0.8 validates the binding structurally).
pub const BTNode = struct {
    kind: BTNodeKind,
    when_root: u32, // RuleDecl.none_when if absent
    children_start: u32, // index into `arena.extra` (u32 bt_nodes indices)
    children_len: u32,
    payload: NodeId, // leaf condition/action; NodeId.none for composites
    payload_is_stmt: bool,
    span: SourceSpan,
};

/// Side-slab entry for a `behavior` declaration (M0.8 E4 Level B, §8.1).
/// `root` indexes `arena.bt_nodes`; the parser accepts a leaf root (item-1
/// ruling) — `E1500` enforces the composite root at validation.
pub const BehaviorDecl = struct {
    name: StringId,
    root: u32, // index into `arena.bt_nodes`
    annotations_extra: u32,
    annotations_len: u32,
};

/// Side-slab entry for a `routine` declaration (M0.8 E4 Level B, §8.2).
/// Segments and interrupts live in `(start, len)` runs of
/// `arena.routine_segments` / `arena.routine_interrupts`.
pub const RoutineDecl = struct {
    name: StringId,
    segments_start: u32,
    segments_len: u32,
    interrupts_start: u32,
    interrupts_len: u32,
    annotations_extra: u32,
    annotations_len: u32,
};

const NamedTypeNode = struct {
    name: StringId,
};

/// `alias . Member` qualified type path (M1.0.16, `etch-grammar.md` §2.1
/// `qualified_path = IDENT , "." , TYPE_IDENT`). `alias` is the whole-module
/// import alias (a lowercase IDENT — explicit `as m` or the implicit
/// last-segment name); `member` is the referenced TYPE_IDENT. The `.path`
/// type-node kind reaches this slab through `data`. Type position only — the
/// expression-position qualified forms are out of scope (whole-import parity).
pub const PathTypeNode = struct {
    alias: StringId,
    member: StringId,
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

/// The five structural-observer lifecycle hooks (M1.0.2 E2). An observer rule
/// is routed by one of the `@on_added` / `@on_removed` / `@on_replaced` /
/// `@on_spawned` / `@on_despawned` annotations — NOT a keyword (the stale
/// `observer` keyword of `engine-ecs-internals.md` §8 is not implemented; the
/// brief routes via annotations, reusing the `@on_event` path). `on_added` /
/// `on_removed` / `on_replaced` carry a target component type; the spawn /
/// despawn hooks carry none.
pub const ObserverKind = enum { on_added, on_removed, on_replaced, on_spawned, on_despawned };

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
    on_event,
    shader_fn, // M0.8 E6 — @shader_fn: a function callable from shader bodies (resolver §15.4)
    // M1.0.2 E2 — structural-observer lifecycle annotations (annotation-routed
    // observer rules, mirroring `@on_event`; see `ObserverKind`).
    on_added,
    on_removed,
    on_replaced,
    on_spawned,
    on_despawned,
    // M1.0.14 E2 — @entity_target: designates the field matched by
    // `await entity_event(e, T)` (§18.10). Field-level, event-only,
    // Entity-typed, at most one per event (validated in the type-checker).
    entity_target,
    // M1.0.15 — `test`-only annotations (§17): `@tag(.unit|.integration|.slow|
    // .perf)`, `@skip(reason: "...")`, `@only`. Applicability is `.test_` only
    // (annotationAppliesTo); args are validated in the test-decl check.
    tag,
    skip,
    only,

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
        if (std.mem.eql(u8, name, "on_event")) return .on_event;
        if (std.mem.eql(u8, name, "shader_fn")) return .shader_fn;
        if (std.mem.eql(u8, name, "on_added")) return .on_added;
        if (std.mem.eql(u8, name, "on_removed")) return .on_removed;
        if (std.mem.eql(u8, name, "on_replaced")) return .on_replaced;
        if (std.mem.eql(u8, name, "on_spawned")) return .on_spawned;
        if (std.mem.eql(u8, name, "on_despawned")) return .on_despawned;
        if (std.mem.eql(u8, name, "entity_target")) return .entity_target;
        if (std.mem.eql(u8, name, "tag")) return .tag;
        if (std.mem.eql(u8, name, "skip")) return .skip;
        if (std.mem.eql(u8, name, "only")) return .only;
        return .custom;
    }

    /// The `ObserverKind` this annotation routes to, or null if it is not a
    /// structural-observer lifecycle annotation (M1.0.2 E2).
    pub fn toObserverKind(self: AnnotationKind) ?ObserverKind {
        return switch (self) {
            .on_added => .on_added,
            .on_removed => .on_removed,
            .on_replaced => .on_replaced,
            .on_spawned => .on_spawned,
            .on_despawned => .on_despawned,
            else => null,
        };
    }
};

// ─────────────────────────────── MultiArrayList entries ─────────────────

const Item = struct {
    kind: ItemKind,
    data: u32,
    span: SourceSpan,
    /// M1.0.8 — `.private` when a `private` prefix precedes this top-level
    /// declaration_body; `.public` otherwise (the dominant case, so the
    /// default keeps every existing `addItem` call literal valid).
    visibility: Visibility = .public,
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
    /// Which grammatical subset produced this arena (M1.1.15.2 G1). Stamped by
    /// `parser.parseWithMode`; every other arena constructor leaves the
    /// `.standard` default, which is the right answer for a hook fragment or a
    /// synthesised arena — neither is a declaration file.
    ///
    /// The type-checker reads it to decide `E1901`, which is a question about
    /// the file's IDENTITY and cannot be answered from the node columns alone.
    mode: ParseMode = .standard,

    items: std.MultiArrayList(Item) = .empty,
    stmts: std.MultiArrayList(Stmt) = .empty,
    exprs: std.MultiArrayList(Expr) = .empty,
    type_nodes: std.MultiArrayList(TypeNode) = .empty,

    extra: std.ArrayListUnmanaged(u32) = .empty,
    strings: StringPool = .{},

    // Side slabs.
    fields: std.ArrayListUnmanaged(Field) = .empty,
    // M1.0.7 cross-file import. `import_decls` holds one entry per `import`
    // directive; `import_path_segs` is the flat module-path segment pool (a
    // `StringId` run, the `tag_path_segs` precedent); `import_items` holds the
    // selective `{ X, Y }` items.
    import_decls: std.ArrayListUnmanaged(ImportDecl) = .empty,
    import_path_segs: std.ArrayListUnmanaged(StringId) = .empty,
    import_items: std.ArrayListUnmanaged(ImportItem) = .empty,
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
    tag_query_exprs: std.ArrayListUnmanaged(TagQueryExpr) = .empty,
    loc_exprs: std.ArrayListUnmanaged(LocExpr) = .empty,
    dialogue_decls: std.ArrayListUnmanaged(DialogueDecl) = .empty,
    dialogue_elems: std.ArrayListUnmanaged(DialogueElem) = .empty,
    dialogue_speakers: std.ArrayListUnmanaged(DialogueSpeaker) = .empty,
    dialogue_lines: std.ArrayListUnmanaged(DialogueLine) = .empty,
    dialogue_choices: std.ArrayListUnmanaged(DialogueChoice) = .empty,
    dialogue_options: std.ArrayListUnmanaged(DialogueOption) = .empty,
    dialogue_emits: std.ArrayListUnmanaged(DialogueEmit) = .empty,
    dialogue_gotos: std.ArrayListUnmanaged(DialogueGoto) = .empty,
    dialogue_branches: std.ArrayListUnmanaged(DialogueBranch) = .empty,
    ability_decls: std.ArrayListUnmanaged(AbilityDecl) = .empty,
    ability_props: std.ArrayListUnmanaged(AbilityProp) = .empty,
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
    const_decls: std.ArrayListUnmanaged(ConstDecl) = .empty,
    test_decls: std.ArrayListUnmanaged(TestDecl) = .empty,
    /// `.d.etch` service declarations (M1.1.15.2 G1). Their method signatures
    /// live in `impl_methods`, shared with traits and impls.
    service_decls: std.ArrayListUnmanaged(ServiceDecl) = .empty,
    data_decls: std.ArrayListUnmanaged(DataDecl) = .empty,
    data_entries: std.ArrayListUnmanaged(DataEntry) = .empty,
    theme_decls: std.ArrayListUnmanaged(ThemeDecl) = .empty,
    theme_entries: std.ArrayListUnmanaged(ThemeEntry) = .empty,
    motion_decls: std.ArrayListUnmanaged(MotionDecl) = .empty,
    motion_states: std.ArrayListUnmanaged(MotionState) = .empty,
    motion_transitions: std.ArrayListUnmanaged(MotionTransition) = .empty,
    motion_animators: std.ArrayListUnmanaged(MotionAnimator) = .empty,
    motion_keyframes: std.ArrayListUnmanaged(MotionKeyframe) = .empty,
    input_mapping_decls: std.ArrayListUnmanaged(InputMappingDecl) = .empty,
    input_actions: std.ArrayListUnmanaged(InputAction) = .empty,
    input_binds: std.ArrayListUnmanaged(InputBind) = .empty,
    input_combos: std.ArrayListUnmanaged(InputCombo) = .empty,
    widget_decls: std.ArrayListUnmanaged(WidgetDecl) = .empty,
    widget_params: std.ArrayListUnmanaged(WidgetParam) = .empty,
    ui_elems: std.ArrayListUnmanaged(UiElem) = .empty,
    ui_widget_calls: std.ArrayListUnmanaged(UiWidgetCall) = .empty,
    ui_ifs: std.ArrayListUnmanaged(UiIf) = .empty,
    ui_fors: std.ArrayListUnmanaged(UiFor) = .empty,
    locale_decls: std.ArrayListUnmanaged(LocaleDecl) = .empty,
    locale_entries: std.ArrayListUnmanaged(LocaleEntry) = .empty,
    effect_decls: std.ArrayListUnmanaged(EffectDecl) = .empty,
    effect_emitters: std.ArrayListUnmanaged(EffectEmitter) = .empty,
    effect_event_handlers: std.ArrayListUnmanaged(EffectEventHandler) = .empty,
    audio_graph_decls: std.ArrayListUnmanaged(AudioGraphDecl) = .empty,
    audio_score_decls: std.ArrayListUnmanaged(AudioScoreDecl) = .empty,
    audio_score_sections: std.ArrayListUnmanaged(AudioScoreSection) = .empty,
    audio_score_stems: std.ArrayListUnmanaged(AudioScoreStem) = .empty,
    audio_score_targets: std.ArrayListUnmanaged(StringId) = .empty,
    sequence_decls: std.ArrayListUnmanaged(SequenceDecl) = .empty,
    sequence_tracks: std.ArrayListUnmanaged(SequenceTrack) = .empty,
    sequence_keyframes: std.ArrayListUnmanaged(SequenceKeyframe) = .empty,
    anim_graph_decls: std.ArrayListUnmanaged(AnimGraphDecl) = .empty,
    anim_states: std.ArrayListUnmanaged(AnimState) = .empty,
    anim_transitions: std.ArrayListUnmanaged(AnimTransition) = .empty,
    anim_chooser_rules: std.ArrayListUnmanaged(AnimChooserRule) = .empty,
    anim_layers: std.ArrayListUnmanaged(AnimLayer) = .empty,
    anim_layer_props: std.ArrayListUnmanaged(AnimLayerProp) = .empty,
    anim_layer_bones: std.ArrayListUnmanaged(StringId) = .empty,
    shader_decls: std.ArrayListUnmanaged(ShaderDecl) = .empty,
    // M0.8 E7 Level C — scene / prefab side-tables. `scene_entities` is shared
    // by scene and prefab (the `entity_decl` body is identical in both).
    scene_decls: std.ArrayListUnmanaged(SceneDecl) = .empty,
    scene_children: std.ArrayListUnmanaged(SceneChild) = .empty,
    scene_entities: std.ArrayListUnmanaged(SceneEntity) = .empty,
    scene_instances: std.ArrayListUnmanaged(SceneInstance) = .empty,
    scene_instance_members: std.ArrayListUnmanaged(InstanceMember) = .empty,
    component_instances: std.ArrayListUnmanaged(ComponentInstance) = .empty,
    field_overrides: std.ArrayListUnmanaged(FieldOverride) = .empty,
    /// Active-extension name references (M1.0.6 E5) — the `extensions:` clause of
    /// an `entity`/`instance`, by NAME (STRING_LITERAL `StringId`s, like `parent`).
    /// `SceneEntity`/`SceneInstance` reference a `(start, len)` run here.
    scene_extensions: std.ArrayListUnmanaged(StringId) = .empty,
    prefab_decls: std.ArrayListUnmanaged(PrefabDecl) = .empty,
    prefab_requires: std.ArrayListUnmanaged(StringId) = .empty,
    quest_decls: std.ArrayListUnmanaged(QuestDecl) = .empty,
    quest_properties: std.ArrayListUnmanaged(QuestProperty) = .empty,
    quest_stages: std.ArrayListUnmanaged(QuestStage) = .empty,
    quest_elems: std.ArrayListUnmanaged(QuestElem) = .empty,
    quest_objectives: std.ArrayListUnmanaged(QuestObjective) = .empty,
    quest_handlers: std.ArrayListUnmanaged(QuestHandler) = .empty,
    quest_branches: std.ArrayListUnmanaged(QuestBranch) = .empty,
    behavior_decls: std.ArrayListUnmanaged(BehaviorDecl) = .empty,
    bt_nodes: std.ArrayListUnmanaged(BTNode) = .empty,
    routine_decls: std.ArrayListUnmanaged(RoutineDecl) = .empty,
    routine_segments: std.ArrayListUnmanaged(RoutineSegment) = .empty,
    routine_triggers: std.ArrayListUnmanaged(RoutineTrigger) = .empty,
    routine_interrupts: std.ArrayListUnmanaged(RoutineInterrupt) = .empty,
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
    /// `structural_spawn` nodes (M1.0.10). Component-literal arg runs live in
    /// `arena.extra` (struct-lit NodeIds); the prefab form carries an interned
    /// name. See `SpawnStructExpr`.
    spawn_structs: std.ArrayListUnmanaged(SpawnStructExpr) = .empty,
    /// Named-argument labels (M0.8 E4, §3.3): runs parallel to call arg
    /// runs, `0` = positional slot. Referenced by `CallExpr.names_start` /
    /// `MethodCall.names_start` (`no_arg_names` = all-positional call).
    call_arg_names: std.ArrayListUnmanaged(StringId) = .empty,
    loop_exprs: std.ArrayListUnmanaged(LoopExpr) = .empty,
    string_interps: std.ArrayListUnmanaged(StringInterp) = .empty,
    block_exprs: std.ArrayListUnmanaged(BlockExpr) = .empty,
    measure_exprs: std.ArrayListUnmanaged(MeasureExpr) = .empty,
    if_exprs: std.ArrayListUnmanaged(IfExpr) = .empty,
    break_stmts: std.ArrayListUnmanaged(BreakStmt) = .empty,
    throw_stmts: std.ArrayListUnmanaged(ThrowStmt) = .empty,
    try_catch_stmts: std.ArrayListUnmanaged(TryCatchStmt) = .empty,
    emit_stmts: std.ArrayListUnmanaged(EmitStmt) = .empty,
    await_exprs: std.ArrayListUnmanaged(AwaitExpr) = .empty,
    /// Branch runs shared by `race_stmts` / `sync_stmts` (M1.0.12 E2). Each
    /// statement's branches are a contiguous `(start, len)` run — nesting is
    /// safe because a nested construct finishes (and appends its run) before
    /// the enclosing one appends its own (the `match_arms` precedent).
    concurrency_branches: std.ArrayListUnmanaged(ConcurrencyBranch) = .empty,
    race_stmts: std.ArrayListUnmanaged(RaceStmt) = .empty,
    sync_stmts: std.ArrayListUnmanaged(SyncStmt) = .empty,
    branch_stmts: std.ArrayListUnmanaged(BranchStmt) = .empty,
    spawn_stmts: std.ArrayListUnmanaged(SpawnStmt) = .empty,
    /// Timer statement payloads (M1.0.13 E2, §4.3 `timer_stmt`), indexed by
    /// the stmt node's `data`. `quantize_stmt` has NO slab (placeholder).
    timer_stmts: std.ArrayListUnmanaged(TimerStmt) = .empty,
    named_types: std.ArrayListUnmanaged(NamedTypeNode) = .empty,
    path_types: std.ArrayListUnmanaged(PathTypeNode) = .empty,
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

    /// Interned name of the builtin `Error` struct (M0.8 E3-C tranche 2,
    /// `etch-reference-part1.md` §10.2). `0` until `ensureErrorBuiltins`
    /// has injected the synthetic declarations.
    error_type_name: StringId = 0,
    /// Interned name of the builtin `ErrorCode` enum. `0` until injected.
    errorcode_type_name: StringId = 0,
    /// Index of the first synthetic builtin item appended by
    /// `ensureErrorBuiltins`. Items at or past this index back no source
    /// text (zero spans); the codegen's declaration pass skips them and
    /// emits the canonical prelude instead. `maxInt(u32)` = none injected.
    builtin_items_from: u32 = std.math.maxInt(u32),
    /// Index of the first synthetic field appended by `ensureErrorBuiltins`
    /// (the builtin Error's `message`/`code`/`source`). Lets the codegen's
    /// `programUsesError` scan source-declared fields only — the synthetic
    /// ones reference `Error`/`ErrorCode` by construction and would force
    /// the prelude into every program. `maxInt(u32)` = none injected.
    builtin_fields_from: u32 = std.math.maxInt(u32),

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
        self.import_decls.deinit(gpa);
        self.import_path_segs.deinit(gpa);
        self.import_items.deinit(gpa);
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
        self.tag_query_exprs.deinit(gpa);
        self.loc_exprs.deinit(gpa);
        self.dialogue_decls.deinit(gpa);
        self.ability_decls.deinit(gpa);
        self.ability_props.deinit(gpa);
        self.dialogue_elems.deinit(gpa);
        self.dialogue_speakers.deinit(gpa);
        self.dialogue_lines.deinit(gpa);
        self.dialogue_choices.deinit(gpa);
        self.dialogue_options.deinit(gpa);
        self.dialogue_emits.deinit(gpa);
        self.dialogue_gotos.deinit(gpa);
        self.dialogue_branches.deinit(gpa);
        self.rule_decls.deinit(gpa);
        self.fn_decls.deinit(gpa);
        self.struct_decls.deinit(gpa);
        self.impl_decls.deinit(gpa);
        self.enum_decls.deinit(gpa);
        self.enum_variants.deinit(gpa);
        self.trait_decls.deinit(gpa);
        self.impl_methods.deinit(gpa);
        self.type_alias_decls.deinit(gpa);
        self.const_decls.deinit(gpa);
        self.test_decls.deinit(gpa);
        self.service_decls.deinit(gpa);
        self.data_decls.deinit(gpa);
        self.data_entries.deinit(gpa);
        self.quest_decls.deinit(gpa);
        self.quest_properties.deinit(gpa);
        self.quest_stages.deinit(gpa);
        self.quest_elems.deinit(gpa);
        self.quest_objectives.deinit(gpa);
        self.quest_handlers.deinit(gpa);
        self.quest_branches.deinit(gpa);
        self.behavior_decls.deinit(gpa);
        self.bt_nodes.deinit(gpa);
        self.routine_decls.deinit(gpa);
        self.routine_segments.deinit(gpa);
        self.routine_triggers.deinit(gpa);
        self.routine_interrupts.deinit(gpa);
        self.theme_decls.deinit(gpa);
        self.theme_entries.deinit(gpa);
        self.motion_decls.deinit(gpa);
        self.motion_states.deinit(gpa);
        self.motion_transitions.deinit(gpa);
        self.motion_animators.deinit(gpa);
        self.motion_keyframes.deinit(gpa);
        self.input_mapping_decls.deinit(gpa);
        self.input_actions.deinit(gpa);
        self.input_binds.deinit(gpa);
        self.input_combos.deinit(gpa);
        self.widget_decls.deinit(gpa);
        self.widget_params.deinit(gpa);
        self.ui_elems.deinit(gpa);
        self.ui_widget_calls.deinit(gpa);
        self.ui_ifs.deinit(gpa);
        self.ui_fors.deinit(gpa);
        self.locale_decls.deinit(gpa);
        self.locale_entries.deinit(gpa);
        self.effect_decls.deinit(gpa);
        self.effect_emitters.deinit(gpa);
        self.effect_event_handlers.deinit(gpa);
        self.audio_graph_decls.deinit(gpa);
        self.audio_score_decls.deinit(gpa);
        self.audio_score_sections.deinit(gpa);
        self.audio_score_stems.deinit(gpa);
        self.audio_score_targets.deinit(gpa);
        self.sequence_decls.deinit(gpa);
        self.sequence_tracks.deinit(gpa);
        self.sequence_keyframes.deinit(gpa);
        self.anim_graph_decls.deinit(gpa);
        self.anim_states.deinit(gpa);
        self.anim_transitions.deinit(gpa);
        self.anim_chooser_rules.deinit(gpa);
        self.anim_layers.deinit(gpa);
        self.anim_layer_props.deinit(gpa);
        self.anim_layer_bones.deinit(gpa);
        self.shader_decls.deinit(gpa);
        self.scene_decls.deinit(gpa);
        self.scene_children.deinit(gpa);
        self.scene_entities.deinit(gpa);
        self.scene_instances.deinit(gpa);
        self.scene_instance_members.deinit(gpa);
        self.component_instances.deinit(gpa);
        self.field_overrides.deinit(gpa);
        self.scene_extensions.deinit(gpa);
        self.prefab_decls.deinit(gpa);
        self.prefab_requires.deinit(gpa);
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
        self.spawn_structs.deinit(gpa);
        self.call_arg_names.deinit(gpa);
        self.loop_exprs.deinit(gpa);
        self.string_interps.deinit(gpa);
        self.block_exprs.deinit(gpa);
        self.measure_exprs.deinit(gpa);
        self.if_exprs.deinit(gpa);
        self.break_stmts.deinit(gpa);
        self.throw_stmts.deinit(gpa);
        self.try_catch_stmts.deinit(gpa);
        self.emit_stmts.deinit(gpa);
        self.await_exprs.deinit(gpa);
        self.concurrency_branches.deinit(gpa);
        self.race_stmts.deinit(gpa);
        self.sync_stmts.deinit(gpa);
        self.branch_stmts.deinit(gpa);
        self.spawn_stmts.deinit(gpa);
        self.timer_stmts.deinit(gpa);
        self.named_types.deinit(gpa);
        self.path_types.deinit(gpa);
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

    /// Inject the builtin `Error` struct + `ErrorCode` enum (M0.8 E3-C
    /// tranche 2, `etch-reference-part1.md` §10.2) as synthetic declaration
    /// items, so the resolver / interpreter / codegen resolve them through
    /// the ordinary declaration machinery:
    ///
    ///   enum ErrorCode { io_fail, network_timeout, invalid_arg,
    ///                    permission_denied, out_of_memory }
    ///   struct Error { message: string, code: ErrorCode, source: Error? }
    ///
    /// The variant set is pinned to the five listed in part1 §10.2 — the
    /// spec's "extensible" comment is language-evolution headroom, not user
    /// extensibility (v0.6 has no enum-extension syntax). Idempotent; spans
    /// are zero (no source text backs these items). Called by the
    /// type-checker before pass 1, the single composition point every
    /// interp / codegen driver runs through.
    pub fn ensureErrorBuiltins(self: *AstArena, gpa: std.mem.Allocator) !void {
        if (self.error_type_name != 0) return;
        const zero_span: SourceSpan = .{ .byte_start = 0, .byte_end = 0 };
        self.builtin_items_from = @intCast(self.items.len);

        self.errorcode_type_name = try self.strings.intern(gpa, "ErrorCode");
        const variant_names = [_][]const u8{
            "io_fail", "network_timeout", "invalid_arg", "permission_denied", "out_of_memory",
        };
        const variants_start: u32 = @intCast(self.enum_variants.items.len);
        for (variant_names) |vn| {
            try self.enum_variants.append(gpa, .{
                .name = try self.strings.intern(gpa, vn),
                .shape = .c_like,
                .data_start = 0,
                .data_len = 0,
            });
        }
        const enum_idx: u32 = @intCast(self.enum_decls.items.len);
        try self.enum_decls.append(gpa, .{
            .name = self.errorcode_type_name,
            .variants_start = variants_start,
            .variants_len = variant_names.len,
            .annotations_extra = 0,
            .annotations_len = 0,
        });
        _ = try self.addItem(gpa, .enum_decl, enum_idx, zero_span);

        self.error_type_name = try self.strings.intern(gpa, "Error");
        const string_type = try self.addNamedType(gpa, try self.strings.intern(gpa, "string"), zero_span);
        const errorcode_type = try self.addNamedType(gpa, self.errorcode_type_name, zero_span);
        const error_named = try self.addNamedType(gpa, self.error_type_name, zero_span);
        const error_opt = try self.addOptionalType(gpa, error_named, zero_span);
        const field_specs = [_]struct { name: []const u8, type_node: NodeId }{
            .{ .name = "message", .type_node = string_type },
            .{ .name = "code", .type_node = errorcode_type },
            .{ .name = "source", .type_node = error_opt },
        };
        const fields_start: u32 = @intCast(self.fields.items.len);
        self.builtin_fields_from = fields_start;
        for (field_specs) |fs| {
            try self.fields.append(gpa, .{
                .name = try self.strings.intern(gpa, fs.name),
                .type_node = fs.type_node,
                .default_value = NodeId.none,
                .annotations_extra = 0,
                .annotations_len = 0,
            });
        }
        const struct_idx: u32 = @intCast(self.struct_decls.items.len);
        try self.struct_decls.append(gpa, .{
            .name = self.error_type_name,
            .fields_start = fields_start,
            .fields_len = field_specs.len,
            .annotations_extra = 0,
            .annotations_len = 0,
        });
        _ = try self.addItem(gpa, .struct_decl, struct_idx, zero_span);
    }

    pub fn addTypeAlias(self: *AstArena, gpa: std.mem.Allocator, name: StringId, target: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.type_alias_decls.items.len);
        try self.type_alias_decls.append(gpa, .{ .name = name, .target = target });
        return try self.addItem(gpa, .type_alias, idx, span);
    }

    /// `const Name : type = value` (M1.0.8, top-level only). Mirrors
    /// `addTypeAlias` — append the side-slab entry, register the `const_decl`
    /// item.
    pub fn addConstDecl(self: *AstArena, gpa: std.mem.Allocator, decl: ConstDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.const_decls.items.len);
        try self.const_decls.append(gpa, decl);
        return try self.addItem(gpa, .const_decl, idx, span);
    }

    /// `test "name" { ... }` (M1.0.8). Append the side-slab entry, register the
    /// `test_decl` item.
    pub fn addTestDecl(self: *AstArena, gpa: std.mem.Allocator, decl: TestDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.test_decls.items.len);
        try self.test_decls.append(gpa, decl);
        return try self.addItem(gpa, .test_decl, idx, span);
    }

    /// `service NAME { fn … }` (M1.1.15.2 G1, `.d.etch` only). The caller
    /// appends the bodyless method `FnDecl`s to `arena.impl_methods` beforehand
    /// and passes the run in `decl`, exactly as `addTraitDecl` expects.
    pub fn addServiceDecl(self: *AstArena, gpa: std.mem.Allocator, decl: ServiceDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.service_decls.items.len);
        try self.service_decls.append(gpa, decl);
        return try self.addItem(gpa, .service_decl, idx, span);
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
                    // A `.path` alias target (`type HA = m.Member`, M1.0.16)
                    // has no single ultimate name in this arena — stop the
                    // by-name chain here (returning `current`) rather than
                    // mis-indexing `named_types`. The qualified target is
                    // resolved by node kind at the consult sites (a `.path`
                    // TypeNode → `resolvePathTypeNode`), not by this walk.
                    if (self.typeNodeKind(alias.target) != .named) break :outer;
                    const named = self.named_types.items[self.typeNodeData(alias.target)];
                    current = named.name;
                    continue :outer;
                }
            }
            break;
        }
        return current;
    }

    /// Whether `field` carries the builtin annotation `kind` (M1.0.14).
    pub fn fieldHasAnnotation(self: *const AstArena, field: Field, kind: AnnotationKind) bool {
        var i: u32 = 0;
        while (i < field.annotations_len) : (i += 1) {
            if (self.annot_pool.items[field.annotations_extra + i].kind == kind) return true;
        }
        return false;
    }

    /// Whether `field`'s declared type is the builtin `Entity` (resolved
    /// through the `type` alias chain). An optional (`Entity?`) or any other
    /// shape is NOT `Entity` — the `await entity_event` target must be a bare
    /// `Entity` (M1.0.14, §9.4).
    pub fn fieldTypeIsEntity(self: *const AstArena, field: Field) bool {
        if (self.typeNodeKind(field.type_node) != .named) return false;
        const named = self.named_types.items[self.typeNodeData(field.type_node)];
        return std.mem.eql(u8, self.strings.slice(self.resolveTypeAliasName(named.name)), "Entity");
    }

    /// Resolve the event's designated `Entity` field for `await entity_event`
    /// scoping (M1.0.14, §9.4 normative order): a field annotated
    /// `@entity_target` wins; else the single `Entity`-typed field; else a
    /// diagnostic condition (`none_entity` / `ambiguous`). The `@entity_target`
    /// field is returned as written — its Entity-typing and uniqueness are
    /// validated at the event declaration (E2), so a program reaching the
    /// interpreter has already passed those checks. This is the ONE
    /// implementation of the designated-field policy (`EntityTargetResolution`).
    pub fn resolveEventEntityTarget(self: *const AstArena, decl: EventDecl) EntityTargetResolution {
        // 1. `@entity_target`-annotated field wins.
        var i: u32 = 0;
        while (i < decl.fields_len) : (i += 1) {
            const field = self.fields.items[decl.fields_start + i];
            if (self.fieldHasAnnotation(field, .entity_target)) {
                return .{ .field = .{ .index = i, .name = field.name } };
            }
        }
        // 2. Else the single `Entity`-typed field.
        var found_index: ?u32 = null;
        var found_name: StringId = 0;
        i = 0;
        while (i < decl.fields_len) : (i += 1) {
            const field = self.fields.items[decl.fields_start + i];
            if (self.fieldTypeIsEntity(field)) {
                if (found_index != null) return .ambiguous; // ≥2 Entity fields → E0909
                found_index = i;
                found_name = field.name;
            }
        }
        if (found_index) |idx| return .{ .field = .{ .index = idx, .name = found_name } };
        return .none_entity; // zero Entity fields → E0908
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

    /// Build a `.path` type node for the qualified type `alias.Member`
    /// (M1.0.16). `alias` is the whole-module import alias, `member` the
    /// referenced TYPE_IDENT — both interned in this arena's strings.
    pub fn addPathType(self: *AstArena, gpa: std.mem.Allocator, alias: StringId, member: StringId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.path_types.items.len);
        try self.path_types.append(gpa, .{ .alias = alias, .member = member });
        return try self.addTypeNode(gpa, .path, idx, span);
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
    /// bulk-appended to `arena.extra` as a contiguous run. `names` carries
    /// the named-argument labels (M0.8 E4, §3.3) parallel to `args`
    /// (`0` = positional); pass an empty slice for an all-positional call
    /// (no `call_arg_names` storage, the pre-E4 representation).
    pub fn addCall(self: *AstArena, gpa: std.mem.Allocator, callee: NodeId, args: []const u32, names: []const StringId, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(gpa, args);
        var names_start: u32 = no_arg_names;
        if (names.len != 0) {
            std.debug.assert(names.len == args.len);
            names_start = @intCast(self.call_arg_names.items.len);
            try self.call_arg_names.appendSlice(gpa, names);
        }
        const idx: u32 = @intCast(self.call_exprs.items.len);
        try self.call_exprs.append(gpa, .{ .callee = callee, .args_start = start, .args_len = @intCast(args.len), .names_start = names_start });
        return try self.addExpr(gpa, .fn_call, idx, span);
    }

    /// Resolve the argument expression bound to parameter `param_idx` of a
    /// call (M0.8 E4 named arguments, §3.3): positionals bind in order, a
    /// named argument binds the parameter carrying its name. ONE binding
    /// algorithm consumed by the resolver, the interpreter, and the codegen
    /// — identical semantics by construction. Returns `null` when no
    /// argument binds the parameter (the resolver reports E0203; downstream
    /// consumers fail loud).
    pub fn callArgForParam(self: *const AstArena, args_start: u32, args_len: u32, names_start: u32, param_idx: u32, param_name: StringId) ?NodeId {
        const idx = self.callArgIndexForParam(args_start, args_len, names_start, param_idx, param_name) orelse return null;
        return @bitCast(self.extra.items[args_start + idx]);
    }

    /// Index variant of `callArgForParam` — the SOURCE-ORDER index of the
    /// argument bound to `param_idx` (M0.8 E4; the 2026-06-10 evaluation-
    /// order ruling: arguments EVALUATE in written order, then BIND in
    /// parameter order — both backends evaluate into source-order slots and
    /// pass through this index).
    pub fn callArgIndexForParam(self: *const AstArena, args_start: u32, args_len: u32, names_start: u32, param_idx: u32, param_name: StringId) ?u32 {
        _ = args_start;
        if (names_start == no_arg_names) {
            if (param_idx >= args_len) return null;
            return param_idx;
        }
        const names = self.call_arg_names.items[names_start .. names_start + args_len];
        // Positional prefix (§3.3: positionals first).
        var n_positional: u32 = 0;
        while (n_positional < args_len and names[n_positional] == 0) n_positional += 1;
        if (param_idx < n_positional) return param_idx;
        var i: u32 = n_positional;
        while (i < args_len) : (i += 1) {
            if (names[i] == param_name) return i;
        }
        return null;
    }

    /// `receiver.method(args)` (M0.8 E2 call mechanism). `args` is a slice of
    /// expr `NodeId.raw()` values, bulk-appended to `arena.extra`. `names`
    /// carries the named-argument labels (M0.8 E4, §3.3) — empty for an
    /// all-positional call, like `addCall`.
    pub fn addMethodCall(self: *AstArena, gpa: std.mem.Allocator, receiver: NodeId, method_name: StringId, args: []const u32, names: []const StringId, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(gpa, args);
        var names_start: u32 = no_arg_names;
        if (names.len != 0) {
            std.debug.assert(names.len == args.len);
            names_start = @intCast(self.call_arg_names.items.len);
            try self.call_arg_names.appendSlice(gpa, names);
        }
        const idx: u32 = @intCast(self.method_calls.items.len);
        try self.method_calls.append(gpa, .{ .receiver = receiver, .method_name = method_name, .args_start = start, .args_len = @intCast(args.len), .names_start = names_start });
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

    /// `data Name: Type { entries }` (M0.8 E4, `etch-grammar.md` §14). The
    /// caller appends the entries to `arena.data_entries` (and their field
    /// runs to `arena.struct_lit_fields`) beforehand, passing the range in
    /// `decl`.
    pub fn addDataDecl(self: *AstArena, gpa: std.mem.Allocator, decl: DataDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.data_decls.items.len);
        try self.data_decls.append(gpa, decl);
        return try self.addItem(gpa, .data_decl, idx, span);
    }

    /// `theme "name" { entries }` (M0.8 E5 Level B, `etch-grammar.md` §10.2).
    /// The caller appends entries to `arena.theme_entries` beforehand,
    /// passing the range in `decl`.
    pub fn addThemeDecl(self: *AstArena, gpa: std.mem.Allocator, decl: ThemeDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.theme_decls.items.len);
        try self.theme_decls.append(gpa, decl);
        return try self.addItem(gpa, .theme_decl, idx, span);
    }

    /// `motion Name { [states { … }] transitions { … } }` (M0.8 E5 Level B,
    /// `etch-grammar.md` §10.3). The caller appends the states / transitions /
    /// animators / keyframes to their slabs beforehand, passing the ranges in
    /// `decl`.
    pub fn addMotionDecl(self: *AstArena, gpa: std.mem.Allocator, decl: MotionDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.motion_decls.items.len);
        try self.motion_decls.append(gpa, decl);
        return try self.addItem(gpa, .motion_decl, idx, span);
    }

    /// `input_mapping "name" { properties actions combos }` (M0.8 E5 Level B
    /// STRICT, `etch-grammar.md` §16). The caller appends the actions / binds /
    /// combos to their slabs beforehand, passing the ranges in `decl`.
    pub fn addInputMappingDecl(self: *AstArena, gpa: std.mem.Allocator, decl: InputMappingDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.input_mapping_decls.items.len);
        try self.input_mapping_decls.append(gpa, decl);
        return try self.addItem(gpa, .input_mapping_decl, idx, span);
    }

    /// `widget Name(params) [when …] { ui_tree }` (M0.8 E5 Level B,
    /// `etch-grammar.md` §10.1). The caller appends the params and the recursive
    /// `ui_tree` (ui_elems / ui_widget_calls / ui_ifs / ui_fors) to their slabs
    /// beforehand, passing the ranges in `decl`.
    pub fn addWidgetDecl(self: *AstArena, gpa: std.mem.Allocator, decl: WidgetDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.widget_decls.items.len);
        try self.widget_decls.append(gpa, decl);
        return try self.addItem(gpa, .widget_decl, idx, span);
    }

    /// `locale code { "key" = "value" }` (M0.8 E5 Level B, `etch-grammar.md`
    /// §10.4). The caller appends the entries to `arena.locale_entries`
    /// beforehand, passing the range in `decl`.
    pub fn addLocaleDecl(self: *AstArena, gpa: std.mem.Allocator, decl: LocaleDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.locale_decls.items.len);
        try self.locale_decls.append(gpa, decl);
        return try self.addItem(gpa, .locale_decl, idx, span);
    }

    /// `effect Name { [params] {emitter} {handler} }` (M0.8 E6,
    /// `etch-grammar.md` §9.2). The caller appends the params fields, emitters,
    /// and event handlers to their slabs beforehand, passing the ranges in `decl`.
    pub fn addEffectDecl(self: *AstArena, gpa: std.mem.Allocator, decl: EffectDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.effect_decls.items.len);
        try self.effect_decls.append(gpa, decl);
        return try self.addItem(gpa, .effect_decl, idx, span);
    }

    /// `audio_graph Name { [params] {statement} output(expr) }` (M0.8 E6,
    /// `etch-grammar.md` §12.2). The caller appends the params fields and body
    /// statements to their slabs beforehand, passing the ranges + sink in `decl`.
    pub fn addAudioGraphDecl(self: *AstArena, gpa: std.mem.Allocator, decl: AudioGraphDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.audio_graph_decls.items.len);
        try self.audio_graph_decls.append(gpa, decl);
        return try self.addItem(gpa, .audio_graph_decl, idx, span);
    }

    /// `audio_score "name" { {element} }` (M0.8 E6, `etch-grammar.md` §12.1).
    /// The caller appends the score properties, sections, and stems to their
    /// slabs beforehand, passing the ranges in `decl`.
    pub fn addAudioScoreDecl(self: *AstArena, gpa: std.mem.Allocator, decl: AudioScoreDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.audio_score_decls.items.len);
        try self.audio_score_decls.append(gpa, decl);
        return try self.addItem(gpa, .audio_score_decl, idx, span);
    }

    /// `sequence Name { {property} {track} }` (M0.8 E6, `etch-grammar.md` §13).
    /// The caller appends the properties, tracks, and keyframes to their slabs
    /// beforehand, passing the ranges + on_start/on_finish in `decl`.
    pub fn addSequenceDecl(self: *AstArena, gpa: std.mem.Allocator, decl: SequenceDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.sequence_decls.items.len);
        try self.sequence_decls.append(gpa, decl);
        return try self.addItem(gpa, .sequence_decl, idx, span);
    }

    /// `anim_graph Name { [params] {state} {layer} }` (M0.8 E6, §11). The caller
    /// appends params / states / transitions / chooser rules / layers to their
    /// slabs beforehand, passing the ranges in `decl`.
    pub fn addAnimGraphDecl(self: *AstArena, gpa: std.mem.Allocator, decl: AnimGraphDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.anim_graph_decls.items.len);
        try self.anim_graph_decls.append(gpa, decl);
        return try self.addItem(gpa, .anim_graph_decl, idx, span);
    }

    /// `shader Name { [params] [vertex] fragment }` (M0.8 E6, §9.1). The caller
    /// appends the params + the stage params (rule_params) + the stage bodies
    /// (extra) beforehand, passing the ranges in `decl`.
    pub fn addShaderDecl(self: *AstArena, gpa: std.mem.Allocator, decl: ShaderDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.shader_decls.items.len);
        try self.shader_decls.append(gpa, decl);
        return try self.addItem(gpa, .shader_decl, idx, span);
    }

    /// `scene "Name" { … }` (M0.8 E7 Level C, §15). The caller appends all child
    /// runs (resources, entities, instances, children) to their slabs first,
    /// passing the ranges in `decl`.
    pub fn addSceneDecl(self: *AstArena, gpa: std.mem.Allocator, decl: SceneDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.scene_decls.items.len);
        try self.scene_decls.append(gpa, decl);
        return try self.addItem(gpa, .scene_decl, idx, span);
    }

    /// `prefab "Name" [of|extends "X"] [requires …] { … }` (M0.8 E7 Level C, §15).
    pub fn addPrefabDecl(self: *AstArena, gpa: std.mem.Allocator, decl: PrefabDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.prefab_decls.items.len);
        try self.prefab_decls.append(gpa, decl);
        return try self.addItem(gpa, .prefab_decl, idx, span);
    }

    /// `import module_path [import_spec]` (M1.0.7, §5.2). The caller appends the
    /// module-path segments to `import_path_segs` and any selective items to
    /// `import_items` first, passing the resulting ranges in `decl`.
    pub fn addImportDecl(self: *AstArena, gpa: std.mem.Allocator, decl: ImportDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.import_decls.items.len);
        try self.import_decls.append(gpa, decl);
        return try self.addItem(gpa, .import_decl, idx, span);
    }

    /// `dialogue Name { elements }` (M0.8 E4, `etch-grammar.md` §8.4). The
    /// caller appends elements to the dialogue slabs beforehand, passing
    /// the range in `decl`.
    /// Append an `ability` declaration (M0.8 E4 Level B, §8.5).
    pub fn addAbilityDecl(self: *AstArena, gpa: std.mem.Allocator, decl: AbilityDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.ability_decls.items.len);
        try self.ability_decls.append(gpa, decl);
        return try self.addItem(gpa, .ability_decl, idx, span);
    }

    pub fn addDialogueDecl(self: *AstArena, gpa: std.mem.Allocator, decl: DialogueDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.dialogue_decls.items.len);
        try self.dialogue_decls.append(gpa, decl);
        return try self.addItem(gpa, .dialogue_decl, idx, span);
    }

    /// `quest Name { properties + stages }` (M0.8 E4, `etch-grammar.md`
    /// §8.3). The caller appends properties / stages / elements to their
    /// slabs beforehand, passing the ranges in `decl`.
    pub fn addQuestDecl(self: *AstArena, gpa: std.mem.Allocator, decl: QuestDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.quest_decls.items.len);
        try self.quest_decls.append(gpa, decl);
        return try self.addItem(gpa, .quest_decl, idx, span);
    }

    /// `behavior Name { bt_node }` (M0.8 E4, `etch-grammar.md` §8.1). The
    /// caller appends the BT nodes to `arena.bt_nodes` beforehand, passing
    /// the root index in `decl`.
    pub fn addBehaviorDecl(self: *AstArena, gpa: std.mem.Allocator, decl: BehaviorDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.behavior_decls.items.len);
        try self.behavior_decls.append(gpa, decl);
        return try self.addItem(gpa, .behavior_decl, idx, span);
    }

    /// `routine Name { segments + interrupts }` (M0.8 E4, `etch-grammar.md`
    /// §8.2). The caller appends segments / triggers / interrupts to their
    /// slabs beforehand, passing the ranges in `decl`.
    pub fn addRoutineDecl(self: *AstArena, gpa: std.mem.Allocator, decl: RoutineDecl, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.routine_decls.items.len);
        try self.routine_decls.append(gpa, decl);
        return try self.addItem(gpa, .routine_decl, idx, span);
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

    /// `spawn(C1 {…}, …)` — component-literal varargs (M1.0.10, §3.2). `components`
    /// is a slice of struct-lit `NodeId.raw()` values, bulk-appended to
    /// `arena.extra` as a contiguous run (the `addArrayLit` convention).
    pub fn addSpawnStructComponents(self: *AstArena, gpa: std.mem.Allocator, components: []const u32, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(gpa, components);
        const idx: u32 = @intCast(self.spawn_structs.items.len);
        try self.spawn_structs.append(gpa, .{
            .is_prefab = false,
            .args_start = start,
            .args_len = @intCast(components.len),
        });
        return try self.addExpr(gpa, .spawn_struct, idx, span);
    }

    /// `spawn("Prefab")` — prefab-name form (M1.0.10, §3.2). `prefab_name` is the
    /// interned string literal. Parses + is recognized; REFUSED at type-check in
    /// Phase 1 (E2).
    pub fn addSpawnStructPrefab(self: *AstArena, gpa: std.mem.Allocator, prefab_name: StringId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.spawn_structs.items.len);
        try self.spawn_structs.append(gpa, .{ .is_prefab = true, .prefab_name = prefab_name });
        return try self.addExpr(gpa, .spawn_struct, idx, span);
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

    pub fn addMeasureExpr(self: *AstArena, gpa: std.mem.Allocator, body_start: u32, body_len: u32, value: NodeId, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.measure_exprs.items.len);
        try self.measure_exprs.append(gpa, .{ .body_start = body_start, .body_len = body_len, .value = value });
        return try self.addExpr(gpa, .measure_expr, idx, span);
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

    pub fn addAwaitExpr(self: *AstArena, gpa: std.mem.Allocator, aw: AwaitExpr, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.await_exprs.items.len);
        try self.await_exprs.append(gpa, aw);
        return try self.addExpr(gpa, .await_expr, idx, span);
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

    /// `branches` is the statement's complete branch list, bulk-appended to
    /// `arena.concurrency_branches` as a contiguous run (M1.0.12 E2 — the
    /// `addMatch` arms pattern, safe under nesting).
    pub fn addRaceStmt(self: *AstArena, gpa: std.mem.Allocator, branches: []const ConcurrencyBranch, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.concurrency_branches.items.len);
        try self.concurrency_branches.appendSlice(gpa, branches);
        const idx: u32 = @intCast(self.race_stmts.items.len);
        try self.race_stmts.append(gpa, .{ .branches_start = start, .branches_len = @intCast(branches.len) });
        return try self.addStmt(gpa, .race_stmt, idx, span);
    }

    /// Same storage discipline as `addRaceStmt` (M1.0.12 E2).
    pub fn addSyncStmt(self: *AstArena, gpa: std.mem.Allocator, branches: []const ConcurrencyBranch, span: SourceSpan) !NodeId {
        const start: u32 = @intCast(self.concurrency_branches.items.len);
        try self.concurrency_branches.appendSlice(gpa, branches);
        const idx: u32 = @intCast(self.sync_stmts.items.len);
        try self.sync_stmts.append(gpa, .{ .branches_start = start, .branches_len = @intCast(branches.len) });
        return try self.addStmt(gpa, .sync_stmt, idx, span);
    }

    pub fn addBranchStmt(self: *AstArena, gpa: std.mem.Allocator, bs: BranchStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.branch_stmts.items.len);
        try self.branch_stmts.append(gpa, bs);
        return try self.addStmt(gpa, .branch_stmt, idx, span);
    }

    pub fn addSpawnStmt(self: *AstArena, gpa: std.mem.Allocator, ss: SpawnStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.spawn_stmts.items.len);
        try self.spawn_stmts.append(gpa, ss);
        return try self.addStmt(gpa, .spawn_stmt, idx, span);
    }

    pub fn addTimerStmt(self: *AstArena, gpa: std.mem.Allocator, ts: TimerStmt, span: SourceSpan) !NodeId {
        const idx: u32 = @intCast(self.timer_stmts.items.len);
        try self.timer_stmts.append(gpa, ts);
        return try self.addStmt(gpa, .timer_stmt, idx, span);
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

    /// Visibility of a top-level item (M1.0.8). `.public` unless the parser set
    /// `.private` via `setItemVisibility`. Consumed by `buildExports`.
    pub fn itemVisibility(self: *const AstArena, id: NodeId) Visibility {
        std.debug.assert(id.category == .item);
        return self.items.items(.visibility)[id.index];
    }

    /// Mark a top-level item `.private` (M1.0.8). Called by `parseOneTopLevel`
    /// when a `private` prefix precedes the declaration_body it parsed.
    pub fn setItemVisibility(self: *AstArena, id: NodeId, vis: Visibility) void {
        std.debug.assert(id.category == .item);
        self.items.items(.visibility)[id.index] = vis;
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

    /// The `AwaitExpr` payload of an `.await_expr` node (M0.8 E3 sub-slice B).
    pub fn awaitExpr(self: *const AstArena, id: NodeId) AwaitExpr {
        std.debug.assert(self.exprKind(id) == .await_expr);
        return self.await_exprs.items[self.exprData(id)];
    }

    /// The `@on_event(T)` annotation on a `rule`, or null if the rule is not an
    /// event observer (M0.8 E3). When present, the rule fires once per received
    /// event of type `T`; the resolver validates `T` (E1203) and binds the
    /// implicit `event`, the interpreter/codegen drive the bus drain.
    pub fn onEventAnnotation(self: *const AstArena, rule: RuleDecl) ?Annotation {
        var i: u32 = 0;
        while (i < rule.annotations_len) : (i += 1) {
            const annot = self.annot_pool.items[rule.annotations_extra + i];
            if (annot.kind == .on_event) return annot;
        }
        return null;
    }

    /// The `@storage` annotation on a `component` declaration (the first one
    /// found), or null when the declaration carries none — in which case the
    /// storage mode is `table` by the domain's default
    /// (`engine-ecs-internals.md` §2). Mirror of `onEventAnnotation`: the
    /// annotation range lives on the decl, so this is the accessor both the
    /// type-checker and the codegen read instead of walking `annot_pool` by
    /// hand at each site.
    ///
    /// Deliberately NOT a resolved mode: the AST does not know the domain, and
    /// answering `?StorageKind` here would put a Tier-0 enum in the parser's
    /// arena. This returns the annotation; the caller validates.
    pub fn storageAnnotation(self: *const AstArena, decl: ComponentDecl) ?Annotation {
        var i: u32 = 0;
        while (i < decl.annotations_len) : (i += 1) {
            const annot = self.annot_pool.items[decl.annotations_extra + i];
            if (annot.kind == .storage) return annot;
        }
        return null;
    }

    /// The enum-variant name of an annotation's single positional argument when
    /// it is written in the language's form for such a value — the **tag path**,
    /// `@storage(.sparse)`. Returns null for every other shape, including the
    /// bare `IDENT` alternative, a named argument and a wrong arity; the
    /// type-checker turns each of those into its own diagnostic.
    ///
    /// **Only the dotted form, and that is a decision, not an omission.**
    /// `etch-grammar.md` §1.5 admits three alternatives for `annotation_arg` —
    /// an expression, `IDENT ":" expression`, and a bare `IDENT` — so the bare
    /// spelling is grammatical. It is refused here because this is a question of
    /// SCHEMA, not of grammar: for an argument whose declared type is an
    /// enumeration domain the language already has a form, and every sibling
    /// annotation of that shape uses it (`@phase`, `@tag`, `@pause_group`, dotted
    /// in every occurrence of the corpus).
    ///
    /// The load-bearing reason is not consistency, it is ambiguity: a bare
    /// enumeration value is syntactically indistinguishable from an identifier
    /// reference. `.sparse` cannot collide with a type or a variable named
    /// `sparse`; `sparse` can, and nothing can remove that from the bare form.
    /// The bare `IDENT` alternative of the grammar serves arguments whose type is
    /// NOT an enumeration domain.
    pub fn annotationTagPathName(self: *const AstArena, annot: Annotation) ?StringId {
        if (annot.args_len != 1) return null;
        const arg = self.annot_args.items[annot.args_start];
        if (arg.name != 0) return null; // a named argument is not a bare value
        if (self.exprKind(arg.value) != .tag_path) return null;
        return self.exprData(arg.value);
    }

    /// The `@requires(...)` annotation on a component declaration, or null.
    pub fn requiresAnnotation(self: *const AstArena, decl: ComponentDecl) ?Annotation {
        var i: u32 = 0;
        while (i < decl.annotations_len) : (i += 1) {
            const annot = self.annot_pool.items[decl.annotations_extra + i];
            if (annot.kind == .requires) return annot;
        }
        return null;
    }

    /// The `i`-th requisite type name of a `@requires(A, B, …)` annotation, or
    /// null when that argument is not a bare type path.
    ///
    /// The annotation is VARIADIC (`etch-reference-part3.md` §6's normative
    /// example is `@requires(Transform, RigidBody)`), so this reads one
    /// argument by index rather than assuming an arity — the shape three of the
    /// four corpus documents had reduced to a single positional before
    /// 2026-09-03.
    ///
    /// A requisite is a TYPE NAME, so the accepted expression kind is `.path` —
    /// the same shape `onEventTypeName` reads for `@on_event(T)`, and NOT the
    /// `.tag_path` that `@storage(.sparse)` uses: a type is named, an
    /// enumeration value is dotted.
    pub fn requiresTypeNameAt(self: *const AstArena, annot: Annotation, i: u32) ?StringId {
        if (i >= annot.args_len) return null;
        const arg = self.annot_args.items[annot.args_start + i];
        if (arg.name != 0) return null; // a named argument is not a requisite
        if (self.exprKind(arg.value) != .path) return null;
        return self.exprData(arg.value);
    }

    /// The event type name `T` from an `@on_event(T)` annotation, or null when
    /// the annotation is malformed (no argument, or the argument is not a type
    /// path). The resolver reports E1203 for the null / non-event cases.
    pub fn onEventTypeName(self: *const AstArena, annot: Annotation) ?StringId {
        if (annot.args_len == 0) return null;
        const arg = self.annot_args.items[annot.args_start];
        if (self.exprKind(arg.value) != .path) return null;
        return self.exprData(arg.value);
    }

    /// The structural-observer lifecycle annotation on a `rule` (the first one
    /// found), or null if the rule is not an observer (M1.0.2 E2). Mirrors
    /// `onEventAnnotation`. The resolver enforces "exactly one lifecycle
    /// annotation" (E1215 ObserverRuleConflict); this returns the first match
    /// for routing once that check has passed.
    pub fn observerAnnotation(self: *const AstArena, rule: RuleDecl) ?Annotation {
        var i: u32 = 0;
        while (i < rule.annotations_len) : (i += 1) {
            const annot = self.annot_pool.items[rule.annotations_extra + i];
            if (annot.kind.toObserverKind() != null) return annot;
        }
        return null;
    }

    /// The target component type name `T` from an `@on_added(T)` /
    /// `@on_removed(T)` / `@on_replaced(T)` annotation, or null when the
    /// annotation carries no type-path argument (the `@on_spawned` /
    /// `@on_despawned` case, or a malformed argument). Mirrors `onEventTypeName`;
    /// the resolver validates arity / component-ness (E1209 ObserverComponentInvalid).
    pub fn observerComponentName(self: *const AstArena, annot: Annotation) ?StringId {
        if (annot.args_len == 0) return null;
        const arg = self.annot_args.items[annot.args_start];
        if (self.exprKind(arg.value) != .path) return null;
        return self.exprData(arg.value);
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

test "AstArena timer statement round-trips through the timer_stmts slab (M1.0.13 E2)" {
    const gpa = std.testing.allocator;
    var arena = try AstArena.init(gpa);
    defer arena.deinit(gpa);

    const arg = try arena.addExpr(gpa, .duration_lit, 0, .{ .byte_start = 6, .byte_end = 10 });
    const binding = try arena.strings.intern(gpa, "t");
    const bound = try arena.addTimerStmt(gpa, .{
        .kind = .every,
        .arg = arg,
        .body_start = 7,
        .body_len = 2,
        .binding = binding,
    }, .{ .byte_start = 0, .byte_end = 20 });
    const unbound = try arena.addTimerStmt(gpa, .{
        .kind = .after_unscaled,
        .arg = arg,
        .body_start = 9,
        .body_len = 0,
        .binding = 0,
    }, .{ .byte_start = 21, .byte_end = 40 });

    try std.testing.expectEqual(StmtKind.timer_stmt, arena.stmtKind(bound));
    try std.testing.expectEqual(StmtKind.timer_stmt, arena.stmtKind(unbound));
    const first = arena.timer_stmts.items[arena.stmtData(bound)];
    try std.testing.expectEqual(TimerKind.every, first.kind);
    try std.testing.expectEqual(arg, first.arg);
    try std.testing.expectEqual(@as(u32, 7), first.body_start);
    try std.testing.expectEqual(@as(u32, 2), first.body_len);
    try std.testing.expectEqual(binding, first.binding);
    const second = arena.timer_stmts.items[arena.stmtData(unbound)];
    try std.testing.expectEqual(TimerKind.after_unscaled, second.kind);
    // `binding == 0` is the discarded-handle sentinel (the SpawnStmt precedent).
    try std.testing.expectEqual(@as(StringId, 0), second.binding);
}

test "AnnotationKind.fromName recognises builtin names" {
    try std.testing.expectEqual(AnnotationKind.phase, AnnotationKind.fromName("phase"));
    try std.testing.expectEqual(AnnotationKind.range, AnnotationKind.fromName("range"));
    try std.testing.expectEqual(AnnotationKind.entity_target, AnnotationKind.fromName("entity_target"));
    try std.testing.expectEqual(AnnotationKind.custom, AnnotationKind.fromName("totally_unknown"));
}
