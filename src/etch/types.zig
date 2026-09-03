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
/// The storage-mode domain, read from the owner of the EFFECT rather than
/// re-listed here (`etch-resolver-types.md` §13.3.1). `weld_etch` already
/// depends on `weld_core` (`build.zig:50`) and `weld_core` imports only
/// `foundation`, so this adds a file-level import inside an existing module
/// edge and no cycle.
const StorageKind = @import("weld_core").ecs.StorageKind;

/// The domain's spellings rendered once for the `@storage` diagnostics, and
/// DERIVED from the enum rather than written out: a third variant would
/// otherwise leave every message behind, which is the drift the domain's single
/// declaration exists to prevent.
const storage_domain_list = blk: {
    var out: []const u8 = "";
    for (@typeInfo(StorageKind).@"enum".fields, 0..) |f, i| {
        out = out ++ (if (i == 0) "" else " | ") ++ f.name;
    }
    break :blk out;
};

/// The same domain rendered in the ACCEPTED spelling — `.table | .sparse` — for
/// every message that tells an author what to write. Derived from the enum for
/// the same reason as its bare twin, and separate from it because the arity
/// message names a count of arguments while the others name a spelling.
const storage_domain_dotted = blk: {
    var out: []const u8 = "";
    for (@typeInfo(StorageKind).@"enum".fields, 0..) |f, i| {
        out = out ++ (if (i == 0) "" else " | ") ++ "." ++ f.name;
    }
    break :blk out;
};

/// Resolve a `component` declaration's storage mode from its `@storage`
/// annotation. **Total by construction**: no annotation, or a value the domain
/// does not carry, yields `table`.
///
/// The fallback is not leniency. `checkStorageAnnotation` has already refused an
/// out-of-domain value with `E0503` by the time any registration runs, so a
/// non-null-but-unknown name reaching here means the program was rejected and
/// this registry will be discarded; answering `table` keeps this function total
/// and stops it from inventing a mode the front-end declined to accept. Making
/// it fallible would put a second refusal channel on a path that has no
/// diagnostic sink.
///
/// Shared by the interpreter and the scene cook so the two registries cannot
/// disagree about the same declaration — the asymmetry that would appear the
/// moment either side resolved the annotation on its own.
pub fn storageModeOf(ast: *const AstArena, decl: ast_mod.ComponentDecl) StorageKind {
    const annot = ast.storageAnnotation(decl) orelse return .table;
    const name_id = ast.annotationTagPathName(annot) orelse return .table;
    return StorageKind.fromName(ast.strings.slice(name_id)) orelse .table;
}

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
    /// `Time` (§2.2 builtin, M0.8 E7). The expression type of a `TIME_LITERAL`
    /// (`HH:MM`, §1.4 / §3.2 literal) — the DURATION/COLOR-precedent lift.
    /// EVALUATION is fail-loud in both backends (time runtime semantics are
    /// Tier-1/E5+); like `duration`/`string_` it is NOT in `fromName`, so it
    /// stays a literal-expression type, not a component/resource field type.
    time,
    /// `string` (M0.8 sub-slice C tranche 1). A first-class expression type so
    /// `"lit"` / concat / `.len()` resolve, but deliberately NOT in `fromName`
    /// — `string` stays rejected as a component/resource field type (POD /
    /// "not in the builtin set", `validateFieldsInDecl`). Since tranche 2
    /// (the Error layer) `string` is accepted on `struct` fields and resolves
    /// as a declared type through `namedTypeToResolved`'s special case.
    string_,
    /// `TaskHandle` (§2.2 builtin, M1.0.12 E3) — the value of a bound spawn
    /// task statement (`let h = spawn { }`). Non-POD (`etch-grammar.md` §2.2):
    /// like `string_`/`time` it is deliberately NOT in `fromName`, so it stays
    /// rejected as a component/resource field type. `h.cancel()` and `await h`
    /// are its only operations (§9.8).
    task_handle,
    /// `TimerHandle` (§2.2 builtin, M1.0.13 E4) — the value of a bound timer
    /// statement (`let t = after(d) { }`). Non-POD (`etch-grammar.md` §2.2):
    /// like `task_handle` it is deliberately NOT in `fromName`, so it stays
    /// rejected as a component/resource field type. `t.cancel()` is its ONLY
    /// operation (§9.10) — a timer is NOT a task: it is not awaitable and
    /// carries no join semantics. Distinct from `task_handle` by design (two
    /// different lifecycle models; reusing one for the other is rejected).
    timer_handle,

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

/// Default-value carrier for a builtin-resource field (M1.0.13 E4). The three
/// time resources only need the POD scalars below.
pub const BuiltinResourceDefault = union(enum) {
    float_: f64,
    int_: i64,
    bool_: bool,
};

/// One field of a builtin engine resource (M1.0.13 E4).
pub const BuiltinResourceField = struct {
    name: []const u8,
    type_: BuiltinType,
    default: BuiltinResourceDefault,
};

/// A builtin engine resource descriptor (M1.0.13 E4).
pub const BuiltinResource = struct {
    name: []const u8,
    fields: []const BuiltinResourceField,
};

/// The three builtin engine time resources (M1.0.13,
/// `engine-gameplay-systems.md` "Les trois temps") — the SINGLE descriptor
/// table: the type-checker resolves `get(GameTime).dt` /
/// `get_mut(GameTime).time_scale` against it, and `interp.zig` Pass A
/// auto-registers the resources from it at the builtin `TagSet` injection
/// point (E5). No `.etch` prelude, no separate module. `GameTime.fixed_dt`'s
/// default IS the interpreter's fixed timestep (`1.0 / 60.0`, the M1.0.11
/// async 60 Hz convention). `UnscaledTime` and `RealTime` are affected by
/// neither `time_scale` nor `paused`.
pub const builtin_resources = [_]BuiltinResource{
    .{ .name = "GameTime", .fields = &.{
        .{ .name = "dt", .type_ = .float_, .default = .{ .float_ = 0.0 } },
        .{ .name = "fixed_dt", .type_ = .float_, .default = .{ .float_ = 1.0 / 60.0 } },
        .{ .name = "total", .type_ = .float_, .default = .{ .float_ = 0.0 } },
        .{ .name = "time_scale", .type_ = .float_, .default = .{ .float_ = 1.0 } },
        .{ .name = "frame", .type_ = .int_, .default = .{ .int_ = 0 } },
        .{ .name = "fixed_frame", .type_ = .int_, .default = .{ .int_ = 0 } },
        .{ .name = "paused", .type_ = .bool_, .default = .{ .bool_ = false } },
    } },
    .{ .name = "UnscaledTime", .fields = &.{
        .{ .name = "dt", .type_ = .float_, .default = .{ .float_ = 0.0 } },
        .{ .name = "total", .type_ = .float_, .default = .{ .float_ = 0.0 } },
    } },
    .{ .name = "RealTime", .fields = &.{
        .{ .name = "dt", .type_ = .float_, .default = .{ .float_ = 0.0 } },
        .{ .name = "total", .type_ = .float_, .default = .{ .float_ = 0.0 } },
        .{ .name = "since_startup", .type_ = .float_, .default = .{ .float_ = 0.0 } },
    } },
};

/// Descriptor lookup by resource name bytes (M1.0.13 E4). Consulted by the
/// receiver-less `get(T)` resolution and by the builtin-resource field
/// lookup; `interp.zig` iterates `builtin_resources` directly (E5).
pub fn builtinResourceByName(name: []const u8) ?*const BuiltinResource {
    for (&builtin_resources) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

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
    /// An `event` value (M0.8 E3) — the implicit `event` binding of an
    /// `@on_event(T)` observer rule. Payload is the event type name; fields
    /// resolve by name against the event declaration (POD struct of fields,
    /// like a component/resource). Self-style binding, no declared param.
    event_t: StringId,
    /// A generic type variable in scope (M0.8 E2 block 4). Payload is the type-
    /// parameter name. Opaque within a generic body (operations are permissive,
    /// like `unknown`); resolved to a concrete type by inference at the call site.
    generic: StringId,
    /// `T?` optional of a builtin-scalar payload (M0.8 E2 block 5). Non-builtin
    /// payloads (`struct?` / `enum?`) are deferred — they resolve to `.unknown`
    /// (the optional-ness is not tracked; permissive). `if let` / `while let`
    /// unwrap this to the payload builtin.
    optional: BuiltinType,
    /// The current test's World handle (M1.0.15) — the return type of
    /// `test_world()` (test bodies only). Receiver of `spawn_with`/`emit`/`tick`
    /// in `dispatchMethodOnType`. No payload (mono-world). Not field-storable.
    test_world,
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
            .event_t => |id| id == b.event_t,
            .generic => |id| id == b.generic,
            .optional => |bt| bt == b.optional,
            .test_world => true,
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
pub const SymbolKind = enum { component, resource, rule, type_alias, fn_, struct_, enum_, trait_, event_, data_, routine_, behavior_, quest_, dialogue_, ability_, motion_, widget_, locale_, effect_, audio_graph_, sequence_, anim_graph_, shader_, const_ };

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

/// Resolve a foreign-arena component field's declared type to a `BuiltinType`,
/// or `null` for a non-builtin (named / array / complex) type — M1.0.7 E6 (D-E).
/// Mirrors the builtin path of `namedTypeToResolved` but reads the FOREIGN arena's
/// strings + alias chain; it consults no symbol table. `null` is unreachable for a
/// valid component (component fields are builtin-POD only, `validateFieldsInDecl
/// .component_like`) — so the cross-arena field-TYPE check is complete for every
/// valid imported component.
fn foreignBuiltinFieldType(decl_arena: *const AstArena, type_node: NodeId) ?BuiltinType {
    if (decl_arena.typeNodeKind(type_node) != .named) return null;
    const named = decl_arena.named_types.items[decl_arena.typeNodeData(type_node)];
    const resolved = decl_arena.resolveTypeAliasName(named.name);
    const tname = decl_arena.strings.slice(resolved);
    if (std.mem.eql(u8, tname, "string")) return .string_;
    return BuiltinType.fromName(tname);
}

/// `true` if `s` contains an ASCII uppercase letter — an `E1768
/// IdInvalidFormat` data-entry id check (ids are snake_case IDENTs,
/// `etch-validation-ecs.md` §22.2; M0.8 E4).
fn containsUppercase(s: []const u8) bool {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') return true;
    }
    return false;
}

/// The `sequence_track` type catalogue (`etch-validation-ecs.md` §21.2, inlined
/// — small + fixed). Backs E1742 TrackTypeUnknown (M0.8 E6).
fn isKnownTrackType(name: []const u8) bool {
    const catalogue = [_][]const u8{ "ComponentTrack", "TransformTrack", "CameraTrack", "AnimationTrack", "EventTrack", "FadeTrack", "SubSequenceTrack" };
    for (catalogue) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

/// Parse a `DURATION_LIT` expr's seconds at VALIDATION time (`DURATION_LIT =
/// FLOAT_LITERAL "s"`, §1.4 — single `s` suffix). Distinct from the deferred
/// RUNTIME duration eval (fail-loud both backends). `null` if not a duration
/// literal. Backs E1744 KeyframeOutOfRange + E1745 KeyframesUnordered (M0.8 E6).
fn durationLitSeconds(arena: *const AstArena, expr_id: NodeId) ?f64 {
    if (arena.exprKind(expr_id) != .duration_lit) return null;
    const lex = arena.strings.slice(arena.exprData(expr_id));
    if (lex.len < 2 or lex[lex.len - 1] != 's') return null;
    return std.fmt.parseFloat(f64, lex[0 .. lex.len - 1]) catch null;
}

/// Parse an int / float literal expr's numeric value at validation time. `null`
/// if not a numeric literal. Backs E1749 FPSInvalid + E1750 DurationInvalid.
fn numericLitValue(arena: *const AstArena, expr_id: NodeId) ?f64 {
    const k = arena.exprKind(expr_id);
    if (k != .int_lit and k != .float_lit) return null;
    return std.fmt.parseFloat(f64, arena.strings.slice(arena.exprData(expr_id))) catch null;
}

/// Target categories the annotation-applicability check distinguishes
/// (M0.8 D-S3-annot-applicability). E1 had `component` / `resource` / `rule`
/// items and their `field`s; `function` joins with top-level `fn` (E2). No
/// builtin annotation in the current catalogue applies to a `function` (the
/// fn-targeting `@native` / `@shader_fn` are not modelled yet), so only
/// `@custom` is accepted there; `event` joins with the `event` construct
/// (M0.8 E3); other construct targets arrive with their constructs.
/// `data` / `routine` join with the E4 Level-B constructs (no builtin
/// annotation targets them — only `.custom` is accepted, like `function`).
const AnnotTarget = enum { component, resource, rule, field, function, event, data, routine, behavior, quest, dialogue, ability, theme, motion, input_mapping, widget, locale, effect, audio_graph, audio_score, sequence, anim_graph, shader, scene, prefab, test_ };

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
        .on_event => target == .rule,
        // M1.0.2 E2 — structural-observer lifecycle annotations route onto a rule.
        .on_added, .on_removed, .on_replaced, .on_spawned, .on_despawned => target == .rule,
        .unit, .range, .hidden, .readonly, .replicated => target == .field,
        .networked => target == .event,
        // M1.0.14 E2 — @entity_target decorates an event field; event-only +
        // Entity-typed + uniqueness are enforced at the declaration (E0502).
        .entity_target => target == .field,
        .shader_fn => target == .function,
        // M1.0.15 — the three `test`-only annotations (§17). Applied to any
        // other target → E0502 (misapplied); applied to a test, arg-validated
        // separately in `checkTestAnnotations`.
        .tag, .skip, .only => target == .test_,
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
    /// Test-name namespace (M1.0.15), SEPARATE from `symbols`: a `test "Foo"`
    /// no longer collides with a `component Foo` (the M1.0.8 collision this
    /// milestone resolves). Keyed by the interned test-name string; membership
    /// enforces intra-namespace uniqueness (two `test "X"` → E0101, contextual
    /// message). Test names are never referenced by code and never exported.
    test_symbols: std.AutoHashMapUnmanaged(StringId, void) = .empty,
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
    /// The `await_expr` node that is the statement-head `await` of the statement
    /// currently being checked (M1.0.11 E3), or `NodeId.none`. Set at the top of
    /// `checkStmt` for the allowed positions (expr-stmt / `let` init / simple
    /// assignment RHS / `return` operand); `synthExprE` flags any OTHER
    /// `await_expr` it visits as E0904 `AwaitNotStatementHead` (a sub-expression
    /// `await` — a Phase-1 tree-walker restriction; §9.12).
    stmt_head_await: NodeId = NodeId.none,
    /// Whether the statements currently being checked sit on the async driver's
    /// frame-driven spine (M1.0.11 E3): a rule / `fn` / method body, or the body
    /// of a statement-position control-flow (the interpreter pushes those as
    /// frames). `false` inside a VALUE block (`let x = if c { … } else { … }`,
    /// `= match`/`= loop`/`= { … }`, a control-flow/block assignment RHS or
    /// `return` operand) — the tree-walker evaluates those synchronously, so a
    /// statement-head `await` there is inexecutable and gets E0904 even though it
    /// is syntactically a head.
    await_suspendable: bool = false,
    /// Whether the `fn` / `rule` / method whose body is currently being checked is
    /// `async` (M1.0.11 E4, function coloring §9.3). An `await`, or a call to an
    /// `async fn`/`async method`, in a NON-async context is E0901
    /// `AsyncCallInNonAsyncContext`. `false` outside any body.
    current_is_async: bool = false,
    /// Whether a `throw` raised HERE has somewhere to go (M1.1.15.2 G2, E0902).
    /// True inside a `try` body and inside a `throws` fn; false in a rule body,
    /// which can never be `throws` (E0903), and false in a plain fn. Saved and
    /// restored at every body boundary, exactly like `current_is_async`.
    current_can_throw: bool = false,
    /// Whether the statements currently being checked are a `test` block body
    /// (M1.0.15). Test-scoped builtins (`test_world`, `tick_until`) and the
    /// `measure { }` expression resolve only when this is `true`; outside a test
    /// body they fall through to E0102 (`test_world`/`tick_until`) or E0910
    /// (`measure`). Set/restored around the body in `checkTest`.
    in_test_body: bool = false,
    /// The kind of the INNERMOST `race`/`sync` branch or `branch`/`spawn` body
    /// enclosing the statements being checked (M1.0.12 E3), `null` outside any.
    /// Drives E0906 (a `return` is legal only in a `race` branch —
    /// winner-return propagation §9.5; `sync`/`branch`/`spawn` reject it) and
    /// E0907 (a `break`/`continue` must not cross the task boundary §9.2).
    /// Saved/restored at each branch entry (innermost wins).
    conc_branch: ?ConcBranchKind = null,
    /// Loop-nesting depth accumulated INSIDE the innermost concurrency branch
    /// (M1.0.12 E3): >0 means an unlabeled `break`/`continue` targets an
    /// in-branch loop (legal); 0 means it would escape the task → E0907.
    /// Reset to 0 at branch entry (saved/restored); incremented by the
    /// `for`/`while` statement arms and `synthLoop`.
    conc_loop_depth: u32 = 0,
    /// Stack of the labels of every labeled loop currently open (M1.0.12 E3),
    /// pushed/popped by `synthLoop`. Only the window past `conc_labels_base`
    /// belongs to the innermost concurrency branch — a labeled
    /// `break`/`continue` whose label is outside that window targets a loop
    /// beyond the task boundary → E0907.
    conc_labels: std.ArrayListUnmanaged(StringId) = .empty,
    /// Start of the innermost branch's label window in `conc_labels`
    /// (M1.0.12 E3). Saved/restored at branch entry.
    conc_labels_base: usize = 0,
    /// The direct-call node consumed by the `await` currently being typed
    /// (M1.0.12 E3): the free-fn/method call sites skip E0905 for it. Set
    /// around the future-form arg synthesis; `NodeId.none` otherwise. The
    /// `await` is the SOLE call-grain consumer of the `{async}` effect
    /// (`etch-resolver-types.md` §9.2, revision 2): the four concurrency
    /// constructs relocate the suspension into a child task — their bodies
    /// are ordinary async contexts where E0905 applies recursively.
    awaited_call: NodeId = NodeId.none,
    /// Merged global tag table (M0.8 E3, `etch-validation-ecs.md` §5.2), built
    /// between pass 1 and pass 2 from every `tags { ... }` block. `null` until
    /// `buildTags` runs. Pass 2 (tag-op when-conditions / `tag_path` operands,
    /// landed in the query-operator commit) resolves paths against it.
    tag_table: ?tags_mod.TagTable = null,
    /// Names captured by the closure body currently being typed (M0.8 E3-C
    /// tranche 6, `etch-resolver-types.md` §8.2): the caller-scope bindings
    /// snapshotted at `synthCall` minus the closure params. An assignment
    /// targeting one of them is E0221 ClosureCannotMutateCapture; a body-local
    /// `let` re-declaring a name removes it (it is body-owned from there).
    /// `null` outside a closure body. Saved/restored around nested typing.
    closure_captures: ?*std.AutoHashMapUnmanaged(StringId, void) = null,
    /// Cross-file project context (M0.9 E2-B). `null` in single-file mode (the
    /// M0.8 behaviour: E1782/E1786/E1791 resolve against per-file sets). When
    /// set (via `checkProject`), those three scene/prefab reference + UUID
    /// checks resolve against the byte-keyed PROJECT indexes instead, so a
    /// prefab or UUID defined in another project file is in scope.
    project: ?*const ProjectContext = null,
    /// Symbols brought into this file's scope by a selective `import a.b { X }`
    /// (M1.0.7 E5), byte-keyed under their LOCAL name's `StringId` in THIS arena
    /// (the `as Y` alias if present, else the imported name). Built by
    /// `bindImports` after pass 1; consulted by E6's `TYPE_IDENT` resolution.
    /// Empty in single-file mode.
    imported_symbols: std.AutoHashMapUnmanaged(StringId, ExportEntry) = .empty,
    /// Module aliases from `import a.b as m` / bare `import a.b` (M1.0.7 E5, D-F):
    /// local alias `StringId` → target file index. Qualified `m.Type` resolution
    /// is deferred; the binding is recorded so the later walk is purely additive.
    imported_aliases: std.AutoHashMapUnmanaged(StringId, usize) = .empty,
    /// Every `service` reachable from this check, keyed by NAME BYTES
    /// (M1.1.15.2 G1). Byte-keyed and not `StringId`-keyed for the reason
    /// M1.0.7 established for the exports index: a `StringId` is per-arena, and
    /// a service is declared in one arena and called from another.
    services: std.StringHashMapUnmanaged(ServiceEntry) = .empty,
    /// Every `event` a `.d.etch` in this project declares, keyed by NAME BYTES
    /// for the reason `services` is (M1.1.15.2 G4).
    foreign_events: std.StringHashMapUnmanaged(ForeignEvent) = .empty,

    /// Byte-keyed cross-file indexes for project-level scene/prefab validation
    /// (M0.9 E2-B). StringIds are per-arena, so cross-file resolution keys on
    /// the interned string BYTES. `prefabs` holds every prefab name declared
    /// anywhere in the project (read-only during checks); `uuids` is the shared
    /// cross-scene UUID tracker, mutated as each file's scenes are visited — a
    /// second occurrence of a UUID is E1782. Both sets' keys reference the
    /// arenas' string pools, which `root.validateProject` keeps alive for the
    /// duration of the checks.
    /// The four concurrency-branch contexts (M1.0.12 E3) — see `conc_branch`.
    pub const ConcBranchKind = enum { race, sync, branch, spawn };

    /// Visibility of an exported symbol (M1.0.7 E5, D-G). Since `private`
    /// graduated (M1.0.8) the exports builder sets `.private` from the decl's
    /// `Item.visibility`, making the binding path's `E0107` check reachable.
    pub const Visibility = enum { public, private };

    /// One exported top-level symbol of a module (M1.0.7 E5). `arena_index` is
    /// the defining file's index in the project (its slot in `exports`/`arenas`);
    /// `item_id` is its `Item` NodeId in that arena. The cross-arena field check
    /// (E6) fetches the decl via `project.arenas[arena_index]` + `item_id`.
    pub const ExportEntry = struct {
        kind: SymbolKind,
        visibility: Visibility,
        arena_index: usize,
        item_id: NodeId,
    };

    /// Per-module exports table, byte-keyed on the interned export name (StringIds
    /// are per-arena → cross-file keys on bytes, the M0.9 pattern). One table per
    /// project file, indexed by file index in `ProjectContext.exports`.
    pub const ExportTable = std.StringHashMapUnmanaged(ExportEntry);

    pub const ProjectContext = struct {
        prefabs: *const std.StringHashMapUnmanaged(void),
        uuids: *std.StringHashMapUnmanaged(void),
        // ── M1.0.7 E5 — cross-file import resolution ──
        /// Module-path bytes → file index (built by `root.validateProject`).
        module_index: *const std.StringHashMapUnmanaged(usize),
        /// Per-file exports tables, indexed by file index.
        exports: []const ExportTable,
        /// Per-file arenas, indexed by file index (= the project's parsed ASTs).
        /// The defining arena for E6's cross-arena component-decl fetch.
        arenas: []AstArena,
    };

    /// One `service` declaration reachable from this check (M1.1.15.2 G1,
    /// `etch-grammar.md` §20.4). A service is declared in a `.d.etch` and CALLED
    /// from a standard `.etch`, so the declaration almost always lives in a
    /// different arena than the call site — hence the arena pointer, which is
    /// what makes the method run reachable at all.
    pub const ServiceEntry = struct {
        /// The arena the declaration lives in. `decl.methods_start` indexes
        /// THIS arena's `impl_methods`, never the caller's.
        arena: *const AstArena,
        decl: ast_mod.ServiceDecl,
        span: SourceSpan,
    };

    /// One `event` declared in a `.d.etch` reachable from this check
    /// (M1.1.15.2 G4). Same shape and same reason as `ServiceEntry`: the
    /// declaration lives in a different arena than the rule observing it, so the
    /// arena pointer is what makes the field run reachable.
    ///
    /// Declaration files ONLY. An `event` in an ordinary `.etch` keeps the
    /// existing single-arena path through `symbols`, and nothing about it moves.
    pub const ForeignEvent = struct {
        arena: *const AstArena,
        decl: ast_mod.EventDecl,
    };

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
        self.test_symbols.deinit(self.gpa);
        self.methods.deinit(self.gpa);
        self.trait_impls.deinit(self.gpa);
        self.conc_labels.deinit(self.gpa);
        self.generic_scope.deinit(self.gpa);
        self.imported_symbols.deinit(self.gpa);
        self.imported_aliases.deinit(self.gpa);
        self.services.deinit(self.gpa);
        self.foreign_events.deinit(self.gpa);
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
        return runCheck(gpa, arena, diagnostics, null);
    }

    /// Cross-file variant (M0.9 E2-B): identical passes to `check`, but the
    /// scene/prefab reference + UUID checks (E1782/E1786/E1791) resolve against
    /// `project` — the byte-keyed global prefab index + shared cross-scene UUID
    /// tracker — instead of the per-file sets. Driven by `root.validateProject`
    /// once per project file, with one shared `ProjectContext`.
    pub fn checkProject(gpa: std.mem.Allocator, arena: *AstArena, diagnostics: *std.ArrayListUnmanaged(Diagnostic), project: *const ProjectContext) !void {
        return runCheck(gpa, arena, diagnostics, project);
    }

    fn runCheck(gpa: std.mem.Allocator, arena: *AstArena, diagnostics: *std.ArrayListUnmanaged(Diagnostic), project: ?*const ProjectContext) !void {
        // Builtin `Error` / `ErrorCode` declarations (M0.8 E3-C tranche 2,
        // part1 §10.2) join the arena before pass 1 so they register like
        // ordinary declarations. Every interp / codegen driver runs through
        // `check`, so the injection point is unique.
        try arena.ensureErrorBuiltins(gpa);
        var tc: TypeChecker = .{
            .gpa = gpa,
            .arena = arena,
            .diagnostics = diagnostics,
            .project = project,
        };
        defer tc.deinit();
        // E1901 runs FIRST: it decides whether the file is even allowed to
        // contain what it contains, and a `.d.etch` carrying a `rule` would
        // otherwise produce a cascade of resolution errors on a body that had
        // no business being parsed. Cheap either way — one walk of the item
        // column, and an immediate return in `.standard` mode.
        try tc.checkDeclarationFileConstructs();
        try tc.collectServices();
        try tc.collectDeclaredEvents();
        try tc.pass1Collect();
        try tc.bindImports();
        try tc.validateTypeAliases();
        try tc.validateImpls();
        try tc.validateDataDecls();
        try tc.validateRoutineDecls();
        try tc.buildTags();
        try tc.validateBehaviorDecls();
        try tc.validateQuestDecls();
        try tc.validateDialogueDecls();
        try tc.validateAbilityDecls();
        try tc.validateThemeDecls();
        try tc.validateMotionDecls();
        try tc.validateInputMappingDecls();
        try tc.validateWidgetDecls();
        try tc.validateLocaleDecls();
        try tc.validateEffectDecls();
        try tc.validateAudioScoreDecls();
        try tc.validateSequenceDecls();
        try tc.validateAnimGraphDecls();
        try tc.validateShaderDecls();
        try tc.validateSceneDecls();
        try tc.validatePrefabDecls();
        try tc.pass2Resolve();
    }

    /// `E1901 ConstructNotAllowedInDeclarationFile` (M1.1.15.2 G1,
    /// `etch-grammar.md` §20.1/§20.2). A no-op outside a declaration file.
    ///
    /// **The predicate is §20.1's ALLOW-LIST, not §20.2's forbidden list**, and
    /// the two are not the same set. §20.1 gives a closed grammar production —
    /// `decl_file_item` — while §20.2 enumerates twenty-one behavioural
    /// constructs under the heading "tout construct comportemental est
    /// interdit". Four constructs are refused here that §20.2 does not name:
    /// `component`, `resource`, `tags` and `override`. The grammar production is
    /// the stronger authority — a construct admissible in a declaration file
    /// would appear in `decl_file_item` — and it is also the reversible
    /// direction: widening an allow-list later is additive, whereas narrowing an
    /// admitted construct is a breaking change. **The divergence between §20.1
    /// and §20.2 is a spec finding, recorded for reconciliation, not resolved by
    /// this code.**
    ///
    /// **`event_decl` is IN the allow-list, and it is the one place where the
    /// reversible-direction argument was actually exercised** (M1.1.15.2, G1
    /// amendment after a Claude.ai round-trip; `etch-grammar.md` §20.1 patched
    /// to match). The gate's own finding contained the reason without naming it:
    /// G4 has to make a Zig-emitted event observable from a rule, and a rule can
    /// only observe an event whose type Etch knows. `TriggerEnter` appears zero
    /// times in the `etch-*` corpus and in `engine-ecs-internals.md`, so the
    /// corpus states nowhere how a Zig event type becomes visible to Etch —
    /// and the only other candidate, a hand-written duplicate in a user `.etch`,
    /// is a surface derived from a Zig shape with no drift guard, which is
    /// exactly the class `bindgen-check` exists to close. The emitted `.d.etch`
    /// is one artefact under one guard.
    ///
    /// An event needs no body rule of its own: `ast.EventDecl` is a name plus a
    /// field run and has no statement run at all, so the "declaration files
    /// carry no bodies" property holds by the construct's shape rather than by a
    /// check. `component` and `resource` stay refused — they are ECS storage
    /// declarations authored in scenes and prefabs, not a Tier 1 module's
    /// emitted surface.
    ///
    /// The switch is EXHAUSTIVE with no `else`, so a future `ItemKind` variant
    /// is a compile error here and must state which side it falls on. That is
    /// the whole point of an allow-list; an `else => {}` would silently admit
    /// it, which is the failure mode this repository has named twice.
    ///
    /// Every occurrence is reported, not only the first. §20.2's "à la première
    /// occurrence" reads as when the error is raised, not as a budget of one per
    /// file, and every other pass in this checker reports all — a one-per-file
    /// rule would cost the author a compile cycle per mistake.
    fn checkDeclarationFileConstructs(self: *TypeChecker) !void {
        if (self.arena.mode != .declaration_file) return;
        const kinds = self.arena.items.items(.kind);
        for (kinds, 0..) |k, i| {
            const item_id = NodeId{ .category = .item, .index = @intCast(i) };
            const allowed = switch (k) {
                // §20.1 `decl_file_item` — the nine admissible alternatives.
                .import_decl,
                .fn_decl,
                .struct_decl,
                .enum_decl,
                .trait_decl,
                .impl_decl,
                .type_alias,
                .const_decl,
                .service_decl,
                // Admitted by the G1 amendment, see the note above.
                .event_decl,
                => true,
                // §20.2's twenty-one behavioural constructs.
                .rule_decl,
                .behavior_decl,
                .routine_decl,
                .quest_decl,
                .dialogue_decl,
                .ability_decl,
                .effect_decl,
                .shader_decl,
                .widget_decl,
                .theme_decl,
                .motion_decl,
                .locale_decl,
                .anim_graph_decl,
                .audio_graph_decl,
                .audio_score_decl,
                .sequence_decl,
                .data_decl,
                .scene_decl,
                .prefab_decl,
                .input_mapping_decl,
                .test_decl,
                => false,
                // The four §20.1 refuses and §20.2 does not name. `override` is
                // unreachable today (the keyword is reserved with no parser
                // path) and is named anyway: the switch's exhaustiveness is the
                // guarantee, and it cannot have holes on the ground that one
                // arm looks unreachable.
                .component_decl,
                .resource_decl,
                .tags_decl,
                .override_decl,
                => false,
            };
            if (allowed) continue;
            try self.emit(
                .construct_not_allowed_in_declaration_file,
                .error_,
                self.arena.itemSpan(item_id),
                "'{s}' is not allowed in a declaration file (.d.etch carries signatures and types only)",
                .{@tagName(k)},
            );
        }
    }

    /// Index every `service` this check can see (M1.1.15.2 G1). With a
    /// `ProjectContext` the index spans the whole project — which is the real
    /// case, since a service is declared in a `.d.etch` and called from a
    /// `.etch` — and `project.arenas` already contains this file, so the
    /// single-arena fallback is for the standalone `check` entry point only.
    ///
    /// A duplicate service name keeps the FIRST and reports E0101, the same
    /// arbitration `pass1Collect` applies to every other global symbol.
    fn collectServices(self: *TypeChecker) !void {
        if (self.project) |proj| {
            for (proj.arenas) |*a| try self.indexServicesOf(a);
        } else {
            try self.indexServicesOf(self.arena);
        }
    }

    /// Index every `event` a project `.d.etch` declares (M1.1.15.2 G4). Runs
    /// with `collectServices` and over the same arenas, bounded to declaration
    /// files: an `event` in an ordinary `.etch` already resolves through
    /// `symbols`, and shadowing that path would change behaviour no gate asked
    /// to change.
    fn collectDeclaredEvents(self: *TypeChecker) !void {
        const proj = self.project orelse return;
        for (proj.arenas) |*a| {
            if (a.mode != .declaration_file) continue;
            const kinds = a.items.items(.kind);
            const datas = a.items.items(.data);
            for (kinds, 0..) |k, i| {
                if (k != .event_decl) continue;
                const decl = a.event_decls.items[datas[i]];
                const name = a.strings.slice(decl.name);
                const gop = try self.foreign_events.getOrPut(self.gpa, name);
                if (gop.found_existing) {
                    const span = a.itemSpan(.{ .category = .item, .index = @intCast(i) });
                    try self.emit(.duplicate_symbol, .error_, span, "duplicate declared event '{s}'", .{name});
                    continue;
                }
                gop.value_ptr.* = .{ .arena = a, .decl = decl };
            }
        }
    }

    /// The `.d.etch`-declared event of that name, if any. Looked up by BYTES,
    /// since the caller's `StringId` and the declaration's belong to different
    /// pools.
    fn declaredEvent(self: *const TypeChecker, name_id: StringId) ?ForeignEvent {
        return self.foreign_events.get(self.arena.strings.slice(name_id));
    }

    fn indexServicesOf(self: *TypeChecker, a: *const AstArena) !void {
        const kinds = a.items.items(.kind);
        const datas = a.items.items(.data);
        for (kinds, 0..) |k, i| {
            if (k != .service_decl) continue;
            const decl = a.service_decls.items[datas[i]];
            const name = a.strings.slice(decl.name);
            const span = a.itemSpan(.{ .category = .item, .index = @intCast(i) });
            const gop = try self.services.getOrPut(self.gpa, name);
            if (gop.found_existing) {
                try self.emit(.duplicate_symbol, .error_, span, "duplicate service '{s}'", .{name});
                continue;
            }
            gop.value_ptr.* = .{ .arena = a, .decl = decl, .span = span };
        }
    }

    /// Resolve `svc.method(args)` against a declared `service` (M1.1.15.2 G1).
    /// Names and arity only — this gate owns the RESOLUTION; the runtime
    /// dispatch is G2's and the argument-type confrontation needs the foreign
    /// arena's type nodes, bounded below.
    fn checkServiceCall(
        self: *TypeChecker,
        id: NodeId,
        mc: ast_mod.MethodCall,
        svc: ServiceEntry,
        ctx_opt: ?*RuleCtx,
    ) TypeError!ResolvedType {
        const method_slice = self.arena.strings.slice(mc.method_name);
        const svc_slice = self.arena.strings.slice(self.arena.exprData(mc.receiver));

        var found: ?ast_mod.FnDecl = null;
        var mi: u32 = 0;
        while (mi < svc.decl.methods_len) : (mi += 1) {
            const m = svc.arena.impl_methods.items[svc.decl.methods_start + mi];
            // Compared BY BYTES: the two `StringId`s belong to different pools.
            if (std.mem.eql(u8, svc.arena.strings.slice(m.name), method_slice)) {
                found = m;
                break;
            }
        }

        // Arguments are synthesised whatever the outcome, so an error inside an
        // argument is reported even when the method name is wrong — the same
        // discipline `checkMethodArgs` follows.
        var ai: u32 = 0;
        while (ai < mc.args_len) : (ai += 1) {
            _ = try self.synthExprE(@bitCast(self.arena.extra.items[mc.args_start + ai]), ctx_opt);
        }

        const method = found orelse {
            try self.emit(
                .undefined_symbol,
                .error_,
                self.arena.exprSpan(id),
                "service '{s}' declares no method '{s}'",
                .{ svc_slice, method_slice },
            );
            return ResolvedType.unknown;
        };

        if (method.throws and !self.current_can_throw) {
            try self.emitUnhandledThrows(id, method_slice);
        }

        if (mc.args_len != method.params_len) {
            try self.emit(
                .arg_count_mismatch,
                .error_,
                self.arena.exprSpan(id),
                "service method '{s}.{s}' takes {d} argument(s), {d} given",
                .{ svc_slice, method_slice, method.params_len, mc.args_len },
            );
            return ResolvedType.unknown;
        }

        return self.foreignReturnType(svc.arena, method);
    }

    /// One message for `E0902`, shared by the free-fn and the service call site
    /// so the two cannot drift. A rule is named explicitly because it is the
    /// case a user meets: `etch-abi-zig.md` §8.7 records that a rule cannot be
    /// `throws` (E0903), so a fallible service call in a rule ALWAYS needs a
    /// local `try`/`catch` — the assumed consequence of the rule forbidding an
    /// entry to swallow a failure, not a defect of the path.
    fn emitUnhandledThrows(self: *TypeChecker, id: NodeId, callee: []const u8) TypeError!void {
        try self.emit(
            .unhandled_throws_call,
            .error_,
            self.arena.exprSpan(id),
            "'{s}' can throw — wrap the call in a `try`/`catch`, or declare the enclosing fn `throws` (a rule can never be `throws`)",
            .{callee},
        );
    }

    /// The return type of a foreign-arena signature, resolved BY BYTES.
    ///
    /// Bounded to builtins on purpose, and the bound is inherited rather than
    /// invented: M1.0.7 settled the same question for cross-arena field types
    /// and recorded "builtin-typed-only; named foreign field types are a
    /// documented residual". Resolving a named foreign type here would mean
    /// re-keying `symbols` and `generic_scope`, which are `StringId` maps over
    /// THIS arena's pool. A named return type therefore types as `unknown`,
    /// which is permissive and never wrong — it is the same value every
    /// unresolved expression carries.
    /// A foreign arena's declared field type, resolved BY BYTES. Same bound and
    /// same reason as `foreignReturnType`.
    fn foreignFieldType(self: *TypeChecker, a: *const AstArena, type_node: NodeId) ResolvedType {
        _ = self;
        if (a.typeNodeKind(type_node) != .named) return ResolvedType.unknown;
        const named = a.named_types.items[a.typeNodeData(type_node)];
        const tname = a.strings.slice(a.resolveTypeAliasName(named.name));
        if (std.mem.eql(u8, tname, "string")) return .{ .builtin = .string_ };
        if (BuiltinType.fromName(tname)) |bt| return .{ .builtin = bt };
        return ResolvedType.unknown;
    }

    fn foreignReturnType(self: *TypeChecker, a: *const AstArena, method: ast_mod.FnDecl) ResolvedType {
        _ = self;
        // A void signature (`fn stop(h: AudioHandle)`) types as `unknown` —
        // "`unknown` ≈ unit, the house convention" (this file, `synthCall`).
        // `ResolvedType` has no unit variant to return instead.
        if (method.return_type.isNone()) return ResolvedType.unknown;
        if (a.typeNodeKind(method.return_type) != .named) return ResolvedType.unknown;
        const named = a.named_types.items[a.typeNodeData(method.return_type)];
        const tname = a.strings.slice(a.resolveTypeAliasName(named.name));
        if (std.mem.eql(u8, tname, "string")) return .{ .builtin = .string_ };
        if (BuiltinType.fromName(tname)) |bt| return .{ .builtin = bt };
        return ResolvedType.unknown;
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
            // M1.0.16 — a qualified `.path` target (`type HA = m.Member`) is
            // the use site for the whole-module import: unlike selective import
            // (diagnosed at the `import { … }` binding), a whole-module import
            // names no members, so E0104 (absent) / E0107 (private) fire HERE.
            // A resolved component/resource is a valid alias target (selective
            // parity); struct/enum/non-type resolve to E0102 exactly as a
            // selective `type HB = ImportedStruct` does today.
            if (self.arena.typeNodeKind(decl.target) == .path) {
                const path = self.arena.path_types.items[self.arena.typeNodeData(decl.target)];
                const tspan = self.arena.typeNodeSpan(decl.target);
                switch (self.resolvePathTypeNode(decl.target)) {
                    .resolved => |t| switch (t) {
                        .component, .resource => {},
                        else => try self.emit(.undefined_symbol, .error_, tspan, "type alias '{s}' does not resolve to a known type", .{self.arena.strings.slice(decl.name)}),
                    },
                    .member_absent => try self.emit(.unknown_export, .error_, tspan, "'{s}' is not exported by the aliased module", .{self.arena.strings.slice(path.member)}),
                    .member_private => try self.emit(.import_private_item, .error_, tspan, "'{s}' is private to the aliased module", .{self.arena.strings.slice(path.member)}),
                    .alias_unresolved => try self.emit(.undefined_symbol, .error_, tspan, "'{s}' is not a module alias in scope", .{self.arena.strings.slice(path.alias)}),
                }
                continue;
            }
            const ultimate = self.arena.resolveTypeAliasName(decl.name);
            const uname = self.arena.strings.slice(ultimate);
            if (BuiltinType.fromName(uname) != null) continue;
            if (self.symbols.get(ultimate)) |sym| {
                if (sym.kind == .component or sym.kind == .resource) continue;
            }
            // M1.0.7 E6 — the alias target may be a selectively-imported type.
            if (self.imported_symbols.get(ultimate)) |entry| {
                if (entry.kind == .component or entry.kind == .resource) continue;
            }
            try self.emit(.undefined_symbol, .error_, self.arena.typeNodeSpan(decl.target), "type alias '{s}' does not resolve to a known type", .{self.arena.strings.slice(decl.name)});
        }
    }

    // ─── Data tables (M0.8 E4, `etch-validation-ecs.md` §22) ─────────────

    /// Identity of one `(table, entry)` pair for the spread graph.
    const DataEntryRef = struct { table: u32, entry: u32 };

    /// Validate every `data` table once all symbols are known (M0.8 E4):
    /// E1760 empty table, E1761 duplicate entry ids, E1762 entry-type /
    /// spread-type mismatch, E1763 unknown entry field, E1764 field value
    /// type, E1765 required field missing (spread-less entries only — a
    /// same-type spread chain provides every field of its source), E1766
    /// spread reference, E1767 spread cycles (DFS), E1768 id format
    /// (snake_case IDENT). Runs between pass 1 and pass 2 — entry values are
    /// self-contained const-shaped expressions typed with no rule context.
    fn validateDataDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .data_decl) continue;
            const table_idx = datas[i];
            try self.validateDataTable(table_idx);
        }
        // Spread cycle detection (E1767) over the cross-table entry graph,
        // after per-entry validation so unresolved spreads are already
        // reported (the DFS resolves quietly and skips them).
        var visiting: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer visiting.deinit(self.gpa);
        var done: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer done.deinit(self.gpa);
        i = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .data_decl) continue;
            const table_idx = datas[i];
            const decl = self.arena.data_decls.items[table_idx];
            var e: u32 = 0;
            while (e < decl.entries_len) : (e += 1) {
                try self.dataSpreadDfs(.{ .table = table_idx, .entry = decl.entries_start + e }, &visiting, &done);
            }
        }
    }

    // ─── Theme (M0.8 E5, `etch-grammar.md` §10.2) ────────────────────────

    /// Validate every `theme` (M0.8 E5 Level B presentation): E1640 empty
    /// (no entries), E1641 duplicate entry key. The grammar shape (string
    /// name, untyped `key: expression` entries) WINS over validation-ecs
    /// §16.1 (E5 ruling 1); E1642 TokenTypeInvalid / E1643 TokenDefaultMissing
    /// are RESERVED (no typed tokens / defaults exist in the grammar shape).
    /// Entry values are structural — no §16 code requires resolution.
    /// `@custom` is the only valid annotation (validateAnnotations).
    fn validateThemeDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .theme_decl) continue;
            const decl = self.arena.theme_decls.items[datas[i]];
            try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .theme);
            if (decl.entries_len == 0) {
                try self.emit(.theme_empty, .error_, decl.name_span, "theme '{s}' has no entries (at least one required)", .{self.arena.strings.slice(decl.name)});
                continue;
            }
            var seen: std.AutoHashMapUnmanaged(StringId, void) = .empty;
            defer seen.deinit(self.gpa);
            var e: u32 = 0;
            while (e < decl.entries_len) : (e += 1) {
                const entry = self.arena.theme_entries.items[decl.entries_start + e];
                const gop = try seen.getOrPut(self.gpa, entry.key);
                if (gop.found_existing) {
                    try self.emit(.duplicate_token_name, .error_, entry.span, "duplicate theme entry key '{s}'", .{self.arena.strings.slice(entry.key)});
                }
            }
        }
    }

    // ─── Motion (M0.8 E5, `etch-grammar.md` §10.3) ───────────────────────

    /// Easing catalogue (`etch-reference-part2.md` §22 "Easings disponibles").
    /// E1666 TransitionEasingUnknown checks the easing identifier against this
    /// closed set — read from the spec, NOT guessed: the validation-ecs §17
    /// illustrative list "{…, custom_bezier, …}" is not exhaustive, part2 §22
    /// is the canonical enumeration of available easings.
    const motion_easings = [_][]const u8{
        "linear",          "ease_in",       "ease_out",        "ease_in_out",
        "ease_in_quad",    "ease_out_quad", "ease_in_cubic",   "ease_out_cubic",
        "ease_in_back",    "ease_out_back", "ease_in_elastic", "ease_out_elastic",
        "ease_out_bounce", "spring",
    };

    fn isKnownEasing(name: []const u8) bool {
        for (motion_easings) |e| {
            if (std.mem.eql(u8, e, name)) return true;
        }
        return false;
    }

    /// Validate every `motion` (M0.8 E5 Level B presentation): E1661 duplicate
    /// state name, E1664 transition source/target not a declared state, E1665
    /// transition duration not a positive numeric/duration, E1666 unknown
    /// easing. E1660/E1662/E1663/E1667/E1668 are RESERVED (E5 ruling 2 — the
    /// diagnostics catalogue carries the rationale). State / keyframe field
    /// values are STRUCTURAL — never resolved (no §17 code requires it; the
    /// canonical text is the proof artifact). The grammar §10.3 shape WINS
    /// over the validation-ecs §17 shape.
    fn validateMotionDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .motion_decl) continue;
            try self.validateMotion(self.arena.motion_decls.items[datas[i]]);
        }
    }

    fn validateMotion(self: *TypeChecker, decl: ast_mod.MotionDecl) !void {
        // E1661 — duplicate state names; the set also backs E1664.
        var states: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer states.deinit(self.gpa);
        var s: u32 = 0;
        while (s < decl.states_len) : (s += 1) {
            const st = self.arena.motion_states.items[decl.states_start + s];
            const gop = try states.getOrPut(self.gpa, st.name);
            if (gop.found_existing) {
                try self.emit(.motion_duplicate_state_name, .error_, st.span, "duplicate motion state '{s}'", .{self.arena.strings.slice(st.name)});
            }
        }
        // Transitions: E1664 source/target reference a declared state (or `*`);
        // E1665/E1666 on the animator (recursive through `stagger`).
        var t: u32 = 0;
        while (t < decl.transitions_len) : (t += 1) {
            const tr = self.arena.motion_transitions.items[decl.transitions_start + t];
            if (!tr.source_wildcard and !states.contains(tr.source)) {
                try self.emit(.transition_state_not_found, .error_, tr.span, "transition source '{s}' is not a declared motion state", .{self.arena.strings.slice(tr.source)});
            }
            if (!tr.target_wildcard and !states.contains(tr.target)) {
                try self.emit(.transition_state_not_found, .error_, tr.span, "transition target '{s}' is not a declared motion state", .{self.arena.strings.slice(tr.target)});
            }
            try self.validateMotionAnimator(tr.animator, tr.span);
        }
    }

    /// Validate one animator (recursive through `stagger`). E1665 — the
    /// duration (animate 1st arg / keyframes over-duration / stagger delay)
    /// must be a positive numeric or duration expression (the ability cooldown
    /// E1582 precedent: `synthExprE` types it, a negative literal is rejected;
    /// Level-A reference validated, never executed). E1666 — the easing
    /// (animate 2nd arg / keyframes trailing) must be an identifier in the
    /// part2 §22 catalogue; it is NOT synthesized (easing names are not
    /// declared symbols — synthesizing would emit a spurious E0102).
    fn validateMotionAnimator(self: *TypeChecker, animator_idx: u32, span: SourceSpan) !void {
        const a = self.arena.motion_animators.items[animator_idx];
        var ctx: RuleCtx = .{};
        defer ctx.deinit(self.gpa);
        const dur_t = try self.synthExprE(a.duration, &ctx);
        const dur_numeric = dur_t == .builtin and (dur_t.builtin.isNumeric() or dur_t.builtin == .duration);
        const dur_neg = self.arena.exprKind(a.duration) == .unary and
            self.arena.unary_exprs.items[self.arena.exprData(a.duration)].op == .neg;
        if (!dur_numeric or dur_neg) {
            try self.emit(.transition_duration_invalid, .error_, span, "motion transition duration must be a positive duration or numeric expression", .{});
        }
        if (!a.easing.isNone()) {
            const is_ident = self.arena.exprKind(a.easing) == .ident;
            if (!is_ident or !isKnownEasing(self.arena.strings.slice(self.arena.exprData(a.easing)))) {
                try self.emit(.transition_easing_unknown, .error_, span, "unknown easing function (expected one of the etch-reference-part2 §22 easings)", .{});
            }
        }
        if (a.kind == .stagger) {
            try self.validateMotionAnimator(a.inner, span);
        }
    }

    // ─── Input mapping (M0.8 E5 Level B STRICT, `etch-grammar.md` §16) ────

    /// Modifier catalogue (`etch-grammar.md` §16 l.1752) — E1804 ModifierTypeUnknown.
    const input_modifiers = [_][]const u8{
        "threshold",     "deadzone",         "deadzone_radial", "sensitivity",
        "invert",        "clamp",            "linear_ramp",     "negate_when_held",
        "swizzle",       "to_world_space",   "smooth",          "stick_emulated",
        "axis_emulated", "quantize_to_grid",
    };

    /// Trigger catalogue (`etch-grammar.md` §16 l.1754) — E1805 TriggerTypeUnknown.
    const input_triggers = [_][]const u8{
        "on_press", "on_release", "on_hold", "on_tap", "on_double_tap", "on_chord",
    };

    const InputCatalog = enum { modifier, trigger };

    fn isInCatalog(comptime catalog: []const []const u8, name: []const u8) bool {
        for (catalog) |e| {
            if (std.mem.eql(u8, e, name)) return true;
        }
        return false;
    }

    /// Validate every `input_mapping` (M0.8 E5 Level B STRICT — NO input
    /// execution): E1800 MappingEmpty (no action AND no combo), E1801
    /// DuplicateActionName, E1804/E1805 modifier/trigger arrays vs the §16
    /// catalogues, E1806 PriorityInvalid (non-negative INT_LITERAL — the
    /// accepted surface is the §16 EBNF; the permissive parse only enables clean
    /// diagnostics), E1808 ComboTimingInvalid (window = positive duration, the
    /// motion-duration precedent). E1802/W1801/E1807 RESERVED, E1803 DEFERRED
    /// (the diagnostics catalogue carries the rationale). `context` (a tag path),
    /// `consume_input`, bind sources, modifier/trigger expr args, and combo
    /// `sequence` tokens are STRUCTURAL — never resolved (no §25 code requires
    /// it; pass2 does not walk input_mapping). STRING-named → no symbol.
    fn validateInputMappingDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .input_mapping_decl) continue;
            try self.validateInputMapping(self.arena.input_mapping_decls.items[datas[i]]);
        }
    }

    fn validateInputMapping(self: *TypeChecker, decl: ast_mod.InputMappingDecl) !void {
        try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .input_mapping);
        if (decl.actions_len == 0 and decl.combos_len == 0) {
            try self.emit(.mapping_empty, .error_, decl.name_span, "input_mapping '{s}' declares no action and no combo", .{self.arena.strings.slice(decl.name)});
        }
        // E1806 — priority is a non-negative INT_LITERAL (a negative parses as
        // `unary .neg`, not `.int_lit`, so it is caught by the kind check).
        if (!decl.priority.isNone() and self.arena.exprKind(decl.priority) != .int_lit) {
            try self.emit(.priority_invalid, .error_, self.arena.exprSpan(decl.priority), "priority must be a non-negative integer literal (etch-grammar.md §16: priority : INT_LITERAL)", .{});
        }
        // E1801 — duplicate action names; E1804/E1805 per bind.
        var seen: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer seen.deinit(self.gpa);
        var a: u32 = 0;
        while (a < decl.actions_len) : (a += 1) {
            const action = self.arena.input_actions.items[decl.actions_start + a];
            const gop = try seen.getOrPut(self.gpa, action.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_action_name, .error_, action.span, "duplicate input action '{s}'", .{self.arena.strings.slice(action.name)});
            }
            var b: u32 = 0;
            while (b < action.binds_len) : (b += 1) {
                const bind = self.arena.input_binds.items[action.binds_start + b];
                if (!bind.modifiers.isNone()) try self.validateInputCatalogArray(bind.modifiers, .modifier);
                if (!bind.triggers.isNone()) try self.validateInputCatalogArray(bind.triggers, .trigger);
            }
        }
        // E1808 — combo window is a positive duration (the motion-duration
        // precedent). E1807 RESERVED: the §16 `sequence` tokens are structural.
        var c: u32 = 0;
        while (c < decl.combos_len) : (c += 1) {
            const combo = self.arena.input_combos.items[decl.combos_start + c];
            if (!combo.window.isNone()) {
                var ctx: RuleCtx = .{};
                defer ctx.deinit(self.gpa);
                const t = try self.synthExprE(combo.window, &ctx);
                const numeric = t == .builtin and (t.builtin.isNumeric() or t.builtin == .duration);
                const neg = self.arena.exprKind(combo.window) == .unary and
                    self.arena.unary_exprs.items[self.arena.exprData(combo.window)].op == .neg;
                if (!numeric or neg) {
                    try self.emit(.combo_timing_invalid, .error_, combo.span, "combo window must be a positive duration", .{});
                }
            }
        }
    }

    /// E1804/E1805 — each element of a `modifiers`/`triggers` array_literal must
    /// be a catalogue entry, identified by the element's name (a bare ident, or
    /// the callee of a `name(args)` form like `deadzone_radial(0.15)`). The
    /// elements are NOT synthesized (modifier/trigger names are not declared
    /// symbols — synthesizing would emit a spurious E0102; the structural name
    /// is checked against the §16 catalogue).
    fn validateInputCatalogArray(self: *TypeChecker, node: NodeId, catalog: InputCatalog) !void {
        if (self.arena.exprKind(node) != .array_lit) return; // not an array — nothing to catalogue-check
        const al = self.arena.array_lits.items[self.arena.exprData(node)];
        if (al.is_fill) return;
        var i: u32 = 0;
        while (i < al.elements_len) : (i += 1) {
            const elem: NodeId = @bitCast(self.arena.extra.items[al.elements_start + i]);
            const name_opt = self.inputCatalogElementName(elem);
            const known = if (name_opt) |name| switch (catalog) {
                .modifier => isInCatalog(&input_modifiers, name),
                .trigger => isInCatalog(&input_triggers, name),
            } else false;
            if (!known) {
                switch (catalog) {
                    .modifier => try self.emit(.modifier_type_unknown, .error_, self.arena.exprSpan(elem), "unknown input modifier (expected one of the etch-grammar.md §16 modifiers)", .{}),
                    .trigger => try self.emit(.trigger_type_unknown, .error_, self.arena.exprSpan(elem), "unknown input trigger (expected one of the etch-grammar.md §16 triggers)", .{}),
                }
            }
        }
    }

    /// The catalogue name of a modifier/trigger array element: a bare ident
    /// (`invert`, `on_press`) or the callee of a call (`deadzone(0.2)`,
    /// `on_hold(0.1s)`). Anything else → `null` (unknown).
    fn inputCatalogElementName(self: *TypeChecker, elem: NodeId) ?[]const u8 {
        return switch (self.arena.exprKind(elem)) {
            .ident => self.arena.strings.slice(self.arena.exprData(elem)),
            .fn_call => blk: {
                const call = self.arena.call_exprs.items[self.arena.exprData(elem)];
                if (self.arena.exprKind(call.callee) != .ident) break :blk null;
                break :blk self.arena.strings.slice(self.arena.exprData(call.callee));
            },
            else => null,
        };
    }

    fn validateWidgetDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .widget_decl) continue;
            try self.validateWidget(self.arena.widget_decls.items[datas[i]]);
        }
    }

    fn validateWidget(self: *TypeChecker, decl: ast_mod.WidgetDecl) !void {
        // E1620 — the tree must contain at least one ui_element.
        if (decl.tree_len == 0) {
            try self.emit(.widget_empty_tree, .error_, decl.name_span, "widget '{s}' has an empty tree (at least one ui_element required)", .{self.arena.strings.slice(decl.name)});
        }
        // E1621 — `@screen` and `@worldspace` are `.custom`-kind annotations
        // (NOT in AnnotationKind), distinguished by name; they are mutually
        // exclusive. This is the ONLY enforced placement rule — a widget with
        // no placement annotation is grammar-valid (E1622 RESERVED, ruling 9).
        var has_screen = false;
        var has_worldspace = false;
        var conflict_span = decl.name_span;
        var i: u32 = 0;
        while (i < decl.annotations_len) : (i += 1) {
            const annot = self.arena.annot_pool.items[decl.annotations_extra + i];
            const aname = self.arena.strings.slice(annot.name);
            if (std.mem.eql(u8, aname, "screen")) {
                has_screen = true;
                conflict_span = annot.span;
            } else if (std.mem.eql(u8, aname, "worldspace")) {
                has_worldspace = true;
                conflict_span = annot.span;
            }
        }
        if (has_screen and has_worldspace) {
            try self.emit(.widget_screen_worldspace_conflict, .error_, conflict_span, "widget '{s}' has both @screen and @worldspace annotations (mutually exclusive)", .{self.arena.strings.slice(decl.name)});
        }
    }

    fn validateLocaleDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .locale_decl) continue;
            try self.validateLocale(self.arena.locale_decls.items[datas[i]]);
        }
    }

    fn validateLocale(self: *TypeChecker, decl: ast_mod.LocaleDecl) !void {
        const code = self.arena.strings.slice(decl.name);
        // E1821 — the name must be a well-formed ISO-639 code (FORM check, not
        // an embedded code table — E5 ruling 4).
        if (!isValidLocaleCode(code)) {
            try self.emit(.locale_code_invalid, .error_, decl.name_span, "locale code '{s}' is not a well-formed ISO-639 code (2-3 lowercase letters, optional regional variant)", .{code});
        }
        // E1820 — at least one entry.
        if (decl.entries_len == 0) {
            try self.emit(.locale_empty, .error_, decl.name_span, "locale '{s}' has no entries (at least one required)", .{code});
            return;
        }
        // E1822 — keys unique within the locale.
        var seen: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer seen.deinit(self.gpa);
        var e: u32 = 0;
        while (e < decl.entries_len) : (e += 1) {
            const entry = self.arena.locale_entries.items[decl.entries_start + e];
            const gop = try seen.getOrPut(self.gpa, entry.key);
            if (gop.found_existing) {
                try self.emit(.locale_duplicate_key, .error_, entry.span, "duplicate locale key '{s}'", .{self.arena.strings.slice(entry.key)});
            }
        }
    }

    /// ISO-639 FORM check (E5 ruling 4): a 2-3 lowercase-letter language subtag,
    /// optionally followed by a `-` / `_` regional variant of exactly 2
    /// uppercase letters (e.g. `en`, `fr`, `zh`, `pt_BR`, `zh-CN`). Validates the
    /// SHAPE only — membership in an actual code table is the i18n / extractor
    /// tool's job, NOT an embedded table here.
    fn isValidLocaleCode(code: []const u8) bool {
        var lang_len: usize = 0;
        while (lang_len < code.len and code[lang_len] >= 'a' and code[lang_len] <= 'z') : (lang_len += 1) {}
        if (lang_len < 2 or lang_len > 3) return false;
        const rest = code[lang_len..];
        if (rest.len == 0) return true;
        // Optional regional variant: separator + exactly 2 uppercase letters.
        if (rest[0] != '-' and rest[0] != '_') return false;
        const region = rest[1..];
        if (region.len != 2) return false;
        for (region) |c| {
            if (c < 'A' or c > 'Z') return false;
        }
        return true;
    }

    fn validateEffectDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .effect_decl) continue;
            try self.validateEffect(self.arena.effect_decls.items[datas[i]]);
        }
    }

    /// `effect` validations (M0.8 E6, `etch-validation-ecs.md` §13). DELIVER the
    /// structural checks; the Ember-semantic ones (E1602/E1603/E1605/E1606/
    /// W1600/W1601) are DEFERRED-no-variant (catalogue not attached).
    fn validateEffect(self: *TypeChecker, decl: ast_mod.EffectDecl) !void {
        // E1601 — emitter names unique within the effect; the set also backs E1604.
        var emitters: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer emitters.deinit(self.gpa);
        var e: u32 = 0;
        while (e < decl.emitters_len) : (e += 1) {
            const em = self.arena.effect_emitters.items[decl.emitters_start + e];
            const gop = try emitters.getOrPut(self.gpa, em.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_emitter_name, .error_, em.span, "duplicate emitter '{s}' in this effect", .{self.arena.strings.slice(em.name)});
            }
        }
        // E1600 — at least one emitter required.
        if (decl.emitters_len == 0) {
            try self.emit(.effect_empty_emitters, .error_, decl.name_span, "effect '{s}' has no emitter (at least one required)", .{self.arena.strings.slice(decl.name)});
        }
        // E1604 — every `on Emitter.event` handler references a declared emitter.
        var h: u32 = 0;
        while (h < decl.handlers_len) : (h += 1) {
            const handler = self.arena.effect_event_handlers.items[decl.handlers_start + h];
            if (!emitters.contains(handler.emitter)) {
                try self.emit(.emitter_ref_not_found, .error_, handler.span, "event handler references '{s}', which is not an emitter of this effect", .{self.arena.strings.slice(handler.emitter)});
            }
        }
    }

    fn validateAudioScoreDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .audio_score_decl) continue;
            try self.validateAudioScore(self.arena.audio_score_decls.items[datas[i]]);
        }
    }

    /// `audio_score` validations (M0.8 E6, `etch-validation-ecs.md` §20 reshaped
    /// onto the grammar §12.1 shape — grammar wins). DELIVER E1720 (reshaped:
    /// "no section AND no stems"), E1721 DuplicateSectionName, E1722
    /// DuplicateStemName, E1726 (rekeyed onto can_transition_to / on_finish
    /// section-name targets), E1728 TempoInvalid. RESERVED-with-variant: E1724
    /// StemActiveUnknown (no `stems_active` in this shape) / E1725
    /// SectionDurationInvalid (no `duration` prop). DEFERRED-no-variant: E1723 /
    /// E1727 / W1720 / W1721 (asset + transition-point catalogues, heuristics).
    fn validateAudioScore(self: *TypeChecker, decl: ast_mod.AudioScoreDecl) !void {
        try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .audio_score);

        // E1720 — a score needs at least one section OR one stem.
        if (decl.sections_len == 0 and decl.stems_len == 0) {
            try self.emit(.score_no_sections, .error_, decl.name_span, "audio_score '{s}' has no section and no stems (at least one required)", .{self.arena.strings.slice(decl.name)});
        }

        // E1721 — section names unique; the set also backs E1726.
        var sections: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer sections.deinit(self.gpa);
        var s: u32 = 0;
        while (s < decl.sections_len) : (s += 1) {
            const sec = self.arena.audio_score_sections.items[decl.sections_start + s];
            const gop = try sections.getOrPut(self.gpa, sec.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_section_name, .error_, sec.span, "duplicate audio_score section '{s}'", .{self.arena.strings.slice(sec.name)});
            }
        }

        // E1726 — every can_transition_to / on_finish target references a
        // declared section.
        s = 0;
        while (s < decl.sections_len) : (s += 1) {
            const sec = self.arena.audio_score_sections.items[decl.sections_start + s];
            var t: u32 = 0;
            while (t < sec.can_transition_len) : (t += 1) {
                const target = self.arena.audio_score_targets.items[sec.can_transition_start + t];
                if (!sections.contains(target)) {
                    try self.emit(.score_transition_from_not_found, .error_, sec.span, "can_transition_to references '{s}', which is not a section of this audio_score", .{self.arena.strings.slice(target)});
                }
            }
            if (sec.has_on_finish and !sections.contains(sec.on_finish)) {
                try self.emit(.score_transition_from_not_found, .error_, sec.span, "on_finish references '{s}', which is not a section of this audio_score", .{self.arena.strings.slice(sec.on_finish)});
            }
        }

        // E1722 — stem names unique.
        var stems: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer stems.deinit(self.gpa);
        var st: u32 = 0;
        while (st < decl.stems_len) : (st += 1) {
            const stem = self.arena.audio_score_stems.items[decl.stems_start + st];
            const gop = try stems.getOrPut(self.gpa, stem.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_stem_name, .error_, stem.span, "duplicate audio_score stem '{s}'", .{self.arena.strings.slice(stem.name)});
            }
        }

        // E1728 — `tempo` (if present) must be a positive integer literal (BPM).
        var p: u32 = 0;
        while (p < decl.props_len) : (p += 1) {
            const prop = self.arena.struct_lit_fields.items[decl.props_start + p];
            if (std.mem.eql(u8, self.arena.strings.slice(prop.name), "tempo")) {
                if (self.arena.exprKind(prop.value) != .int_lit) {
                    try self.emit(.tempo_invalid, .error_, decl.name_span, "audio_score tempo must be a positive integer (BPM)", .{});
                }
            }
        }
    }

    fn validateSequenceDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .sequence_decl) continue;
            try self.validateSequence(self.arena.sequence_decls.items[datas[i]]);
        }
    }

    /// `sequence` validations (M0.8 E6, `etch-validation-ecs.md` §21). DELIVER
    /// E1740 SequenceNoTracks, E1741 DuplicateTrackName, E1742 TrackTypeUnknown
    /// (catalogue inlined), E1744 KeyframeOutOfRange + E1745 KeyframesUnordered
    /// (keyframe DURATION_LIT seconds, validation-time parse — distinct from the
    /// deferred RUNTIME duration eval), E1746 EventTrackEventUnknown, E1749
    /// FPSInvalid, E1750 DurationInvalid, W1740 EmptyTrack. RESERVED-with-variant:
    /// E1748 SubSequenceRefInvalid (the grammar §13 has no sub-sequence-ref
    /// production — grammar-wins, so it can never fire). DEFERRED-no-variant:
    /// E1743 TrackTargetNotFound (scene/binding resolution is E7), E1747
    /// AnimationTrackClipInvalid (asset), W1741 OverlappingTracks (heuristic).
    fn validateSequence(self: *TypeChecker, decl: ast_mod.SequenceDecl) !void {
        // E1749 fps + E1750 duration positivity; capture duration (seconds) for E1744.
        var duration_secs: ?f64 = null;
        var p: u32 = 0;
        while (p < decl.props_len) : (p += 1) {
            const prop = self.arena.struct_lit_fields.items[decl.props_start + p];
            const pname = self.arena.strings.slice(prop.name);
            if (std.mem.eql(u8, pname, "duration")) {
                const v = numericLitValue(self.arena, prop.value);
                if (v == null or v.? <= 0) {
                    try self.emit(.sequence_duration_invalid, .error_, decl.name_span, "sequence duration must be a positive number", .{});
                } else duration_secs = v;
            } else if (std.mem.eql(u8, pname, "fps")) {
                const v = numericLitValue(self.arena, prop.value);
                if (v == null or v.? <= 0) {
                    try self.emit(.fps_invalid, .error_, decl.name_span, "sequence fps must be a positive number", .{});
                }
            }
        }

        // E1740 — at least one track.
        if (decl.tracks_len == 0) {
            try self.emit(.sequence_no_tracks, .error_, decl.name_span, "sequence '{s}' has no track (at least one required)", .{self.arena.strings.slice(decl.name)});
        }

        var tracks: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer tracks.deinit(self.gpa);
        var t: u32 = 0;
        while (t < decl.tracks_len) : (t += 1) {
            const track = self.arena.sequence_tracks.items[decl.tracks_start + t];
            // E1741 — unique track names.
            const gop = try tracks.getOrPut(self.gpa, track.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_track_name, .error_, track.span, "duplicate sequence track '{s}'", .{self.arena.strings.slice(track.name)});
            }
            // E1742 — track type in the §21.2 catalogue.
            if (!isKnownTrackType(self.arena.strings.slice(track.track_type))) {
                try self.emit(.track_type_unknown, .error_, track.span, "unknown sequence track type '{s}'", .{self.arena.strings.slice(track.track_type)});
            }
            // W1740 — empty track.
            if (track.keyframes_len == 0) {
                try self.emit(.empty_track, .warning, track.span, "sequence track '{s}' has no keyframe", .{self.arena.strings.slice(track.name)});
            }
            // Keyframes: E1744 range, E1745 chronological order, E1746 event ref.
            var prev: ?f64 = null;
            var k: u32 = 0;
            while (k < track.keyframes_len) : (k += 1) {
                const kf = self.arena.sequence_keyframes.items[track.keyframes_start + k];
                if (durationLitSeconds(self.arena, kf.time)) |secs| {
                    if (duration_secs) |d| {
                        if (secs > d) try self.emit(.keyframe_out_of_range, .error_, kf.span, "keyframe time exceeds the sequence duration", .{});
                    }
                    if (prev) |pv| {
                        if (secs < pv) try self.emit(.keyframes_unordered, .error_, kf.span, "sequence keyframes must be in chronological order", .{});
                    }
                    prev = secs;
                }
                if (kf.kind == .emit) {
                    const em = self.arena.emit_stmts.items[self.arena.stmtData(kf.value)];
                    const sym = self.symbols.get(em.event_type);
                    if (sym == null or sym.?.kind != .event_) {
                        try self.emit(.event_track_event_unknown, .error_, kf.span, "keyframe emits '{s}', which is not a declared event", .{self.arena.strings.slice(em.event_type)});
                    }
                }
            }
        }
    }

    /// The `anim_graph` param type catalogue (`etch-validation-ecs.md` §18.2 E1695,
    /// the common set inlined — the open `…` is treated as this fixed list for
    /// M0.8). All resolve to a `.named` type node.
    fn isKnownAnimParamType(self: *TypeChecker, type_node: NodeId) bool {
        if (self.arena.typeNodeKind(type_node) != .named) return false;
        const name = self.arena.strings.slice(self.arena.named_types.items[self.arena.typeNodeData(type_node)].name);
        const cat = [_][]const u8{ "bool", "float", "int", "i32", "u32", "f32", "f64", "Vec2", "Vec3", "Vec4", "Trajectory" };
        for (cat) |c| {
            if (std.mem.eql(u8, name, c)) return true;
        }
        return false;
    }

    fn validateAnimGraphDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .anim_graph_decl) continue;
            try self.validateAnimGraph(self.arena.anim_graph_decls.items[datas[i]]);
        }
    }

    /// `anim_graph` validations (M0.8 E6, `etch-validation-ecs.md` §18, grammar
    /// §11 shape). DELIVER E1680 AnimGraphEmptyStates, E1681 DuplicateStateName,
    /// E1682 StateBodyMissing (body_count == 0), E1683 StateBodyInvalid
    /// (body_count > 1), E1689 TransitionToNotFound (transition + on_finish
    /// targets), E1690 TransitionConditionNotBool (the §6 when-clause machinery
    /// over a params scope), E1695 ParamTypeInvalid (catalogue), W1680
    /// UnreachableState, W1681 DeadendState. RESERVED-with-variant (grammar shape
    /// makes them inexpressible): E1688 TransitionFromNotFound (from = enclosing
    /// state), E1691 TransitionDurationInvalid (no transition duration), E1692
    /// InitialStateMissing (initial = first declared state), E1694 LayerBlendInvalid
    /// (additive-flag only), W1682 RedundantWildcardTransition (no `*`).
    /// DEFERRED-no-variant: E1684/E1685/E1686/E1687 (clip/db/clip/bone assets),
    /// E1693 LayerMaskInvalid (Kinesis bone mask).
    fn validateAnimGraph(self: *TypeChecker, decl: ast_mod.AnimGraphDecl) !void {
        // E1695 + a params scope for the transition when-clause typing (E1690).
        var ctx: RuleCtx = .{ .unrestricted_ecs_access = true };
        defer ctx.deinit(self.gpa);
        var pi: u32 = 0;
        while (pi < decl.params_len) : (pi += 1) {
            const f = self.arena.fields.items[decl.params_start + pi];
            if (!self.isKnownAnimParamType(f.type_node)) {
                try self.emit(.anim_param_type_invalid, .error_, self.arena.typeNodeSpan(f.type_node), "anim_graph parameter type is not in the supported set (bool / int / float / Vec2-4 / Trajectory)", .{});
            }
            // Populate the scope (unknown-resolved params stay `.unknown`, which
            // the §6 machinery tolerates — no spurious undefined-symbol error).
            try ctx.locals.put(self.gpa, f.name, .{ .type_ = self.namedTypeToResolved(f.type_node), .is_mut = false });
        }

        // E1680 — at least one state.
        if (decl.states_len == 0) {
            try self.emit(.anim_graph_empty_states, .error_, decl.name_span, "anim_graph '{s}' has no state (at least one required)", .{self.arena.strings.slice(decl.name)});
            return;
        }

        // E1681 — state names unique; the set backs E1689 + W1680.
        var states: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer states.deinit(self.gpa);
        var s: u32 = 0;
        while (s < decl.states_len) : (s += 1) {
            const st = self.arena.anim_states.items[decl.states_start + s];
            const gop = try states.getOrPut(self.gpa, st.name);
            if (gop.found_existing) {
                try self.emit(.anim_duplicate_state_name, .error_, st.span, "duplicate anim_graph state '{s}'", .{self.arena.strings.slice(st.name)});
            }
        }

        // E1682/E1683/E1689/E1690/W1681 per state; collect reached targets for W1680.
        var reached: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer reached.deinit(self.gpa);
        s = 0;
        while (s < decl.states_len) : (s += 1) {
            const st = self.arena.anim_states.items[decl.states_start + s];
            if (st.body_count == 0) {
                try self.emit(.anim_state_body_missing, .error_, st.span, "anim_graph state '{s}' has no body (clip / motion_matching / chooser / warping / distance_matching / blend_space_2d)", .{self.arena.strings.slice(st.name)});
            } else if (st.body_count > 1) {
                try self.emit(.anim_state_body_invalid, .error_, st.span, "anim_graph state '{s}' has more than one animation body source", .{self.arena.strings.slice(st.name)});
            }
            var t: u32 = 0;
            while (t < st.transitions_len) : (t += 1) {
                const tr = self.arena.anim_transitions.items[st.transitions_start + t];
                if (!states.contains(tr.target)) {
                    try self.emit(.anim_transition_to_not_found, .error_, tr.span, "transition target '{s}' is not a declared anim_graph state", .{self.arena.strings.slice(tr.target)});
                }
                try reached.put(self.gpa, tr.target, {});
                if (tr.when_root != ast_mod.RuleDecl.none_when) {
                    try self.collectWhenConstruct(&ctx, tr.when_root, .anim_transition_condition_not_bool, "anim_graph transition");
                }
            }
            if (st.has_on_finish) {
                if (!states.contains(st.on_finish)) {
                    try self.emit(.anim_transition_to_not_found, .error_, st.span, "on_finish target '{s}' is not a declared anim_graph state", .{self.arena.strings.slice(st.on_finish)});
                }
                try reached.put(self.gpa, st.on_finish, {});
            }
            // W1681 — a state with no outgoing transition and no on_finish.
            if (st.transitions_len == 0 and !st.has_on_finish) {
                try self.emit(.anim_deadend_state, .warning, st.span, "anim_graph state '{s}' has no outgoing transition", .{self.arena.strings.slice(st.name)});
            }
        }

        // W1680 — a non-initial state (initial = first declared) reached by nothing.
        s = 1;
        while (s < decl.states_len) : (s += 1) {
            const st = self.arena.anim_states.items[decl.states_start + s];
            if (!reached.contains(st.name)) {
                try self.emit(.anim_unreachable_state, .warning, st.span, "anim_graph state '{s}' is not the initial state and is not a transition target", .{self.arena.strings.slice(st.name)});
            }
        }
    }

    fn validateShaderDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .shader_decl) continue;
            try self.validateShader(self.arena.shader_decls.items[datas[i]]);
        }
    }

    /// `shader` SHADER-MODE validation (M0.8 E6, resolver §15). The `fragment`
    /// stage is parser-mandatory and `vertex` optional, so E1610 ShaderStageMissing
    /// + E1611 ShaderFragmentRequiresVertex are RESERVED (never fire); E1612-E1616
    /// + W1610 are DEFERRED (the GPU param/input-type catalogues are not attached,
    /// Phase 2+). The stage bodies are walked in SHADER MODE: a STRUCTURAL pass
    /// (§15.3) that flags the §15.2 GPU-incompatible CONSTRUCTS with the single
    /// representative E0400 ShaderModeViolation — it does NOT resolve symbols
    /// (shader bodies reference undeclared GPU builtins; a synthExpr-based check
    /// would false-positive E0102). E0420 ShaderRecursion (call-graph DFS) +
    /// E0421 NonShaderFnCalledFromShader (GPU-builtin table) are RESERVED — their
    /// emission is deferred. SPIR-V/MSL/DXIL emission is out of scope; eval of a
    /// shader body is fail-loud both backends (the descriptor is the Level-B output).
    fn validateShader(self: *TypeChecker, decl: ast_mod.ShaderDecl) !void {
        if (decl.has_vertex) try self.checkShaderBody(decl.vertex.body_start, decl.vertex.body_len);
        try self.checkShaderBody(decl.fragment.body_start, decl.fragment.body_len);
    }

    /// Walk a shader stage body, flagging GPU-incompatible constructs (E0400).
    fn checkShaderBody(self: *TypeChecker, body_start: u32, body_len: u32) !void {
        var i: u32 = 0;
        while (i < body_len) : (i += 1) {
            const stmt: NodeId = @bitCast(self.arena.extra.items[body_start + i]);
            try self.checkShaderStmt(stmt);
        }
    }

    fn checkShaderStmt(self: *TypeChecker, stmt: NodeId) !void {
        const kind = self.arena.stmtKind(stmt);
        const data = self.arena.stmtData(stmt);
        switch (kind) {
            .while_stmt => try self.emit(.shader_mode_violation, .error_, self.arena.stmtSpan(stmt), "shader mode: unbounded `while` loops are not supported on the GPU", .{}),
            .for_stmt => try self.emit(.shader_mode_violation, .error_, self.arena.stmtSpan(stmt), "shader mode: `for` loops with a non-const bound are not supported on the GPU", .{}),
            .try_catch_stmt => try self.emit(.shader_mode_violation, .error_, self.arena.stmtSpan(stmt), "shader mode: `try`/`catch` is not supported on the GPU", .{}),
            .throw_stmt => try self.emit(.shader_mode_violation, .error_, self.arena.stmtSpan(stmt), "shader mode: `throw` is not supported on the GPU", .{}),
            .emit_stmt => try self.emit(.shader_mode_violation, .error_, self.arena.stmtSpan(stmt), "shader mode: `emit` is not supported in a shader body", .{}),
            .tag_mutation_stmt => try self.emit(.shader_mode_violation, .error_, self.arena.stmtSpan(stmt), "shader mode: tag mutation is not supported in a shader body", .{}),
            .let_stmt => try self.checkShaderBoundExpr(self.arena.let_stmts.items[data].value),
            .assign_stmt => try self.checkShaderBoundExpr(self.arena.assign_stmts.items[data].value),
            .expr_stmt => try self.checkShaderBoundExpr(@bitCast(data)),
            .return_stmt => {
                const value: NodeId = @bitCast(data);
                if (!value.isNone()) try self.checkShaderBoundExpr(value);
            },
            else => {},
        }
    }

    /// Flag a bound value's top-level GPU-incompatible expression kind (the
    /// representative E0400 walk is shallow for M0.8 — deep expression recursion,
    /// like the recursion-DFS E0420 and the GPU-builtin-table E0421, is deferred).
    fn checkShaderBoundExpr(self: *TypeChecker, expr: NodeId) !void {
        switch (self.arena.exprKind(expr)) {
            .string_lit, .string_interp => try self.emit(.shader_mode_violation, .error_, self.arena.exprSpan(expr), "shader mode: string types are not supported on the GPU", .{}),
            .map_lit => try self.emit(.shader_mode_violation, .error_, self.arena.exprSpan(expr), "shader mode: map types are not supported on the GPU", .{}),
            .await_expr => try self.emit(.shader_mode_violation, .error_, self.arena.exprSpan(expr), "shader mode: `await` is not supported on the GPU", .{}),
            .loop_expr => try self.emit(.shader_mode_violation, .error_, self.arena.exprSpan(expr), "shader mode: `loop` is not supported on the GPU", .{}),
            .method_get, .method_get_mut => try self.emit(.shader_mode_violation, .error_, self.arena.exprSpan(expr), "shader mode: ECS access is not supported in a shader body", .{}),
            else => {},
        }
    }

    // ── M0.8 E7 Level C — scene (§23) + prefab (§24) validations ──────────
    // Serialization-only (parse + validation + descriptor); runtime
    // instantiation is M0.9. DELIVER the structural / reference / field-name +
    // field-type checks over the single-file compilation unit. RESERVED-with-
    // variant: E1796 PrefabComponentRedefined (variant/base component-shape
    // MERGE is M0.9 runtime — the variant's components are already validated
    // against the component RTTI here) + W1790 PrefabRemoveBaseComponent (no
    // `remove` syntax in the §24.1 grammar — grammar-wins, inexpressible).
    // DEFERRED: cross-FILE project-graph refs (E1782/E1786/E1791 only resolve
    // within the arena passed to `check`); the W1780 full "no Transform/Tier-1
    // component" heuristic (the Tier-1 catalogue is not attached) — the
    // conservative "no components at all" form is delivered.

    /// Collect the names of every `prefab` declaration in the compilation unit
    /// (prefabs are STRING-named — no symbol; cross-references go through this
    /// in-file set). Caller owns the returned map.
    fn collectPrefabNames(self: *TypeChecker) !std.AutoHashMapUnmanaged(StringId, void) {
        var names: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        errdefer names.deinit(self.gpa);
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .prefab_decl) continue;
            try names.put(self.gpa, self.arena.prefab_decls.items[datas[i]].name, {});
        }
        return names;
    }

    /// Check one component/resource-instance field (`name: value`) against the
    /// declared field run (over `arena.fields`): `code_unknown` if the field is
    /// absent; `code_type` (when non-null) if a builtin/struct/enum value type
    /// mismatches. Mirrors `validateDataEntryField` — synthExprE with null ctx;
    /// check-mode for `.variant` shorthand + anonymous `.{ }` values. Permissive
    /// on non-builtin declared types (no false positives on Vec3-from-array).
    fn checkInstanceField(self: *TypeChecker, owner: []const u8, decl_fields_start: u32, decl_fields_len: u32, field: ast_mod.StructLitField, code_unknown: DiagnosticCode, code_type: ?DiagnosticCode) !void {
        if (field.name == 0) return; // spread — not produced in component/resource bodies
        var declared: ?ResolvedType = null;
        var f: u32 = 0;
        while (f < decl_fields_len) : (f += 1) {
            const df = self.arena.fields.items[decl_fields_start + f];
            if (df.name == field.name) {
                declared = self.namedTypeToResolved(df.type_node);
                break;
            }
        }
        const d = declared orelse {
            try self.emit(code_unknown, .error_, self.arena.exprSpan(field.value), "'{s}' has no field '{s}'", .{ owner, self.arena.strings.slice(field.name) });
            return;
        };
        const tcode = code_type orelse return; // field-name-only check (resources)
        const actual = blk: {
            if (d == .enum_t and self.arena.exprKind(field.value) == .tag_path) {
                break :blk try self.checkEnumShorthand(field.value, d.enum_t);
            }
            if (d == .struct_t and self.arena.exprKind(field.value) == .struct_lit) {
                const inner_data = self.arena.exprData(field.value);
                if (self.arena.struct_lits.items[inner_data].type_name == 0) {
                    break :blk try self.checkStructLitAgainst(field.value, inner_data, d.struct_t, null);
                }
            }
            break :blk try self.synthExprE(field.value, null);
        };
        const mismatch = switch (d) {
            .builtin => |db| actual == .builtin and !self.literalTypeFits(db, field.value, actual.builtin),
            .struct_t => |dn| actual == .struct_t and actual.struct_t != dn,
            .enum_t => |dn| switch (actual) {
                .enum_t => |an| an != dn,
                .builtin => true,
                else => false,
            },
            else => false,
        };
        if (mismatch) {
            try self.emit(tcode, .error_, self.arena.exprSpan(field.value), "field '{s}' value type does not match its declared type", .{self.arena.strings.slice(field.name)});
        }
    }

    /// Resolve a `component_instance` against the component RTTI: `code_type`
    /// if the type is not a declared component, then per-field checks.
    ///
    /// M1.0.7 E6 (D-E): the component type may be a SELECTIVELY-IMPORTED symbol
    /// whose declaration lives in another file's arena. When it is, the decl is
    /// fetched from `project.arenas[entry.arena_index]` and the fields are checked
    /// CROSS-ARENA (field names compared by bytes — StringIds are per-arena). This
    /// is the E1793 unblock: a `.prefab.etch` importing its components validates
    /// clean instead of tripping `PrefabComponentTypeUnknown`.
    fn checkComponentInstance(self: *TypeChecker, ci: ast_mod.ComponentInstance, code_type: DiagnosticCode, code_field: DiagnosticCode, code_field_type: DiagnosticCode) !void {
        const owner = self.arena.strings.slice(ci.type_name);
        // 1. Local component (the M0.8 path).
        if (self.symbols.get(ci.type_name)) |sym| {
            if (sym.kind == .component) {
                const decl = self.arena.component_decls.items[self.arena.itemData(sym.item_id)];
                var f: u32 = 0;
                while (f < ci.fields_len) : (f += 1) {
                    try self.checkInstanceField(owner, decl.fields_start, decl.fields_len, self.arena.struct_lit_fields.items[ci.fields_start + f], code_field, code_field_type);
                }
                return;
            }
            // A local symbol that is NOT a component → fall through to code_type.
        } else if (self.imported_symbols.get(ci.type_name)) |entry| {
            // 2. Imported component (cross-arena, E6 / D-E).
            if (entry.kind == .component) {
                const decl_arena = &self.project.?.arenas[entry.arena_index];
                const decl = decl_arena.component_decls.items[decl_arena.itemData(entry.item_id)];
                var f: u32 = 0;
                while (f < ci.fields_len) : (f += 1) {
                    try self.checkInstanceFieldForeign(decl_arena, owner, decl.fields_start, decl.fields_len, self.arena.struct_lit_fields.items[ci.fields_start + f], code_field, code_field_type);
                }
                return;
            }
        }
        try self.emit(code_type, .error_, ci.span, "'{s}' is not a declared component", .{owner});
    }

    /// Cross-arena field check for an imported component instance (M1.0.7 E6,
    /// D-E). The instance field (`field`) lives in `self.arena`; the declared
    /// fields live in `decl_arena`. Field names are matched by BYTES (StringIds
    /// are per-arena). `code_unknown` (E1794) is full; the field-TYPE check
    /// (`code_type`, E1795) resolves the foreign declared type via
    /// `foreignBuiltinFieldType`. That covers EVERY valid component field type:
    /// `validateFieldsInDecl(.component_like)` admits only builtin-POD field types
    /// (named struct/enum/string are rejected on components), so a valid imported
    /// component's fields are all builtins. The `orelse return` (named foreign
    /// type) is therefore unreachable for a valid component — forward-compat
    /// headroom if components ever gain named-typed fields, not a skipped check.
    fn checkInstanceFieldForeign(self: *TypeChecker, decl_arena: *const AstArena, owner: []const u8, decl_fields_start: u32, decl_fields_len: u32, field: ast_mod.StructLitField, code_unknown: DiagnosticCode, code_type: DiagnosticCode) !void {
        if (field.name == 0) return; // spread — not produced in component bodies
        const field_name_bytes = self.arena.strings.slice(field.name);
        var declared_type_node: ?NodeId = null;
        var f: u32 = 0;
        while (f < decl_fields_len) : (f += 1) {
            const df = decl_arena.fields.items[decl_fields_start + f];
            if (std.mem.eql(u8, decl_arena.strings.slice(df.name), field_name_bytes)) {
                declared_type_node = df.type_node;
                break;
            }
        }
        const tn = declared_type_node orelse {
            try self.emit(code_unknown, .error_, self.arena.exprSpan(field.value), "'{s}' has no field '{s}'", .{ owner, field_name_bytes });
            return;
        };
        // Field-TYPE check. Component fields are builtin-POD only
        // (validateFieldsInDecl .component_like), so this resolves for every
        // valid imported component; the `orelse return` is unreachable for a
        // valid component (forward-compat headroom).
        const declared_builtin = foreignBuiltinFieldType(decl_arena, tn) orelse return;
        const actual = try self.synthExprE(field.value, null);
        if (actual == .builtin and !self.literalTypeFits(declared_builtin, field.value, actual.builtin)) {
            try self.emit(code_type, .error_, self.arena.exprSpan(field.value), "field '{s}' value type does not match its declared type", .{field_name_bytes});
        }
    }

    /// Resolve a `resources { … }` entry against the resource RTTI: E1789 if not
    /// a declared resource; E0303 per unknown field (no resource-field-type code).
    fn checkResourceInstance(self: *TypeChecker, ci: ast_mod.ComponentInstance) !void {
        const sym = self.symbols.get(ci.type_name);
        if (sym == null or sym.?.kind != .resource) {
            try self.emit(.scene_resource_type_unknown, .error_, ci.span, "'{s}' is not a declared resource", .{self.arena.strings.slice(ci.type_name)});
            return;
        }
        const decl = self.arena.resource_decls.items[self.arena.itemData(sym.?.item_id)];
        const owner = self.arena.strings.slice(ci.type_name);
        var f: u32 = 0;
        while (f < ci.fields_len) : (f += 1) {
            try self.checkInstanceField(owner, decl.fields_start, decl.fields_len, self.arena.struct_lit_fields.items[ci.fields_start + f], .resource_field_unknown, null);
        }
    }

    /// Validate a `component_field_override` (`Type.field = value`): E1783 if the
    /// component type is unknown, E1784 if the field is absent, E1785 on a type
    /// mismatch.
    fn checkFieldOverride(self: *TypeChecker, fo: ast_mod.FieldOverride) !void {
        const sym = self.symbols.get(fo.type_name);
        if (sym == null or sym.?.kind != .component) {
            try self.emit(.scene_component_type_unknown, .error_, fo.span, "'{s}' is not a declared component", .{self.arena.strings.slice(fo.type_name)});
            return;
        }
        const decl = self.arena.component_decls.items[self.arena.itemData(sym.?.item_id)];
        try self.checkInstanceField(self.arena.strings.slice(fo.type_name), decl.fields_start, decl.fields_len, .{ .name = fo.field, .value = fo.value }, .scene_component_field_unknown, .scene_component_field_type_invalid);
    }

    /// E1782 helper — record `uuid_id` as seen, returning whether it was
    /// already present. In project mode (M0.9 E2-B) the shared byte-keyed
    /// cross-scene tracker is consulted (a UUID reused across scenes or files
    /// is a duplicate); in single-file mode the per-scene `local` set keeps the
    /// M0.8 intra-scene semantics.
    fn uuidSeen(self: *TypeChecker, local: *std.AutoHashMapUnmanaged(StringId, void), uuid_id: StringId) !bool {
        if (self.project) |proj| {
            return (try proj.uuids.getOrPut(self.gpa, self.arena.strings.slice(uuid_id))).found_existing;
        }
        return (try local.getOrPut(self.gpa, uuid_id)).found_existing;
    }

    /// E1786 / E1791 helper — is `name_id` a known prefab? In project mode the
    /// byte-keyed PROJECT prefab index is consulted (a prefab declared in any
    /// project file is in scope); in single-file mode the per-file `local` set
    /// keeps the M0.8 compilation-unit semantics. `local` is `anytype` because
    /// the scene caller passes a `…(StringId, void)` set and the prefab caller
    /// a `…(StringId, usize)` name→index map — both answer `.contains`.
    fn prefabKnown(self: *TypeChecker, local: anytype, name_id: StringId) bool {
        if (self.project) |proj| return proj.prefabs.contains(self.arena.strings.slice(name_id));
        return local.contains(name_id);
    }

    fn validateSceneDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var prefab_names = try self.collectPrefabNames();
        defer prefab_names.deinit(self.gpa);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .scene_decl) continue;
            try self.validateScene(self.arena.scene_decls.items[datas[i]], &prefab_names);
        }
    }

    fn validateScene(self: *TypeChecker, decl: ast_mod.SceneDecl, prefab_names: *const std.AutoHashMapUnmanaged(StringId, void)) !void {
        try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .scene);

        // E1780 — a scene needs at least one entity or instance.
        if (decl.children_len == 0) {
            try self.emit(.scene_empty_entities, .error_, decl.name_span, "scene '{s}' has no entity or instance (at least one required)", .{self.arena.strings.slice(decl.name)});
        }

        // Identity sets (entity + instance names, and uuids) back E1781 / E1782
        // / E1787; the per-entity parent edges feed the E1788 cycle DFS.
        var names: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer names.deinit(self.gpa);
        var uuids: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer uuids.deinit(self.gpa);
        var ident_to_local: std.AutoHashMapUnmanaged(StringId, usize) = .empty;
        defer ident_to_local.deinit(self.gpa);
        var ent_names: std.ArrayListUnmanaged(StringId) = .empty;
        defer ent_names.deinit(self.gpa);
        var ent_spans: std.ArrayListUnmanaged(SourceSpan) = .empty;
        defer ent_spans.deinit(self.gpa);
        var ent_parent: std.ArrayListUnmanaged(StringId) = .empty; // 0 = none
        defer ent_parent.deinit(self.gpa);

        // Identity pass: build the entity local list + ident → local map.
        var c: u32 = 0;
        while (c < decl.children_len) : (c += 1) {
            const child = self.arena.scene_children.items[decl.children_start + c];
            if (child.kind != .entity) continue;
            const e = self.arena.scene_entities.items[child.index];
            const local = ent_names.items.len;
            try ent_names.append(self.gpa, e.name);
            try ent_spans.append(self.gpa, e.span);
            try ent_parent.append(self.gpa, e.parent);
            try ident_to_local.put(self.gpa, e.name, local);
            if (e.uuid != 0) try ident_to_local.put(self.gpa, e.uuid, local);
        }

        // Main pass: dup names/uuids, components, prefab refs, orphan warning.
        c = 0;
        while (c < decl.children_len) : (c += 1) {
            const child = self.arena.scene_children.items[decl.children_start + c];
            switch (child.kind) {
                .entity => {
                    const e = self.arena.scene_entities.items[child.index];
                    if ((try names.getOrPut(self.gpa, e.name)).found_existing) {
                        try self.emit(.duplicate_entity_name, .error_, e.span, "duplicate entity/instance name '{s}'", .{self.arena.strings.slice(e.name)});
                    }
                    if (e.uuid != 0 and try self.uuidSeen(&uuids, e.uuid)) {
                        try self.emit(.duplicate_uuid, .error_, e.span, "duplicate uuid '{s}'", .{self.arena.strings.slice(e.uuid)});
                    }
                    if (e.components_len == 0) {
                        try self.emit(.orphan_entity, .warning, e.span, "entity '{s}' has no components", .{self.arena.strings.slice(e.name)});
                    }
                    var f: u32 = 0;
                    while (f < e.components_len) : (f += 1) {
                        try self.checkComponentInstance(self.arena.component_instances.items[e.components_start + f], .scene_component_type_unknown, .scene_component_field_unknown, .scene_component_field_type_invalid);
                    }
                },
                .instance => {
                    const inst = self.arena.scene_instances.items[child.index];
                    if ((try names.getOrPut(self.gpa, inst.instance_name)).found_existing) {
                        try self.emit(.duplicate_entity_name, .error_, inst.span, "duplicate entity/instance name '{s}'", .{self.arena.strings.slice(inst.instance_name)});
                    }
                    if (inst.uuid != 0 and try self.uuidSeen(&uuids, inst.uuid)) {
                        try self.emit(.duplicate_uuid, .error_, inst.span, "duplicate uuid '{s}'", .{self.arena.strings.slice(inst.uuid)});
                    }
                    if (!self.prefabKnown(prefab_names, inst.prefab_name)) {
                        if (self.project != null) {
                            try self.emit(.prefab_ref_not_found, .error_, inst.span, "instance references prefab '{s}', which is not declared in the project", .{self.arena.strings.slice(inst.prefab_name)});
                        } else {
                            try self.emit(.prefab_ref_not_found, .error_, inst.span, "instance references prefab '{s}', which is not declared in this compilation unit", .{self.arena.strings.slice(inst.prefab_name)});
                        }
                    }
                    var m: u32 = 0;
                    while (m < inst.members_len) : (m += 1) {
                        const mem = self.arena.scene_instance_members.items[inst.members_start + m];
                        switch (mem.kind) {
                            .component => try self.checkComponentInstance(self.arena.component_instances.items[mem.index], .scene_component_type_unknown, .scene_component_field_unknown, .scene_component_field_type_invalid),
                            .field_override => try self.checkFieldOverride(self.arena.field_overrides.items[mem.index]),
                        }
                    }
                },
            }
        }

        // E1789 / E0303 — `resources { … }` entries are RESOURCES.
        var r: u32 = 0;
        while (r < decl.resources_len) : (r += 1) {
            try self.checkResourceInstance(self.arena.component_instances.items[decl.resources_start + r]);
        }

        // E1787 — every parent ref resolves to an entity name/uuid in the scene.
        // E1788 — the parent hierarchy is acyclic (color DFS over the functional
        // graph: each entity has ≤1 parent).
        const n = ent_names.items.len;
        var parent_pos = try self.gpa.alloc(?usize, n);
        defer self.gpa.free(parent_pos);
        var li: usize = 0;
        while (li < n) : (li += 1) {
            const par = ent_parent.items[li];
            if (par == 0) {
                parent_pos[li] = null;
                continue;
            }
            if (ident_to_local.get(par)) |target| {
                parent_pos[li] = target;
            } else {
                parent_pos[li] = null;
                try self.emit(.parent_not_found, .error_, ent_spans.items[li], "entity parent '{s}' is not an entity name or uuid in this scene", .{self.arena.strings.slice(par)});
            }
        }
        var color = try self.gpa.alloc(u8, n); // 0 white, 1 gray, 2 black
        defer self.gpa.free(color);
        @memset(color, 0);
        var path: std.ArrayListUnmanaged(usize) = .empty;
        defer path.deinit(self.gpa);
        var start: usize = 0;
        while (start < n) : (start += 1) {
            if (color[start] != 0) continue;
            path.clearRetainingCapacity();
            var cur: ?usize = start;
            while (cur) |ci| {
                if (color[ci] == 1) {
                    try self.emit(.parent_cycle, .error_, ent_spans.items[ci], "entity '{s}' is part of a parent cycle", .{self.arena.strings.slice(ent_names.items[ci])});
                    break;
                }
                if (color[ci] == 2) break;
                color[ci] = 1;
                try path.append(self.gpa, ci);
                cur = parent_pos[ci];
            }
            for (path.items) |p| color[p] = 2;
        }
    }

    fn validatePrefabDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        // Collect every prefab decl + a name → local-index map (prefabs are
        // STRING-named: this in-file map backs E1791 + the E1792 cycle DFS).
        var decls: std.ArrayListUnmanaged(ast_mod.PrefabDecl) = .empty;
        defer decls.deinit(self.gpa);
        var name_to_local: std.AutoHashMapUnmanaged(StringId, usize) = .empty;
        defer name_to_local.deinit(self.gpa);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .prefab_decl) continue;
            const decl = self.arena.prefab_decls.items[datas[i]];
            try name_to_local.put(self.gpa, decl.name, decls.items.len);
            try decls.append(self.gpa, decl);
        }
        // Per-decl structural + reference + component validation.
        for (decls.items) |decl| {
            try self.validatePrefab(decl, &name_to_local);
        }
        // E1792 — the `of`/`extends` relation graph is acyclic (color DFS;
        // each prefab has ≤1 relation parent).
        const n = decls.items.len;
        var parent_pos = try self.gpa.alloc(?usize, n);
        defer self.gpa.free(parent_pos);
        for (decls.items, 0..) |decl, idx| {
            if (decl.relation == .none) {
                parent_pos[idx] = null;
            } else {
                parent_pos[idx] = name_to_local.get(decl.relation_target); // null = base not found (E1791 already emitted)
            }
        }
        var color = try self.gpa.alloc(u8, n);
        defer self.gpa.free(color);
        @memset(color, 0);
        var path: std.ArrayListUnmanaged(usize) = .empty;
        defer path.deinit(self.gpa);
        var start: usize = 0;
        while (start < n) : (start += 1) {
            if (color[start] != 0) continue;
            path.clearRetainingCapacity();
            var cur: ?usize = start;
            while (cur) |ci| {
                if (color[ci] == 1) {
                    try self.emit(.prefab_cycle, .error_, decls.items[ci].name_span, "prefab '{s}' is part of an of/extends cycle", .{self.arena.strings.slice(decls.items[ci].name)});
                    break;
                }
                if (color[ci] == 2) break;
                color[ci] = 1;
                try path.append(self.gpa, ci);
                cur = parent_pos[ci];
            }
            for (path.items) |p| color[p] = 2;
        }
    }

    fn validatePrefab(self: *TypeChecker, decl: ast_mod.PrefabDecl, prefab_names: *const std.AutoHashMapUnmanaged(StringId, usize)) !void {
        try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .prefab);

        // E1790 — a prefab needs at least one component (across its entities).
        var total_components: u32 = 0;
        var e: u32 = 0;
        while (e < decl.entities_len) : (e += 1) {
            total_components += self.arena.scene_entities.items[decl.entities_start + e].components_len;
        }
        if (total_components == 0) {
            try self.emit(.prefab_empty, .error_, decl.name_span, "prefab '{s}' has no component (at least one required)", .{self.arena.strings.slice(decl.name)});
        }

        // E1791 — the of/extends base must be a declared prefab. Single-file:
        // in this compilation unit. Project mode (M0.9 E2-B): anywhere in the
        // project's prefab index.
        if (decl.relation != .none and !self.prefabKnown(prefab_names, decl.relation_target)) {
            if (self.project != null) {
                try self.emit(.prefab_base_not_found, .error_, decl.name_span, "prefab '{s}' extends/of '{s}', which is not declared in the project", .{ self.arena.strings.slice(decl.name), self.arena.strings.slice(decl.relation_target) });
            } else {
                try self.emit(.prefab_base_not_found, .error_, decl.name_span, "prefab '{s}' extends/of '{s}', which is not declared in this compilation unit", .{ self.arena.strings.slice(decl.name), self.arena.strings.slice(decl.relation_target) });
            }
        }

        // E1793/E1794/E1795 — component instances in the prefab's entities.
        e = 0;
        while (e < decl.entities_len) : (e += 1) {
            const ent = self.arena.scene_entities.items[decl.entities_start + e];
            var f: u32 = 0;
            while (f < ent.components_len) : (f += 1) {
                try self.checkComponentInstance(self.arena.component_instances.items[ent.components_start + f], .prefab_component_type_unknown, .prefab_component_field_unknown, .prefab_component_field_type_invalid);
            }
        }
    }

    fn validateDataTable(self: *TypeChecker, table_idx: u32) !void {
        const decl = self.arena.data_decls.items[table_idx];
        const table_name = self.arena.strings.slice(decl.name);
        if (decl.entries_len == 0) {
            try self.emit(.data_empty_entries, .error_, decl.entry_type_span, "data table '{s}' has no entries", .{table_name});
        }
        // Entry type: must resolve to a declared struct. Unknown → E0102;
        // known-but-not-a-struct → E1762 (the table itself cannot conform).
        var entry_struct: ?ast_mod.StructDecl = null;
        if (self.symbols.get(decl.entry_type)) |sym| {
            if (sym.kind == .struct_) {
                entry_struct = self.arena.struct_decls.items[self.arena.itemData(sym.item_id)];
            } else {
                try self.emit(.entry_type_mismatch, .error_, decl.entry_type_span, "data entry type '{s}' is not a struct", .{self.arena.strings.slice(decl.entry_type)});
            }
        } else {
            try self.emit(.undefined_symbol, .error_, decl.entry_type_span, "data entry type '{s}' does not resolve to a declared struct", .{self.arena.strings.slice(decl.entry_type)});
        }

        var seen_ids: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer seen_ids.deinit(self.gpa);
        var e: u32 = 0;
        while (e < decl.entries_len) : (e += 1) {
            const entry = self.arena.data_entries.items[decl.entries_start + e];
            const id_slice = self.arena.strings.slice(entry.id);
            // E1768 — entry ids are snake_case IDENTs (`etch-validation-ecs.md`
            // §22.2): a TYPE_IDENT-shaped id or any uppercase letter fails.
            if (entry.id_pascal or containsUppercase(id_slice)) {
                try self.emit(.id_invalid_format, .error_, entry.span, "data entry id '{s}' must be a snake_case identifier", .{id_slice});
            }
            const gop = try seen_ids.getOrPut(self.gpa, entry.id);
            if (gop.found_existing) {
                try self.emit(.duplicate_entry_id, .error_, entry.span, "duplicate data entry id '{s}' in table '{s}'", .{ id_slice, table_name });
            }
            var has_spread = false;
            var f: u32 = 0;
            while (f < entry.fields_len) : (f += 1) {
                const field = self.arena.struct_lit_fields.items[entry.fields_start + f];
                if (field.name == 0) {
                    has_spread = true;
                    _ = try self.resolveDataSpread(decl, field.value, true);
                    continue;
                }
                try self.validateDataEntryField(decl, entry_struct, field);
            }
            // E1765 — required fields (no declared default) must be provided
            // by a spread-less entry; a same-type spread chain (E1762-checked)
            // provides every field of its source entry.
            if (!has_spread) {
                if (entry_struct) |sd| {
                    var sf: u32 = 0;
                    while (sf < sd.fields_len) : (sf += 1) {
                        const sfield = self.arena.fields.items[sd.fields_start + sf];
                        if (!sfield.default_value.isNone()) continue;
                        var provided = false;
                        f = 0;
                        while (f < entry.fields_len) : (f += 1) {
                            if (self.arena.struct_lit_fields.items[entry.fields_start + f].name == sfield.name) {
                                provided = true;
                                break;
                            }
                        }
                        if (!provided) {
                            try self.emit(.entry_field_required_missing, .error_, entry.span, "data entry '{s}' is missing required field '{s}' (no declared default)", .{ id_slice, self.arena.strings.slice(sfield.name) });
                        }
                    }
                }
            }
        }
    }

    /// Validate one named field of a data entry against the declared entry
    /// struct: E1763 unknown field, E1764 value type. Value typing mirrors
    /// `checkStructLitAgainst` (check mode for `.variant` shorthands and
    /// anonymous `.{ … }` values, synth otherwise).
    fn validateDataEntryField(self: *TypeChecker, decl: ast_mod.DataDecl, entry_struct: ?ast_mod.StructDecl, field: ast_mod.StructLitField) !void {
        const sd = entry_struct orelse return; // type already reported
        var declared: ?ResolvedType = null;
        var sf: u32 = 0;
        while (sf < sd.fields_len) : (sf += 1) {
            const sfield = self.arena.fields.items[sd.fields_start + sf];
            if (sfield.name == field.name) {
                declared = self.namedTypeToResolved(sfield.type_node);
                break;
            }
        }
        const d = declared orelse {
            try self.emit(.entry_field_unknown, .error_, self.arena.exprSpan(field.value), "entry type '{s}' has no field '{s}'", .{ self.arena.strings.slice(decl.entry_type), self.arena.strings.slice(field.name) });
            return;
        };
        const actual = blk: {
            if (d == .enum_t and self.arena.exprKind(field.value) == .tag_path) {
                break :blk try self.checkEnumShorthand(field.value, d.enum_t);
            }
            if (d == .struct_t and self.arena.exprKind(field.value) == .struct_lit) {
                const inner_data = self.arena.exprData(field.value);
                if (self.arena.struct_lits.items[inner_data].type_name == 0) {
                    break :blk try self.checkStructLitAgainst(field.value, inner_data, d.struct_t, null);
                }
            }
            break :blk try self.synthExprE(field.value, null);
        };
        const mismatch = switch (d) {
            .builtin => |db| actual == .builtin and !self.literalTypeFits(db, field.value, actual.builtin),
            .struct_t => |dn| actual == .struct_t and actual.struct_t != dn,
            .enum_t => |dn| switch (actual) {
                .enum_t => |an| an != dn,
                .builtin => true,
                else => false, // `.unknown` already reported upstream
            },
            else => false,
        };
        if (mismatch) {
            try self.emit(.entry_field_type_invalid, .error_, self.arena.exprSpan(field.value), "data entry field '{s}' value type does not match its declared type", .{self.arena.strings.slice(field.name)});
        }
    }

    /// Resolve a spread value `..Table.entry` to its `(table, entry)` pair.
    /// With `emit_diags`, reports E1766 (shape / unknown table / unknown
    /// entry) and E1762 (spread source table of a different entry type);
    /// without, resolves quietly (the cycle DFS re-walks resolved edges).
    fn resolveDataSpread(self: *TypeChecker, decl: ast_mod.DataDecl, value: NodeId, emit_diags: bool) !?DataEntryRef {
        const span = self.arena.exprSpan(value);
        if (self.arena.exprKind(value) != .field_access) {
            if (emit_diags) try self.emit(.spread_reference_not_found, .error_, span, "spread must reference a data entry as 'Table.entry'", .{});
            return null;
        }
        const fa = self.arena.field_accesses.items[self.arena.exprData(value)];
        if (self.arena.exprKind(fa.receiver) != .path) {
            if (emit_diags) try self.emit(.spread_reference_not_found, .error_, span, "spread must reference a data entry as 'Table.entry'", .{});
            return null;
        }
        const src_table_name: StringId = self.arena.exprData(fa.receiver);
        const sym = self.symbols.get(src_table_name) orelse {
            if (emit_diags) try self.emit(.spread_reference_not_found, .error_, span, "spread references unknown data table '{s}'", .{self.arena.strings.slice(src_table_name)});
            return null;
        };
        if (sym.kind != .data_) {
            if (emit_diags) try self.emit(.spread_reference_not_found, .error_, span, "spread source '{s}' is not a data table", .{self.arena.strings.slice(src_table_name)});
            return null;
        }
        const src_idx = self.arena.itemData(sym.item_id);
        const src = self.arena.data_decls.items[src_idx];
        if (src.entry_type != decl.entry_type) {
            if (emit_diags) try self.emit(.entry_type_mismatch, .error_, span, "spread source table '{s}' has entry type '{s}', expected '{s}'", .{ self.arena.strings.slice(src_table_name), self.arena.strings.slice(src.entry_type), self.arena.strings.slice(decl.entry_type) });
            return null;
        }
        var e: u32 = 0;
        while (e < src.entries_len) : (e += 1) {
            if (self.arena.data_entries.items[src.entries_start + e].id == fa.field_name) {
                return .{ .table = src_idx, .entry = src.entries_start + e };
            }
        }
        if (emit_diags) try self.emit(.spread_reference_not_found, .error_, span, "data table '{s}' has no entry '{s}'", .{ self.arena.strings.slice(src_table_name), self.arena.strings.slice(fa.field_name) });
        return null;
    }

    /// DFS over the spread graph (E1767). `visiting` marks the current path
    /// (a revisit is a cycle); `done` marks settled entries. Keys pack the
    /// table slab index and the global entry index.
    fn dataSpreadDfs(self: *TypeChecker, ref: DataEntryRef, visiting: *std.AutoHashMapUnmanaged(u64, void), done: *std.AutoHashMapUnmanaged(u64, void)) !void {
        const key = (@as(u64, ref.table) << 32) | @as(u64, ref.entry);
        if (done.contains(key)) return;
        if (visiting.contains(key)) {
            const entry = self.arena.data_entries.items[ref.entry];
            try self.emit(.spread_cycle, .error_, entry.span, "data entry '{s}' participates in a spread cycle", .{self.arena.strings.slice(entry.id)});
            return;
        }
        try visiting.put(self.gpa, key, {});
        const decl = self.arena.data_decls.items[ref.table];
        const entry = self.arena.data_entries.items[ref.entry];
        var f: u32 = 0;
        while (f < entry.fields_len) : (f += 1) {
            const field = self.arena.struct_lit_fields.items[entry.fields_start + f];
            if (field.name != 0) continue;
            if (try self.resolveDataSpread(decl, field.value, false)) |next| {
                try self.dataSpreadDfs(next, visiting, done);
            }
        }
        _ = visiting.remove(key);
        try done.put(self.gpa, key, {});
    }

    // ─── Routines (M0.8 E4, `etch-validation-ecs.md` §9) ─────────────────

    /// Validate every `routine` once all symbols are known (M0.8 E4):
    /// E1520 empty routine, E1521 duplicate segment names, E1522/E1523
    /// malformed trigger/until times (HH < 24, MM < 60 — the only semantic
    /// content left after the parse-enforced §8.2 forms), E1524 `after`
    /// segment references, E1525 `on_event` event types, E1526 interrupt
    /// targets (a declared behavior or `pause_segment`), E1527 action
    /// return types (a routine action calls a void fn). The temporal-logic
    /// heuristics (W1520/W1521) are deferred per validation-ecs §9.3
    /// (Phase 2+).
    fn validateRoutineDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .routine_decl) continue;
            try self.validateRoutine(self.arena.routine_decls.items[datas[i]]);
        }
    }

    fn validateRoutine(self: *TypeChecker, decl: ast_mod.RoutineDecl) !void {
        const routine_name = self.arena.strings.slice(decl.name);
        if (decl.segments_len == 0) {
            const span = self.symbols.get(decl.name).?.item_id;
            try self.emit(.routine_empty_segments, .error_, self.arena.itemSpan(span), "routine '{s}' has no segments", .{routine_name});
        }
        var seen_names: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer seen_names.deinit(self.gpa);
        var s: u32 = 0;
        while (s < decl.segments_len) : (s += 1) {
            const seg = self.arena.routine_segments.items[decl.segments_start + s];
            const gop = try seen_names.getOrPut(self.gpa, seg.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_segment_name, .error_, seg.span, "duplicate segment name '{s}' in routine '{s}'", .{ self.arena.strings.slice(seg.name), routine_name });
            }
        }
        s = 0;
        while (s < decl.segments_len) : (s += 1) {
            const seg = self.arena.routine_segments.items[decl.segments_start + s];
            try self.validateTriggerRun(decl, seg.triggers_start, seg.triggers_len, .trigger_invalid);
            try self.validateTriggerRun(decl, seg.untils_start, seg.untils_len, .until_invalid);
            var a: u32 = 0;
            while (a < seg.actions_len) : (a += 1) {
                const action: NodeId = @bitCast(self.arena.extra.items[seg.actions_start + a]);
                try self.validateRoutineAction(action);
            }
        }
        var it: u32 = 0;
        while (it < decl.interrupts_len) : (it += 1) {
            const intr = self.arena.routine_interrupts.items[decl.interrupts_start + it];
            if (intr.is_pause) continue;
            if (self.symbols.get(intr.target)) |sym| {
                if (sym.kind != .behavior_) {
                    try self.emit(.interrupt_target_invalid, .error_, intr.span, "interrupt target '{s}' is not a behavior (or 'pause_segment')", .{self.arena.strings.slice(intr.target)});
                }
            } else {
                try self.emit(.interrupt_target_invalid, .error_, intr.span, "interrupt target '{s}' references no declared behavior (or 'pause_segment')", .{self.arena.strings.slice(intr.target)});
            }
        }
    }

    /// Validate one trigger/until alternative run: `at HH:MM` time ranges
    /// (E1522/E1523 per `code`), `after Segment` references (E1524),
    /// `on_event T` event types (E1525).
    fn validateTriggerRun(self: *TypeChecker, decl: ast_mod.RoutineDecl, start: u32, len: u32, code: DiagnosticCode) !void {
        var t: u32 = 0;
        while (t < len) : (t += 1) {
            const trig = self.arena.routine_triggers.items[start + t];
            switch (trig.kind) {
                .at_time => {
                    const lex = self.arena.strings.slice(trig.value); // "HH:MM" by lexing
                    const hh = (lex[0] - '0') * 10 + (lex[1] - '0');
                    const mm = (lex[3] - '0') * 10 + (lex[4] - '0');
                    if (hh > 23 or mm > 59) {
                        try self.emit(code, .error_, trig.span, "time literal '{s}' is out of range (hours 00-23, minutes 00-59)", .{lex});
                    }
                },
                .after_segment => {
                    var found = false;
                    var s: u32 = 0;
                    while (s < decl.segments_len) : (s += 1) {
                        if (self.arena.routine_segments.items[decl.segments_start + s].name == trig.value) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try self.emit(.segment_reference_not_found, .error_, trig.span, "'after {s}' references no segment of this routine", .{self.arena.strings.slice(trig.value)});
                    }
                },
                .on_event => {
                    if (self.symbols.get(trig.value)) |sym| {
                        if (sym.kind != .event_) {
                            try self.emit(.event_type_unknown, .error_, trig.span, "'on_event {s}': '{s}' is not an event", .{ self.arena.strings.slice(trig.value), self.arena.strings.slice(trig.value) });
                        }
                    } else {
                        try self.emit(.event_type_unknown, .error_, trig.span, "'on_event {s}' references no declared event", .{self.arena.strings.slice(trig.value)});
                    }
                },
            }
        }
    }

    /// Validate one routine action (E1527 + the standard call checks): the
    /// call is synthed with no rule context (arity / arg types / unknown
    /// callee via the regular paths), then the callee fn must be void.
    fn validateRoutineAction(self: *TypeChecker, action: NodeId) !void {
        _ = try self.synthExprE(action, null);
        // Parse enforced `fn_call`; resolve the callee's declared return.
        const call = self.arena.call_exprs.items[self.arena.exprData(action)];
        if (self.arena.exprKind(call.callee) != .ident) return;
        const callee_name: StringId = self.arena.exprData(call.callee);
        const sym = self.symbols.get(callee_name) orelse return; // E0102 already emitted by synth
        if (sym.kind != .fn_) return;
        const fn_decl = self.arena.fn_decls.items[self.arena.itemData(sym.item_id)];
        if (!fn_decl.return_type.isNone()) {
            try self.emit(.action_invalid_return, .error_, self.arena.exprSpan(action), "a routine action must call a void fn ('{s}' declares a return type)", .{self.arena.strings.slice(callee_name)});
        }
    }

    // ─── Quests (M0.8 E4, `etch-validation-ecs.md` §10) ──────────────────

    /// Validate every `quest` once all symbols are known and the tag table
    /// is built: E1540 empty quest, E1541 quest-wide duplicate stage names
    /// (branch stages included), E1542 `requires` bool, E1543 objective
    /// returns (bool, or a void-fn call), E1545 switch_branch targets,
    /// E1546 empty branches, E1547 branch-when bare-arm bool, E1548 known
    /// property types, E1550 handler emit event references, W1541 stages
    /// whose objectives are all optional. E1544/E1549 are parse-enforced
    /// (terminal sets — recorded). Expressions type in the ambient quest
    /// scope — implicit `player: Entity` (item-5 ruling). W1540
    /// (UnreachableBranch) is a deferred heuristic (recorded at the STOP).
    fn validateQuestDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .quest_decl) continue;
            try self.validateQuest(self.arena.quest_decls.items[datas[i]]);
        }
    }

    fn validateQuest(self: *TypeChecker, decl: ast_mod.QuestDecl) !void {
        var ctx: RuleCtx = .{ .unrestricted_ecs_access = true };
        defer ctx.deinit(self.gpa);
        if (self.arena.strings.find("player")) |player_id| {
            try ctx.locals.put(self.gpa, player_id, .{ .type_ = .{ .builtin = .entity }, .is_mut = false });
        }
        // Properties: `requires` must be bool (E1542); the part2 §15 known
        // properties type-check (E1548); unknown property names are open
        // (extension modes) and synth freely.
        var p: u32 = 0;
        while (p < decl.properties_len) : (p += 1) {
            const prop = self.arena.quest_properties.items[decl.properties_start + p];
            const t = try self.synthExprE(prop.value, &ctx);
            const pname = self.arena.strings.slice(prop.name);
            if (prop.is_requires) {
                if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
                    try self.emit(.quest_requires_not_bool, .error_, prop.span, "'requires' must be a bool expression", .{});
                }
            } else if (std.mem.eql(u8, pname, "display_name") or std.mem.eql(u8, pname, "description")) {
                if (t != .unknown and !(t == .builtin and t.builtin == .string_)) {
                    try self.emit(.property_invalid_type, .error_, prop.span, "quest property '{s}' must be a string", .{pname});
                }
            } else if (std.mem.eql(u8, pname, "required_level")) {
                if (t != .unknown and !(t == .builtin and t.builtin.isInteger())) {
                    try self.emit(.property_invalid_type, .error_, prop.span, "quest property 'required_level' must be an int", .{});
                }
            }
        }
        if (decl.stages_len == 0) {
            const sym = self.symbols.get(decl.name).?;
            try self.emit(.quest_empty_stages, .error_, self.arena.itemSpan(sym.item_id), "quest '{s}' has no stages", .{self.arena.strings.slice(decl.name)});
        }
        // Quest-wide name sets: stage names (E1541, branch stages included)
        // and branch names (E1545 targets), collected up front.
        var stage_names: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer stage_names.deinit(self.gpa);
        var branch_names: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer branch_names.deinit(self.gpa);
        var st: u32 = 0;
        while (st < decl.stages_len) : (st += 1) {
            try self.collectQuestNames(self.arena.extra.items[decl.stages_start + st], &stage_names, &branch_names, decl.name);
        }
        st = 0;
        while (st < decl.stages_len) : (st += 1) {
            try self.validateQuestStage(self.arena.extra.items[decl.stages_start + st], &ctx, &branch_names);
        }
    }

    /// Collect stage / branch names quest-wide (recursive), emitting E1541
    /// on a duplicate stage name as encountered.
    fn collectQuestNames(self: *TypeChecker, stage_idx: u32, stage_names: *std.AutoHashMapUnmanaged(StringId, void), branch_names: *std.AutoHashMapUnmanaged(StringId, void), quest_name: StringId) !void {
        const stage = self.arena.quest_stages.items[stage_idx];
        const gop = try stage_names.getOrPut(self.gpa, stage.name);
        if (gop.found_existing) {
            try self.emit(.duplicate_stage_name, .error_, stage.span, "duplicate stage name '{s}' in quest '{s}'", .{ self.arena.strings.slice(stage.name), self.arena.strings.slice(quest_name) });
        }
        var e: u32 = 0;
        while (e < stage.elems_len) : (e += 1) {
            const elem = self.arena.quest_elems.items[stage.elems_start + e];
            if (elem.kind != .branch) continue;
            const branch = self.arena.quest_branches.items[elem.index];
            try branch_names.put(self.gpa, branch.name, {});
            var bs: u32 = 0;
            while (bs < branch.stages_len) : (bs += 1) {
                try self.collectQuestNames(self.arena.extra.items[branch.stages_start + bs], stage_names, branch_names, quest_name);
            }
        }
    }

    fn validateQuestStage(self: *TypeChecker, stage_idx: u32, ctx: *RuleCtx, branch_names: *const std.AutoHashMapUnmanaged(StringId, void)) (TypeError || error{OutOfMemory})!void {
        const stage = self.arena.quest_stages.items[stage_idx];
        var n_objectives: u32 = 0;
        var has_main = false;
        var e: u32 = 0;
        while (e < stage.elems_len) : (e += 1) {
            const elem = self.arena.quest_elems.items[stage.elems_start + e];
            switch (elem.kind) {
                .objective => {
                    const obj = self.arena.quest_objectives.items[elem.index];
                    n_objectives += 1;
                    if (obj.modifier == .main) has_main = true;
                    // E1543 — bool (true = complete), or a void-fn call
                    // (emit-style completion; the behavior E1504 shape).
                    if (self.arena.exprKind(obj.value) == .fn_call) {
                        const call = self.arena.call_exprs.items[self.arena.exprData(obj.value)];
                        if (self.arena.exprKind(call.callee) == .ident) {
                            if (self.symbols.get(self.arena.exprData(call.callee))) |sym| {
                                if (sym.kind == .fn_) {
                                    _ = try self.synthExprE(obj.value, ctx);
                                    continue;
                                }
                            }
                        }
                    }
                    const t = try self.synthExprE(obj.value, ctx);
                    if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
                        try self.emit(.objective_invalid_return, .error_, obj.span, "an objective must be a bool expression or a call to a declared fn", .{});
                    }
                },
                .handler => {
                    const h = self.arena.quest_handlers.items[elem.index];
                    switch (h.kind) {
                        .on_start, .on_complete => {
                            if (h.payload_is_stmt) {
                                // Emit payload: E1550 on an unknown event
                                // reference, else the regular emit checks.
                                const em = self.arena.emit_stmts.items[self.arena.stmtData(h.payload)];
                                if (self.symbols.get(em.event_type)) |sym| {
                                    if (sym.kind != .event_) {
                                        try self.emit(.event_reference_not_found, .error_, h.span, "'{s}' is not an event", .{self.arena.strings.slice(em.event_type)});
                                    } else {
                                        try self.checkStmt(ctx, h.payload);
                                    }
                                } else {
                                    try self.emit(.event_reference_not_found, .error_, h.span, "handler emits unknown event '{s}'", .{self.arena.strings.slice(em.event_type)});
                                }
                            } else {
                                _ = try self.synthExprE(h.payload, ctx);
                            }
                        },
                        .on_fail => {
                            const t = try self.synthExprE(h.fail_cond, ctx);
                            if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
                                try self.emit(.type_mismatch, .error_, h.span, "an on_fail condition must be a bool expression", .{});
                            }
                            if (h.fail_action == .switch_branch and !branch_names.contains(h.fail_branch)) {
                                try self.emit(.switch_branch_target_not_found, .error_, h.span, "switch_branch target '{s}' is not a branch of this quest", .{self.arena.strings.slice(h.fail_branch)});
                            }
                        },
                    }
                },
                .branch => {
                    const branch = self.arena.quest_branches.items[elem.index];
                    if (branch.stages_len == 0) {
                        try self.emit(.branch_empty, .error_, branch.span, "branch '{s}' must have at least one stage", .{self.arena.strings.slice(branch.name)});
                    }
                    if (branch.when_root != ast_mod.RuleDecl.none_when) {
                        try self.collectWhenConstruct(ctx, branch.when_root, .branch_condition_not_bool, "branch");
                    }
                    var bs: u32 = 0;
                    while (bs < branch.stages_len) : (bs += 1) {
                        try self.validateQuestStage(self.arena.extra.items[branch.stages_start + bs], ctx, branch_names);
                    }
                },
                .statement => {
                    const stmt: NodeId = @bitCast(elem.index);
                    try self.checkStmt(ctx, stmt);
                },
            }
        }
        // W1541 — objectives present but none `main`: the stage can neither
        // fail nor complete on a principal objective (validation-ecs §10.2).
        if (n_objectives > 0 and !has_main) {
            try self.emit(.no_main_objective, .warning, stage.span, "stage '{s}' has no 'main' objective (all optional)", .{self.arena.strings.slice(stage.name)});
        }
    }

    // ─── Dialogues (M0.8 E4, `etch-validation-ecs.md` §11) ───────────────

    /// Validate every `dialogue` once all symbols are known and the tag
    /// table is built: E1560 empty dialogue, E1561 dialogue-wide duplicate
    /// branch labels, E1562/E1564 goto / choice targets (a declared branch
    /// or `end`), E1565/E1566 line / choice conditions (full §6 when
    /// machinery, bare arm on the construct codes), E1567 emit event
    /// references (the item-11 trailing condition validates through the
    /// same when machinery). E1563 (SpeakerNotFound) is VACUOUS in E4
    /// (scene/prefab context is E7; any string is referencable — recorded);
    /// W1560/W1561 are deferred heuristics (recorded at the STOP). The
    /// ambient scope injects `player: Entity` (item-5 ruling).
    fn validateDialogueDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .dialogue_decl) continue;
            try self.validateDialogue(self.arena.dialogue_decls.items[datas[i]]);
        }
    }

    fn validateDialogue(self: *TypeChecker, decl: ast_mod.DialogueDecl) !void {
        var ctx: RuleCtx = .{ .unrestricted_ecs_access = true };
        defer ctx.deinit(self.gpa);
        if (self.arena.strings.find("player")) |player_id| {
            try ctx.locals.put(self.gpa, player_id, .{ .type_ = .{ .builtin = .entity }, .is_mut = false });
        }
        if (decl.elems_len == 0) {
            const sym = self.symbols.get(decl.name).?;
            try self.emit(.dialogue_empty, .error_, self.arena.itemSpan(sym.item_id), "dialogue '{s}' is empty", .{self.arena.strings.slice(decl.name)});
        }
        // Dialogue-wide branch label set (E1561 + the E1562/E1564 targets).
        var labels: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer labels.deinit(self.gpa);
        try self.collectDialogueLabels(decl.elems_start, decl.elems_len, &labels);
        try self.validateDialogueElems(decl.elems_start, decl.elems_len, &ctx, &labels);
    }

    fn collectDialogueLabels(self: *TypeChecker, start: u32, len: u32, labels: *std.AutoHashMapUnmanaged(StringId, void)) !void {
        var e: u32 = 0;
        while (e < len) : (e += 1) {
            const elem = self.arena.dialogue_elems.items[start + e];
            if (elem.kind != .branch) continue;
            const branch = self.arena.dialogue_branches.items[elem.index];
            const gop = try labels.getOrPut(self.gpa, branch.name);
            if (gop.found_existing) {
                try self.emit(.duplicate_branch_label, .error_, branch.span, "duplicate branch label '{s}'", .{self.arena.strings.slice(branch.name)});
            }
            try self.collectDialogueLabels(branch.elems_start, branch.elems_len, labels);
        }
    }

    fn validateDialogueElems(self: *TypeChecker, start: u32, len: u32, ctx: *RuleCtx, labels: *const std.AutoHashMapUnmanaged(StringId, void)) (TypeError || error{OutOfMemory})!void {
        var e: u32 = 0;
        while (e < len) : (e += 1) {
            const elem = self.arena.dialogue_elems.items[start + e];
            switch (elem.kind) {
                .speaker => {
                    const sp = self.arena.dialogue_speakers.items[elem.index];
                    var l: u32 = 0;
                    while (l < sp.lines_len) : (l += 1) {
                        const line = self.arena.dialogue_lines.items[sp.lines_start + l];
                        _ = try self.synthExprE(line.text, ctx);
                        if (line.when_root != ast_mod.RuleDecl.none_when) {
                            try self.collectWhenConstruct(ctx, line.when_root, .line_condition_not_bool, "line");
                        }
                    }
                },
                .choice => {
                    const ch = self.arena.dialogue_choices.items[elem.index];
                    var o: u32 = 0;
                    while (o < ch.options_len) : (o += 1) {
                        const opt = self.arena.dialogue_options.items[ch.options_start + o];
                        _ = try self.synthExprE(opt.text, ctx);
                        if (opt.when_root != ast_mod.RuleDecl.none_when) {
                            try self.collectWhenConstruct(ctx, opt.when_root, .choice_condition_not_bool, "choice");
                        }
                        if (!opt.is_end and !labels.contains(opt.target)) {
                            try self.emit(.choice_target_not_found, .error_, opt.span, "choice target '{s}' is not a branch of this dialogue", .{self.arena.strings.slice(opt.target)});
                        }
                    }
                },
                .branch => {
                    const branch = self.arena.dialogue_branches.items[elem.index];
                    try self.validateDialogueElems(branch.elems_start, branch.elems_len, ctx, labels);
                },
                .emit => {
                    const em_elem = self.arena.dialogue_emits.items[elem.index];
                    const em = self.arena.emit_stmts.items[self.arena.stmtData(em_elem.stmt)];
                    if (self.symbols.get(em.event_type)) |sym| {
                        if (sym.kind != .event_) {
                            try self.emit(.dialogue_event_type_unknown, .error_, em_elem.span, "'{s}' is not an event", .{self.arena.strings.slice(em.event_type)});
                        } else {
                            try self.checkStmt(ctx, em_elem.stmt);
                        }
                    } else {
                        try self.emit(.dialogue_event_type_unknown, .error_, em_elem.span, "dialogue emits unknown event '{s}'", .{self.arena.strings.slice(em.event_type)});
                    }
                    if (em_elem.when_root != ast_mod.RuleDecl.none_when) {
                        try self.collectWhenConstruct(ctx, em_elem.when_root, .type_mismatch, "dialogue emit");
                    }
                },
                .goto => {
                    const g = self.arena.dialogue_gotos.items[elem.index];
                    if (!g.is_end and !labels.contains(g.target)) {
                        try self.emit(.branch_reference_not_found, .error_, g.span, "'-> {s}' references no branch of this dialogue", .{self.arena.strings.slice(g.target)});
                    }
                },
            }
        }
    }

    // ─── Abilities (M0.8 E4, `etch-validation-ecs.md` §12 TRANSPOSED) ────

    /// Validate every `ability` once all symbols are known and the tag
    /// table is built (items 12-15 ruling: the §8.5 grammar shape WINS over
    /// the validation-ecs §12 handler shape): E1580 empty ability (neither
    /// property nor rule — transposed from AbilityEmptyHandlers), E1581
    /// cost keys are numeric fields of a declared resource with numeric
    /// values, E1582 cooldown numeric (a negative literal is rejected),
    /// E1583/E1584 tag arrays against the tag table (keyed on the §8.5
    /// names `tags_required` / `tags_blocked`), E1586 same tag required AND
    /// blocked. E1585/W1580 are RESERVED (the ruled shape has no handlers).
    /// The embedded rule validates through the NORMAL rule path
    /// (`checkRule` — params, when machinery, accessibility gates; never
    /// registered for ticking).
    fn validateAbilityDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .ability_decl) continue;
            try self.validateAbility(self.arena.ability_decls.items[datas[i]]);
        }
    }

    fn validateAbility(self: *TypeChecker, decl: ast_mod.AbilityDecl) !void {
        if (decl.props_len == 0 and decl.rule_idx == ast_mod.AbilityDecl.no_rule) {
            const sym = self.symbols.get(decl.name).?;
            try self.emit(.ability_empty, .error_, self.arena.itemSpan(sym.item_id), "ability '{s}' declares neither a property nor a rule", .{self.arena.strings.slice(decl.name)});
        }
        var ctx: RuleCtx = .{};
        defer ctx.deinit(self.gpa);
        // Tag-path texts of the two arrays, for the E1586 conflict check.
        var required_paths: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = required_paths.keyIterator();
            while (it.next()) |key| self.gpa.free(key.*);
            required_paths.deinit(self.gpa);
        }
        var p: u32 = 0;
        while (p < decl.props_len) : (p += 1) {
            const prop = self.arena.ability_props.items[decl.props_start + p];
            switch (prop.kind) {
                .cost => try self.validateAbilityCost(prop, &ctx),
                .cooldown => {
                    // E1582 — Duration positive (§12.2), transposed: a
                    // DURATION_LIT or a positive numeric expression; a
                    // negative literal is rejected (duration lexemes are
                    // unsigned, so the unary-minus check covers both).
                    const t = try self.synthExprE(prop.value, &ctx);
                    const numeric = t == .builtin and (t.builtin.isNumeric() or t.builtin == .duration);
                    const neg_literal = self.arena.exprKind(prop.value) == .unary and
                        self.arena.unary_exprs.items[self.arena.exprData(prop.value)].op == .neg;
                    if (!numeric or neg_literal) {
                        try self.emit(.cooldown_invalid, .error_, prop.span, "cooldown must be a positive duration or numeric expression", .{});
                    }
                },
                .tags_required => try self.validateAbilityTagArray(prop, .tags_required, &required_paths),
                .tags_blocked => try self.validateAbilityTagArray(prop, .tags_blocked, &required_paths),
                .custom => _ = try self.synthExprE(prop.value, &ctx),
            }
        }
        if (decl.rule_idx != ast_mod.AbilityDecl.no_rule) {
            try self.checkRule(self.arena.rule_decls.items[decl.rule_idx]);
        }
    }

    /// E1581 — every `cost:` key must name a NUMERIC field of a declared
    /// resource (the cost is consumed from a resource pool at activation,
    /// validation-ecs §12.2 transposed onto the §8.5 `struct_literal_body`
    /// form); values must be numeric. Spread entries have no key — rejected.
    fn validateAbilityCost(self: *TypeChecker, prop: ast_mod.AbilityProp, ctx: *RuleCtx) !void {
        var f: u32 = 0;
        while (f < prop.cost_fields_len) : (f += 1) {
            const field = self.arena.struct_lit_fields.items[prop.cost_fields_start + f];
            if (field.name == 0) {
                try self.emit(.cost_invalid, .error_, prop.span, "cost entries must be 'key: value' pairs (no spread)", .{});
                continue;
            }
            if (!self.resourceHasNumericField(field.name)) {
                try self.emit(.cost_invalid, .error_, prop.span, "cost key '{s}' is not a numeric field of a declared resource", .{self.arena.strings.slice(field.name)});
            }
            const t = try self.synthExprE(field.value, ctx);
            if (!(t == .builtin and t.builtin.isNumeric())) {
                try self.emit(.cost_invalid, .error_, prop.span, "cost value for '{s}' must be numeric", .{self.arena.strings.slice(field.name)});
            }
        }
    }

    /// Whether ANY declared resource has a numeric field named `name`.
    fn resourceHasNumericField(self: *TypeChecker, name: StringId) bool {
        for (self.arena.resource_decls.items) |res| {
            var f: u32 = 0;
            while (f < res.fields_len) : (f += 1) {
                const field = self.arena.fields.items[res.fields_start + f];
                if (field.name != name) continue;
                const t = self.namedTypeToResolved(field.type_node);
                if (t == .builtin and t.builtin.isNumeric()) return true;
            }
        }
        return false;
    }

    /// E1583/E1584 — every element of a `tags_required` / `tags_blocked`
    /// array must be a tag path present in the tag table; E1586 — a path in
    /// BOTH arrays is incoherent. `required_paths` accumulates the
    /// `tags_required` path texts (owned by the caller) so the conflict
    /// check is order-independent within one array kind ordering
    /// (`tags_required` listed before `tags_blocked` in the corpus; a
    /// blocked-before-required ordering is also caught — the map fills
    /// from whichever array carries `.tags_required`).
    fn validateAbilityTagArray(self: *TypeChecker, prop: ast_mod.AbilityProp, kind: ast_mod.AbilityPropKind, required_paths: *std.StringHashMapUnmanaged(void)) !void {
        const al = self.arena.array_lits.items[self.arena.exprData(prop.value)];
        const code: DiagnosticCode = if (kind == .tags_required) .required_tags_unknown else .blocked_tags_unknown;
        var e: u32 = 0;
        while (e < al.elements_len) : (e += 1) {
            const path_node: NodeId = @bitCast(self.arena.extra.items[al.elements_start + e]);
            const tp = self.arena.tag_paths.items[self.arena.exprData(path_node)];
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(self.gpa);
            var i: u32 = 0;
            while (i < tp.segs_len) : (i += 1) {
                if (i > 0) try buf.append(self.gpa, '.');
                try buf.appendSlice(self.gpa, self.arena.strings.slice(self.arena.tag_path_segs.items[tp.segs_start + i]));
            }
            if (self.tag_table) |*table| {
                if (table.lookup(buf.items) == null) {
                    try self.emit(code, .error_, self.arena.exprSpan(path_node), "unknown tag path '.{s}' in {s}", .{ buf.items, @tagName(kind) });
                    continue;
                }
            }
            if (kind == .tags_required) {
                const gop = try required_paths.getOrPut(self.gpa, buf.items);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.gpa.dupe(u8, buf.items);
                }
            } else if (required_paths.contains(buf.items)) {
                try self.emit(.tags_required_blocked_conflict, .error_, self.arena.exprSpan(path_node), "tag '.{s}' is both required and blocked", .{buf.items});
            }
        }
    }

    // ─── Behaviors (M0.8 E4, `etch-validation-ecs.md` §8) ────────────────

    /// Validate every `behavior` once all symbols are known AND the tag
    /// table is built (composite when clauses ride the §6 machinery):
    /// E1500 composite root, E1501 empty composites, E1502 unknown
    /// behavior/routine references in leaf intrinsics, E1503 condition
    /// bool, E1504 action returns void (item-3 ruling), E1505 when-clause
    /// arms, E1506 recursion via `run_behavior` (DFS). Expressions type in
    /// the AMBIENT behavior scope — implicit `self: Entity` + `target:
    /// Entity` (item-5 ruling, the self/event injection pattern). An action
    /// `let` binds for the REST OF ITS COMPOSITE (M0.8 structural
    /// approximation; the cross-action scope is pinned by Cortex Phase 1+,
    /// item-2 ruling).
    fn validateBehaviorDecls(self: *TypeChecker) !void {
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        // behavior name → behaviors-slab index, for the recursion DFS.
        var index_of: std.AutoHashMapUnmanaged(StringId, u32) = .empty;
        defer index_of.deinit(self.gpa);
        var i: u28 = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .behavior_decl) continue;
            try index_of.put(self.gpa, self.arena.behavior_decls.items[datas[i]].name, datas[i]);
        }
        // `run_behavior` edges: edge list per behavior-slab index.
        var edges: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer edges.deinit(self.gpa);
        i = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .behavior_decl) continue;
            const decl = self.arena.behavior_decls.items[datas[i]];
            var ctx: RuleCtx = .{ .unrestricted_ecs_access = true };
            defer ctx.deinit(self.gpa);
            const entity_t: ResolvedType = .{ .builtin = .entity };
            if (self.arena.strings.find("self")) |self_id| try ctx.locals.put(self.gpa, self_id, .{ .type_ = entity_t, .is_mut = false });
            if (self.arena.strings.find("target")) |target_id| try ctx.locals.put(self.gpa, target_id, .{ .type_ = entity_t, .is_mut = false });
            const root = self.arena.bt_nodes.items[decl.root];
            if (root.kind != .selector and root.kind != .sequence) {
                try self.emit(.behavior_root_missing, .error_, root.span, "behavior '{s}' must have a composite root (selector or sequence)", .{self.arena.strings.slice(decl.name)});
            }
            try self.validateBTNode(decl.root, datas[i], &ctx, &index_of, &edges);
        }
        // E1506 — any cycle in the run_behavior graph (validation-ecs §8.3:
        // every recursion is rejected, direct or transitive).
        var visiting: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visiting.deinit(self.gpa);
        var done: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer done.deinit(self.gpa);
        i = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .behavior_decl) continue;
            try self.behaviorCycleDfs(datas[i], &edges, &visiting, &done);
        }
    }

    fn behaviorCycleDfs(self: *TypeChecker, b: u32, edges: *const std.AutoHashMapUnmanaged(u64, void), visiting: *std.AutoHashMapUnmanaged(u32, void), done: *std.AutoHashMapUnmanaged(u32, void)) !void {
        if (done.contains(b)) return;
        if (visiting.contains(b)) {
            const decl = self.arena.behavior_decls.items[b];
            const span = self.arena.bt_nodes.items[decl.root].span;
            try self.emit(.behavior_recursion, .error_, span, "behavior '{s}' references itself (directly or transitively via run_behavior)", .{self.arena.strings.slice(decl.name)});
            return;
        }
        try visiting.put(self.gpa, b, {});
        const n: u32 = @intCast(self.arena.behavior_decls.items.len);
        var to: u32 = 0;
        while (to < n) : (to += 1) {
            if (edges.contains((@as(u64, b) << 32) | to)) {
                try self.behaviorCycleDfs(to, edges, visiting, done);
            }
        }
        _ = visiting.remove(b);
        try done.put(self.gpa, b, {});
    }

    fn validateBTNode(self: *TypeChecker, node_idx: u32, behavior_idx: u32, ctx: *RuleCtx, index_of: *const std.AutoHashMapUnmanaged(StringId, u32), edges: *std.AutoHashMapUnmanaged(u64, void)) (TypeError || error{OutOfMemory})!void {
        const node = self.arena.bt_nodes.items[node_idx];
        switch (node.kind) {
            .selector, .sequence => {
                if (node.children_len == 0) {
                    try self.emit(.behavior_empty_composite, .error_, node.span, "a composite must have at least one child", .{});
                }
                if (node.when_root != ast_mod.RuleDecl.none_when) {
                    // The composite `when` rides the §6 machinery: structured
                    // arms validate as in rules; bool-arm violations surface
                    // as E1211/E0200 from `collectWhen` — the construct-level
                    // E1505 wraps a when clause whose ARMS are unknown kinds
                    // is parse-impossible, so E1505 fires on the bare-expr
                    // arm typing below via the dedicated path.
                    try self.collectWhenBehavior(ctx, node.when_root);
                }
                // Action `let` bindings scope to the rest of THIS composite:
                // snapshot the locals and restore at exit.
                var added: std.ArrayListUnmanaged(StringId) = .empty;
                defer added.deinit(self.gpa);
                var c: u32 = 0;
                while (c < node.children_len) : (c += 1) {
                    const child_idx = self.arena.extra.items[node.children_start + c];
                    const child = self.arena.bt_nodes.items[child_idx];
                    try self.validateBTNode(child_idx, behavior_idx, ctx, index_of, edges);
                    // An action `let` child binds for the following siblings.
                    if (child.kind == .action and child.payload_is_stmt and self.arena.stmtKind(child.payload) == .let_stmt) {
                        const let = self.arena.let_stmts.items[self.arena.stmtData(child.payload)];
                        try added.append(self.gpa, let.name);
                    }
                }
                for (added.items) |name| _ = ctx.locals.remove(name);
            },
            .condition => {
                const t = try self.synthExprE(node.payload, ctx);
                if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
                    try self.emit(.behavior_condition_not_bool, .error_, node.span, "a behavior condition must be a bool expression", .{});
                }
            },
            .action => {
                if (node.payload_is_stmt) {
                    // `let` / `emit` action (item-2 PATCHED forms): the
                    // regular statement checks validate the binding value /
                    // the event structurally. The `let` name joins the
                    // composite scope at the parent (sibling visibility).
                    try self.checkStmt(ctx, node.payload);
                    return;
                }
                // Cortex intrinsics: `run_behavior(B)` / `run_routine(R)` —
                // the referenced symbol must exist with the right kind
                // (E1502); the call is void by definition. `run_behavior`
                // records a recursion edge.
                if (try self.btIntrinsicAction(node, behavior_idx, index_of, edges)) return;
                const t = try self.synthExprE(node.payload, ctx);
                // Item-3 ruling: actions return void. A free-fn call to a
                // declared fn must have no return type; other expression
                // shapes that type non-void are rejected. (Method-call
                // actions: the declared-return check is bounded to free fns
                // — recorded.)
                if (self.arena.exprKind(node.payload) == .fn_call) {
                    const call = self.arena.call_exprs.items[self.arena.exprData(node.payload)];
                    if (self.arena.exprKind(call.callee) == .ident) {
                        if (self.symbols.get(self.arena.exprData(call.callee))) |sym| {
                            if (sym.kind == .fn_) {
                                const fdecl = self.arena.fn_decls.items[self.arena.itemData(sym.item_id)];
                                if (!fdecl.return_type.isNone()) {
                                    try self.emit(.behavior_action_invalid_return, .error_, node.span, "a behavior action must call a void fn (item-3 ruling)", .{});
                                }
                                return;
                            }
                        }
                    }
                } else if (t != .unknown) {
                    try self.emit(.behavior_action_invalid_return, .error_, node.span, "a behavior action must be a void call, a 'let' binding, or an 'emit' (got a value expression)", .{});
                }
            },
        }
    }

    /// Recognize and validate a Cortex intrinsic action (`run_behavior` /
    /// `run_routine`, M0.8 E4): the single argument must name a declared
    /// behavior / routine (E1502 BehaviorInvalidLeaf otherwise — the
    /// "unknown identifier referenced by a leaf"). Returns true when the
    /// payload was an intrinsic (normal synth skipped — Cortex owns the
    /// runtime signature, Phase 1+).
    fn btIntrinsicAction(self: *TypeChecker, node: ast_mod.BTNode, behavior_idx: u32, index_of: *const std.AutoHashMapUnmanaged(StringId, u32), edges: *std.AutoHashMapUnmanaged(u64, void)) !bool {
        if (self.arena.exprKind(node.payload) != .fn_call) return false;
        const call = self.arena.call_exprs.items[self.arena.exprData(node.payload)];
        if (self.arena.exprKind(call.callee) != .ident) return false;
        const callee = self.arena.strings.slice(self.arena.exprData(call.callee));
        const is_behavior = std.mem.eql(u8, callee, "run_behavior");
        const is_routine = std.mem.eql(u8, callee, "run_routine");
        if (!is_behavior and !is_routine) return false;
        if (call.args_len != 1 or call.names_start != ast_mod.no_arg_names) {
            try self.emit(.behavior_invalid_leaf, .error_, node.span, "'{s}' takes exactly one positional argument (the referenced declaration)", .{callee});
            return true;
        }
        const arg: NodeId = @bitCast(self.arena.extra.items[call.args_start]);
        if (self.arena.exprKind(arg) != .path and self.arena.exprKind(arg) != .ident) {
            try self.emit(.behavior_invalid_leaf, .error_, node.span, "'{s}' argument must name a declared {s}", .{ callee, if (is_behavior) "behavior" else "routine" });
            return true;
        }
        const ref_name: StringId = self.arena.exprData(arg);
        const sym = self.symbols.get(ref_name) orelse {
            try self.emit(.behavior_invalid_leaf, .error_, node.span, "'{s}' references unknown {s} '{s}'", .{ callee, if (is_behavior) "behavior" else "routine", self.arena.strings.slice(ref_name) });
            return true;
        };
        if (is_behavior) {
            if (sym.kind != .behavior_) {
                try self.emit(.behavior_invalid_leaf, .error_, node.span, "'run_behavior' target '{s}' is not a behavior", .{self.arena.strings.slice(ref_name)});
                return true;
            }
            if (index_of.get(ref_name)) |to| {
                try edges.put(self.gpa, (@as(u64, behavior_idx) << 32) | to, {});
            }
        } else if (sym.kind != .routine_) {
            try self.emit(.behavior_invalid_leaf, .error_, node.span, "'run_routine' target '{s}' is not a routine", .{self.arena.strings.slice(ref_name)});
            return true;
        }
        return true;
    }

    /// `collectWhen` specialization for construct-level when clauses (M0.8
    /// E4 — behavior composites, quest branches): the same §6 arm checks,
    /// with the bare-expression arm's non-bool case reported as the
    /// CONSTRUCT's code (`bare_code`; the rule path reports E0200).
    fn collectWhenConstruct(self: *TypeChecker, ctx: *RuleCtx, idx: u32, comptime bare_code: DiagnosticCode, comptime what: []const u8) !void {
        const node = self.arena.when_nodes.items[idx];
        switch (node.kind) {
            .logical_and, .logical_or => {
                try self.collectWhenConstruct(ctx, node.lhs, bare_code, what);
                try self.collectWhenConstruct(ctx, node.rhs, bare_code, what);
            },
            .logical_not => try self.collectWhenConstruct(ctx, node.lhs, bare_code, what),
            .expr_cond => {
                const t = try self.synthExprE(node.filter_value, ctx);
                if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
                    try self.emit(bare_code, .error_, node.span, "a " ++ what ++ " when clause must be a bool expression", .{});
                }
            },
            else => try self.collectWhen(ctx, idx),
        }
    }

    fn collectWhenBehavior(self: *TypeChecker, ctx: *RuleCtx, idx: u32) !void {
        try self.collectWhenConstruct(ctx, idx, .behavior_when_clause_not_bool, "composite");
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
                    try self.checkStorageAnnotation(decl);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, .component_like);
                },
                .resource_decl => {
                    const decl = self.arena.resource_decls.items[data];
                    try self.registerSymbol(.resource, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .resource);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, .resource);
                },
                .event_decl => {
                    // An `event` is a frame-arena struct-message, not a POD
                    // component: the `EMIT_EVENT` opcode promotes non-POD fields
                    // rule-arena → frame-arena (`etch-memory-model.md` §6.7 / §2.5;
                    // `etch-abi-zig.md` §3.1/§3.2 passes non-POD by handle), and
                    // `etch-grammar.md` §5.10 imposes no POD constraint. POD-strict
                    // is component-only (part1 §5.5, SoA storage). Event fields
                    // therefore follow the `struct` field surface (`string`/enum
                    // accepted, nested-struct deferred) via the `.event_` origin
                    // (M1.0.2 ruling — decision on the E1 test-4 blocker).
                    const decl = self.arena.event_decls.items[data];
                    try self.registerSymbol(.event_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .event);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, .event_);
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
                    // the name and validate fields. Struct fields are builtin
                    // scalars plus, since tranche 2 (the Error layer), `string`
                    // and enum-typed fields; nested-struct fields stay deferred.
                    const decl = self.arena.struct_decls.items[data];
                    try self.registerSymbol(.struct_, decl.name, item_id, span);
                    // Generic params (M0.8 E2 block 4) in scope so a field typed
                    // by a param (`min: T`) is accepted as a generic field.
                    try self.addGenerics(decl.generics_start, decl.generics_len);
                    defer self.removeGenerics(decl.generics_start, decl.generics_len);
                    try self.validateFieldsInDecl(decl.fields_start, decl.fields_len, .struct_);
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
                .const_decl => {
                    // Top-level `const` (M1.0.8). Register the name (so it
                    // collides with a same-named symbol via E0101 and resolves
                    // cross-file once exported), then check the value is
                    // const-evaluable (E1101) and matches its declared type
                    // (E0200) — reusing the field-default const surface.
                    const decl = self.arena.const_decls.items[data];
                    try self.registerSymbol(.const_, decl.name, item_id, span);
                    try self.checkConstValue(decl.value, decl.type_node);
                },
                .test_decl => {
                    // Top-level `test` block (M1.0.15). The test name lives in a
                    // DEDICATED namespace (`test_symbols`), so `test "Foo"` does
                    // not collide with `component Foo` (the M1.0.8 collision this
                    // milestone resolves). Intra-namespace uniqueness only: two
                    // `test "X"` → E0101 with a contextual message (the code is
                    // reused per `etch-diagnostics.md` §24.1, the
                    // `collectImplMethods` precedent). Never exported.
                    const decl = self.arena.test_decls.items[data];
                    const gop = try self.test_symbols.getOrPut(self.gpa, decl.name);
                    if (gop.found_existing) {
                        try self.emit(.duplicate_symbol, .error_, span, "duplicate test '{s}'", .{self.arena.strings.slice(decl.name)});
                    }
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .test_);
                    try self.checkTestAnnotations(decl.annotations_extra, decl.annotations_len);
                },
                .data_decl => {
                    // A `data` table (M0.8 E4 Level B) registers its name; the
                    // table body (entries, spreads, entry-type conformance) is
                    // validated in `validateDataDecls` once all symbols are
                    // known (the entry type may be declared after the table).
                    const decl = self.arena.data_decls.items[data];
                    try self.registerSymbol(.data_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .data);
                },
                .dialogue_decl => {
                    // A `dialogue` (M0.8 E4 Level B) registers its name; the
                    // graph (branch labels, targets, conditions, emits) is
                    // validated in `validateDialogueDecls`.
                    const decl = self.arena.dialogue_decls.items[data];
                    try self.registerSymbol(.dialogue_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .dialogue);
                },
                .ability_decl => {
                    // An `ability` (M0.8 E4 Level B) registers its name; the
                    // properties + embedded rule are validated in
                    // `validateAbilityDecls` once all symbols are known.
                    const decl = self.arena.ability_decls.items[data];
                    try self.registerSymbol(.ability_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .ability);
                },
                .quest_decl => {
                    // A `quest` (M0.8 E4 Level B) registers its name; the body
                    // (properties, stages, objectives, handlers, branches) is
                    // validated in `validateQuestDecls` once all symbols are
                    // known.
                    const decl = self.arena.quest_decls.items[data];
                    try self.registerSymbol(.quest_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .quest);
                },
                .behavior_decl => {
                    // A `behavior` (M0.8 E4 Level B) registers its name; the
                    // tree (root shape, composites, leaves, when clauses,
                    // recursion) is validated in `validateBehaviorDecls` once
                    // all symbols are known.
                    const decl = self.arena.behavior_decls.items[data];
                    try self.registerSymbol(.behavior_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .behavior);
                },
                .routine_decl => {
                    // A `routine` (M0.8 E4 Level B) registers its name; the
                    // body (segments, triggers, interrupts, actions) is
                    // validated in `validateRoutineDecls` once all symbols
                    // are known (events / behaviors / action fns may be
                    // declared after the routine).
                    const decl = self.arena.routine_decls.items[data];
                    try self.registerSymbol(.routine_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .routine);
                },
                .motion_decl => {
                    // A `motion` (M0.8 E5 Level B) is TYPE_IDENT-named → it
                    // registers a symbol; the states / transitions / animators
                    // are validated in `validateMotionDecls`.
                    const decl = self.arena.motion_decls.items[data];
                    try self.registerSymbol(.motion_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .motion);
                },
                .widget_decl => {
                    // A `widget` (M0.8 E5 Level B) is TYPE_IDENT-named → it
                    // registers a symbol; the ui_tree + the `@screen`/`@worldspace`
                    // exclusivity (E1621) are validated in `validateWidgetDecls`.
                    const decl = self.arena.widget_decls.items[data];
                    try self.registerSymbol(.widget_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .widget);
                },
                .locale_decl => {
                    // A `locale` (M0.8 E5 Level B) is IDENT-named → it registers a
                    // symbol; entries + the ISO-639 code form are validated in
                    // `validateLocaleDecls`.
                    const decl = self.arena.locale_decls.items[data];
                    try self.registerSymbol(.locale_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .locale);
                },
                .effect_decl => {
                    // An `effect` (M0.8 E6 Level B VFX) is TYPE_IDENT-named → it
                    // registers a symbol; emitters / handlers / the ≥1-emitter
                    // rule are validated in `validateEffectDecls`.
                    const decl = self.arena.effect_decls.items[data];
                    try self.registerSymbol(.effect_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .effect);
                },
                .sequence_decl => {
                    // A `sequence` (M0.8 E6 Level B cinematic) is TYPE_IDENT-named
                    // → it registers a symbol; tracks / keyframes / the §21
                    // checks run in `validateSequenceDecls`.
                    const decl = self.arena.sequence_decls.items[data];
                    try self.registerSymbol(.sequence_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .sequence);
                },
                .anim_graph_decl => {
                    // An `anim_graph` (M0.8 E6 Level B animation) is TYPE_IDENT-named
                    // → it registers a symbol; states / transitions / layers / the
                    // §18 checks run in `validateAnimGraphDecls`.
                    const decl = self.arena.anim_graph_decls.items[data];
                    try self.registerSymbol(.anim_graph_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .anim_graph);
                },
                .shader_decl => {
                    // A `shader` (M0.8 E6 Level B render) is TYPE_IDENT-named → it
                    // registers a symbol; the vertex/fragment bodies are
                    // shader-mode-validated in `validateShaderDecls` (resolver §15).
                    const decl = self.arena.shader_decls.items[data];
                    try self.registerSymbol(.shader_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .shader);
                },
                .audio_graph_decl => {
                    // An `audio_graph` (M0.8 E6 Level B audio) is TYPE_IDENT-named
                    // → it registers a symbol; the body is declaration-only
                    // (rendered, never executed). All §19 checks are
                    // RESERVED-with-variant (E1700/E1701 — output is
                    // parser-mandatory and single) or DEFERRED-no-variant (the
                    // Pulse DSP catalogue is not attached), so there is no
                    // validate pass.
                    const decl = self.arena.audio_graph_decls.items[data];
                    try self.registerSymbol(.audio_graph_, decl.name, item_id, span);
                    try self.validateAnnotations(decl.annotations_extra, decl.annotations_len, .audio_graph);
                },
                else => {}, // forward-compatible: unknown items ignored
            }
        }
    }

    /// Bind this file's `import` directives against the project exports index
    /// (M1.0.7 E5). For each `ImportDecl`:
    ///   - resolve the module path against `project.module_index`; a path that
    ///     names no project file is `E0103 NotAModule`.
    ///   - selective `{ X }`: look X up in the target module's exports — absent →
    ///     `E0104 UnknownExport`; private → `E0107` (activated M1.0.8); else
    ///     register it in `imported_symbols` under its local name (alias if present).
    ///   - module alias `as m` / bare `import a.b`: record the alias → target
    ///     binding in `imported_aliases` (D-F; qualified `m.Type` resolution is
    ///     E6+ additive, not done here).
    /// No-op in single-file mode (`project == null`). This pass only records the
    /// bindings + emits the import diagnostics; APPLYING the imports to
    /// `TYPE_IDENT` resolution + the cross-arena component check is E6.
    fn bindImports(self: *TypeChecker) !void {
        const project = self.project orelse return;
        const kinds = self.arena.items.items(.kind);
        const datas = self.arena.items.items(.data);
        const spans = self.arena.items.items(.span);
        var i: usize = 0;
        while (i < self.arena.items.len) : (i += 1) {
            if (kinds[i] != .import_decl) continue;
            const decl = self.arena.import_decls.items[datas[i]];
            const span = spans[i];

            // Join the module-path segments ("a.b.c") and resolve to a file.
            var path_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer path_buf.deinit(self.gpa);
            var s: u32 = 0;
            while (s < decl.path_len) : (s += 1) {
                if (s != 0) try path_buf.append(self.gpa, '.');
                try path_buf.appendSlice(self.gpa, self.arena.strings.slice(self.arena.import_path_segs.items[decl.path_start + s]));
            }
            const target_idx = project.module_index.get(path_buf.items) orelse {
                try self.emit(.not_a_module, .error_, span, "import path '{s}' does not name a module in the project", .{path_buf.items});
                continue;
            };

            if (decl.items_len == 0) {
                // Whole-module form (1 or 3): record the alias → target binding.
                // Explicit `as m` alias, else the implicit last-segment alias.
                const alias_id = if (decl.module_alias != 0)
                    decl.module_alias
                else
                    self.arena.import_path_segs.items[decl.path_start + decl.path_len - 1];
                try self.imported_aliases.put(self.gpa, alias_id, target_idx);
                continue;
            }

            // Selective form (2 or 4): bind each item against the target exports.
            const exports = &project.exports[target_idx];
            var j: u32 = 0;
            while (j < decl.items_len) : (j += 1) {
                const item = self.arena.import_items.items[decl.items_start + j];
                const item_name = self.arena.strings.slice(item.name);
                const entry = exports.get(item_name) orelse {
                    try self.emit(.unknown_export, .error_, span, "'{s}' is not exported by module '{s}'", .{ item_name, path_buf.items });
                    continue;
                };
                if (entry.visibility == .private) {
                    // Dormant until `private` graduates (M1.0.8, D-G).
                    try self.emit(.import_private_item, .error_, span, "'{s}' is private to module '{s}'", .{ item_name, path_buf.items });
                    continue;
                }
                const local = if (item.alias != 0) item.alias else item.name;
                try self.imported_symbols.put(self.gpa, local, entry);
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

        // §10.2 — W0902 PrivateTypeInPublicImpl: a PUBLIC trait implemented for a
        // PRIVATE target type surfaces the private type through a public
        // interface. Warning, not error — legitimate for internal use. Fires
        // only when the target is a local private type AND the trait is a local
        // PUBLIC trait (both symbols resolved above). An imported target is
        // public by construction (only public items import), so it never trips
        // this; an imported PUBLIC trait implemented for a private local type is
        // the spec's "trait imported" case, but an imported-trait impl does not
        // resolve here today (returns early at the `!trait_local` gate) — a
        // pre-existing, orthogonal gap, not this milestone's surface.
        if (type_sym) |ts| {
            const target_private = self.arena.itemVisibility(ts.item_id) == .private;
            const trait_public = self.arena.itemVisibility(trait_sym.?.item_id) == .public;
            if (target_private and trait_public) {
                try self.emit(.private_type_in_public_impl, .warning, span, "public trait '{s}' implemented for private type '{s}'", .{ trait_slice, type_slice });
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

    /// Which declaration kind a validated field range belongs to. `component_like`
    /// (components) keeps the POD-strict surface (`string`/enum/nested-struct
    /// rejected — part1 §5.5, SoA archetype storage). `resource` shares the wider
    /// non-POD surface with `struct_` / `event_` for `string` (M1.0.3 E2 — the
    /// Option A alignment, formerly deferred "tranche 7"; part1 §5.5 "no POD
    /// constraint for resources"); enum-typed resource fields land in M1.0.3 E3,
    /// nested-struct fields stay deferred. `struct_` and `event_` accept `string`
    /// + enum-typed fields (the builtin `Error` forces them on structs; events
    /// carry frame-arena non-POD payloads per `etch-memory-model.md` §6.7 / §2.5).
    /// POD-strict is component-only.
    const FieldDeclOrigin = enum { component_like, resource, struct_, event_ };

    fn validateFieldsInDecl(self: *TypeChecker, fields_start: u32, fields_len: u32, origin: FieldDeclOrigin) !void {
        // Field name uniqueness within parent: collect into a small set.
        var seen: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer seen.deinit(self.gpa);
        // M1.0.14 E2 — `@entity_target` is at most one per event (across this decl's fields).
        var entity_target_seen = false;

        var i: u32 = 0;
        while (i < fields_len) : (i += 1) {
            const field = self.arena.fields.items[fields_start + i];
            const fname = self.arena.strings.slice(field.name);

            // Field-level annotation applicability (M0.8 D-S3-annot-applicability).
            try self.validateAnnotations(field.annotations_extra, field.annotations_len, .field);

            // M1.0.14 E2 — `@entity_target` field-annotation placement (§18.10):
            // it designates the `await entity_event` match field, so it is
            // event-only, `Entity`-typed, and at most one per event. Misuse →
            // E0502 (existing kind, no new codes). The designated-field POLICY
            // lives in `arena.resolveEventEntityTarget` (consumed at the await site).
            if (self.arena.fieldHasAnnotation(field, .entity_target)) {
                const at_span = self.arena.typeNodeSpan(field.type_node);
                if (origin != .event_) {
                    try self.emit(.annotation_misapplied, .error_, at_span, "annotation '@entity_target' is only valid on an event field", .{});
                } else if (!self.arena.fieldTypeIsEntity(field)) {
                    try self.emit(.annotation_misapplied, .error_, at_span, "annotation '@entity_target' must be on an Entity-typed field", .{});
                }
                if (entity_target_seen) {
                    try self.emit(.annotation_misapplied, .error_, at_span, "at most one '@entity_target' per event", .{});
                }
                entity_target_seen = true;
            }

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
                // One bounded exception (M0.8 E3-C tranche 2): a `struct` field
                // may be `Error?` — the builtin Error's `source` chaining field
                // (part1 §10.2). General optional fields are tranche 4.
                if (origin == .struct_ and self.arena.typeNodeKind(field.type_node) == .optional) {
                    const payload: NodeId = @bitCast(self.arena.typeNodeData(field.type_node));
                    if (self.arena.typeNodeKind(payload) == .named) {
                        const pn = self.arena.named_types.items[self.arena.typeNodeData(payload)];
                        if (pn.name == self.arena.error_type_name) continue;
                    }
                }
                // Resource collection fields (M1.0.17): `T[]` (`.slice`),
                // `[K: V]` (`.map_type`), `Set<T>` (`.set_type`) unlock on
                // `resource` with a supported element type — `etch-reference-
                // part1.md` §5.5 (`recent_servers: string[]`), the persistent-heap
                // `CollectionSlot`. Fixed `T[N]` (`.array`) stays out of scope
                // (falls through to rejection). Element ∈ {POD scalar, string,
                // enum}; nested collection / unsupported element → E0222. The
                // collection default (`= []`) is wired in E2+, so the accepted
                // field skips the scalar-default check below.
                if (origin == .resource) {
                    switch (self.arena.typeNodeKind(field.type_node)) {
                        .slice => {
                            const at = self.arena.array_types.items[self.arena.typeNodeData(field.type_node)];
                            try self.checkResourceCollectionElement(at.elem);
                            continue;
                        },
                        .set_type => {
                            const st = self.arena.set_types.items[self.arena.typeNodeData(field.type_node)];
                            try self.checkResourceCollectionElement(st.elem);
                            continue;
                        },
                        .map_type => {
                            const mt = self.arena.map_types.items[self.arena.typeNodeData(field.type_node)];
                            try self.checkResourceCollectionElement(mt.key);
                            try self.checkResourceCollectionElement(mt.value);
                            continue;
                        },
                        else => {},
                    }
                }
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
                if ((origin == .struct_ or origin == .event_ or origin == .resource) and std.mem.eql(u8, tname, "string")) {
                    // `string` fields unlock for structs (the Error layer,
                    // M0.8 E3-C tranche 2 — `Error.message` forces them), events
                    // (frame-arena non-POD payload, `etch-memory-model.md` §6.7 /
                    // §2.5 — M1.0.2 ruling), and now resources (M1.0.3 E2 — the
                    // Option A alignment; part1 §5.5 "no POD constraint for
                    // resources"; the persistent-heap slot is `{ptr,len}`). part1
                    // §5.5 constrains components only — component string fields
                    // stay rejected below.
                } else if ((origin == .struct_ or origin == .event_ or origin == .resource) and self.declaredEnumName(resolved_name)) {
                    // Enum-typed fields unlock for structs (`Error.code:
                    // ErrorCode`, same tranche), events (M1.0.2), and now resources
                    // (M1.0.3 E3 — mirrors the `string` unlock; the slot stores the
                    // variant's declaration-order discriminant, POD). Checked
                    // against the AST enum slab (not the symbol table) so a
                    // later-declared enum is seen — pass 1 registers symbols
                    // incrementally. Components stay enum-rejected (POD-strict).
                } else if ((origin == .struct_ or origin == .event_) and self.declaredStructName(resolved_name)) {
                    // Struct-typed STRUCT / event fields are deferred: the
                    // anonymous `.{ … }` field-value context (M0.8 E3-C tranche 8)
                    // carries them — part1 §5.5 allows nested POD structs; the
                    // literal must PROVIDE such a field (E0208, checked at the
                    // struct literal) because it has no declared default the two
                    // backends could agree on. Component / resource fields stay
                    // builtin-POD-bounded (E1 ruling, unchanged).
                } else if (self.symbols.get(resolved_name)) |sym| {
                    if (sym.kind == .rule) {
                        try self.emit(.undefined_symbol, .error_, tspan, "type '{s}' is not a component, resource, or builtin", .{tname});
                    }
                    // A field of component-typed or resource-typed value is
                    // still not in the S3 POD builtin set — reject as
                    // unsupported. The brief enforces builtin POD only.
                    try self.emit(.undefined_symbol, .error_, tspan, "type '{s}' is not in the S3 POD builtin set", .{tname});
                } else if (std.mem.eql(u8, tname, "string")) {
                    // Reached only by `component_like` now: struct / event /
                    // resource `string` fields are accepted above (M1.0.3 E2
                    // unlocked resources). Components stay POD-strict (part1
                    // §5.5, SoA archetype storage). The `else` is defensive.
                    if (origin == .component_like) {
                        try self.emit(.undefined_symbol, .error_, tspan, "type 'string' is rejected on components in S3 (POD enforcement)", .{});
                    } else {
                        try self.emit(.undefined_symbol, .error_, tspan, "type 'string' is not in the S3 builtin set", .{});
                    }
                } else if (std.mem.eql(u8, tname, "TaskHandle")) {
                    // M1.0.12 E3 — `TaskHandle` is a non-POD builtin
                    // (`etch-grammar.md` §2.2): like `string` on components,
                    // it is rejected as a field type everywhere (a task
                    // handle is a live runtime identity, never stored state).
                    try self.emit(.undefined_symbol, .error_, tspan, "type 'TaskHandle' is non-POD (etch-grammar.md par. 2.2) and cannot be a field type", .{});
                } else if (std.mem.eql(u8, tname, "TimerHandle")) {
                    // M1.0.13 E4 — `TimerHandle` is a non-POD builtin
                    // (`etch-grammar.md` §2.2): rejected as a field type
                    // everywhere, the `TaskHandle` precedent (a timer handle
                    // is a live runtime identity, never stored state).
                    try self.emit(.undefined_symbol, .error_, tspan, "type 'TimerHandle' is non-POD (etch-grammar.md par. 2.2) and cannot be a field type", .{});
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

    /// M1.0.17 (E1): validate a resource collection field's element type is in
    /// the supported set {POD scalar builtin, `string`, enum} — the exact
    /// resource scalar-field surface (M1.0.3). A nested collection, or any other
    /// element (component/resource/struct/unknown/optional/function/…), emits
    /// `E0222 CollectionFieldElementInvalid`. This is the type-check gate only;
    /// element STORAGE / promotion wiring is E2+ (`string[]`) / E3 / E4.
    fn checkResourceCollectionElement(self: *TypeChecker, elem: NodeId) !void {
        const espan = self.arena.typeNodeSpan(elem);
        switch (self.arena.typeNodeKind(elem)) {
            .named => {},
            .slice, .array, .map_type, .set_type => {
                try self.emit(.collection_field_element_invalid, .error_, espan, "nested collections are not supported as a resource collection element (Phase 1)", .{});
                return;
            },
            else => {
                try self.emit(.collection_field_element_invalid, .error_, espan, "resource collection element must be a scalar POD, string, or enum", .{});
                return;
            },
        }
        const named = self.arena.named_types.items[self.arena.typeNodeData(elem)];
        const resolved = self.arena.resolveTypeAliasName(named.name);
        const tname = self.arena.strings.slice(resolved);
        // Value-POD builtins + `string` + a declared enum are the supported
        // element set: they are stored inline (POD) or promoted into an owned
        // persistent string, with no per-element load-time fixup. `Entity` is a
        // builtin scalar field type, but it carries cross-reference-table remap
        // semantics at scene load (M1.0.6: a cooked `.entity_` slot is written
        // `dead` and resolved via the Cross-references Table) — the collection
        // container wires no per-element remap, so an entity reference as a
        // collection element is out of Phase-1 scope (rejected here rather than
        // becoming a silent load-time gap).
        if (BuiltinType.fromName(tname)) |bt| {
            if (bt == .entity) {
                try self.emit(.collection_field_element_invalid, .error_, espan, "'Entity' is not supported as a resource collection element (Phase 1) — an entity reference carries cross-reference-table remap semantics a persistent collection does not wire", .{});
                return;
            }
            return; // value-POD builtin, stored inline
        }
        if (std.mem.eql(u8, tname, "string")) return;
        if (self.declaredEnumName(resolved)) return;
        try self.emit(.collection_field_element_invalid, .error_, espan, "resource collection element type '{s}' is not supported — must be a scalar POD, string, or enum", .{tname});
    }

    /// `true` if `name` is a declared `enum`, checked against the AST slab
    /// (declaration-order independent, unlike the incrementally-built pass-1
    /// symbol table). Includes the synthetic builtin `ErrorCode`.
    fn declaredEnumName(self: *TypeChecker, name: StringId) bool {
        for (self.arena.enum_decls.items) |decl| {
            if (decl.name == name) return true;
        }
        return false;
    }

    /// `true` if `name` is a declared `struct` (M0.8 E3-C tranche 8). Checked
    /// against the AST struct slab (not the symbol table) so a later-declared
    /// struct is seen — pass 1 registers symbols incrementally, mirroring
    /// `declaredEnumName`.
    fn declaredStructName(self: *TypeChecker, name: StringId) bool {
        for (self.arena.struct_decls.items) |decl| {
            if (decl.name == name) return true;
        }
        return false;
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

    /// Validate a top-level `const` value (M1.0.8): it must be const-evaluable
    /// (`E1101`) and its synthesized type must match the declared `: type`
    /// (`E0200`). Reuses the field-default const surface (`isConstEvaluable` +
    /// `namedTypeToResolved` + `synthExpr` + `literalTypeFits`); the only
    /// difference is the const-specific diagnostic wording.
    fn checkConstValue(self: *TypeChecker, value: NodeId, type_node: NodeId) !void {
        if (!isConstEvaluable(self.arena, value)) {
            try self.emit(.not_const_evaluable, .error_, self.arena.exprSpan(value), "const value must be a constant expression (literal, arithmetic on literals, or parenthesized)", .{});
            return;
        }
        const declared = self.namedTypeToResolved(type_node);
        const actual = self.synthExpr(value, null);
        if (declared == .builtin and actual == .builtin) {
            if (!self.literalTypeFits(declared.builtin, value, actual.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(value), "const value type does not match the declared type", .{});
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
                // `string` in a declared-type position (M0.8 E3-C tranche 2 —
                // struct fields like `Error.message`, `let s: string = …`).
                // Kept out of `fromName` so the component/resource POD
                // rejection wording in `validateFieldsInDecl` stays keyed on
                // the builtin table.
                if (std.mem.eql(u8, tname, "string")) return .{ .builtin = .string_ };
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
                // M1.0.7 E6 — a selectively-imported type resolves in any type
                // position (`type HA = Health`, field types, signatures). Identity
                // is the local-name `StringId`; the defining arena is reached via
                // `imported_symbols` only where the decl itself is needed (the
                // cross-arena component check, `checkComponentInstance`).
                if (self.imported_symbols.get(resolved_name)) |entry| {
                    return switch (entry.kind) {
                        .component => .{ .component = resolved_name },
                        .resource => .{ .resource = resolved_name },
                        .struct_ => .{ .struct_t = resolved_name },
                        .enum_ => .{ .enum_t = resolved_name },
                        else => .unknown,
                    };
                }
                return .unknown;
            },
            .path => {
                // `alias.Member` qualified type (M1.0.16). Resolve silently
                // through the whole-module aliases + project exports — the
                // qualified twin of the `imported_symbols` branch above. A
                // failure (unknown alias / absent / private member) is a
                // silent `.unknown` here; the use-site diagnostics
                // (E0102/E0104/E0107) are minted where a selective type would
                // be (the type-alias target, `validateTypeAliases`).
                return switch (self.resolvePathTypeNode(type_node)) {
                    .resolved => |t| t,
                    else => .unknown,
                };
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

    /// Outcome of resolving a `.path` qualified type node (`alias.Member`,
    /// M1.0.16). Split so the silent central resolver (`namedTypeToResolved`)
    /// and the emitting use site (`validateTypeAliases`) share one lookup, each
    /// deciding whether/how to diagnose.
    const PathResolution = union(enum) {
        /// The member resolved to a type kind (component / resource / struct /
        /// enum), or `.unknown` when it is exported but not a type (fn / const
        /// / …) — mirrors the `imported_symbols` arm's `else => .unknown`.
        resolved: ResolvedType,
        /// The receiver ident is not a whole-module alias in scope → E0102.
        alias_unresolved,
        /// The alias resolves, but the target module exports no such member → E0104.
        member_absent,
        /// The member exists in the target module but is `private` → E0107.
        member_private,
    };

    /// Resolve a `.path` type node (`alias.Member`, M1.0.16) against the
    /// whole-module import aliases (`imported_aliases` → target file index) and
    /// the project exports index — the qualified twin of the `imported_symbols`
    /// branch in `namedTypeToResolved`. Pure lookup, no diagnostics. Identity of
    /// a resolved kind is the member's `StringId` in THIS arena (`path.member`),
    /// matching how the selective arm keys on the local name. No-op-ish when
    /// `project == null` (single-file mode has no aliases → `.alias_unresolved`).
    fn resolvePathTypeNode(self: *TypeChecker, type_node: NodeId) PathResolution {
        const path = self.arena.path_types.items[self.arena.typeNodeData(type_node)];
        const project = self.project orelse return .alias_unresolved;
        const target_idx = self.imported_aliases.get(path.alias) orelse return .alias_unresolved;
        const member_bytes = self.arena.strings.slice(path.member);
        const entry = project.exports[target_idx].get(member_bytes) orelse return .member_absent;
        if (entry.visibility == .private) return .member_private;
        return .{ .resolved = switch (entry.kind) {
            .component => .{ .component = path.member },
            .resource => .{ .resource = path.member },
            .struct_ => .{ .struct_t = path.member },
            .enum_ => .{ .enum_t = path.member },
            else => .unknown,
        } };
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
                .test_decl => try self.checkTest(self.arena.test_decls.items[data]),
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
        // The body statements sit on the async driver's frame-driven spine
        // (M1.0.11 E3): a statement-head `await` here is executable.
        const saved_susp = self.await_suspendable;
        self.await_suspendable = true;
        defer self.await_suspendable = saved_susp;
        // Function coloring context (M1.0.11 E4): `await` / async calls are legal
        // only when this body is `async`.
        const saved_async = self.current_is_async;
        self.current_is_async = decl.is_async;
        defer self.current_is_async = saved_async;
        // A `throws` fn may propagate a throw; a plain one may not (E0902).
        const saved_throw = self.current_can_throw;
        self.current_can_throw = decl.throws;
        defer self.current_can_throw = saved_throw;

        var s: u32 = 0;
        while (s < decl.body_len) : (s += 1) {
            try self.checkStmt(&ctx, @bitCast(self.arena.extra.items[decl.body_start + s]));
        }

        if (!decl.value.isNone()) {
            const vt = self.synthExpr(decl.value, &ctx);
            if (!decl.return_type.isNone() and ret_t == .builtin and vt == .builtin and !self.literalTypeFits(ret_t.builtin, decl.value, vt.builtin)) {
                try self.emit(.return_type_mismatch, .error_, self.arena.exprSpan(decl.value), "method '{s}' body value type does not match its declared return type", .{self.arena.strings.slice(decl.name)});
            }
        }
    }

    /// Per-rule context: components accessible via `entity.get(T)` and
    /// resources accessible via `get(T)` (without receiver) as derived
    /// from the `when` clause.
    const RuleCtx = struct {
        components_in_when: std.AutoHashMapUnmanaged(StringId, void) = .empty,
        resources_in_when: std.AutoHashMapUnmanaged(StringId, void) = .empty,
        /// Level-B ambient scopes (M0.8 E4 — behavior/quest/dialogue, the
        /// item-5 ruling): component/resource accessibility is NOT gated on
        /// a when clause there (the construct's Tier-1 runtime owns the
        /// scheduling, no archetype query is derived). Rules keep the gate.
        unrestricted_ecs_access: bool = false,
        /// Local variables in the rule body, keyed by name.
        locals: std.AutoHashMapUnmanaged(StringId, Local) = .empty,

        pub const Local = struct { type_: ResolvedType, is_mut: bool };

        pub fn deinit(self: *RuleCtx, gpa: std.mem.Allocator) void {
            self.components_in_when.deinit(gpa);
            self.resources_in_when.deinit(gpa);
            self.locals.deinit(gpa);
        }
    };

    /// Number of structural-observer lifecycle annotations on a rule (M1.0.2 E2).
    fn observerAnnotationCount(self: *TypeChecker, rule: ast_mod.RuleDecl) u32 {
        var n: u32 = 0;
        var i: u32 = 0;
        while (i < rule.annotations_len) : (i += 1) {
            const annot = self.arena.annot_pool.items[rule.annotations_extra + i];
            if (annot.kind.toObserverKind() != null) n += 1;
        }
        return n;
    }

    /// True iff rule param `idx` is named `entity` and typed `Entity` (M1.0.2 E2).
    fn observerParamIsEntity(self: *TypeChecker, rule: ast_mod.RuleDecl, idx: u32) bool {
        const p = self.arena.rule_params.items[rule.params_start + idx];
        if (!std.mem.eql(u8, self.arena.strings.slice(p.name), "entity")) return false;
        const t = self.namedTypeToResolved(p.type_node);
        return t == .builtin and t.builtin == .entity;
    }

    /// True iff rule param `idx` is named `name` and typed by the component
    /// `comp` (the lifecycle annotation's T) — M1.0.2 E2.
    fn observerParamIsComponent(self: *TypeChecker, rule: ast_mod.RuleDecl, idx: u32, name: []const u8, comp: StringId) bool {
        const p = self.arena.rule_params.items[rule.params_start + idx];
        if (!std.mem.eql(u8, self.arena.strings.slice(p.name), name)) return false;
        const t = self.namedTypeToResolved(p.type_node);
        return t == .component and t.component == comp;
    }

    /// Emit E1208 ObserverSignatureMismatch with the parameter shape required by
    /// the lifecycle `kind` (M1.0.2 E2).
    fn emitObserverShape(self: *TypeChecker, annot: ast_mod.Annotation, kind: ast_mod.ObserverKind) !void {
        const shape = switch (kind) {
            .on_added => "(entity: Entity, value: T)",
            .on_replaced => "(entity: Entity, old: T, new: T)",
            .on_removed => "(entity: Entity, old: T)",
            .on_spawned, .on_despawned => "(entity: Entity)",
        };
        try self.emit(.observer_signature_mismatch, .error_, annot.span, "@{s} observer rule requires the parameter shape {s}", .{ self.arena.strings.slice(annot.name), shape });
    }

    /// Validate an observer rule's annotation argument + parameter shape against
    /// its lifecycle kind (M1.0.2 E2). E1209 for a bad component argument
    /// (arity / not a declared component); E1208 for a parameter list that does
    /// not match the required `(entity: Entity, …)` shape (at most one E1208).
    fn checkObserverSignature(self: *TypeChecker, rule: ast_mod.RuleDecl, annot: ast_mod.Annotation) !void {
        const kind = annot.kind.toObserverKind().?;
        const aname = self.arena.strings.slice(annot.name);
        const needs_component = switch (kind) {
            .on_added, .on_removed, .on_replaced => true,
            .on_spawned, .on_despawned => false,
        };

        // 1. Component argument (E1209).
        var comp_name: ?StringId = null;
        if (needs_component) {
            if (self.arena.observerComponentName(annot)) |cn| {
                const sym = self.symbols.get(cn);
                if (sym != null and sym.?.kind == .component) {
                    comp_name = cn;
                } else {
                    try self.emit(.observer_component_invalid, .error_, annot.span, "@{s}(T) requires T to be a declared component; '{s}' is not", .{ aname, self.arena.strings.slice(cn) });
                }
            } else {
                try self.emit(.observer_component_invalid, .error_, annot.span, "@{s}(T) requires a single component-type argument", .{aname});
            }
            // A bad component argument already reported E1209 — skip the shape
            // check (its component-param type comparison would cascade).
            if (comp_name == null) return;
        } else if (annot.args_len != 0) {
            try self.emit(.observer_component_invalid, .error_, annot.span, "@{s} takes no argument", .{aname});
        }

        // 2. Parameter shape (E1208).
        const want: u32 = switch (kind) {
            .on_added, .on_removed => 2,
            .on_replaced => 3,
            .on_spawned, .on_despawned => 1,
        };
        if (rule.params_len != want or !self.observerParamIsEntity(rule, 0)) return self.emitObserverShape(annot, kind);
        switch (kind) {
            // `@on_added`'s value binding is `value`, not `component` — the latter
            // is a reserved keyword (M1.0.2 E2 ruling, option a; see deviations).
            .on_added => if (!self.observerParamIsComponent(rule, 1, "value", comp_name.?)) return self.emitObserverShape(annot, kind),
            .on_removed => if (!self.observerParamIsComponent(rule, 1, "old", comp_name.?)) return self.emitObserverShape(annot, kind),
            .on_replaced => {
                if (!self.observerParamIsComponent(rule, 1, "old", comp_name.?)) return self.emitObserverShape(annot, kind);
                if (!self.observerParamIsComponent(rule, 2, "new", comp_name.?)) return self.emitObserverShape(annot, kind);
            },
            .on_spawned, .on_despawned => {},
        }
    }

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

        // `@on_event(T)` observer: bind the implicit `event` payload (M0.8 E3,
        // resolver-types §12). E1203 OnEventTypeMismatch is a type-coherence
        // check — the implicit `event` binding carries the annotation's type T,
        // so T must be a declared event. There is NO declared `event:` param
        // (the ruling: `event` stays a keyword, the payload is an implicit
        // binding named `event`, self-style like `self` in a method).
        if (self.arena.onEventAnnotation(rule)) |annot| {
            if (self.arena.onEventTypeName(annot)) |event_type| {
                const sym = self.symbols.get(event_type);
                const local_event = sym != null and sym.?.kind == .event_;
                // A `.d.etch`-declared event resolves here too (M1.1.15.2 G4) —
                // which is the whole point of admitting `event_decl` into §20.1
                // at G1: a rule can only observe an event whose type Etch knows.
                if (local_event or self.declaredEvent(event_type) != null) {
                    const event_id = try self.arena.strings.intern(self.gpa, "event");
                    try ctx.locals.put(self.gpa, event_id, .{ .type_ = .{ .event_t = event_type }, .is_mut = false });
                } else {
                    try self.emit(.on_event_type_mismatch, .error_, annot.span, "@on_event(...) requires a declared event type; '{s}' is not an event", .{self.arena.strings.slice(event_type)});
                }
            } else {
                try self.emit(.on_event_type_mismatch, .error_, annot.span, "@on_event(EventType) requires a single event-type argument", .{});
            }
        }

        // Observer lifecycle annotations (M1.0.2 E2): `@on_added/removed/replaced/
        // spawned/despawned` route a structural observer onto a rule, mirroring
        // `@on_event`. Surface validations only (the Tier-0 ObserverRegistry
        // bridge is E3). The component-typed params (`component`/`old`/`new`: T)
        // are bound self-style by the param loop above. An observer rule carries
        // exactly one lifecycle annotation and no `when` / `@on_event` (the
        // lifecycle component type is the sole trigger; observers do not iterate).
        if (self.arena.observerAnnotation(rule)) |oannot| {
            if (self.arena.onEventAnnotation(rule) != null) {
                try self.emit(.observer_rule_conflict, .error_, oannot.span, "an observer rule cannot also be an @on_event handler", .{});
            }
            if (rule.when_root != ast_mod.RuleDecl.none_when) {
                try self.emit(.observer_rule_conflict, .error_, oannot.span, "an observer rule takes no `when` clause (the lifecycle component type is the sole trigger)", .{});
            }
            if (self.observerAnnotationCount(rule) > 1) {
                try self.emit(.observer_rule_conflict, .error_, oannot.span, "an observer rule must carry exactly one lifecycle annotation", .{});
            }
            try self.checkObserverSignature(rule, oannot);
        }

        // Validate when-clause and collect accessible component/resource types.
        if (rule.when_root != ast_mod.RuleDecl.none_when) {
            try self.collectWhen(&ctx, rule.when_root);
        }

        // Walk the body statements. The rule body sits on the async driver's
        // frame-driven spine (M1.0.11 E3): a statement-head `await` is executable.
        const saved_susp = self.await_suspendable;
        self.await_suspendable = true;
        defer self.await_suspendable = saved_susp;
        // Function coloring context (M1.0.11 E4): `await` / async calls are legal
        // only in an `async rule`.
        const saved_async = self.current_is_async;
        self.current_is_async = rule.is_async;
        defer self.current_is_async = saved_async;
        // A rule can never be `throws` (E0903), so a `throws` call in a rule
        // body needs a local `try`/`catch` — `etch-abi-zig.md` §8.7 states this
        // as the assumed consequence for fallible services, not a defect.
        const saved_rule_throw = self.current_can_throw;
        self.current_can_throw = false;
        defer self.current_can_throw = saved_rule_throw;
        var s: u32 = 0;
        while (s < rule.body_len) : (s += 1) {
            const stmt_raw = self.arena.extra.items[rule.body_start + s];
            const stmt_id: NodeId = @bitCast(stmt_raw);
            try self.checkStmt(&ctx, stmt_id);
        }
    }

    /// Type-check a `test` block body (M1.0.15, §32 normative). The body is a
    /// SYNC statement context: `await` inside it → E0901 (function coloring,
    /// `current_is_async = false`); the async surface is exercised through the
    /// file's rules driven by `tick(n)`. `in_test_body` unlocks the test-scoped
    /// builtins (`test_world`/`tick_until`) and the `measure { }` expression for
    /// the duration of the body. Mirrors `checkTimerBodyRun`'s sync-context
    /// discipline; the body is a single `block_expr`, checked via `synthExprE`.
    fn checkTest(self: *TypeChecker, decl: ast_mod.TestDecl) !void {
        // A test body has no `when` clause but full ECS access (`get`/`get_mut`
        // on any resource/component, e.g. `world.spawn_with(...).get(Health)`) —
        // the same unrestricted context observer / data bodies use.
        var ctx: RuleCtx = .{ .unrestricted_ecs_access = true };
        defer ctx.deinit(self.gpa);

        const saved_async = self.current_is_async;
        const saved_susp = self.await_suspendable;
        const saved_test = self.in_test_body;
        self.current_is_async = false;
        self.await_suspendable = true;
        self.in_test_body = true;
        defer {
            self.current_is_async = saved_async;
            self.await_suspendable = saved_susp;
            self.in_test_body = saved_test;
        }
        _ = try self.synthExprE(decl.body, &ctx);
    }

    /// Validate the argument shape of the three `test`-only annotations (M1.0.15,
    /// §17). Applicability (test-only) is already enforced by
    /// `validateAnnotations` with the `.test_` target; this checks the args,
    /// reusing E0502 with a contextual message (no new diagnostic code — E0910 is
    /// the milestone's only new code):
    ///   - `@tag(.X)`: exactly one enum-shorthand arg in {unit, integration,
    ///     slow, perf}.
    ///   - `@skip(reason: "...")`: exactly one string-literal arg (positional or
    ///     named `reason`).
    ///   - `@only`: no args.
    fn checkTestAnnotations(self: *TypeChecker, start: u32, len: u32) !void {
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const annot = self.arena.annot_pool.items[start + i];
            switch (annot.kind) {
                .tag => {
                    const ok = annot.args_len == 1 and blk: {
                        const arg = self.arena.annot_args.items[annot.args_start];
                        if (self.arena.exprKind(arg.value) != .tag_path) break :blk false;
                        const v = self.arena.strings.slice(self.arena.exprData(arg.value));
                        break :blk std.mem.eql(u8, v, "unit") or std.mem.eql(u8, v, "integration") or
                            std.mem.eql(u8, v, "slow") or std.mem.eql(u8, v, "perf");
                    };
                    if (!ok) try self.emit(.annotation_misapplied, .error_, annot.span, "@tag requires one of .unit / .integration / .slow / .perf", .{});
                },
                .skip => {
                    const ok = annot.args_len == 1 and self.arena.exprKind(self.arena.annot_args.items[annot.args_start].value) == .string_lit;
                    if (!ok) try self.emit(.annotation_misapplied, .error_, annot.span, "@skip requires a string reason (e.g. @skip(reason: \"WIP\"))", .{});
                },
                .only => {
                    if (annot.args_len != 0) try self.emit(.annotation_misapplied, .error_, annot.span, "@only takes no arguments", .{});
                },
                else => {},
            }
        }
    }

    /// Validate `@storage`'s argument against the `StorageKind` domain
    /// (`engine-ecs-internals.md` §2 — `table | sparse`, default `table`), the
    /// two steps `etch-resolver-types.md` §13.3 numbers 3 and 4. Applicability
    /// (`component`-only) is already enforced by `validateAnnotations`; this is
    /// the argument, which nothing checked before M1.B/G1 — every value passed,
    /// including a value outside the domain.
    ///
    /// **The accepted spelling is the tag path, `@storage(.sparse)`, and only
    /// that.** The bare `@storage(sparse)` is grammatical (`etch-grammar.md`
    /// §1.5 admits a bare `IDENT` for `annotation_arg`) and is refused, because
    /// the question is one of schema and not of grammar: an argument whose
    /// declared type is an enumeration domain is written as a tag path, which is
    /// what every sibling annotation of that shape already does. The decisive
    /// reason is ambiguity rather than uniformity — a bare enumeration value is
    /// syntactically indistinguishable from an identifier reference, so `sparse`
    /// can collide with a type or a variable of that name and `.sparse` cannot.
    /// The bare form was in the corpus for one reason only: `@storage` was a
    /// no-op, so its spelling had never met an execution path.
    ///
    /// **The order of the branches is the design, not a style choice.** Both
    /// codes exist so the failures are told apart, and §13.3 assigns them
    /// different questions: step 3 is arity, name and value; step 4 is
    /// const-evaluability. The two are written as disjoint and are not —
    /// `.tag_path` satisfies BOTH, since `isConstEvaluable` returns true for it —
    /// so the name form must be resolved before the const test runs, or
    /// `@storage(.archetype)` would be reported as a wrong-typed constant instead
    /// of as a value outside the domain. The code would be the same and the
    /// REASON would be wrong.
    ///
    /// Step 3 asks four questions here and all four land on E0503, by its own
    /// wording (*number, name or type*): `@storage()` and `@storage(a, b)` fail
    /// on number, `@storage(kind: .sparse)` on name, `@storage(sparse)` on
    /// spelling, and `@storage(.archetype)` / `@storage(1)` on value. Only a
    /// well-formed positional argument that is neither a tag path nor a constant
    /// reaches step 4.
    fn checkStorageAnnotation(self: *TypeChecker, decl: ast_mod.ComponentDecl) !void {
        const annot = self.arena.storageAnnotation(decl) orelse return;

        // Step 3, arity.
        if (annot.args_len != 1) {
            try self.emit(.annotation_arg_mismatch, .error_, annot.span, "@storage takes exactly one argument, one of {s}", .{storage_domain_list});
            return;
        }

        const arg = self.arena.annot_args.items[annot.args_start];

        // Step 3, NAME — and this branch is here because writing the comment
        // and re-reading the code disagreed. `@storage(kind: .sparse)` carries a
        // value the domain does have and a name the schema does not declare, so
        // it is a step-3 failure; without this branch it fell through to the
        // const test, where the answer was `E0504 — must be a CONSTANT storage
        // mode`, false about the value and silent about the actual fault.
        if (arg.name != 0) {
            try self.emit(.annotation_arg_mismatch, .error_, annot.span, "@storage takes a positional argument, not a named one; write one of {s}", .{storage_domain_dotted});
            return;
        }

        // Step 3, value — the tag path, resolved against the domain's single
        // declaration.
        if (self.arena.annotationTagPathName(annot)) |name_id| {
            const name = self.arena.strings.slice(name_id);
            if (StorageKind.fromName(name) == null) {
                try self.emit(.annotation_arg_mismatch, .error_, annot.span, "'.{s}' is not a storage mode; @storage takes one of {s}", .{ name, storage_domain_dotted });
            }
            return;
        }

        // Step 3, SPELLING — a bare enumeration value. Its own branch and its own
        // message, because the fault is the sigil and not the value: falling
        // through would answer `E0504 — must be a constant`, which is false about
        // `sparse` and says nothing about what to write instead. An `ident` is
        // not const-evaluable, so without this branch that is exactly where it
        // would land.
        if (self.arena.exprKind(arg.value) == .ident) {
            const name = self.arena.strings.slice(self.arena.exprData(arg.value));
            try self.emit(.annotation_arg_mismatch, .error_, annot.span, "@storage's argument is an enum value: write '.{s}', not '{s}'", .{ name, name });
            return;
        }

        // Neither a tag path nor a bare name. A const-evaluable expression is
        // still a step-3 failure (a value outside the domain, e.g. `@storage(1)`
        // or `@storage("sparse")`); anything else fails step 4.
        if (isConstEvaluable(self.arena, arg.value)) {
            try self.emit(.annotation_arg_mismatch, .error_, annot.span, "@storage's argument must be a storage mode, one of {s}", .{storage_domain_dotted});
        } else {
            try self.emit(.annotation_arg_not_const, .error_, annot.span, "@storage's argument must be a constant storage mode, one of {s}", .{storage_domain_dotted});
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
        // The body statements sit on the async driver's frame-driven spine
        // (M1.0.11 E3): a statement-head `await` here is executable.
        const saved_susp = self.await_suspendable;
        self.await_suspendable = true;
        defer self.await_suspendable = saved_susp;
        // Function coloring context (M1.0.11 E4): `await` / async calls are legal
        // only when this body is `async`.
        const saved_async = self.current_is_async;
        self.current_is_async = decl.is_async;
        defer self.current_is_async = saved_async;
        // A `throws` fn may propagate a throw; a plain one may not (E0902).
        const saved_throw = self.current_can_throw;
        self.current_can_throw = decl.throws;
        defer self.current_can_throw = saved_throw;

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
                try self.emit(.return_type_mismatch, .error_, self.arena.exprSpan(decl.value), "function '{s}' body value type does not match its declared return type", .{self.arena.strings.slice(decl.name)});
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
            .has, .has_with_filter, .has_changed => {
                // `has T`, `has T { f == v }`, and `has T changed` (M0.8 E3) all
                // require `T` to be a declared component — same check, same code
                // (E1210). `changed` adds no new error case (a change-detection
                // filter on a non-component is just an unknown component); the
                // resolver/ruling deliberately does NOT mint a new E12xx for it.
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
            .has_expr_filter => {
                // `has T { expression }` (M0.8 E4 — the §6 general field
                // filter, item-4 ruling). Component check identical to `.has`;
                // the filter expression types in a FIELDS-ONLY scope (T's
                // fields bound by name) and must be bool (E1211). An unknown
                // name inside the filter surfaces as the regular E0102.
                const tname_slice = self.arena.strings.slice(node.type_name);
                if (self.symbols.get(node.type_name)) |sym| {
                    if (sym.kind != .component) {
                        try self.emit(.unknown_component_in_when, .error_, node.span, "'has' clause requires a component, '{s}' is a {s}", .{ tname_slice, @tagName(sym.kind) });
                    } else {
                        try ctx.components_in_when.put(self.gpa, node.type_name, {});
                        const decl = self.arena.component_decls.items[self.arena.itemData(sym.item_id)];
                        try self.checkWhenExprFilter(node, decl.fields_start, decl.fields_len);
                    }
                } else {
                    try self.emit(.unknown_component_in_when, .error_, node.span, "unknown component '{s}' in when clause", .{tname_slice});
                }
            },
            .resource_filter => {
                // `resource T { expression }` (M0.8 E4 — §6). Resource check
                // identical to `.resource`; same fields-only filter typing.
                const tname_slice = self.arena.strings.slice(node.type_name);
                if (self.symbols.get(node.type_name)) |sym| {
                    if (sym.kind != .resource) {
                        try self.emit(.resource_expected_in_when, .error_, node.span, "'resource' clause requires a resource, '{s}' is a {s}", .{ tname_slice, @tagName(sym.kind) });
                    } else {
                        try ctx.resources_in_when.put(self.gpa, node.type_name, {});
                        const decl = self.arena.resource_decls.items[self.arena.itemData(sym.item_id)];
                        try self.checkWhenExprFilter(node, decl.fields_start, decl.fields_len);
                    }
                } else {
                    try self.emit(.resource_expected_in_when, .error_, node.span, "unknown resource '{s}' in when clause", .{tname_slice});
                }
            },
            .expr_cond => {
                // Bare expression condition (M0.8 E4 — the §6 last arm,
                // item-4 ruling). Typed in the rule's own scope — params are
                // already bound in `ctx.locals` when `collectWhen` runs — and
                // must be bool. Component reads inside it require the
                // component in the when clause (the regular accessibility
                // check), so `entity has T and entity.get(T).f > 0` is the
                // canonical shape.
                const t = try self.synthExprE(node.filter_value, ctx);
                if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
                    try self.emit(.type_mismatch, .error_, node.span, "a bare when condition must be a bool expression", .{});
                }
            },
        }
    }

    /// Type a §6 general filter expression (`{ expression }` on `has T` /
    /// `resource T`, M0.8 E4) in a FIELDS-ONLY scope: each field of the
    /// filtered component/resource is bound by name to its declared type.
    /// Non-bool filters are E1211 (the field-filter code family).
    fn checkWhenExprFilter(self: *TypeChecker, node: ast_mod.WhenNode, fields_start: u32, fields_len: u32) !void {
        var scratch: RuleCtx = .{};
        defer scratch.deinit(self.gpa);
        var f: u32 = 0;
        while (f < fields_len) : (f += 1) {
            const field = self.arena.fields.items[fields_start + f];
            try scratch.locals.put(self.gpa, field.name, .{ .type_ = self.namedTypeToResolved(field.type_node), .is_mut = false });
        }
        const t = try self.synthExprE(node.filter_value, &scratch);
        if (t != .unknown and !(t == .builtin and t.builtin == .bool_)) {
            try self.emit(.invalid_field_filter, .error_, node.span, "a when filter expression must be bool", .{});
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

    /// Validate a run of `struct_lit_fields[start .. start+len]` against event
    /// `T`'s declared fields (M1.0.14 E2). Shared by `emit` and the
    /// `entity_event` / `global_event` payload filter: each `IDENT :
    /// expression` must name a field of `T` (`E1211 InvalidFieldFilter` else)
    /// and its value must fit that field's declared type (`E0200 TypeMismatch`
    /// else). `event_decl_index` indexes `arena.event_decls`.
    fn checkEventFieldRun(self: *TypeChecker, event_decl_index: u32, start: u32, len: u32, ctx_opt: ?*RuleCtx) !void {
        const decl = self.arena.event_decls.items[event_decl_index];
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const flit = self.arena.struct_lit_fields.items[start + i];
            var declared: ?ResolvedType = null;
            var f_i: u32 = 0;
            while (f_i < decl.fields_len) : (f_i += 1) {
                const f = self.arena.fields.items[decl.fields_start + f_i];
                if (f.name == flit.name) {
                    declared = self.namedTypeToResolved(f.type_node);
                    break;
                }
            }
            const actual = self.synthExpr(flit.value, ctx_opt);
            if (declared) |d| {
                if (d == .builtin and actual == .builtin and !self.literalTypeFits(d.builtin, flit.value, actual.builtin)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(flit.value), "event field '{s}' value type does not match its declared type", .{self.arena.strings.slice(flit.name)});
                }
            } else {
                try self.emit(.invalid_field_filter, .error_, self.arena.exprSpan(flit.value), "event '{s}' has no field '{s}'", .{ self.arena.strings.slice(decl.name), self.arena.strings.slice(flit.name) });
            }
        }
    }

    /// Type-check an `await entity_event` / `await global_event` target
    /// (M1.0.14 E2). `T` must be a declared `event` (`E0102` — fix-as-you-go:
    /// `global_event` previously accepted an undeclared `T` silently). For an
    /// entity-scoped target the designated field must resolve (`E0908`/`E0909`
    /// at the await site, via the shared `arena.resolveEventEntityTarget`). The
    /// optional payload filter is validated for both targets.
    fn checkEventTarget(self: *TypeChecker, await_id: NodeId, aw: ast_mod.AwaitExpr, entity_scoped: bool, ctx_opt: ?*RuleCtx) !void {
        const sym = self.symbols.get(aw.event_type);
        if (sym == null or sym.?.kind != .event_) {
            try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(await_id), "'{s}' is not a declared event", .{self.arena.strings.slice(aw.event_type)});
            return;
        }
        const decl_index = self.arena.itemData(sym.?.item_id);
        if (entity_scoped) {
            switch (self.arena.resolveEventEntityTarget(self.arena.event_decls.items[decl_index])) {
                .field => {},
                .none_entity => try self.emit(.event_not_entity_scoped, .error_, self.arena.exprSpan(await_id), "event '{s}' has no Entity field — 'await entity_event' requires a designated entity target", .{self.arena.strings.slice(aw.event_type)}),
                .ambiguous => try self.emit(.ambiguous_event_entity_target, .error_, self.arena.exprSpan(await_id), "event '{s}' has multiple Entity fields — annotate the target field with '@entity_target'", .{self.arena.strings.slice(aw.event_type)}),
            }
        }
        try self.checkEventFieldRun(decl_index, aw.filter_start, aw.filter_len, ctx_opt);
    }

    fn checkStmt(self: *TypeChecker, ctx: *RuleCtx, stmt_id: NodeId) !void {
        const kind = self.arena.stmtKind(stmt_id);
        const data = self.arena.stmtData(stmt_id);
        // M1.0.11 E3 — mark this statement's head `await` (if any) as allowed:
        // it is the full RHS of an expr-stmt / `let` init / simple assignment /
        // `return`. Any OTHER `await_expr` visited while checking this statement
        // is a sub-expression and is flagged E0904 in `synthExprE`. Reset first
        // (a non-head statement carries no allowed await).
        self.stmt_head_await = NodeId.none;
        switch (kind) {
            .expr_stmt => {
                const e: NodeId = @bitCast(data);
                if (self.arena.exprKind(e) == .await_expr) self.stmt_head_await = e;
            },
            .let_stmt => {
                const v = self.arena.let_stmts.items[data].value;
                if (self.arena.exprKind(v) == .await_expr) self.stmt_head_await = v;
            },
            .assign_stmt => {
                // Only a simple `local = await …` is a frame-driven head (the
                // interpreter's `assign_local`); a field/index target or a
                // compound op leaves the await as a sub-expression → E0904.
                const a = self.arena.assign_stmts.items[data];
                if (a.op == .assign and self.arena.exprKind(a.target) == .ident and self.arena.exprKind(a.value) == .await_expr) self.stmt_head_await = a.value;
            },
            .return_stmt => {
                const v: NodeId = @bitCast(data);
                if (!v.isNone() and self.arena.exprKind(v) == .await_expr) self.stmt_head_await = v;
            },
            else => {},
        }
        switch (kind) {
            .let_stmt => {
                const let = self.arena.let_stmts.items[data];
                var declared: ?ResolvedType = null;
                if (!let.type_annotation.isNone()) {
                    declared = self.namedTypeToResolved(let.type_annotation);
                    // The literal/constructor and annotation paths are the
                    // only two gates through which a `map_t` / `set_t` enters
                    // the program (fields and params reject composite types)
                    // — the Hash bound is checked at both.
                    if (declared.? == .map_t) try self.checkHashBound(declared.?.map_t.key, "map key type", "K: Hash", self.arena.typeNodeSpan(let.type_annotation));
                    if (declared.? == .set_t) try self.checkHashBound(declared.?.set_t, "set element type", "T: Hash", self.arena.typeNodeSpan(let.type_annotation));
                }
                // Anonymous `.{ … }` initializer against a struct annotation
                // (M0.8 E3-C tranche 8): check mode — the annotation is the
                // expected type (resolver-types §4), the same propagation as
                // the tranche-4 field-value position.
                const inferred = blk: {
                    if (declared != null and declared.? == .struct_t and self.arena.exprKind(let.value) == .struct_lit) {
                        const sl_data = self.arena.exprData(let.value);
                        if (self.arena.struct_lits.items[sl_data].type_name == 0) {
                            break :blk self.checkStructLitAgainst(let.value, sl_data, declared.?.struct_t, ctx) catch ResolvedType.unknown;
                        }
                    }
                    break :blk self.synthHeadValue(let.value, ctx);
                };
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
                // A `let` inside a closure body re-declaring a captured name
                // owns it from there (nested-scope shadowing) — it is no
                // longer a capture for the E0221 gate (M0.8 E3-C tranche 6).
                if (self.closure_captures) |caps| _ = caps.remove(let.name);
                try ctx.locals.put(self.gpa, let.name, .{ .type_ = final, .is_mut = let.is_mut or value_is_get_mut });
            },
            .assign_stmt => {
                const assign = self.arena.assign_stmts.items[data];
                // Target must be either a mut local, or a field via get_mut.
                const target_kind = self.arena.exprKind(assign.target);
                if (target_kind == .ident) {
                    const name_id = self.arena.exprData(assign.target);
                    if (ctx.locals.get(name_id)) |local| {
                        // E0221 (M0.8 E3-C tranche 6, resolver-types §8.2):
                        // a closure body cannot mutate a captured binding —
                        // captures are value snapshots in both backends. The
                        // capture check precedes the mutability check (a
                        // captured `let mut` is still immutable here).
                        const is_captured = if (self.closure_captures) |caps| caps.contains(name_id) else false;
                        if (is_captured) {
                            const span = self.arena.exprSpan(assign.target);
                            try self.emit(.closure_cannot_mutate_capture, .error_, span, "closure cannot mutate captured binding '{s}' (pass it as an argument or mutate through entity.get_mut)", .{self.arena.strings.slice(name_id)});
                        } else if (!local.is_mut) {
                            const span = self.arena.exprSpan(assign.target);
                            try self.emit(.type_mismatch, .error_, span, "cannot assign to immutable binding (use 'let mut')", .{});
                        }
                        const rhs_type = self.synthHeadValue(assign.value, ctx);
                        if (local.type_ == .builtin and rhs_type == .builtin and !self.literalTypeFits(local.type_.builtin, assign.value, rhs_type.builtin)) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(assign.value), "assignment value type does not match binding type", .{});
                        }
                        // Compound assignment on strings (`s += t`) is not in
                        // the M0.8 minimal subset (only `+` concatenation is —
                        // stdlib §12.4): reject here so neither backend sees
                        // one (interp would fail at runtime, codegen would
                        // emit invalid Zig — fail loud, not divergently).
                        if (assign.op != .assign and ((local.type_ == .builtin and local.type_.builtin == .string_) or (rhs_type == .builtin and rhs_type.builtin == .string_))) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(assign.target), "compound assignment on strings is not in the M0.8 minimal subset (use 's = s + ...')", .{});
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
                // A structural `spawn(...)` is statement-position only (§4.5, no
                // body handle): check it here so the value-position refusal
                // (E0304) in `synthExpr` does NOT fire on a legal statement use.
                // Every other expression types normally.
                if (self.arena.exprKind(expr_id) == .spawn_struct) {
                    _ = try self.checkSpawnStruct(expr_id, self.arena.exprData(expr_id), ctx, false);
                } else {
                    _ = self.synthExpr(expr_id, ctx);
                }
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
                    } else if (iter_t == .set_t) {
                        // Set for-in is not delivered with the tranche-3bis
                        // subset (no differential requires it) — rejected
                        // here so NEITHER backend sees one, the established
                        // out-of-subset policy. Must precede `elementType`,
                        // which would otherwise bind the element.
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(f.iterable), "set for-in is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{});
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
                // M1.0.12 E3 — a loop opened here is INSIDE any enclosing
                // concurrency branch: its `break`/`continue` are legal (E0907
                // fires only on the boundary-crossing ones).
                self.conc_loop_depth += 1;
                defer self.conc_loop_depth -= 1;
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
                // M1.0.12 E3 — in-branch loop, mirror of the `for` arm.
                self.conc_loop_depth += 1;
                defer self.conc_loop_depth -= 1;
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
                // M1.0.12 E3 — E0907: the break must not cross the enclosing
                // concurrency-branch task boundary (§9.2).
                try self.checkConcControlFlow(stmt_id, b.label, "break");
            },
            .continue_stmt => {
                // M1.0.12 E3 — E0907, mirror of `break` (the label rides in
                // the statement's `data`; `0` = unlabeled).
                try self.checkConcControlFlow(stmt_id, data, "continue");
            },
            .throw_stmt => {
                // `throw expression` (M0.8 error handling, E3-C tranche 2).
                // The thrown value must be the builtin `Error` struct — part1
                // §10.2 ("no custom error hierarchy") + `etch-grammar.md`
                // l.793 ("peut throw une Error"): the catch binding is
                // statically an `Error`, so a non-Error operand is rejected
                // here (no runtime coercion). The interpreter's carrier stays
                // an arbitrary `Value` — unreachable for checked programs.
                const t = self.arena.throw_stmts.items[data];
                const vt = self.synthExpr(t.value, ctx);
                const is_error = vt == .struct_t and vt.struct_t == self.arena.error_type_name;
                if (!is_error and vt != .unknown) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(t.value), "thrown value must be the builtin 'Error' struct (part1 §10.2)", .{});
                }
            },
            .try_catch_stmt => {
                // `try { ... } catch err { ... }` (M0.8 error handling). Check
                // both bodies; the caught binding is statically the builtin
                // `Error` struct (E3-C tranche 2 — the throw rule above pins
                // every thrown value to `Error`), so `err.message` /
                // `err.code` resolve through the ordinary struct machinery.
                const tc = self.arena.try_catch_stmts.items[data];
                // Inside the TRY body a throw has somewhere to go (E0902). The
                // CATCH body is deliberately left at the enclosing value: a
                // throw raised there re-propagates past this construct, so it
                // needs whatever the surrounding context offers, not `true`.
                const saved_try_throw = self.current_can_throw;
                self.current_can_throw = true;
                var i: u32 = 0;
                while (i < tc.try_len) : (i += 1) {
                    try self.checkStmt(ctx, @bitCast(self.arena.extra.items[tc.try_start + i]));
                }
                self.current_can_throw = saved_try_throw;
                try ctx.locals.put(self.gpa, tc.catch_name, .{ .type_ = .{ .struct_t = self.arena.error_type_name }, .is_mut = false });
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
                //
                // M1.0.12 E3 — E0906: inside a concurrency branch, `return` is
                // legal ONLY in a `race` branch (winner-return propagation at
                // the race site, §9.5); in a `sync` branch an early return
                // contradicts the join-all, and in a `branch`/`spawn` body the
                // parent has potentially already advanced — no propagation
                // site (`etch-resolver-types.md` §9.2). Asymmetric by design
                // (brief Notes) — do NOT generalize.
                if (self.conc_branch) |ck| {
                    if (ck != .race) {
                        try self.emit(.illegal_return_in_concurrency_branch, .error_, self.arena.stmtSpan(stmt_id), "'return' is illegal in a '{s}' {s} (only a 'race' branch may return — the winner's return propagates at the race site)", .{ @tagName(ck), if (ck == .sync) "branch" else "body" });
                    }
                }
                const value: NodeId = @bitCast(data);
                if (!value.isNone()) {
                    const vt = self.synthHeadValue(value, ctx);
                    if (self.current_fn_return) |ret| {
                        if (ret == .builtin and vt == .builtin and !self.literalTypeFits(ret.builtin, value, vt.builtin)) {
                            try self.emit(.return_type_mismatch, .error_, self.arena.exprSpan(value), "return value type does not match the declared return type", .{});
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
                    // Field-value validation is shared with the `entity_event` /
                    // `global_event` payload filter (M1.0.14 E2).
                    try self.checkEventFieldRun(self.arena.itemData(sym.?.item_id), em.fields_start, em.fields_len, ctx);
                }
            },
            .tag_mutation_stmt => {
                // `entity.add_tag(.path)` / `entity.remove_tag(.path)` (M0.8 E3,
                // `etch-grammar.md` §4.4). The receiver must be an `Entity`
                // (E0833); the operand must be a declared leaf tag (E0830) —
                // a mutation sets or clears a single bit. Resolves only; the
                // deferred structural mutation runs in the interpreter / codegen.
                const tm = self.arena.tag_mutation_stmts.items[data];
                const recv_t = self.synthExpr(tm.receiver, ctx);
                if (recv_t != .builtin or recv_t.builtin != .entity) {
                    const op_name = switch (tm.kind) {
                        .add => "add_tag",
                        .remove => "remove_tag",
                    };
                    try self.emit(.tag_invalid_operation, .error_, self.arena.exprSpan(tm.receiver), "'{s}' applies to an Entity, not this receiver", .{op_name});
                }
                try self.validateTagMutationPath(tm.path);
            },
            .race_stmt, .sync_stmt => {
                // `race { race_branch* }` / `sync { sync_branch* }` (M1.0.12
                // E3, §4.2). Async-context requirement first (E0901 — §4.2:
                // the async constructs are only available in an async
                // context). Each conditional guard (`if cond =>`) types as bool
                // in the PARENT scope (it is evaluated there, synchronously,
                // at construct entry — §9.5); each branch statement is then
                // checked inside its branch context (E0906/E0907; E0905 keeps
                // applying recursively — §9.2 revision 2).
                if (!self.current_is_async) {
                    try self.emit(.async_call_in_non_async_context, .error_, self.arena.stmtSpan(stmt_id), "'{s}' is only allowed in an 'async fn' or 'async rule'", .{if (kind == .race_stmt) "race" else "sync"});
                }
                const range: ast_mod.RaceStmt = if (kind == .race_stmt)
                    self.arena.race_stmts.items[data]
                else blk: {
                    const ss = self.arena.sync_stmts.items[data];
                    break :blk .{ .branches_start = ss.branches_start, .branches_len = ss.branches_len };
                };
                const branch_kind: ConcBranchKind = if (kind == .race_stmt) .race else .sync;
                var i: u32 = 0;
                while (i < range.branches_len) : (i += 1) {
                    const br = self.arena.concurrency_branches.items[range.branches_start + i];
                    if (!br.cond.isNone()) {
                        const cond_t = self.synthExpr(br.cond, ctx);
                        if (cond_t == .builtin and cond_t.builtin != .bool_) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(br.cond), "conditional branch guard must be a bool expression", .{});
                        }
                    }
                    try self.checkConcBranchStmt(ctx, br.stmt, branch_kind);
                }
            },
            .branch_stmt => {
                // `branch { }` (M1.0.12 E3, §4.2) — fire-and-forget detached
                // task. Async context required (E0901); the body is checked
                // inside a `.branch` context (return → E0906, escaping
                // break/continue → E0907; E0905 keeps applying recursively).
                if (!self.current_is_async) {
                    try self.emit(.async_call_in_non_async_context, .error_, self.arena.stmtSpan(stmt_id), "'branch' is only allowed in an 'async fn' or 'async rule'", .{});
                }
                const bs = self.arena.branch_stmts.items[data];
                try self.checkConcBodyRun(ctx, bs.body_start, bs.body_len, .branch);
            },
            .spawn_stmt => {
                // `[let h =] spawn { }` (M1.0.12 E3, §4.2) — detached task
                // with a handle. Async context required (E0901); body checked
                // inside a `.spawn` context. The binding types as the builtin
                // `TaskHandle` (§2.2, non-POD) and is bound AFTER the body:
                // the task starts on a snapshot of the parent scope taken
                // before the parent binds the handle (§9.8) — the handle does
                // not exist inside the body.
                if (!self.current_is_async) {
                    try self.emit(.async_call_in_non_async_context, .error_, self.arena.stmtSpan(stmt_id), "'spawn {{ ... }}' is only allowed in an 'async fn' or 'async rule'", .{});
                }
                const ss = self.arena.spawn_stmts.items[data];
                try self.checkConcBodyRun(ctx, ss.body_start, ss.body_len, .spawn);
                if (ss.binding != 0) {
                    try ctx.locals.put(self.gpa, ss.binding, .{ .type_ = .{ .builtin = .task_handle }, .is_mut = false });
                }
            },
            .timer_stmt => {
                // `[let t =] after/every/after_unscaled(d) { }` (M1.0.13 E4,
                // §9.10). A timer is usable in ANY body, async or not — it
                // carries no `{async}` effect (absent from the §9.4
                // builtin-effect table), so there is no E0901 gate on the
                // statement itself.
                const ts = self.arena.timer_stmts.items[data];
                // The duration argument is a full expression typed `Duration`
                // (§9.10), evaluated once at scheduling time (E6).
                const arg_t = self.synthExpr(ts.arg, ctx);
                if (arg_t != .unknown and !(arg_t == .builtin and arg_t.builtin == .duration)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(ts.arg), "timer argument must be a Duration expression", .{});
                }
                try self.checkTimerBodyRun(ctx, ts.body_start, ts.body_len);
                // The binding types as the builtin `TimerHandle` (§2.2,
                // non-POD), bound AFTER the body: the callback runs on a
                // scope snapshot taken at scheduling, before the parent binds
                // the handle (E6) — the handle does not exist inside the body.
                if (ts.binding != 0) {
                    try ctx.locals.put(self.gpa, ts.binding, .{ .type_ = .{ .builtin = .timer_handle }, .is_mut = false });
                }
            },
            else => {},
        }
    }

    /// Check a timer callback body (M1.0.13 E4, §9.10) — a SYNCHRONOUS
    /// context: `current_is_async` is forced false so an `await` / async call
    /// inside it emits `E0901` even when the scheduling rule is async (the
    /// timer carries no `{async}` effect). The concurrency-branch state
    /// resets across the boundary too: the callback is a detached synchronous
    /// context executed run-to-completion at firing (E6), not part of an
    /// enclosing task branch.
    fn checkTimerBodyRun(self: *TypeChecker, ctx: *RuleCtx, start: u32, len: u32) TypeError!void {
        const saved_async = self.current_is_async;
        const saved_branch = self.conc_branch;
        const saved_depth = self.conc_loop_depth;
        const saved_base = self.conc_labels_base;
        self.current_is_async = false;
        self.conc_branch = null;
        self.conc_loop_depth = 0;
        self.conc_labels_base = self.conc_labels.items.len;
        defer {
            self.current_is_async = saved_async;
            self.conc_branch = saved_branch;
            self.conc_loop_depth = saved_depth;
            self.conc_labels_base = saved_base;
        }
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            try self.checkStmt(ctx, @bitCast(self.arena.extra.items[start + i]));
        }
    }

    /// Enter a concurrency-branch context around one `race`/`sync` branch
    /// statement (M1.0.12 E3): E0906/E0907 anchor to the INNERMOST branch and
    /// the in-branch loop depth and label window restart at the boundary. The
    /// branch body stays an ORDINARY async context otherwise — E0905 applies
    /// recursively inside it (§9.2 revision 2: the constructs relocate the
    /// `await`, they do not replace it).
    fn checkConcBranchStmt(self: *TypeChecker, ctx: *RuleCtx, stmt: NodeId, kind: ConcBranchKind) TypeError!void {
        const saved_branch = self.conc_branch;
        const saved_depth = self.conc_loop_depth;
        const saved_base = self.conc_labels_base;
        self.conc_branch = kind;
        self.conc_loop_depth = 0;
        self.conc_labels_base = self.conc_labels.items.len;
        defer {
            self.conc_branch = saved_branch;
            self.conc_loop_depth = saved_depth;
            self.conc_labels_base = saved_base;
        }
        try self.checkStmt(ctx, stmt);
    }

    /// `checkConcBranchStmt` for a `branch`/`spawn` BODY (a statement run in
    /// `arena.extra`) — same context discipline, applied around the whole run.
    fn checkConcBodyRun(self: *TypeChecker, ctx: *RuleCtx, start: u32, len: u32, kind: ConcBranchKind) TypeError!void {
        const saved_branch = self.conc_branch;
        const saved_depth = self.conc_loop_depth;
        const saved_base = self.conc_labels_base;
        self.conc_branch = kind;
        self.conc_loop_depth = 0;
        self.conc_labels_base = self.conc_labels.items.len;
        defer {
            self.conc_branch = saved_branch;
            self.conc_loop_depth = saved_depth;
            self.conc_labels_base = saved_base;
        }
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            try self.checkStmt(ctx, @bitCast(self.arena.extra.items[start + i]));
        }
    }

    /// True when an async call at `id` has its `{async}` effect consumed
    /// (M1.0.12 E3, `etch-resolver-types.md` §9.2 revision 2): it is the
    /// direct target of the `await` currently being typed — the SOLE
    /// call-grain consumer. The four concurrency constructs do NOT consume
    /// it: they relocate the suspension into a child task, so a bare async
    /// call inside their bodies is E0905 like anywhere else (at execution it
    /// would hit the sync call path's `is_async` fail-loud gate).
    fn consumesAsyncEffect(self: *const TypeChecker, id: NodeId) bool {
        return @as(u32, @bitCast(id)) == @as(u32, @bitCast(self.awaited_call));
    }

    /// E0907 (M1.0.12 E3, `etch-resolver-types.md` §9.2): a `break`/`continue`
    /// inside a concurrency branch must target a loop INSIDE the branch — an
    /// unlabeled one needs an in-branch loop (depth > 0); a labeled one needs
    /// its label among the loops opened inside the branch (the label window
    /// past `conc_labels_base`). Loops fully inside the branch keep working.
    fn checkConcControlFlow(self: *TypeChecker, stmt_id: NodeId, label: StringId, comptime what: []const u8) !void {
        if (self.conc_branch == null) return;
        if (label == 0) {
            if (self.conc_loop_depth > 0) return;
        } else {
            for (self.conc_labels.items[self.conc_labels_base..]) |l| {
                if (l == label) return;
            }
        }
        try self.emit(.control_flow_escapes_task_branch, .error_, self.arena.stmtSpan(stmt_id), "'" ++ what ++ "' targets a loop outside the enclosing concurrency branch — control flow cannot cross the task boundary", .{});
    }

    /// Validate a tag-mutation operand path against the global tag table (M0.8
    /// E3, `etch-grammar.md` §4.4). `add_tag` / `remove_tag` set or clear a
    /// single bit, so the path must resolve to a declared **leaf**; an unknown
    /// path or a namespace is `E0830 TagPathInvalid` (the bare-category mutation
    /// form is deferred, consistent with the query operands).
    fn validateTagMutationPath(self: *TypeChecker, path_node: NodeId) !void {
        const tp = self.arena.tag_paths.items[self.arena.exprData(path_node)];
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);
        var i: u32 = 0;
        while (i < tp.segs_len) : (i += 1) {
            if (i > 0) try buf.append(self.gpa, '.');
            try buf.appendSlice(self.gpa, self.arena.strings.slice(self.arena.tag_path_segs.items[tp.segs_start + i]));
        }
        const table = self.tag_table orelse return;
        if (table.leafBit(buf.items) == null) {
            try self.emit(.tag_path_invalid, .error_, self.arena.exprSpan(path_node), "unknown tag path '.{s}' (add_tag/remove_tag require a declared leaf tag)", .{buf.items});
        }
    }

    // ─── Expression typing ───────────────────────────────────────────────

    const TypeError = std.mem.Allocator.Error;

    fn synthExpr(self: *TypeChecker, id: NodeId, ctx_opt: ?*RuleCtx) ResolvedType {
        return self.synthExprE(id, ctx_opt) catch ResolvedType.unknown;
    }

    /// Synthesize a statement-head VALUE expression (`let` init / assignment RHS /
    /// `return` operand) with the correct suspendable context (M1.0.11 E3): the
    /// value is on the frame-driven spine ONLY if it IS this statement's head
    /// `await` (`let x = await f()`). Any other value (an `if`/`match`/`loop`/
    /// block, or an expression merely containing an `await`) is synchronous, so a
    /// statement-head `await` nested inside it is inexecutable → E0904.
    fn synthHeadValue(self: *TypeChecker, id: NodeId, ctx_opt: ?*RuleCtx) ResolvedType {
        const saved = self.await_suspendable;
        self.await_suspendable = @as(u32, @bitCast(id)) == @as(u32, @bitCast(self.stmt_head_await));
        defer self.await_suspendable = saved;
        return self.synthExpr(id, ctx_opt);
    }

    fn synthExprE(self: *TypeChecker, id: NodeId, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const kind = self.arena.exprKind(id);
        const data = self.arena.exprData(id);
        switch (kind) {
            .int_lit => return .{ .builtin = .int_ },
            .float_lit => return .{ .builtin = .float_ },
            .duration_lit => return .{ .builtin = .duration },
            .time_lit => return .{ .builtin = .time },
            .color_lit => return .{ .builtin = .color },
            .bool_lit => return .{ .builtin = .bool_ },
            .string_lit => return ResolvedType{ .builtin = .string_ },
            // Interpolated string `"a {x} b"` (M0.8 E3-C tranche 1c, stdlib
            // §12.5): each embedded expression must be Display-able within
            // the minimal subset — int / i32 / u32 / float / f64 / bool /
            // string. `f32` is rejected: the interpreter widens it to f64
            // before formatting, so its text could diverge from the
            // codegen's native-f32 formatting (byte-exact guard). The rest
            // of the §4.2 Display catalogue is stdlib Phase 1+ → fail loud.
            .string_interp => {
                const si = self.arena.string_interps.items[data];
                var k: u32 = 0;
                while (k < si.n_exprs) : (k += 1) {
                    const e: NodeId = @bitCast(self.arena.extra.items[si.exprs_start + k]);
                    const t = try self.synthExprE(e, ctx_opt);
                    const ok = t == .builtin and switch (t.builtin) {
                        .int_, .i32_, .u32_, .float_, .f64_, .bool_, .string_ => true,
                        else => false,
                    };
                    if (!ok and t != .unknown) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(e), "interpolation of this type is not in the M0.8 minimal subset (stdlib Display activation is Phase 1+)", .{});
                    }
                }
                return ResolvedType{ .builtin = .string_ };
            },
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
            .loc_expr => {
                // `@loc…` (§3.2, M0.8 E4 — item 10): structurally a string.
                // Key/fingerprint resolution (E1627) is E5 with `locale`;
                // interpolation args type freely here.
                const le = self.arena.loc_exprs.items[data];
                var a: u32 = 0;
                while (a < le.args_len) : (a += 1) {
                    _ = try self.synthExprE(self.arena.struct_lit_fields.items[le.args_start + a].value, ctx_opt);
                }
                return .{ .builtin = .string_ };
            },
            .tag_query => {
                // Postfix tag query (§3.2 `tag_expr`, M0.8 E4): the receiver
                // must be an Entity (E0833 TagInvalidOperation), the operand
                // paths must resolve in the global tag table (E1212-family
                // via `validateTagPath`); the query is a bool. Evaluation is
                // fail-loud in both backends (flagged bound).
                const tq = self.arena.tag_query_exprs.items[data];
                const recv_t = try self.synthExprE(tq.receiver, ctx_opt);
                if (recv_t != .unknown and !(recv_t == .builtin and recv_t.builtin == .entity)) {
                    try self.emit(.tag_invalid_operation, .error_, self.arena.exprSpan(id), "a tag query requires an Entity receiver", .{});
                }
                const tf = self.arena.tag_filters.items[tq.filter];
                var oi: u32 = 0;
                while (oi < tf.operand_len) : (oi += 1) {
                    try self.validateTagPath(self.arena.tag_operands.items[tf.operand_start + oi], tf.op);
                }
                return .{ .builtin = .bool_ };
            },
            .field_access => {
                const fa = self.arena.field_accesses.items[data];
                // `recv?.field` (M0.8 E3-C tranche 4): optional payloads are
                // builtin scalars in M0.8 — they have no fields, so the
                // chained field form has nothing to resolve against. The
                // interpreter stays the reference for the op set delivered
                // (`?.method`, `??`, `!`, patterns).
                if (fa.opt_chain) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "optional-chained field access is not in the M0.8 minimal subset (scalar optional payloads have no fields)", .{});
                    return ResolvedType.unknown;
                }
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
                    // Builtin engine resource (M1.0.13 E4): resolved against
                    // the `builtin_resources` descriptor table — no AST
                    // declaration, auto-registered by the runtime (E5). The
                    // when-clause gate does not apply: the time resources are
                    // ambient, readable from any rule (the spec examples read
                    // `get(GameTime).dt` without a `when resource` clause).
                    if (builtinResourceByName(tname) != null) {
                        return .{ .resource = mg.type_name };
                    }
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
                        if (!ctx.unrestricted_ecs_access and !ctx.resources_in_when.contains(mg.type_name)) {
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
                    if (!ctx.unrestricted_ecs_access and !ctx.components_in_when.contains(mg.type_name)) {
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
            .measure_expr => return try self.synthMeasure(id, data, ctx_opt),
            .if_expr => return try self.synthIf(id, data, ctx_opt),
            // Reaching a structural spawn through `synthExpr` means it is being
            // used as a VALUE (let binding, field receiver, call argument) — the
            // v0.6 refusal (E0304): structural spawn is statement-position only,
            // no body handle (§4.5). `checkStmt` handles the legal statement
            // position before this arm is reached.
            .spawn_struct => return try self.checkSpawnStruct(id, data, ctx_opt, true),
            // M1.0.11 E2/E3 — type an `await`. The `future` form (`await f()`)
            // carries the awaited call's declared return type, so `let x = await f()`
            // binds the right type (and the inner call is type-checked here — arg
            // count, etc.). The wake-condition forms (`wait` / `wait_unscaled` /
            // `entity_event` / `global_event`) produce no value. E3 placement
            // (E0904): an `await` that is not this statement's head await is a
            // sub-expression (`some(await f())`, `a + await b`) — rejected; hoist
            // it into a `let`. Function coloring (E0901) is added in E4.
            .await_expr => {
                // E0904 fires unless this `await` is BOTH the statement head AND
                // on the frame-driven spine — a statement-head `await` inside a
                // synchronously-evaluated VALUE block (e.g. `let x = if c { await
                // f() }`) is inexecutable, so it is rejected too (M1.0.11 E3).
                const is_head = @as(u32, @bitCast(id)) == @as(u32, @bitCast(self.stmt_head_await));
                if (!is_head or !self.await_suspendable) {
                    try self.emit(.await_not_statement_head, .error_, self.arena.exprSpan(id), "`await` must be the full right-hand expression of a statement on the async path — hoist it into a `let` (Phase-1 restriction)", .{});
                }
                // Function coloring (M1.0.11 E4, §9.3): `await` is an async effect
                // — only an `async fn`/`async rule` may use it.
                if (!self.current_is_async) {
                    try self.emit(.async_call_in_non_async_context, .error_, self.arena.exprSpan(id), "`await` is only allowed in an `async fn` or `async rule`", .{});
                }
                const aw = self.arena.awaitExpr(id);
                switch (aw.target_kind) {
                    // `wait` / `wait_unscaled` take a Duration LITERAL, validated
                    // at the interpreter (literal-only, M1.0.11/13) — nothing to
                    // synthesize here.
                    .wait, .wait_unscaled => {},
                    .entity_event => {
                        // The entity operand (evaluated once at suspension in the
                        // interpreter) must type `Entity` — reuse E0200 (M1.0.14 E2;
                        // this operand was never synthesized before).
                        const et = self.synthExpr(aw.entity_expr, ctx_opt);
                        if (!(et == .builtin and et.builtin == .entity)) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(aw.entity_expr), "the first argument of entity_event(e, T) must be an Entity", .{});
                        }
                        try self.checkEventTarget(id, aw, true, ctx_opt);
                    },
                    .global_event => try self.checkEventTarget(id, aw, false, ctx_opt),
                    .future => {
                        // The direct call is CONSUMED by this await (M1.0.12 E3,
                        // §9.2) — exempt from E0905 while it is synthesized. Only
                        // the target itself is exempt: an async call among its
                        // ARGUMENTS is still bare.
                        const saved_awaited = self.awaited_call;
                        self.awaited_call = aw.arg_expr;
                        defer self.awaited_call = saved_awaited;
                        const t = try self.synthExprE(aw.arg_expr, ctx_opt);
                        const ak = self.arena.exprKind(aw.arg_expr);
                        if (ak == .fn_call or ak == .method_call) return t;
                        // Non-call target: the handle-await form (M1.0.12 E3,
                        // §9.8) — the target must be a TaskHandle. The result is
                        // unit in Phase 1 (spawn bodies have no value channel —
                        // brief Notes); `unknown` ≈ unit, the house convention.
                        if (t == .builtin and t.builtin == .task_handle) return ResolvedType.unknown;
                        // A `TimerHandle` is NOT awaitable (M1.0.13 E4, §9.10):
                        // a timer is not a task — no join semantics. Precise
                        // message ahead of the generic rejection below.
                        if (t == .builtin and t.builtin == .timer_handle) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(aw.arg_expr), "a TimerHandle is not awaitable — a timer is not a task (its only operation is 'cancel()', par. 9.10)", .{});
                            return ResolvedType.unknown;
                        }
                        if (t != .unknown) {
                            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(aw.arg_expr), "await target must be a direct async call or a TaskHandle", .{});
                        }
                        return ResolvedType.unknown;
                    },
                }
                return ResolvedType.unknown;
            },
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
    /// stdlib §14 / §15 pin `K: Hash + Eq` on map keys and `T: Hash + Eq` on
    /// set elements, and the builtin Hash set excludes float/f32/f64 (NaN !=
    /// NaN, hash undefined — stdlib §4.3): a float map key or set element is
    /// an invalid program, rejected at the resolver so NEITHER backend ever
    /// sees one (E0601 BoundNotSatisfied). Generalized from the tranche-4
    /// `checkMapKeyHashable` for the tranche-3bis Set vertical — same code,
    /// same wording family, `what`/`bound` carry the per-collection nouns.
    fn checkHashBound(self: *TypeChecker, t: BuiltinType, comptime what: []const u8, comptime bound: []const u8, span: SourceSpan) !void {
        if (t.isFloat()) {
            try self.emit(.bound_not_satisfied, .error_, span, what ++ " does not satisfy the '" ++ bound ++ "' bound (float/f32/f64 are not hashable); wrap the float in a struct with a custom Hash", .{});
        }
    }

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
            } else {
                key_bt = kt.builtin;
                try self.checkHashBound(kt.builtin, "map key type", "K: Hash", self.arena.exprSpan(entry.key));
            }
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
            // M1.0.12 E3 — a `loop` opened here (incl. a labeled one) is
            // INSIDE any enclosing concurrency branch: its `break`/`continue`
            // (by depth or by label) are legal; E0907 fires only on the
            // boundary-crossing ones.
            self.conc_loop_depth += 1;
            defer self.conc_loop_depth -= 1;
            if (lp.label != 0) try self.conc_labels.append(self.gpa, lp.label);
            defer if (lp.label != 0) {
                _ = self.conc_labels.pop();
            };
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

    /// Type a `measure { block }` expression (M1.0.15, §17 erratum). Result type
    /// is always `Duration` (the elapsed wall-clock; the block's own value is
    /// discarded). Legal ONLY inside a test body — anywhere else it is
    /// `E0910 MeasureOutsideTest` (wall-clock never enters deterministic gameplay
    /// code). The block statements are checked in the current (sync test) context.
    fn synthMeasure(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        if (!self.in_test_body) {
            try self.emit(.measure_outside_test, .error_, self.arena.exprSpan(id), "measure {{ … }} is only valid inside a test body", .{});
        }
        const m = self.arena.measure_exprs.items[data];
        if (ctx_opt) |ctx| {
            var i: u32 = 0;
            while (i < m.body_len) : (i += 1) {
                const stmt: NodeId = @bitCast(self.arena.extra.items[m.body_start + i]);
                try self.checkStmt(ctx, stmt);
            }
        }
        if (!m.value.isNone()) _ = try self.synthExprE(m.value, ctx_opt);
        return .{ .builtin = .duration };
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

    fn synthArg(self: *TypeChecker, call: ast_mod.CallExpr, i: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const arg: NodeId = @bitCast(self.arena.extra.items[call.args_start + i]);
        return try self.synthExprE(arg, ctx_opt);
    }

    /// Whether a type has a meaningful runtime equality for `assert_eq`/`assert_neq`
    /// (M1.0.15): scalars/strings (`.builtin`, incl. `string_`/`Entity`), enums,
    /// or `unknown` (already-diagnosed). Aggregates lack a structural `Value.eql`.
    fn assertComparable(t: ResolvedType) bool {
        return switch (t) {
            .builtin, .enum_t, .unknown => true,
            else => false,
        };
    }

    /// Whether a type is a float (or `unknown`, already-diagnosed) — the operand
    /// constraint for `assert_approx` (M1.0.15): a tolerance comparison is
    /// float-only, so int operands are rejected at type-check (symmetry with the
    /// rest of the assert family) rather than failing loud at runtime.
    fn isFloatType(t: ResolvedType) bool {
        return t == .unknown or (t == .builtin and t.builtin.isFloat());
    }

    /// Resolve a builtin free-function call by name (M1.0.15). Returns the result
    /// type when `name` is a builtin, else `null` (the caller falls through to the
    /// user-fn lookup, then E0102). Global builtins — the assertion family
    /// (`assert_eq`/`assert_neq`/`assert_approx`/`assert_some`/`assert_none`,
    /// `etch-stdlib.md §19.4`) + `panic`/`todo`/`unreachable` — resolve anywhere;
    /// test-scoped builtins (`test_world`, `tick_until`) only inside a test body.
    /// Statement-effect builtins yield `unknown` (≈ unit); args are synth-checked
    /// so nested expressions are typed and light shape checks surface misuse.
    fn synthBuiltinCall(self: *TypeChecker, id: NodeId, call: ast_mod.CallExpr, callee_name: StringId, ctx_opt: ?*RuleCtx) TypeError!?ResolvedType {
        const name = self.arena.strings.slice(callee_name);
        const span = self.arena.exprSpan(id);

        // ── Test-scoped (only inside a test body; else null → E0102) ──
        if (self.in_test_body) {
            if (std.mem.eql(u8, name, "test_world")) {
                if (call.args_len != 0) try self.emit(.arg_count_mismatch, .error_, span, "test_world() takes no arguments", .{});
                return ResolvedType.test_world;
            }
            if (std.mem.eql(u8, name, "tick_until")) {
                // `tick_until(pred: () -> bool, timeout: Duration) -> bool`.
                if (call.args_len != 2) {
                    try self.emit(.arg_count_mismatch, .error_, span, "tick_until(pred: () -> bool, timeout: Duration) takes 2 arguments", .{});
                } else {
                    _ = try self.synthArg(call, 0, ctx_opt);
                    const t1 = try self.synthArg(call, 1, ctx_opt);
                    if (t1 == .builtin and t1.builtin != .duration) {
                        try self.emit(.type_mismatch, .error_, span, "tick_until timeout must be a Duration", .{});
                    }
                }
                return .{ .builtin = .bool_ };
            }
        }

        // ── Global assertion family + panic/todo/unreachable ──
        if (std.mem.eql(u8, name, "assert_eq") or std.mem.eql(u8, name, "assert_neq")) {
            if (call.args_len < 2 or call.args_len > 3) {
                try self.emit(.arg_count_mismatch, .error_, span, "{s}(a, b[, msg]) takes 2 or 3 arguments", .{name});
            } else {
                const ta = try self.synthArg(call, 0, ctx_opt);
                const tb = try self.synthArg(call, 1, ctx_opt);
                // Only scalar / enum / string values compare at runtime (M1.0.15
                // review fix): aggregates (struct/array/map/set/optional/closure)
                // have no structural `Value.eql`, so an aggregate operand would
                // false-fail `assert_eq` and false-PASS `assert_neq`. Reject them
                // fail-loud rather than mis-compare.
                if (!assertComparable(ta) or !assertComparable(tb)) {
                    try self.emit(.type_mismatch, .error_, span, "{s} compares scalar / string / enum values (structs, arrays, maps, sets, optionals are not comparable in v0.6)", .{name});
                } else if (ta == .builtin and tb == .builtin and ta.builtin != tb.builtin) {
                    try self.emit(.type_mismatch, .error_, span, "{s} compares two values of the same type", .{name});
                }
                if (call.args_len == 3) _ = try self.synthArg(call, 2, ctx_opt);
            }
            return ResolvedType.unknown;
        }
        if (std.mem.eql(u8, name, "assert_approx")) {
            if (call.args_len < 2 or call.args_len > 4) {
                try self.emit(.arg_count_mismatch, .error_, span, "assert_approx(a, b[, tolerance][, msg]) takes 2 to 4 arguments", .{});
            } else {
                // Float-only by construction (tolerance comparison): constrain a,
                // b, and the optional tolerance at type-check — symmetric with the
                // rest of the family (the runtime keeps a defensive fail-loud).
                const ta = try self.synthArg(call, 0, ctx_opt);
                const tb = try self.synthArg(call, 1, ctx_opt);
                if (!isFloatType(ta) or !isFloatType(tb)) {
                    try self.emit(.type_mismatch, .error_, span, "assert_approx compares float values (use assert_eq for other types)", .{});
                }
                if (call.args_len >= 3) {
                    const tt = try self.synthArg(call, 2, ctx_opt);
                    if (!isFloatType(tt)) {
                        try self.emit(.type_mismatch, .error_, span, "assert_approx tolerance must be a float", .{});
                    }
                }
                if (call.args_len == 4) _ = try self.synthArg(call, 3, ctx_opt);
            }
            return ResolvedType.unknown;
        }
        if (std.mem.eql(u8, name, "assert_some") or std.mem.eql(u8, name, "assert_none")) {
            if (call.args_len < 1 or call.args_len > 2) {
                try self.emit(.arg_count_mismatch, .error_, span, "{s}(value[, msg]) takes 1 or 2 arguments", .{name});
            } else {
                const tv = try self.synthArg(call, 0, ctx_opt);
                if (tv != .optional and tv != .unknown) {
                    try self.emit(.type_mismatch, .error_, span, "{s} requires an optional (T?) value", .{name});
                }
                if (call.args_len == 2) _ = try self.synthArg(call, 1, ctx_opt);
            }
            return ResolvedType.unknown;
        }
        if (std.mem.eql(u8, name, "panic")) {
            if (call.args_len != 1) {
                try self.emit(.arg_count_mismatch, .error_, span, "panic(msg) takes 1 argument", .{});
            } else _ = try self.synthArg(call, 0, ctx_opt);
            return ResolvedType.unknown;
        }
        if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "unreachable")) {
            if (call.args_len > 1) {
                try self.emit(.arg_count_mismatch, .error_, span, "{s}([msg]) takes 0 or 1 arguments", .{name});
            } else if (call.args_len == 1) _ = try self.synthArg(call, 0, ctx_opt);
            return ResolvedType.unknown;
        }
        return null;
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
                // Builtin free functions (M1.0.15) — the assertion family +
                // panic/todo/unreachable (global), test_world/tick_until
                // (test-scoped). Resolved before the user-fn lookup so a builtin
                // name is never shadowed by a stdlib decl; a test-scoped builtin
                // outside a test body returns null → falls through to E0102
                // (§32: "fall through to E0102").
                if (try self.synthBuiltinCall(id, call, callee_name, ctx_opt)) |t| return t;
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
        // Named arguments on a closure call are an M0.8 bound (item-16
        // scope: declared fns + methods; flagged for the gate) — the
        // binding machinery targets declared signatures.
        if (call.names_start != ast_mod.no_arg_names) {
            try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "named arguments require a declared fn or method callee (M0.8 bound)", .{});
            return ResolvedType.unknown;
        }
        if (ce.params_len != call.args_len) {
            try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "closure called with {d} argument(s), expected {d}", .{ call.args_len, ce.params_len });
            return ResolvedType.unknown;
        }
        const ctx = ctx_opt orelse return ResolvedType.unknown;
        // Snapshot the caller-scope binding names BEFORE the params bind:
        // those are the body's potential captures (`etch-resolver-types.md`
        // §8.1 — any body ident resolving to the parent scope). Params are
        // excluded below; a body-local `let` removes its name at the
        // `let_stmt` check. The set gates E0221 in the assign-stmt path.
        var captures: std.AutoHashMapUnmanaged(StringId, void) = .empty;
        defer captures.deinit(self.gpa);
        var locals_it = ctx.locals.iterator();
        while (locals_it.next()) |e| try captures.put(self.gpa, e.key_ptr.*, {});
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
            _ = captures.remove(p.name);
            try ctx.locals.put(self.gpa, p.name, .{ .type_ = ptype, .is_mut = false });
        }
        const saved_captures = self.closure_captures;
        self.closure_captures = &captures;
        defer self.closure_captures = saved_captures;
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

    /// Validate a call's argument BINDING against a parameter-name list
    /// (M0.8 E4 named arguments, §3.3 — item-16 ruling): arity (E0203),
    /// every named label names a parameter, no parameter bound twice
    /// (positionally or by name), every parameter bound at the end. Returns
    /// false (after emitting E0203) when the binding is unsound — callers
    /// skip the per-argument type checks to avoid cascades.
    fn checkCallBinding(self: *TypeChecker, id: NodeId, args_start: u32, args_len: u32, names_start: u32, param_names: []const StringId, callee_kind: []const u8, callee_name: StringId) !bool {
        _ = args_start;
        if (param_names.len != args_len) {
            try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "{s} '{s}' called with {d} argument(s), expected {d}", .{ callee_kind, self.arena.strings.slice(callee_name), args_len, param_names.len });
            return false;
        }
        if (names_start == ast_mod.no_arg_names) return true;
        const names = self.arena.call_arg_names.items[names_start .. names_start + args_len];
        var n_positional: u32 = 0;
        while (n_positional < args_len and names[n_positional] == 0) n_positional += 1;
        var ok = true;
        var i: u32 = n_positional;
        while (i < args_len) : (i += 1) {
            const label = names[i];
            var param_idx: ?usize = null;
            for (param_names, 0..) |pn, pi| {
                if (pn == label) {
                    param_idx = pi;
                    break;
                }
            }
            if (param_idx == null) {
                try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "{s} '{s}' has no parameter named '{s}'", .{ callee_kind, self.arena.strings.slice(callee_name), self.arena.strings.slice(label) });
                ok = false;
                continue;
            }
            if (param_idx.? < n_positional) {
                try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "parameter '{s}' of {s} '{s}' is already bound positionally", .{ self.arena.strings.slice(label), callee_kind, self.arena.strings.slice(callee_name) });
                ok = false;
                continue;
            }
            var j: u32 = n_positional;
            while (j < i) : (j += 1) {
                if (names[j] == label) {
                    try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "parameter '{s}' of {s} '{s}' is bound twice", .{ self.arena.strings.slice(label), callee_kind, self.arena.strings.slice(callee_name) });
                    ok = false;
                    break;
                }
            }
        }
        // Arity matches and every named arg bound a distinct non-positional
        // parameter → by counting, every parameter is bound.
        return ok;
    }

    /// Collect a callee's parameter names into a caller-owned buffer.
    fn fnParamNames(self: *TypeChecker, params_start: u32, params_len: u32, buf: *std.ArrayListUnmanaged(StringId)) !void {
        var i: u32 = 0;
        while (i < params_len) : (i += 1) {
            try buf.append(self.gpa, self.arena.fn_params.items[params_start + i].name);
        }
    }

    /// Type a free-function call `f(args)` to a top-level `fn` (M0.8 E2). Checks
    /// the argument binding (named arguments per §3.3, M0.8 E4 — E0203) then
    /// each bound argument against its declared parameter type; the result
    /// is the declared return type (`unknown` for a void fn).
    fn synthFreeFnCall(self: *TypeChecker, id: NodeId, call: ast_mod.CallExpr, item_id: NodeId, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const decl = self.arena.fn_decls.items[self.arena.itemData(item_id)];
        // Function coloring (M1.0.11 E4, §9.3): calling an `async fn` from a
        // non-async context is E0901. (A legal async→async call is via `await`,
        // which reaches here with `current_is_async` true.)
        if (decl.is_async and !self.current_is_async) {
            try self.emit(.async_call_in_non_async_context, .error_, self.arena.exprSpan(id), "cannot call `async fn` '{s}' from a non-async context (needs an `async fn`/`async rule` + `await`)", .{self.arena.strings.slice(decl.name)});
        } else if (decl.is_async and !self.consumesAsyncEffect(id)) {
            // M1.0.12 E3 — E0905: a BARE async call in an async context. The
            // `await` is the SOLE call-grain consumer of the `{async}` effect
            // (§9.2 revision 2) — the four constructs relocate the suspension,
            // they do not consume it.
            try self.emit(.unconsumed_async_effect, .error_, self.arena.exprSpan(id), "bare call to `async fn` '{s}' — consume the async effect with `await` (inside spawn/branch/race/sync bodies too: the constructs relocate the await into a child task, they do not replace it)", .{self.arena.strings.slice(decl.name)});
        }
        // E0902 (M1.1.15.2 G2): a `throws` callee needs somewhere for its throw
        // to go — an enclosing `try`/`catch`, or a `throws` caller.
        if (decl.throws and !self.current_can_throw) {
            try self.emitUnhandledThrows(id, self.arena.strings.slice(decl.name));
        }
        const ret: ResolvedType = if (decl.return_type.isNone()) ResolvedType.unknown else self.namedTypeToResolved(decl.return_type);
        var pnames: std.ArrayListUnmanaged(StringId) = .empty;
        defer pnames.deinit(self.gpa);
        try self.fnParamNames(decl.params_start, decl.params_len, &pnames);
        if (!try self.checkCallBinding(id, call.args_start, call.args_len, call.names_start, pnames.items, "function", decl.name)) {
            return ret;
        }
        if (decl.generics_len > 0) return try self.synthGenericFnCall(id, call, decl, ctx_opt);
        var i: u32 = 0;
        while (i < decl.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[decl.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            const arg = self.arena.callArgForParam(call.args_start, call.args_len, call.names_start, i, p.name) orelse continue;
            const arg_t = try self.synthExprE(arg, ctx_opt);
            if (ptype == .builtin and arg_t == .builtin and !self.literalTypeFits(ptype.builtin, arg, arg_t.builtin)) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "argument type does not match the parameter type of function '{s}'", .{self.arena.strings.slice(decl.name)});
            }
        }
        return ret;
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

        var pnames: std.ArrayListUnmanaged(StringId) = .empty;
        defer pnames.deinit(self.gpa);
        try self.fnParamNames(decl.params_start, decl.params_len, &pnames);
        var i: u32 = 0;
        while (i < decl.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[decl.params_start + i];
            const arg = self.arena.callArgForParam(call.args_start, call.args_len, call.names_start, i, p.name) orelse continue;
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
    /// Resolve an enum-variant shorthand `.variant` against an expected enum
    /// type — check mode, resolver-types §3.5/§4 (M0.8 E3-C tranche 4). In
    /// expression position the parser stores the bare `tag_path` with the
    /// variant ident as the expr data directly (multi-segment paths are a
    /// parse error there). E0105 when the variant does not exist.
    fn checkEnumShorthand(self: *TypeChecker, value: NodeId, enum_name: StringId) TypeError!ResolvedType {
        const variant: StringId = self.arena.exprData(value);
        if (self.enumVariantIndex(enum_name, variant) != null) return .{ .enum_t = enum_name };
        try self.emit(.enum_variant_not_found, .error_, self.arena.exprSpan(value), "enum '{s}' has no variant '{s}'", .{ self.arena.strings.slice(enum_name), self.arena.strings.slice(variant) });
        return ResolvedType.unknown;
    }

    fn synthStructLit(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const sl = self.arena.struct_lits.items[data];
        // Anonymous `.{ … }` in synth position (M0.8 E3-C tranche 8): the
        // form is check-mode-ONLY (resolver-types §4) — without an expected
        // type from the context there is no struct to resolve against. The
        // wired contexts are the let annotation and the typed field value;
        // fn-arg / return positions are not wired (no differential requires
        // them) and land here.
        if (sl.type_name == 0) {
            try self.emit(.ambiguous_type, .error_, self.arena.exprSpan(id), "anonymous struct literal '.{{ … }}' needs an expected struct type from its context (let annotation or typed field value)", .{});
            return ResolvedType.unknown;
        }
        return try self.checkStructLitAgainst(id, data, sl.type_name, ctx_opt);
    }

    /// Check a struct literal's fields against the declared struct
    /// `struct_name` (M0.8 E2 block 3; split out in E3-C tranche 8 so the
    /// anonymous `.{ … }` form checks through the same point with the name
    /// supplied by its context — check mode, resolver-types §4).
    fn checkStructLitAgainst(self: *TypeChecker, id: NodeId, data: u32, struct_name: StringId, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const sl = self.arena.struct_lits.items[data];
        const sym = self.symbols.get(struct_name);
        if (sym == null or sym.?.kind != .struct_) {
            try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(id), "'{s}' is not a struct type", .{self.arena.strings.slice(struct_name)});
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
            // Check mode (resolver-types §4 + §3.5, M0.8 E3-C tranche 4):
            // the declared field type is the expected type, so a bare
            // `.variant` shorthand in field-value position resolves against
            // a declared enum field — the part1 §10.2 canonical form
            // `Error { code: .io_fail }` — and an anonymous `.{ … }` value
            // resolves against a declared struct field (tranche 8, the same
            // propagation extended from the bare variant to the whole
            // literal).
            const actual = blk: {
                if (declared != null and declared.? == .enum_t and self.arena.exprKind(flit.value) == .tag_path) {
                    break :blk try self.checkEnumShorthand(flit.value, declared.?.enum_t);
                }
                if (declared != null and declared.? == .struct_t and self.arena.exprKind(flit.value) == .struct_lit) {
                    const inner_data = self.arena.exprData(flit.value);
                    if (self.arena.struct_lits.items[inner_data].type_name == 0) {
                        break :blk try self.checkStructLitAgainst(flit.value, inner_data, declared.?.struct_t, ctx_opt);
                    }
                }
                break :blk try self.synthExprE(flit.value, ctx_opt);
            };
            if (declared) |d| {
                if (d == .builtin and actual == .builtin and !self.literalTypeFits(d.builtin, flit.value, actual.builtin)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(flit.value), "struct-literal field '{s}' value type does not match its declared type", .{self.arena.strings.slice(flit.name)});
                }
                if (d == .struct_t and actual == .struct_t and d.struct_t != actual.struct_t) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(flit.value), "struct-literal field '{s}' value type does not match its declared type", .{self.arena.strings.slice(flit.name)});
                }
            } else {
                try self.emit(.invalid_field_filter, .error_, self.arena.exprSpan(id), "struct '{s}' has no field '{s}'", .{ self.arena.strings.slice(struct_name), self.arena.strings.slice(flit.name) });
            }
        }
        // A builtin-`Error` literal must provide `message` and `code` (part1
        // §10.2 declares no defaults; `source` is the omittable chaining
        // field). Bounded to `Error` — general struct-literal completeness
        // stays permissive (declared defaults fill omissions), but Error's
        // fields have no defaults the two backends could agree on.
        if (struct_name == self.arena.error_type_name) {
            const required = [_][]const u8{ "message", "code" };
            for (required) |req| {
                var provided = false;
                var li: u32 = 0;
                while (li < sl.fields_len) : (li += 1) {
                    const flit = self.arena.struct_lit_fields.items[sl.fields_start + li];
                    if (std.mem.eql(u8, self.arena.strings.slice(flit.name), req)) {
                        provided = true;
                        break;
                    }
                }
                if (!provided) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "'Error' literal must provide field '{s}' (part1 §10.2)", .{req});
                }
            }
        }
        // A struct-typed field must be provided (E0208, M0.8 E3-C tranche 8):
        // like Error's fields, it has no declared default the two backends
        // could agree on (the codegen's `.{}` default-fill and the interp's
        // zero-fill would diverge on nested declared defaults).
        var df_i: u32 = 0;
        while (df_i < decl.fields_len) : (df_i += 1) {
            const f = self.arena.fields.items[decl.fields_start + df_i];
            if (self.namedTypeToResolved(f.type_node) != .struct_t) continue;
            var provided = false;
            var li: u32 = 0;
            while (li < sl.fields_len) : (li += 1) {
                if (self.arena.struct_lit_fields.items[sl.fields_start + li].name == f.name) {
                    provided = true;
                    break;
                }
            }
            if (!provided) {
                try self.emit(.struct_field_missing, .error_, self.arena.exprSpan(id), "struct-typed field '{s}' must be provided in the literal (no declared default)", .{self.arena.strings.slice(f.name)});
            }
        }
        return .{ .struct_t = struct_name };
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
            if (mc.opt_chain) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "optional chain '?.' cannot target an associated function (the receiver is a type, not an optional)", .{});
                return ResolvedType.unknown;
            }
            const type_name = self.arena.exprData(mc.receiver);
            // Builtin-type associated calls (M0.8 E3-C tranche 3bis):
            // `Set.new()` / `Set.from([...])`. Checked BEFORE the user
            // `impl` lookup — `Set` is a builtin stdlib type and is not
            // user-overridable (stdlib §2.6), so the builtin route masks
            // any user `impl Set` rather than racing it.
            if (std.mem.eql(u8, self.arena.strings.slice(type_name), "Set")) {
                // Builtin associated calls take positional args only (M0.8
                // E4 item-16 bound: named args target declared signatures).
                if (mc.names_start != ast_mod.no_arg_names) {
                    try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "named arguments require a declared fn or method callee (M0.8 bound)", .{});
                    return ResolvedType.unknown;
                }
                return try self.synthSetAssociated(id, mc, ctx_opt);
            }
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

        // Service dispatch (M1.1.15.2 G1, `etch-grammar.md` §20.4): the
        // receiver is a bare lowercase IDENT naming a declared `service`.
        // Checked BEFORE `synthExprE`, which would otherwise report the
        // receiver as an unknown identifier and never reach the method at all.
        //
        // A LOCAL SHADOWS a service: locals are the inner scope, and the
        // alternative — a service silently winning over a variable the author
        // just bound — would be a name capture with no diagnostic.
        if (self.arena.exprKind(mc.receiver) == .ident) {
            const recv_id: StringId = self.arena.exprData(mc.receiver);
            const shadowed = if (ctx_opt) |ctx| ctx.locals.get(recv_id) != null else false;
            if (!shadowed) {
                if (self.services.get(self.arena.strings.slice(recv_id))) |svc| {
                    if (mc.opt_chain) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "optional chain '?.' cannot target a service (a service is not a value)", .{});
                        return ResolvedType.unknown;
                    }
                    return try self.checkServiceCall(id, mc, svc, ctx_opt);
                }
            }
        }

        const raw_t = try self.synthExprE(mc.receiver, ctx_opt);

        // Named arguments bind against DECLARED signatures (M0.8 E4 item-16
        // bound): struct methods route through `checkMethodArgs` below;
        // every builtin-method route (string / collections / ECS access)
        // is positional-only — reject up front rather than silently
        // ignoring the labels.
        if (mc.names_start != ast_mod.no_arg_names and raw_t != .struct_t and raw_t != .unknown) {
            try self.emit(.arg_count_mismatch, .error_, self.arena.exprSpan(id), "named arguments require a declared fn or method callee (M0.8 bound)", .{});
            return ResolvedType.unknown;
        }

        // `recv?.method(args)` — optional chain (M0.8 E3-C tranche 4, part1
        // §6.6): the method dispatches against the payload type and the
        // result re-wraps in an optional (`none` short-circuits at runtime).
        if (mc.opt_chain) {
            if (raw_t == .unknown) return ResolvedType.unknown;
            if (raw_t != .optional) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "optional chain '?.' requires an optional receiver", .{});
                return ResolvedType.unknown;
            }
            const res = try self.dispatchMethodOnType(id, mc, .{ .builtin = raw_t.optional }, ctx_opt);
            if (res == .builtin) return .{ .optional = res.builtin };
            return ResolvedType.unknown;
        }
        return try self.dispatchMethodOnType(id, mc, raw_t, ctx_opt);
    }

    /// Type a `Set.assoc(...)` builtin associated call (M0.8 E3-C tranche
    /// 3bis, stdlib §15.1 — minimal faithful subset). `Set.new()` is
    /// element-less: it synthesizes `unknown` and the let annotation types
    /// the binding (the same policy as the empty map literal `[:]`).
    /// `Set.from(arr)` takes its element type from the array argument;
    /// stdlib §15 pins `T: Hash + Eq` and §4.3 excludes float/f32/f64 from
    /// the builtin Hash set, so a float element is an invalid program for
    /// BOTH backends (E0601 — the same redressement as map keys).
    /// `with_capacity` (a generic call form) and anything else §15.1 is a
    /// stdlib activation (Phase 1+).
    fn synthSetAssociated(self: *TypeChecker, id: NodeId, mc: ast_mod.MethodCall, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const method_slice = self.arena.strings.slice(mc.method_name);
        if (std.mem.eql(u8, method_slice, "new")) {
            if (mc.args_len != 0) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "'Set.new' takes no arguments", .{});
            }
            return ResolvedType.unknown; // element-less: the annotation types the binding
        }
        if (std.mem.eql(u8, method_slice, "from")) {
            if (mc.args_len != 1) {
                try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "'Set.from' takes exactly one array argument", .{});
                return ResolvedType.unknown;
            }
            const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
            const arg_t = try self.synthExprE(arg, ctx_opt);
            const elem: BuiltinType = switch (arg_t) {
                .array_fixed => |info| info.elem,
                .array_dyn => |bt| bt,
                .unknown => return ResolvedType.unknown,
                else => {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "'Set.from' expects an array argument", .{});
                    return ResolvedType.unknown;
                },
            };
            try self.checkHashBound(elem, "set element type", "T: Hash", self.arena.exprSpan(arg));
            return .{ .set_t = elem };
        }
        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "associated function '{s}' on 'Set' is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{method_slice});
        return ResolvedType.unknown;
    }

    /// M1.0.9 B2 — validate the single string argument of an `Entity` extension
    /// method (`activate_extension` / `deactivate_extension` / `has_extension`).
    /// A non-builtin / `unknown` arg type is left alone (no cascading error), the
    /// same shape as the collection-method arg checks above.
    fn checkExtensionNameArg(self: *TypeChecker, id: NodeId, mc: ast_mod.MethodCall, method_slice: []const u8, ctx_opt: ?*RuleCtx) TypeError!void {
        if (mc.args_len != 1) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "Entity method '{s}' takes exactly one (string) argument", .{method_slice});
            return;
        }
        const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
        const arg_t = try self.synthExprE(arg, ctx_opt);
        if (arg_t == .builtin and arg_t.builtin != .string_) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "Entity method '{s}' expects a string extension name", .{method_slice});
        }
    }

    /// M1.0.10 E2 — type-check a structural `spawn(...)` node (`etch-grammar.md`
    /// §3.2 / §4.5). The spawn is statement-position only (no body handle, v0.6):
    /// `value_position` is `true` when reached through `synthExpr` (a value use:
    /// `let e = spawn(…)`, `spawn(…).field`, `spawn(…)` as an argument) → E0304;
    /// `checkStmt` passes `false` for the legal `expr_stmt` position. The
    /// prefab-name form is recognized but refused (E0305, gated on the prefab
    /// runtime). The component-literal form validates each argument names a
    /// declared `component`. Returns `unknown` (statement effect, no value).
    fn checkSpawnStruct(self: *TypeChecker, id: NodeId, data: u32, ctx_opt: ?*RuleCtx, value_position: bool) TypeError!ResolvedType {
        _ = ctx_opt;
        const ss = self.arena.spawn_structs.items[data];
        if (value_position) {
            try self.emit(.spawn_handle_unavailable, .error_, self.arena.exprSpan(id), "structural spawn produces no usable handle in a body (v0.6) — call spawn(...) as a statement, do not bind or use its result", .{});
        }
        if (ss.is_prefab) {
            try self.emit(.prefab_spawn_not_executable, .error_, self.arena.exprSpan(id), "prefab spawn 'spawn(\"...\")' is not executable in Phase 1 (gating on the prefab runtime)", .{});
            return ResolvedType.unknown;
        }
        var i: u32 = 0;
        while (i < ss.args_len) : (i += 1) {
            const arg: NodeId = @bitCast(self.arena.extra.items[ss.args_start + i]);
            try self.checkStructuralComponentLiteral(arg);
        }
        return ResolvedType.unknown;
    }

    /// M1.0.10 E2 — validate one component-literal argument of `spawn(...)` /
    /// `entity.add(...)`: it must be a `TYPE_IDENT { ... }` struct literal naming
    /// a declared `component`, and its field set + field-value types must match
    /// the component declaration. The `struct_lit` shares the `struct_lit_fields`
    /// storage with a `ComponentInstance`, so the scene/prefab validation path
    /// (`checkComponentInstance` → `checkInstanceField` / `checkInstanceFieldForeign`,
    /// local + imported) is reused rather than reinvented — `weld check` (C1.6)
    /// must catch the same field errors as scene/prefab. The node is NOT routed
    /// through `synthStructLit` (which requires a `struct`, not a `component`).
    fn checkStructuralComponentLiteral(self: *TypeChecker, arg: NodeId) TypeError!void {
        if (self.arena.exprKind(arg) != .struct_lit) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "expected a component literal 'T {{ ... }}'", .{});
            return;
        }
        const sl = self.arena.struct_lits.items[self.arena.exprData(arg)];
        if (sl.type_name == 0) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "a component literal needs an explicit component type ('T {{ ... }}')", .{});
            return;
        }
        // A non-component type name surfaces through `code_type` (E0200 — the
        // structural "not a component" path); declared component fields are
        // checked with the dedicated E0306/E0307 codes.
        const ci: ast_mod.ComponentInstance = .{
            .type_name = sl.type_name,
            .fields_start = sl.fields_start,
            .fields_len = sl.fields_len,
            .span = self.arena.exprSpan(arg),
        };
        try self.checkComponentInstance(ci, .type_mismatch, .structural_component_field_unknown, .structural_component_field_type_invalid);
    }

    /// M1.0.15 — validate `world.spawn_with([C {…}, …])`: exactly one array
    /// literal whose every element is a component literal. Reuses
    /// `checkStructuralComponentLiteral` (the same E0306/E0307 as scene / prefab /
    /// structural `spawn`) — bespoke checking, NOT a general heterogeneous array
    /// type (a component list is not a typed `T[]`).
    fn checkSpawnWithArg(self: *TypeChecker, id: NodeId, mc: ast_mod.MethodCall, ctx_opt: ?*RuleCtx) TypeError!void {
        _ = ctx_opt;
        if (mc.args_len != 1) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "spawn_with takes exactly one component-literal list '[C {{ ... }}, ...]'", .{});
            return;
        }
        const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
        if (self.arena.exprKind(arg) != .array_lit) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "spawn_with expects a component-literal list '[C {{ ... }}, ...]'", .{});
            return;
        }
        const al = self.arena.array_lits.items[self.arena.exprData(arg)];
        if (al.is_fill) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "spawn_with does not accept fill syntax '[x; n]'", .{});
            return;
        }
        var i: u32 = 0;
        while (i < al.elements_len) : (i += 1) {
            const elem: NodeId = @bitCast(self.arena.extra.items[al.elements_start + i]);
            try self.checkStructuralComponentLiteral(elem);
        }
    }

    /// M1.0.15 — validate `world.emit(T {…})`: exactly one event-literal arg
    /// naming a declared `event`, fields checked via the shared
    /// `checkEventFieldRun` (identical to the `emit` statement, §32).
    fn checkWorldEmitArg(self: *TypeChecker, id: NodeId, mc: ast_mod.MethodCall, ctx_opt: ?*RuleCtx) TypeError!void {
        if (mc.args_len != 1) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "emit takes exactly one event literal 'T {{ ... }}'", .{});
            return;
        }
        const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
        if (self.arena.exprKind(arg) != .struct_lit) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "emit expects an event literal 'T {{ ... }}'", .{});
            return;
        }
        const sl = self.arena.struct_lits.items[self.arena.exprData(arg)];
        if (sl.type_name == 0) {
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "emit needs an explicit event type ('T {{ ... }}')", .{});
            return;
        }
        const sym = self.symbols.get(sl.type_name);
        if (sym == null or sym.?.kind != .event_) {
            try self.emit(.undefined_symbol, .error_, self.arena.exprSpan(arg), "'{s}' is not a declared event", .{self.arena.strings.slice(sl.type_name)});
            return;
        }
        try self.checkEventFieldRun(self.arena.itemData(sym.?.item_id), sl.fields_start, sl.fields_len, ctx_opt);
    }

    /// M1.0.10 E2 — validate a type name used in a structural mutation
    /// (`entity.remove(T)` and the component-literal types of `spawn` / `add`)
    /// resolves to a declared `component`. Mirrors the `when has` component
    /// lookup (`self.symbols.get` + `SymbolKind.component`).
    fn checkStructuralComponentName(self: *TypeChecker, name: StringId, span: SourceSpan) TypeError!void {
        const tname = self.arena.strings.slice(name);
        if (self.symbols.get(name)) |sym| {
            if (sym.kind != .component) {
                try self.emit(.type_mismatch, .error_, span, "structural mutation requires a component, '{s}' is a {s}", .{ tname, @tagName(sym.kind) });
            }
        } else {
            try self.emit(.type_mismatch, .error_, span, "unknown component '{s}' in structural mutation", .{tname});
        }
    }

    /// Dispatch an instance method call against an already-typed receiver
    /// (`etch-resolver-types.md §5.5` strict order: inherent → trait →
    /// builtin → service). Split from `synthMethodCall` so the optional
    /// chain dispatches the same way on the payload type (M0.8 E3-C
    /// tranche 4) — same logical point, both entry paths.
    fn dispatchMethodOnType(self: *TypeChecker, id: NodeId, mc: ast_mod.MethodCall, recv_t: ResolvedType, ctx_opt: ?*RuleCtx) TypeError!ResolvedType {
        const method_slice = self.arena.strings.slice(mc.method_name);

        // Builtin string methods (M0.8 sub-slice C tranche 1 — minimal faithful
        // subset). `len` → int (byte length). Any other §12 String method is a
        // stdlib activation (Phase 1+), not Level-A language → diagnostic here +
        // fail-loud codegen.
        if (recv_t == .builtin and recv_t.builtin == .string_) {
            if (std.mem.eql(u8, method_slice, "len")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "string method 'len' takes no arguments", .{});
                }
                return ResolvedType{ .builtin = .int_ };
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "string method '{s}' is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{method_slice});
            return ResolvedType.unknown;
        }

        // Builtin dynamic-array methods (M0.8 E3-C tranche 3 — minimal
        // faithful subset of stdlib §13.2). `push(item)` (mut receiver,
        // element-typed arg, void return) and `len()` (→ int). Any other §13
        // method is a stdlib activation (Phase 1+) → diagnostic here +
        // fail-loud codegen.
        if (recv_t == .array_dyn) {
            if (std.mem.eql(u8, method_slice, "push")) {
                if (mc.args_len != 1) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "array method 'push' takes exactly one argument", .{});
                } else {
                    const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    const arg_t = try self.synthExprE(arg, ctx_opt);
                    if (arg_t == .builtin and !self.literalTypeFits(recv_t.array_dyn, arg, arg_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "pushed value type does not match the array element type", .{});
                    }
                }
                try self.checkMutCollectionReceiver(mc, ctx_opt);
                return ResolvedType.unknown; // void return
            }
            if (std.mem.eql(u8, method_slice, "len")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "array method 'len' takes no arguments", .{});
                }
                return ResolvedType{ .builtin = .int_ };
            }
            // `pop() -> T?` (stdlib §13.2, M0.8 E3-C tranche 4): the
            // optional-returning accessor unlocked by the Optional ops —
            // lifts the tranche-3 rejection. `mut self` like `push`.
            if (std.mem.eql(u8, method_slice, "pop")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "array method 'pop' takes no arguments", .{});
                }
                try self.checkMutCollectionReceiver(mc, ctx_opt);
                return .{ .optional = recv_t.array_dyn };
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "array method '{s}' is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{method_slice});
            return ResolvedType.unknown;
        }

        // Builtin map methods (M0.8 E3-C tranche 3 — minimal faithful subset
        // of stdlib §14.2). `insert(k, v)` (mut receiver, key/value-typed
        // args; its `V?` return is out of the subset — statement use only)
        // and `len()` (→ int). Any other §14 method is stdlib Phase 1+.
        if (recv_t == .map_t) {
            if (std.mem.eql(u8, method_slice, "insert")) {
                if (mc.args_len != 2) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "map method 'insert' takes exactly two arguments (key, value)", .{});
                } else {
                    const karg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    const varg: NodeId = @bitCast(self.arena.extra.items[mc.args_start + 1]);
                    const k_t = try self.synthExprE(karg, ctx_opt);
                    const v_t = try self.synthExprE(varg, ctx_opt);
                    if (k_t == .builtin and !self.literalTypeFits(recv_t.map_t.key, karg, k_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(karg), "inserted key type does not match the map key type", .{});
                    }
                    if (v_t == .builtin and !self.literalTypeFits(recv_t.map_t.value, varg, v_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(varg), "inserted value type does not match the map value type", .{});
                    }
                }
                try self.checkMutCollectionReceiver(mc, ctx_opt);
                return ResolvedType.unknown; // V? return is out of the subset
            }
            if (std.mem.eql(u8, method_slice, "len")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "map method 'len' takes no arguments", .{});
                }
                return ResolvedType{ .builtin = .int_ };
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "map method '{s}' is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{method_slice});
            return ResolvedType.unknown;
        }

        // Builtin set methods (M0.8 E3-C tranche 3bis — minimal faithful
        // subset of stdlib §15.2). `insert(item)` (mut receiver, element-typed
        // arg; its `bool` return is out of the subset — statement use only),
        // `contains(item)` (→ bool) and `len()` (→ int). The §15.2 remainder
        // (remove, clear, the set-algebra ops, iter) is a stdlib activation
        // (Phase 1+).
        if (recv_t == .set_t) {
            if (std.mem.eql(u8, method_slice, "insert")) {
                if (mc.args_len != 1) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "set method 'insert' takes exactly one argument", .{});
                } else {
                    const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    const arg_t = try self.synthExprE(arg, ctx_opt);
                    if (arg_t == .builtin and !self.literalTypeFits(recv_t.set_t, arg, arg_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "inserted item type does not match the set element type", .{});
                    }
                }
                try self.checkMutCollectionReceiver(mc, ctx_opt);
                return ResolvedType.unknown; // bool return is out of the subset
            }
            if (std.mem.eql(u8, method_slice, "contains")) {
                if (mc.args_len != 1) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "set method 'contains' takes exactly one argument", .{});
                } else {
                    const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    const arg_t = try self.synthExprE(arg, ctx_opt);
                    if (arg_t == .builtin and !self.literalTypeFits(recv_t.set_t, arg, arg_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "item type does not match the set element type", .{});
                    }
                }
                return ResolvedType{ .builtin = .bool_ };
            }
            if (std.mem.eql(u8, method_slice, "len")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "set method 'len' takes no arguments", .{});
                }
                return ResolvedType{ .builtin = .int_ };
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "set method '{s}' is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{method_slice});
            return ResolvedType.unknown;
        }

        // M1.0.12 E3 — builtin TaskHandle method (§9.8): `cancel()` — no args,
        // statement-effect (`unknown` ≈ unit; idempotent at runtime, E5). The
        // handle's only other operation is `await h` (handled in the await
        // arm); anything else is an error with a pointer to both.
        if (recv_t == .builtin and recv_t.builtin == .task_handle) {
            if (std.mem.eql(u8, method_slice, "cancel")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "TaskHandle method 'cancel' takes no arguments", .{});
                }
                return ResolvedType.unknown;
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "no method '{s}' on a TaskHandle (only 'cancel()'; join with 'await h')", .{method_slice});
            return ResolvedType.unknown;
        }

        // M1.0.13 E4 — builtin TimerHandle method (§9.10): `cancel()` — no
        // args, statement-effect (`unknown` ≈ unit), idempotent at runtime
        // (E6). Its ONLY operation: a timer is not a task — no `await t`,
        // no join, nothing else.
        if (recv_t == .builtin and recv_t.builtin == .timer_handle) {
            if (std.mem.eql(u8, method_slice, "cancel")) {
                if (mc.args_len != 0) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "TimerHandle method 'cancel' takes no arguments", .{});
                }
                return ResolvedType.unknown;
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "no method '{s}' on a TimerHandle (only 'cancel()'; a timer is not awaitable)", .{method_slice});
            return ResolvedType.unknown;
        }

        // M1.0.15 — the test World surface (§32): methods on the handle returned
        // by `test_world()`. `spawn_with([C {…}, …])` -> Entity (immediate spawn,
        // fires on_spawn observers, live handle); `emit(T {…})` -> unit (emit-
        // statement semantics); `tick(n)` -> unit (advance n ticks, n >= 1
        // enforced at runtime). Reachable only on `.test_world`, itself resolvable
        // only in a test body.
        if (recv_t == .test_world) {
            if (std.mem.eql(u8, method_slice, "spawn_with")) {
                try self.checkSpawnWithArg(id, mc, ctx_opt);
                return ResolvedType{ .builtin = .entity };
            }
            if (std.mem.eql(u8, method_slice, "emit")) {
                try self.checkWorldEmitArg(id, mc, ctx_opt);
                return ResolvedType.unknown;
            }
            if (std.mem.eql(u8, method_slice, "tick")) {
                if (mc.args_len != 1) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "tick takes exactly one count 'tick(n)'", .{});
                } else {
                    const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    const t = self.synthExpr(arg, ctx_opt);
                    if (t == .builtin and !t.builtin.isInteger()) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "tick(n) requires an integer tick count", .{});
                    }
                }
                return ResolvedType.unknown;
            }
            try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "no method '{s}' on the test world (spawn_with / emit / tick)", .{method_slice});
            return ResolvedType.unknown;
        }

        // M1.0.9 B2 — builtin extension methods on an `Entity` receiver, checked
        // BEFORE the trait-method resolution below (these are interpreter builtins,
        // not user traits; any other method on an Entity falls through to the
        // trait lookup). `activate_extension`/`deactivate_extension` are
        // statement-use (`unknown` return, like `array.push`); `has_extension`
        // → bool; `active_extensions` → `[string]`.
        if (recv_t == .builtin and recv_t.builtin == .entity) {
            if (std.mem.eql(u8, method_slice, "activate_extension") or std.mem.eql(u8, method_slice, "deactivate_extension")) {
                try self.checkExtensionNameArg(id, mc, method_slice, ctx_opt);
                return ResolvedType.unknown;
            }
            if (std.mem.eql(u8, method_slice, "has_extension")) {
                try self.checkExtensionNameArg(id, mc, method_slice, ctx_opt);
                return ResolvedType{ .builtin = .bool_ };
            }
            if (std.mem.eql(u8, method_slice, "active_extensions")) {
                if (mc.args_len != 0) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "Entity method 'active_extensions' takes no arguments", .{});
                return ResolvedType{ .array_dyn = .string_ };
            }
            // M1.0.10 — structural mutation methods on an `Entity` receiver
            // (`etch-grammar.md` §4.5). All three are statement-effect (`unknown`
            // return, like `array.push` / `activate_extension`); they enqueue a
            // deferred command at run (E3). `add` on a present component is a
            // replace (`@on_replaced`), no separate construct.
            if (std.mem.eql(u8, method_slice, "despawn")) {
                if (mc.args_len != 0) try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "Entity method 'despawn' takes no arguments", .{});
                return ResolvedType.unknown;
            }
            if (std.mem.eql(u8, method_slice, "add")) {
                if (mc.args_len != 1) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "Entity method 'add' takes exactly one component literal 'T {{ ... }}'", .{});
                } else {
                    const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    try self.checkStructuralComponentLiteral(arg);
                }
                return ResolvedType.unknown;
            }
            if (std.mem.eql(u8, method_slice, "remove")) {
                if (mc.args_len != 1) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(id), "Entity method 'remove' takes exactly one component type 'T'", .{});
                } else {
                    const arg: NodeId = @bitCast(self.arena.extra.items[mc.args_start]);
                    if (self.arena.exprKind(arg) != .path) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arg), "Entity method 'remove' expects a component type 'T'", .{});
                    } else {
                        try self.checkStructuralComponentName(self.arena.exprData(arg), self.arena.exprSpan(arg));
                    }
                }
                return ResolvedType.unknown;
            }
        }

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

    /// E0220-shaped check for the builtin mutating collection methods
    /// (M0.8 E3-C tranche 3): `push` / `insert` are `mut self` per stdlib
    /// §13.2/§14.2, so the receiver must be a mutable binding. Same
    /// reachability rule as `checkMutSelfReceiver`, without a user `FnDecl`.
    fn checkMutCollectionReceiver(self: *TypeChecker, mc: ast_mod.MethodCall, ctx_opt: ?*RuleCtx) !void {
        const ctx = ctx_opt orelse return;
        if (!isAssignTargetReachable(self.arena, ctx, mc.receiver)) {
            try self.emit(.immutable_receiver_for_mut_self, .error_, self.arena.exprSpan(mc.receiver), "cannot call a mutating collection method on an immutable receiver (bind it with 'let mut')", .{});
        }
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
        // Function coloring (M1.0.11 E4, §9.3): calling an `async method` from a
        // non-async context is E0901 (a legal call is via `await` in an async
        // context, which reaches here with `current_is_async` true).
        if (method.is_async and !self.current_is_async) {
            try self.emit(.async_call_in_non_async_context, .error_, self.arena.exprSpan(id), "cannot call `async` method '{s}' from a non-async context (needs an `async fn`/`async rule` + `await`)", .{self.arena.strings.slice(mc.method_name)});
        } else if (method.is_async and !self.consumesAsyncEffect(id)) {
            // M1.0.12 E3 — E0905 (mirror of the free-fn site, §9.2 revision 2).
            try self.emit(.unconsumed_async_effect, .error_, self.arena.exprSpan(id), "bare call to `async` method '{s}' — consume the async effect with `await` (inside spawn/branch/race/sync bodies too: the constructs relocate the await into a child task, they do not replace it)", .{self.arena.strings.slice(mc.method_name)});
        }
        const ret: ResolvedType = if (method.return_type.isNone()) ResolvedType.unknown else self.namedTypeToResolved(method.return_type);
        var pnames: std.ArrayListUnmanaged(StringId) = .empty;
        defer pnames.deinit(self.gpa);
        try self.fnParamNames(method.params_start, method.params_len, &pnames);
        if (!try self.checkCallBinding(id, mc.args_start, mc.args_len, mc.names_start, pnames.items, "method", mc.method_name)) {
            return ret;
        }
        var i: u32 = 0;
        while (i < method.params_len) : (i += 1) {
            const p = self.arena.fn_params.items[method.params_start + i];
            const ptype = self.namedTypeToResolved(p.type_node);
            const arg = self.arena.callArgForParam(mc.args_start, mc.args_len, mc.names_start, i, p.name) orelse continue;
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
            .map_t => |mi| {
                // `m[k] -> V?` (stdlib §14.2/§14.3, M0.8 E3-C tranche 4):
                // the optional-returning accessor unlocked by the Optional
                // ops — lifts the tranche-3 rejection. The key must fit the
                // map's key type.
                if (idx_t == .builtin and !self.literalTypeFits(mi.key, ix.index, idx_t.builtin)) {
                    try self.emit(.type_mismatch, .error_, self.arena.exprSpan(ix.index), "map index key type does not match the map key type", .{});
                }
                return .{ .optional = mi.value };
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
        var saw_some = false;
        var saw_none = false;

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
                .wildcard => has_catch_all = true,
                .binding => {
                    has_catch_all = true;
                    // A bare binding `n => …` binds the scrutinee value for its
                    // arm body — the SAME flat per-rule local scoping as
                    // `some(v) =>` above (M0.8 E7, Guy's gate amendment). The
                    // interpreter (interp.zig match `.binding`) and codegen
                    // (lower.zig `emitMatch` `.binding`) already bind it; the
                    // type-checker must too, else the body's use of `n` is
                    // `E0102 UnknownSymbol`.
                    if (ctx_opt) |ctx| {
                        try ctx.locals.put(self.gpa, arm.pattern_payload, .{ .type_ = scrut_t, .is_mut = false });
                    }
                },
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
                // `some(v)` / `none` optional patterns (M0.8 E3-C tranche 4,
                // part1 §7.6): the scrutinee must be an optional; `some(v)`
                // binds the payload for its arm body (flat per-rule locals,
                // the E1 scoping policy).
                .optional_some => {
                    if (scrut_t == .optional) {
                        saw_some = true;
                        if (ctx_opt) |ctx| {
                            try ctx.locals.put(self.gpa, arm.pattern_payload, .{ .type_ = .{ .builtin = scrut_t.optional }, .is_mut = false });
                        }
                    } else if (scrut_t != .unknown) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arm.body), "some(...) pattern used on a non-optional scrutinee", .{});
                    }
                },
                .optional_none => {
                    if (scrut_t == .optional) {
                        saw_none = true;
                    } else if (scrut_t != .unknown) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(arm.body), "none pattern used on a non-optional scrutinee", .{});
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
            // An optional scrutinee is exhaustive iff both `some(v)` and
            // `none` are covered (M0.8 E3-C tranche 4).
            const optional_exhaustive = scrut_t == .optional and saw_some and saw_none;
            var enum_exhaustive = false;
            if (enum_name != null) {
                enum_exhaustive = covered.items.len > 0;
                for (covered.items) |c| {
                    if (!c) enum_exhaustive = false;
                }
            }
            if (!bool_exhaustive and !enum_exhaustive and !optional_exhaustive) {
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
                    // `string + string → string` — concatenation, the only
                    // string arithmetic in the M0.8 minimal subset (stdlib
                    // §12.4 / `etch-resolver-types.md` §16 builtin `Add`).
                    // `-`/`*`/`/`/`%` on strings stay errors via the numeric
                    // checks below.
                    if (bin.op == .add and lhs_t.builtin == .string_ and rhs_t.builtin == .string_) {
                        return ResolvedType{ .builtin = .string_ };
                    }
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
                // String `Eq`/`Ord` (content equality, lexicographic order —
                // stdlib §12.4) are NOT in the M0.8 minimal subset: reject at
                // type-check so neither backend sees one (fail loud here, not
                // divergently at runtime / in generated Zig).
                if ((lhs_t == .builtin and lhs_t.builtin == .string_) or (rhs_t == .builtin and rhs_t.builtin == .string_)) {
                    try self.emit(.type_mismatch, .error_, span, "string comparison is not in the M0.8 minimal subset (stdlib activation is Phase 1+)", .{});
                    return ResolvedType.unknown;
                }
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
            .coalesce => {
                // `expr ?? default` ≡ `expr.unwrap_or(default)` (stdlib
                // §16.2, M0.8 E3-C tranche 4): the lhs must be an optional;
                // the default must fit the payload type; the result is the
                // unwrapped payload.
                if (lhs_t == .optional) {
                    if (rhs_t == .builtin and !self.literalTypeFits(lhs_t.optional, bin.rhs, rhs_t.builtin)) {
                        try self.emit(.type_mismatch, .error_, self.arena.exprSpan(bin.rhs), "'??' default type does not match the optional payload type", .{});
                    }
                    return .{ .builtin = lhs_t.optional };
                }
                if (lhs_t == .unknown) return rhs_t;
                try self.emit(.type_mismatch, .error_, span, "'??' requires an optional left operand", .{});
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
            .force_unwrap => {
                // `expr!` ≡ `expr.unwrap()` — panic if none (stdlib §16.2,
                // M0.8 E3-C tranche 4).
                if (operand_t == .optional) return .{ .builtin = operand_t.optional };
                if (operand_t == .unknown) return ResolvedType.unknown;
                try self.emit(.type_mismatch, .error_, span, "'!' force unwrap requires an optional operand", .{});
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
                // Builtin engine resource (M1.0.13 E4): fields resolve
                // against the `builtin_resources` descriptor table (there is
                // no AST declaration to consult).
                if (builtinResourceByName(self.arena.strings.slice(name_id))) |br| {
                    const fname = self.arena.strings.slice(field_name);
                    for (br.fields) |f| {
                        if (std.mem.eql(u8, fname, f.name)) return .{ .builtin = f.type_ };
                    }
                    try self.emit(.invalid_field_filter, .error_, span, "field '{s}' does not exist on builtin resource '{s}'", .{ fname, br.name });
                    return ResolvedType.unknown;
                }
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
            .event_t => |name_id| {
                // Field of the implicit `event` binding inside an `@on_event(T)`
                // observer (M0.8 E3) — e.g. `event.amount`. An event is a POD
                // struct of fields, resolved against its declaration.
                if (self.symbols.get(name_id)) |sym| {
                    const decl = self.arena.event_decls.items[self.arena.itemData(sym.item_id)];
                    var i: u32 = 0;
                    while (i < decl.fields_len) : (i += 1) {
                        const f = self.arena.fields.items[decl.fields_start + i];
                        if (f.name == field_name) return self.namedTypeToResolved(f.type_node);
                    }
                } else if (self.declaredEvent(name_id)) |fe| {
                    // Cross-arena field lookup, BY BYTES on both the field name
                    // and the type — the discipline M1.0.7 settled for
                    // `checkComponentInstance`, and bounded the same way:
                    // builtins resolve, a named foreign type yields `unknown`.
                    const want = self.arena.strings.slice(field_name);
                    var i: u32 = 0;
                    while (i < fe.decl.fields_len) : (i += 1) {
                        const f = fe.arena.fields.items[fe.decl.fields_start + i];
                        if (!std.mem.eql(u8, fe.arena.strings.slice(f.name), want)) continue;
                        return self.foreignFieldType(fe.arena, f.type_node);
                    }
                }
                try self.emit(.invalid_field_filter, .error_, span, "field '{s}' does not exist on event '{s}'", .{ self.arena.strings.slice(field_name), self.arena.strings.slice(name_id) });
                return ResolvedType.unknown;
            },
            .builtin, .range, .array_fixed, .array_dyn, .map_t, .set_t, .closure, .enum_t, .generic, .optional, .test_world, .unknown => return ResolvedType.unknown,
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

// ── M1.B / G1 — `@storage` argument schema (E0503 / E0504) ────────────────
//
// The two codes exist so the two failures are TOLD APART, so each test below
// asserts the presence of its own code AND the absence of the other. Asserting
// presence alone would be satisfied by a checker that emitted both, and then
// the fixtures of `tests/etch/corpus/invalid/` would be distinguished by
// nothing but the fact that both fail.
//
// The accepted spelling is the tag path. Every source below is written in it
// except where the bare form is the subject.

test "E0503: @storage with a value outside the StorageKind domain" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\@storage(.archetype)
        \\component Burning { remaining: float = 3.0 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .annotation_arg_mismatch);
    try expectNoCode(result.diagnostics.items, .annotation_arg_not_const);
}

test "E0503 and not E0504: the BARE spelling of a domain value is refused" {
    // The fault is the sigil, not the value: `sparse` is in the domain. Falling
    // through to the const test would answer `E0504 — must be a constant`, which
    // is false about the value and silent about what to write instead — and an
    // `ident` is not const-evaluable, so that is exactly where it would land
    // without its own branch. The absence assertion is what holds that line.
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\@storage(sparse)
        \\component Chilled { stacks: int = 1 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .annotation_arg_mismatch);
    try expectNoCode(result.diagnostics.items, .annotation_arg_not_const);
}

test "E0504: @storage with a syntactically valid but non-constant argument" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\@storage(config.mode)
        \\component Poisoned { stacks: int = 1 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .annotation_arg_not_const);
    try expectNoCode(result.diagnostics.items, .annotation_arg_mismatch);
}

test "E0503: @storage arity — no argument, and more than one" {
    const gpa = std.testing.allocator;
    {
        var result = try parseAndCheck(gpa,
            \\@storage()
            \\component A { x: int = 0 }
        );
        defer result.deinit(gpa);
        try expectAnyCode(result.diagnostics.items, .annotation_arg_mismatch);
    }
    {
        var result = try parseAndCheck(gpa,
            \\@storage(.sparse, .table)
            \\component B { x: int = 0 }
        );
        defer result.deinit(gpa);
        try expectAnyCode(result.diagnostics.items, .annotation_arg_mismatch);
    }
}

test "E0503 and not E0504: @storage with a NAMED argument" {
    // The schema declares one POSITIONAL argument. `kind: .sparse` carries a
    // value the domain does have, so the fault is the name — step 3, not step
    // 4. Before this case existed the checker answered `E0504 — must be a
    // constant storage mode`, false about the value and silent about the fault.
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\@storage(kind: .sparse)
        \\component Chilled { stacks: int = 1 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .annotation_arg_mismatch);
    try expectNoCode(result.diagnostics.items, .annotation_arg_not_const);
}

test "the guard's bound, tested in BOTH directions" {
    // A guard has two ways of being wrong — missing what it must catch, and
    // catching what it must let through. The tests above exercise the first.
    // This one exercises both at once, which is what makes it a bound and not a
    // second presence check: every accepted spelling must come out clean, and
    // the refused one must come out refused, in the same test over the same
    // shape of source. Under the earlier both-spellings rule the last row was
    // clean, so this row is the reversal made observable.
    const gpa = std.testing.allocator;
    const Case = struct { src: []const u8, clean: bool };
    for ([_]Case{
        .{ .src = "@storage(.sparse)\ncomponent A { x: int = 0 }", .clean = true },
        .{ .src = "@storage(.table)\ncomponent B { x: int = 0 }", .clean = true },
        .{ .src = "component C { x: int = 0 }", .clean = true },
        .{ .src = "@storage(sparse)\ncomponent D { x: int = 0 }", .clean = false },
    }) |case| {
        var result = try parseAndCheck(gpa, case.src);
        defer result.deinit(gpa);
        try expectNoCode(result.diagnostics.items, .annotation_arg_not_const);
        if (case.clean) {
            try expectNoCode(result.diagnostics.items, .annotation_arg_mismatch);
        } else {
            try expectAnyCode(result.diagnostics.items, .annotation_arg_mismatch);
        }
    }
}

// ── M0.8 E7 Level C — scene / prefab validation tests ─────────────────────

test "scene + prefab: a well-formed scene and prefab type-check clean (M0.8 E7)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\resource GameMode { max_players: int = 4 }
        \\prefab "WallTorch" { entity "root" { Health { current: 50.0 } } }
        \\scene "Village" {
        \\  version: 3
        \\  resources { GameMode { max_players: 4 } }
        \\  entity "Hero" { uuid: "u1" Health { current: 80.0 } }
        \\  entity "Child" { parent: "Hero" Health { current: 10.0 } }
        \\  instance of "WallTorch" "Torch_01" { Health { current: 5.0 } }
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "scene E1780: an empty scene is rejected" {
    const gpa = std.testing.allocator;
    var r = try parseAndCheck(gpa, "scene \"S\" { }");
    defer r.deinit(gpa);
    try expectAnyCode(r.diagnostics.items, .scene_empty_entities);
}

test "scene E1781/E1782: duplicate entity name and uuid" {
    const gpa = std.testing.allocator;
    var r1 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { entity "Hero" { Health {} } entity "Hero" { Health {} } }
    );
    defer r1.deinit(gpa);
    try expectAnyCode(r1.diagnostics.items, .duplicate_entity_name);
    var r2 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { entity "A" { uuid: "x" Health {} } entity "B" { uuid: "x" Health {} } }
    );
    defer r2.deinit(gpa);
    try expectAnyCode(r2.diagnostics.items, .duplicate_uuid);
}

test "scene E1783/E1784/E1785: component type + field-name + field-type checks" {
    const gpa = std.testing.allocator;
    var r1 = try parseAndCheck(gpa, "scene \"S\" { entity \"A\" { Nonexistent {} } }");
    defer r1.deinit(gpa);
    try expectAnyCode(r1.diagnostics.items, .scene_component_type_unknown);
    var r2 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { entity "A" { Health { bogus: 1.0 } } }
    );
    defer r2.deinit(gpa);
    try expectAnyCode(r2.diagnostics.items, .scene_component_field_unknown);
    var r3 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { entity "A" { Health { current: "oops" } } }
    );
    defer r3.deinit(gpa);
    try expectAnyCode(r3.diagnostics.items, .scene_component_field_type_invalid);
}

test "scene E1786/E1787/E1788: prefab ref, parent ref, parent cycle" {
    const gpa = std.testing.allocator;
    var r1 = try parseAndCheck(gpa, "scene \"S\" { instance of \"Ghost\" \"g\" { } }");
    defer r1.deinit(gpa);
    try expectAnyCode(r1.diagnostics.items, .prefab_ref_not_found);
    var r2 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { entity "A" { parent: "Nobody" Health {} } }
    );
    defer r2.deinit(gpa);
    try expectAnyCode(r2.diagnostics.items, .parent_not_found);
    var r3 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { entity "A" { parent: "B" Health {} } entity "B" { parent: "A" Health {} } }
    );
    defer r3.deinit(gpa);
    try expectAnyCode(r3.diagnostics.items, .parent_cycle);
}

test "scene E1789/E0303: resources block type + field checks" {
    const gpa = std.testing.allocator;
    var r1 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\scene "S" { resources { Health { current: 1.0 } } entity "A" { Health {} } }
    );
    defer r1.deinit(gpa);
    try expectAnyCode(r1.diagnostics.items, .scene_resource_type_unknown);
    var r2 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\resource GameMode { max_players: int = 4 }
        \\scene "S" { resources { GameMode { bogus: 1 } } entity "A" { Health {} } }
    );
    defer r2.deinit(gpa);
    try expectAnyCode(r2.diagnostics.items, .resource_field_unknown);
}

test "scene W1780: an entity with no components warns" {
    const gpa = std.testing.allocator;
    var r = try parseAndCheck(gpa, "scene \"S\" { entity \"A\" { } }");
    defer r.deinit(gpa);
    try expectAnyCode(r.diagnostics.items, .orphan_entity);
}

test "prefab E1790/E1791/E1792: empty, base-not-found, cycle" {
    const gpa = std.testing.allocator;
    var r1 = try parseAndCheck(gpa, "prefab \"P\" { entity \"root\" { } }");
    defer r1.deinit(gpa);
    try expectAnyCode(r1.diagnostics.items, .prefab_empty);
    var r2 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\prefab "P" of "Ghost" { entity "root" { Health {} } }
    );
    defer r2.deinit(gpa);
    try expectAnyCode(r2.diagnostics.items, .prefab_base_not_found);
    var r3 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\prefab "A" of "B" { entity "r" { Health {} } }
        \\prefab "B" of "A" { entity "r" { Health {} } }
    );
    defer r3.deinit(gpa);
    try expectAnyCode(r3.diagnostics.items, .prefab_cycle);
}

test "prefab E1793/E1794/E1795: component type + field-name + field-type checks" {
    const gpa = std.testing.allocator;
    var r1 = try parseAndCheck(gpa, "prefab \"P\" { entity \"root\" { Nonexistent {} } }");
    defer r1.deinit(gpa);
    try expectAnyCode(r1.diagnostics.items, .prefab_component_type_unknown);
    var r2 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\prefab "P" { entity "root" { Health { bogus: 1.0 } } }
    );
    defer r2.deinit(gpa);
    try expectAnyCode(r2.diagnostics.items, .prefab_component_field_unknown);
    var r3 = try parseAndCheck(gpa,
        \\component Health { current: float = 1.0 }
        \\prefab "P" { entity "root" { Health { current: "oops" } } }
    );
    defer r3.deinit(gpa);
    try expectAnyCode(r3.diagnostics.items, .prefab_component_field_type_invalid);
}

test "type-checker emits E0102 on field referencing unknown type" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: NotAType = 0 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .undefined_symbol);
}

// ── M1.0.17 E1 — resource collection field type-check ─────────────────────

test "resource string[] field type-checks" {
    const gpa = std.testing.allocator;
    // `etch-reference-part1.md` §5.5 — a resource `string[]` field is sanctioned
    // (no POD constraint on resources). Accepted clean, no diagnostic.
    var result = try parseAndCheck(gpa,
        \\resource GameSettings { recent_servers: string[] }
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "resource collection field with unsupported element yields E0222" {
    const gpa = std.testing.allocator;
    // A component-typed element is outside {POD scalar, string, enum}.
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 0.0 }
        \\resource Bag { items: Health[] }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .collection_field_element_invalid);
}

test "resource nested collection field string[][] yields E0222" {
    const gpa = std.testing.allocator;
    // Nesting is out of Phase 1 (the recursive-drop dimension is out of scope).
    var result = try parseAndCheck(gpa,
        \\resource Grid { rows: string[][] }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .collection_field_element_invalid);
}

test "component int[] field still rejected (POD-strict unchanged)" {
    const gpa = std.testing.allocator;
    // Collection fields do NOT unlock on components — POD-strict is unchanged.
    // The rejection is the pre-existing composite-field one (E0102), NOT E0222.
    var result = try parseAndCheck(gpa,
        \\component Buffer { items: int[] }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .undefined_symbol);
    try expectNoCode(result.diagnostics.items, .collection_field_element_invalid);
}

test "resource Entity[] collection element yields E0222 (entity-reference message)" {
    const gpa = std.testing.allocator;
    // `Entity` is a valid resource scalar field type, but as a collection element
    // it carries cross-reference-table remap semantics a persistent collection
    // does not wire (M1.0.6 `.entity_` load-time resolution) → rejected with a
    // message distinct from the generic unsupported-element one.
    var result = try parseAndCheck(gpa,
        \\resource Party { members: Entity[] }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .collection_field_element_invalid);
    var entity_specific = false;
    for (result.diagnostics.items) |d| {
        if (d.code == .collection_field_element_invalid and
            std.mem.indexOf(u8, d.primary_message, "cross-reference-table") != null)
        {
            entity_specific = true;
        }
    }
    try std.testing.expect(entity_specific);
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

test "const type mismatch emits E0200" {
    const gpa = std.testing.allocator;
    // M1.0.8 — a `const` value whose type does not match the declared `: type`.
    var result = try parseAndCheck(gpa,
        \\const PORT: int = 3.14
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .type_mismatch);
}

test "non-const-evaluable const emits E1101" {
    const gpa = std.testing.allocator;
    // M1.0.8 — a `const` whose value is not const-evaluable (a bare ident).
    var result = try parseAndCheck(gpa,
        \\const LIMIT: int = some_var
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .not_const_evaluable);
}

test "well-formed top-level const checks clean" {
    const gpa = std.testing.allocator;
    // The two acceptance fixtures: an ident-cased and a SCREAMING_SNAKE_CASE
    // (type_ident) const, both literal values matching their declared types.
    var result = try parseAndCheck(gpa,
        \\const max_players: int = 16
        \\const ROOM_CAP: int = 8
        \\const PI: float = 3.14
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "duplicate test names collide within the test namespace (E0101, M1.0.15)" {
    const gpa = std.testing.allocator;
    // Intra-namespace uniqueness: two top-level `test` blocks with the same name
    // collide → E0101 (contextual "duplicate test 'X'"). The "not exported" half
    // is exercised cross-file in tests/etch/import_resolve_test.zig (a test name
    // is not in module exports → E0104 on import).
    var result = try parseAndCheck(gpa,
        \\test "same name" { }
        \\test "same name" { }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .duplicate_symbol);
}

test "test name does not collide with a component of the same name (M1.0.15)" {
    const gpa = std.testing.allocator;
    // The M1.0.8 collision this milestone resolves: a `test "Foo"` lives in a
    // dedicated namespace, so it no longer clashes with `component Foo`.
    var result = try parseAndCheck(gpa,
        \\component Foo { x: int = 0 }
        \\test "Foo" { }
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "test annotation applicability + args (M1.0.15)" {
    const gpa = std.testing.allocator;

    // `@phase` is rule-only — on a test it is misapplied (E0502).
    var wrong = try parseAndCheck(gpa,
        \\@phase(.update)
        \\test "x" { }
    );
    defer wrong.deinit(gpa);
    try expectAnyCode(wrong.diagnostics.items, .annotation_misapplied);

    // The three test annotations with well-formed args check clean.
    var ok = try parseAndCheck(gpa,
        \\@tag(.perf)
        \\test "a" { }
        \\@skip(reason: "WIP")
        \\test "b" { }
        \\@only
        \\test "c" { }
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // A bad `@tag` value (not in {unit, integration, slow, perf}) is E0502.
    var bad_tag = try parseAndCheck(gpa,
        \\@tag(.bogus)
        \\test "d" { }
    );
    defer bad_tag.deinit(gpa);
    try expectAnyCode(bad_tag.diagnostics.items, .annotation_misapplied);
}

test "await in a test body is E0901 (sync context, M1.0.15)" {
    const gpa = std.testing.allocator;
    // A `test` body is a sync context (§32): `await` there is a coloring error.
    var result = try parseAndCheck(gpa,
        \\test "no await here" {
        \\  await wait(1.0s)
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .async_call_in_non_async_context);
}

test "measure outside a test body is E0910; inside checks clean (M1.0.15)" {
    const gpa = std.testing.allocator;
    // `measure { }` in a `fn` body → E0910 (wall-clock stays out of gameplay).
    var outside = try parseAndCheck(gpa,
        \\fn timed() -> Duration { measure { } }
    );
    defer outside.deinit(gpa);
    try expectAnyCode(outside.diagnostics.items, .measure_outside_test);

    // Inside a test body it types clean (result is Duration).
    var inside = try parseAndCheck(gpa,
        \\test "m" {
        \\  let d = measure { let x = 1 + 1 }
        \\  assert(d > 0.0s)
        \\}
    );
    defer inside.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), inside.diagnostics.items.len);
}

test "assert_eq rejects non-comparable aggregate operands (M1.0.15 review fix)" {
    const gpa = std.testing.allocator;
    // A struct value has no structural equality — comparing it would false-fail
    // assert_eq / false-pass assert_neq, so it is rejected at type-check.
    var result = try parseAndCheck(gpa,
        \\struct P { x: int }
        \\test "cmp" {
        \\  let a = P { x: 1 }
        \\  assert_eq(a, a)
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .type_mismatch);

    // Scalars compare clean.
    var ok = try parseAndCheck(gpa,
        \\test "cmp ok" { assert_eq(1 + 1, 2) }
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "assert_approx constrains its operands to float at type-check (M1.0.15 review fix)" {
    const gpa = std.testing.allocator;
    // Int operands → type_mismatch at check (symmetric with the rest of the
    // family), not a generic runtime failure.
    var ints = try parseAndCheck(gpa,
        \\test "approx ints" { assert_approx(1, 2) }
    );
    defer ints.deinit(gpa);
    try expectAnyCode(ints.diagnostics.items, .type_mismatch);

    // Floats (incl. an explicit tolerance) check clean.
    var floats = try parseAndCheck(gpa,
        \\test "approx floats" { assert_approx(1.0, 1.5, 0.6) }
    );
    defer floats.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), floats.diagnostics.items.len);
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

test "type-checker accepts string .len() as int, rejects other string methods (M0.8 sub-slice C)" {
    const gpa = std.testing.allocator;
    // `.len()` resolves to int — the minimal faithful string subset; the
    // assignment to an int field type-checks clean.
    {
        var result = try parseAndCheck(gpa,
            \\component Acc { out: int = 0 }
            \\rule run(entity: Entity) when entity has Acc {
            \\  entity.get_mut(Acc).out = "hello".len()
            \\}
        );
        defer result.deinit(gpa);
        try expectNoCode(result.diagnostics.items, .type_mismatch);
    }
    // Any other §12 String method is stdlib Phase 1+ → rejected (E0200).
    {
        var result = try parseAndCheck(gpa,
            \\component Acc { out: int = 0 }
            \\rule run(entity: Entity) when entity has Acc {
            \\  entity.get_mut(Acc).out = "hello".index_of("e")
            \\}
        );
        defer result.deinit(gpa);
        try expectAnyCode(result.diagnostics.items, .type_mismatch);
    }
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

    // Wrong arity → E0203 (unfolded from E0200, M0.8 E4 item 16).
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
    try expectAnyCode(arity.diagnostics.items, .arg_count_mismatch);

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

test "closure body cannot mutate a capture, E0221 (M0.8 E3-C tranche 6)" {
    const gpa = std.testing.allocator;

    // Mutating a captured binding inside the body → E0221, even though the
    // source binding is `let mut` (resolver-types §8.2: captures are value
    // snapshots; mutation through a closure is forbidden).
    var mutate = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let mut total = 0
        \\  let add = |x: int| {
        \\    total = total + x
        \\    total
        \\  }
        \\  entity.get_mut(C).out = add(2)
        \\}
    );
    defer mutate.deinit(gpa);
    try expectAnyCode(mutate.diagnostics.items, .closure_cannot_mutate_capture);

    // A body-local `let mut` re-declaring the name owns it — mutating it is
    // clean (nested-scope shadowing, not a capture).
    var local_mut = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let total = 40
        \\  let add = |x: int| {
        \\    let mut total = 0
        \\    total = total + x
        \\    total
        \\  }
        \\  entity.get_mut(C).out = add(2) + total
        \\}
    );
    defer local_mut.deinit(gpa);
    try expectNoCode(local_mut.diagnostics.items, .closure_cannot_mutate_capture);

    // READING a capture stays clean (the E1 capture path, unchanged).
    var read_ok = try parseAndCheck(gpa,
        \\component C { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has C
        \\{
        \\  let mut factor = 40
        \\  let scale = |x: int| x + factor
        \\  factor = 100
        \\  entity.get_mut(C).out = scale(2)
        \\}
    );
    defer read_ok.deinit(gpa);
    try expectNoCode(read_ok.diagnostics.items, .closure_cannot_mutate_capture);
    try expectNoCode(read_ok.diagnostics.items, .type_mismatch);
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

    // Wrong arity → E0203 (unfolded from E0200, M0.8 E4 item 16).
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
    try expectAnyCode(arity.diagnostics.items, .arg_count_mismatch);

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

    // Body value type does not match the declared return type → E0204
    // (unfolded from E0200, M0.8 E4 item 16).
    var retty = try parseAndCheck(gpa,
        \\fn bad(x: int) -> bool { x * 2 }
    );
    defer retty.deinit(gpa);
    try expectAnyCode(retty.diagnostics.items, .return_type_mismatch);
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

    // Argument-count mismatch on an associated fn → E0203 (unfolded from
    // E0200, M0.8 E4 item 16).
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
    try expectAnyCode(arity.diagnostics.items, .arg_count_mismatch);
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

test "type-checker validates entity_event / global_event await targets (M1.0.14 E2)" {
    const gpa = std.testing.allocator;

    // Non-Entity first operand of `entity_event` → E0200 (the operand was
    // never synthesized before M1.0.14). `Ev` has an Entity field so E0908 does
    // not also fire.
    var bad_operand = try parseAndCheck(gpa,
        \\component C { }
        \\event Ev { who: Entity }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(5, Ev)
        \\}
    );
    defer bad_operand.deinit(gpa);
    try expectAnyCode(bad_operand.diagnostics.items, .type_mismatch);

    // Undeclared event on `entity_event` → E0102.
    var undecl_ent = try parseAndCheck(gpa,
        \\component C { }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(e, Ghost)
        \\}
    );
    defer undecl_ent.deinit(gpa);
    try expectAnyCode(undecl_ent.diagnostics.items, .undefined_symbol);

    // Undeclared event on `global_event` → E0102 (fix-as-you-go: previously
    // accepted silently).
    var undecl_glob = try parseAndCheck(gpa,
        \\resource R { n: int = 0 }
        \\async rule r()
        \\  when resource R
        \\{
        \\  await global_event(Ghost)
        \\}
    );
    defer undecl_glob.deinit(gpa);
    try expectAnyCode(undecl_glob.diagnostics.items, .undefined_symbol);

    // Zero Entity fields → E0908 EventNotEntityScoped.
    var no_entity = try parseAndCheck(gpa,
        \\component C { }
        \\event Ev { amount: int = 0 }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(e, Ev)
        \\}
    );
    defer no_entity.deinit(gpa);
    try expectAnyCode(no_entity.diagnostics.items, .event_not_entity_scoped);

    // Two Entity fields, no `@entity_target` → E0909 AmbiguousEventEntityTarget.
    var ambiguous = try parseAndCheck(gpa,
        \\component C { }
        \\event Ev { source: Entity, target: Entity }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(e, Ev)
        \\}
    );
    defer ambiguous.deinit(gpa);
    try expectAnyCode(ambiguous.diagnostics.items, .ambiguous_event_entity_target);

    // Two Entity fields WITH `@entity_target` → clean (annotation disambiguates).
    var annotated = try parseAndCheck(gpa,
        \\component C { }
        \\event Ev { source: Entity, @entity_target target: Entity }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(e, Ev)
        \\}
    );
    defer annotated.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), annotated.diagnostics.items.len);

    // `@entity_target` on a non-Entity field → E0502 (existing kind).
    var at_non_entity = try parseAndCheck(gpa,
        \\event Ev { @entity_target amount: int = 0, who: Entity }
    );
    defer at_non_entity.deinit(gpa);
    try expectAnyCode(at_non_entity.diagnostics.items, .annotation_misapplied);

    // Duplicate `@entity_target` in one event → E0502.
    var at_dup = try parseAndCheck(gpa,
        \\event Ev { @entity_target a: Entity, @entity_target b: Entity }
    );
    defer at_dup.deinit(gpa);
    try expectAnyCode(at_dup.diagnostics.items, .annotation_misapplied);

    // Filter naming a field the event does not declare → E1211.
    var filter_unknown = try parseAndCheck(gpa,
        \\component C { }
        \\event Ev { who: Entity }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(e, Ev { nope: 1 })
        \\}
    );
    defer filter_unknown.deinit(gpa);
    try expectAnyCode(filter_unknown.diagnostics.items, .invalid_field_filter);

    // Filter value type does not match the field's declared type → E0200.
    var filter_type = try parseAndCheck(gpa,
        \\component C { }
        \\event Ev { amount: int = 0, who: Entity }
        \\async rule r(e: Entity)
        \\  when e has C
        \\{
        \\  await entity_event(e, Ev { amount: true })
        \\}
    );
    defer filter_type.deinit(gpa);
    try expectAnyCode(filter_type.diagnostics.items, .type_mismatch);

    // Filtered `global_event` type-checks clean (filter on both targets §4.2).
    var filtered_global = try parseAndCheck(gpa,
        \\event Ev { amount: int = 0 }
        \\resource R { n: int = 0 }
        \\async rule r()
        \\  when resource R
        \\{
        \\  await global_event(Ev { amount: 3 })
        \\}
    );
    defer filtered_global.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), filtered_global.diagnostics.items.len);
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

test "type-checker validates @on_event observer: E1203 on non-event, accepts declared event + event-field access (M0.8 E3)" {
    const gpa = std.testing.allocator;

    // Valid: `@on_event(Damage)` on a declared event; the implicit `event`
    // binding resolves `event.amount` against the event's fields (no E1203, no
    // field error, no diagnostics at all).
    var ok = try parseAndCheck(gpa,
        \\event Damage { amount: i32 = 0 }
        \\resource Tally { total: i32 = 0 }
        \\@on_event(Damage)
        \\rule absorb()
        \\  when resource Tally
        \\{
        \\  let t = get_mut(Tally)
        \\  t.total += event.amount
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .on_event_type_mismatch);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // E1203: `@on_event(T)` where T is a component, not an event.
    var not_event = try parseAndCheck(gpa,
        \\component Health { hp: i32 = 0 }
        \\@on_event(Health)
        \\rule react() { }
    );
    defer not_event.deinit(gpa);
    try expectAnyCode(not_event.diagnostics.items, .on_event_type_mismatch);

    // E1203: malformed `@on_event` with no type argument.
    var malformed = try parseAndCheck(gpa,
        \\event Damage { amount: i32 = 0 }
        \\@on_event()
        \\rule react() { }
    );
    defer malformed.deinit(gpa);
    try expectAnyCode(malformed.diagnostics.items, .on_event_type_mismatch);
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
}

test "type-checker accepts `has T changed` on a component, E1210 on a non-component (M0.8 E3)" {
    const gpa = std.testing.allocator;

    // Valid: `has Health changed` where Health is a declared component → no
    // diagnostic (the `changed` filter reuses the `has` component check).
    var ok = try parseAndCheck(gpa,
        \\component Health { current: i32 = 0 }
        \\component Counter { value: i32 = 0 }
        \\rule react(entity: Entity)
        \\  when entity has Counter and entity has Health changed
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // `has T changed` where T is not a declared component → E1210 (reused; no
    // new E12xx code is minted for the `changed` form, per the resolver ruling).
    var unknown = try parseAndCheck(gpa,
        \\rule react(entity: Entity) when entity has Nope changed { }
    );
    defer unknown.deinit(gpa);
    try expectAnyCode(unknown.diagnostics.items, .unknown_component_in_when);

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

test "entity structural methods type-check on an Entity receiver (M1.0.10 E2)" {
    const gpa = std.testing.allocator;
    // `entity.add(T { … })` / `entity.remove(T)` / `entity.despawn()` on an
    // Entity receiver with declared components → zero diagnostics.
    var ok = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\component Shield { amount: i32 = 0 }
        \\component Poisoned { stacks: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Shield { amount: 5 })
        \\  entity.remove(Poisoned)
        \\  entity.despawn()
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "structural spawn of component literals type-checks (M1.0.10 E2)" {
    const gpa = std.testing.allocator;
    var ok = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\component Projectile { speed: f32 = 0.0 }
        \\component Velocity { vx: f32 = 0.0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  spawn(Projectile { speed: 20.0 }, Velocity { vx: 1.0 })
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "binding a structural spawn result is rejected (M1.0.10 E2)" {
    const gpa = std.testing.allocator;
    // `let e = spawn(…)` uses the spawn result as a value → E0304 (no body
    // handle, statement-position only, v0.6).
    var bad = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\component Health { max: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  let e = spawn(Health { max: 10 })
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .spawn_handle_unavailable);
}

test "prefab-name spawn is refused in Phase 1 (M1.0.10 E2)" {
    const gpa = std.testing.allocator;
    // `spawn("Name")` parses + is recognized but is refused → E0305 (gating on
    // the prefab runtime).
    var bad = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  spawn("Goblin")
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .prefab_spawn_not_executable);
}

test "structural component-literal unknown field is rejected (M1.0.10 E2 completion)" {
    const gpa = std.testing.allocator;
    // via spawn(...)
    var s = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\component Health { max: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  spawn(Health { maxx: 10 })
        \\}
    );
    defer s.deinit(gpa);
    try expectAnyCode(s.diagnostics.items, .structural_component_field_unknown);
    // via entity.add(...)
    var a = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\component Health { max: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Health { maxx: 10 })
        \\}
    );
    defer a.deinit(gpa);
    try expectAnyCode(a.diagnostics.items, .structural_component_field_unknown);
}

test "structural component-literal mistyped field is rejected (M1.0.10 E2 completion)" {
    const gpa = std.testing.allocator;
    // `max: i32` given a float literal → E0307 (same field-type path as scene/prefab).
    var bad = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\component Health { max: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Health { max: 1.5 })
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .structural_component_field_type_invalid);
}

test "structural mutation of a non-component type is rejected (M1.0.10 E3 carry-over)" {
    const gpa = std.testing.allocator;
    // A resource (not a component) given to `entity.add(...)` → E0200 (the
    // "not a declared component" path; scene/prefab collapse the same way).
    var a = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\resource Conf { v: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.add(Conf { v: 1 })
        \\}
    );
    defer a.deinit(gpa);
    try expectAnyCode(a.diagnostics.items, .type_mismatch);
    // Same for `entity.remove(T)` on a non-component type.
    var rm = try parseAndCheck(gpa,
        \\component Marker { x: i32 = 0 }
        \\resource Conf { v: i32 = 0 }
        \\rule r(entity: Entity) when entity has Marker {
        \\  entity.remove(Conf)
        \\}
    );
    defer rm.deinit(gpa);
    try expectAnyCode(rm.diagnostics.items, .type_mismatch);
}

test "type-checker validates tag mutations (M0.8 E3)" {
    const gpa = std.testing.allocator;

    // Valid: an Entity receiver + declared leaf paths → no E0830 / E0833.
    var ok = try parseAndCheck(gpa,
        \\tags { character { status { alive, stunned } } }
        \\rule r(entity: Entity) {
        \\  entity.add_tag(.character.status.stunned)
        \\  entity.remove_tag(.character.status.alive)
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .tag_path_invalid);
    try expectNoCode(ok.diagnostics.items, .tag_invalid_operation);

    // Unknown tag path → E0830 TagPathInvalid.
    var unknown = try parseAndCheck(gpa,
        \\tags { character { status { alive } } }
        \\rule r(entity: Entity) { entity.add_tag(.character.status.frozen) }
    );
    defer unknown.deinit(gpa);
    try expectAnyCode(unknown.diagnostics.items, .tag_path_invalid);

    // A namespace (not a leaf) → E0830: a mutation sets a single bit.
    var ns = try parseAndCheck(gpa,
        \\tags { character { status { alive } } }
        \\rule r(entity: Entity) { entity.add_tag(.character.status) }
    );
    defer ns.deinit(gpa);
    try expectAnyCode(ns.diagnostics.items, .tag_path_invalid);

    // A non-Entity receiver → E0833 TagInvalidOperation.
    var bad_recv = try parseAndCheck(gpa,
        \\tags { character { status { alive } } }
        \\rule r(dt: float) { dt.add_tag(.character.status.alive) }
    );
    defer bad_recv.deinit(gpa);
    try expectAnyCode(bad_recv.diagnostics.items, .tag_invalid_operation);
}

test "type-checker accepts string + enum fields on struct + resource, keeps component rejection (M1.0.3)" {
    const gpa = std.testing.allocator;

    // `string` + enum-typed struct fields are the tranche-2 unlock (the
    // builtin Error forces both; part1 §5.5 constrains components only).
    var ok = try parseAndCheck(gpa,
        \\enum Severity { low, high }
        \\struct LogLine {
        \\  text: string
        \\  severity: Severity
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .undefined_symbol);

    // Components stay POD: `string` rejected (part1 §5.5, SoA archetype storage).
    var comp = try parseAndCheck(gpa,
        \\component Name { value: string }
    );
    defer comp.deinit(gpa);
    try expectAnyCode(comp.diagnostics.items, .undefined_symbol);

    // Components stay POD: enum rejected too.
    var comp_enum = try parseAndCheck(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\component Mode { diff: Difficulty }
    );
    defer comp_enum.deinit(gpa);
    try expectAnyCode(comp_enum.diagnostics.items, .undefined_symbol);

    // Resources accept `string` since M1.0.3 E2 (the Option A alignment,
    // formerly the deferred "tranche 7"; part1 §5.5 "no POD constraint for
    // resources"). FLIPPED from rejected → accepted — the intended resolution,
    // not a regression.
    var res = try parseAndCheck(gpa,
        \\resource Settings { player_name: string }
    );
    defer res.deinit(gpa);
    try expectNoCode(res.diagnostics.items, .undefined_symbol);

    // Resources accept enum fields since M1.0.3 E3 (mirrors the `string` unlock).
    var res_enum = try parseAndCheck(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\resource GameMode { diff: Difficulty = .normal }
    );
    defer res_enum.deinit(gpa);
    try expectNoCode(res_enum.diagnostics.items, .undefined_symbol);
}

test "type-checker resolves the builtin Error struct end-to-end (M0.8 E3-C tranche 2)" {
    const gpa = std.testing.allocator;
    // Construct, throw, catch, read fields — every step through the synthetic
    // declarations; `err.message.len()` types as int, `err.code` as ErrorCode.
    var ok = try parseAndCheck(gpa,
        \\component Probe { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  try {
        \\    throw Error { message: "boom", code: ErrorCode.io_fail }
        \\  } catch err {
        \\    entity.get_mut(Probe).n = err.message.len()
        \\    let c = err.code
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "struct-literal field values resolve the enum shorthand in check mode (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    // The part1 §10.2 canonical form `Error { code: .io_fail }` plus a user
    // enum field — the declared field type is the expected type (check
    // mode, resolver-types §4 + §3.5).
    var ok = try parseAndCheck(gpa,
        \\enum Faction { red, blue }
        \\struct Spec {
        \\  hp: int
        \\  faction: Faction
        \\}
        \\component Probe { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  let s = Spec { hp: 5, faction: .red }
        \\  try {
        \\    throw Error { message: "boom", code: .io_fail }
        \\  } catch err {
        \\    entity.get_mut(Probe).n = s.hp + err.message.len()
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // An unknown variant on the declared enum field → E0105.
    var bad = try parseAndCheck(gpa,
        \\enum Faction { red, blue }
        \\struct Spec {
        \\  faction: Faction
        \\}
        \\rule r(entity: Entity) {
        \\  let s = Spec { faction: .green }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .enum_variant_not_found);
}

test "type-checker rejects throwing a non-Error value (M0.8 E3-C tranche 2)" {
    const gpa = std.testing.allocator;
    // part1 §10.2: no custom error hierarchy — the thrown value is an Error.
    var bad = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  try {
        \\    throw 99
        \\  } catch err {
        \\    let x = err
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);
}

test "type-checker requires message and code on an Error literal (M0.8 E3-C tranche 2)" {
    const gpa = std.testing.allocator;
    // part1 §10.2 declares no defaults for message/code; `source` is the
    // omittable chaining field.
    var bad = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  try {
        \\    throw Error { message: "boom" }
        \\  } catch err {
        \\    let x = err
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);
}

test "type-checker rejects a user declaration colliding with the builtin Error (M0.8 E3-C tranche 2)" {
    const gpa = std.testing.allocator;
    var bad = try parseAndCheck(gpa,
        \\struct Error { value: int }
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .duplicate_symbol);
}

test "type-checker accepts the minimal collection method subset (M0.8 E3-C tranche 3)" {
    const gpa = std.testing.allocator;
    // stdlib §13.2/§14.2 minimal subset: array push/len, map insert/len —
    // mutating methods on `let mut` receivers, `len` typing as int.
    var ok = try parseAndCheck(gpa,
        \\component Probe { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  let mut xs: int[] = []
        \\  xs.push(4)
        \\  let mut m = [1: 10]
        \\  m.insert(2, 20)
        \\  entity.get_mut(Probe).n = xs.len() + m.len()
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "type-checker rejects out-of-subset collection methods and immutable receivers (M0.8 E3-C tranches 3-4)" {
    const gpa = std.testing.allocator;
    // `remove` is §13.2 but outside the minimal subset (stdlib Phase 1+).
    var rem = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let mut xs: int[] = [1, 2]
        \\  let v = xs.remove(0)
        \\}
    );
    defer rem.deinit(gpa);
    try expectAnyCode(rem.diagnostics.items, .type_mismatch);

    // `push` is `mut self` (stdlib §13.2): an immutable binding is rejected.
    var immut = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let xs: int[] = []
        \\  xs.push(1)
        \\}
    );
    defer immut.deinit(gpa);
    try expectAnyCode(immut.diagnostics.items, .immutable_receiver_for_mut_self);

    // `pop` is `mut self` too (lifted into the subset in tranche 4): an
    // immutable receiver stays rejected.
    var pop_immut = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let xs: int[] = [1]
        \\  let v = xs.pop()
        \\}
    );
    defer pop_immut.deinit(gpa);
    try expectAnyCode(pop_immut.diagnostics.items, .immutable_receiver_for_mut_self);
}

test "type-checker checks collection method argument types (M0.8 E3-C tranche 3)" {
    const gpa = std.testing.allocator;
    // A pushed value must fit the array element type...
    var bad_push = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let mut xs: int[] = []
        \\  xs.push(1.5)
        \\}
    );
    defer bad_push.deinit(gpa);
    try expectAnyCode(bad_push.diagnostics.items, .type_mismatch);

    // ...and an inserted key/value must fit the map's key/value types.
    var bad_insert = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let mut m = [1: 10]
        \\  m.insert(true, 20)
        \\}
    );
    defer bad_insert.deinit(gpa);
    try expectAnyCode(bad_insert.diagnostics.items, .type_mismatch);
}

test "type-checker types the Optional ops: ??, !, ?., patterns, pop, m[k] (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    // The full tranche-4 op surface (part1 §6.6, stdlib §16.2/§16.3):
    // `??` unwraps to the payload, `!` force-unwraps, `?.len()` re-wraps the
    // string-method result, `some(v)`/`none` patterns are exhaustive on an
    // optional scrutinee, and the tranche-3 lift points type `pop() -> T?`
    // and `m[k] -> V?`.
    var ok = try parseAndCheck(gpa,
        \\component Probe { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  let mut xs: int[] = [10, 20]
        \\  let p = xs.pop()
        \\  let a = p ?? -1
        \\  let mut m = [1: 100]
        \\  let b = m[1] ?? 0
        \\  let c = m[1]!
        \\  let s: string? = some("hello")
        \\  let d = s?.len() ?? 0
        \\  let e = match m[2] { some(x) => x + 1, none => 0 }
        \\  entity.get_mut(Probe).n = a + b + c + d + e
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "type-checker rejects misused Optional ops (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    // `??` requires an optional lhs.
    var bad_coalesce = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let x = 1 ?? 2
        \\}
    );
    defer bad_coalesce.deinit(gpa);
    try expectAnyCode(bad_coalesce.diagnostics.items, .type_mismatch);

    // `!` requires an optional operand.
    var bad_unwrap = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let x = true!
        \\}
    );
    defer bad_unwrap.deinit(gpa);
    try expectAnyCode(bad_unwrap.diagnostics.items, .type_mismatch);

    // A some-only optional match is non-exhaustive (needs `none` or `_`).
    var partial = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let m = [1: 10]
        \\  let x = match m[1] { some(v) => v }
        \\}
    );
    defer partial.deinit(gpa);
    try expectAnyCode(partial.diagnostics.items, .non_exhaustive_match);

    // `?.field` is out of the subset (scalar payloads have no fields).
    var chain_field = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let s: string? = none
        \\  let x = s?.foo
        \\}
    );
    defer chain_field.deinit(gpa);
    try expectAnyCode(chain_field.diagnostics.items, .type_mismatch);

    // `??` default must fit the payload type.
    var bad_default = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let m = [1: 10]
        \\  let x = m[1] ?? true
        \\}
    );
    defer bad_default.deinit(gpa);
    try expectAnyCode(bad_default.diagnostics.items, .type_mismatch);
}

test "type-checker rejects float map keys at both gates (E0601, M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    // stdlib §14 pins `K: Hash + Eq` and §4.3 excludes float/f32/f64 from
    // the builtin Hash set — a float map key is an INVALID program for both
    // backends, not a codegen-only bound (2026-06-10 tranche-3 redressement).
    var lit = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let m = [1.5: 10]
        \\}
    );
    defer lit.deinit(gpa);
    try expectAnyCode(lit.diagnostics.items, .bound_not_satisfied);

    var ann = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let m: [f32: int] = [:]
        \\}
    );
    defer ann.deinit(gpa);
    try expectAnyCode(ann.diagnostics.items, .bound_not_satisfied);

    // Hashable keys stay accepted (int here; string keys keep the ratified
    // tranche-3 bound: interp reference, codegen fail-loud).
    var ok = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let mut m = [1: 10]
        \\  m.insert(2, 20)
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "type-checker resolves the Set builtin associated calls + method subset (M0.8 E3-C tranche 3bis)" {
    const gpa = std.testing.allocator;
    // stdlib §15.1/§15.2 minimal subset: `Set.new()` is typed by the let
    // annotation (empty-map-literal policy), `Set.from([...])` takes the
    // element type from its array argument; `insert` (statement-only),
    // `contains` (bool) and `len` (int) dispatch on `set_t`.
    var ok = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let e: Set<int> = Set.new()
        \\  let mut s = Set.from([1, 2, 2, 3])
        \\  s.insert(4)
        \\  let hit = s.contains(2)
        \\  let n = s.len() + e.len()
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // The builtin route must not shadow user associated fns on other types:
    // `Pt.origin()` still resolves through the user `impl` lookup.
    var user = try parseAndCheck(gpa,
        \\struct Pt { x: int = 0 }
        \\impl Pt {
        \\  fn origin() -> Pt { Pt { x: 0 } }
        \\}
        \\rule r(entity: Entity) {
        \\  let p = Pt.origin()
        \\  let v = p.x
        \\}
    );
    defer user.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), user.diagnostics.items.len);
}

test "type-checker rejects float set elements at both gates (E0601, M0.8 E3-C tranche 3bis)" {
    const gpa = std.testing.allocator;
    // stdlib §15 pins `T: Hash + Eq` on set elements and §4.3 excludes
    // float/f32/f64 from the builtin Hash set — a float set element is an
    // INVALID program for both backends (the tranche-4 map-key redressement,
    // generalized through `checkHashBound`).
    var from = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let s = Set.from([1.5, 2.5])
        \\}
    );
    defer from.deinit(gpa);
    try expectAnyCode(from.diagnostics.items, .bound_not_satisfied);

    var ann = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let s: Set<f32> = Set.new()
        \\}
    );
    defer ann.deinit(gpa);
    try expectAnyCode(ann.diagnostics.items, .bound_not_satisfied);
}

test "type-checker rejects the out-of-subset Set surface (M0.8 E3-C tranche 3bis)" {
    const gpa = std.testing.allocator;
    // `with_capacity` (a generic call form), `remove` (§15.2 remainder), set
    // for-in (no differential requires it), a non-array `from` argument, and
    // `insert` on an immutable binding — each rejected at the resolver so
    // NEITHER backend sees one (the established out-of-subset policy).
    const cases = [_][]const u8{
        \\rule r(entity: Entity) {
        \\  let s = Set.with_capacity(8)
        \\}
        ,
        \\rule r(entity: Entity) {
        \\  let mut s = Set.from([1])
        \\  s.remove(1)
        \\}
        ,
        \\rule r(entity: Entity) {
        \\  let mut s = Set.from([1])
        \\  for x in s {
        \\    let y = x
        \\  }
        \\}
        ,
        \\rule r(entity: Entity) {
        \\  let s = Set.from(7)
        \\}
        ,
        \\rule r(entity: Entity) {
        \\  let s = Set.from([1])
        \\  s.insert(2)
        \\}
        ,
    };
    for (cases) |source| {
        var out = try parseAndCheck(gpa, source);
        defer out.deinit(gpa);
        try std.testing.expect(out.diagnostics.items.len > 0);
    }
}

test "anonymous struct literal resolves in check mode, rejected without an expected type (M0.8 E3-C tranche 8)" {
    const gpa = std.testing.allocator;

    // The two wired contexts — let annotation and typed field value (the
    // tranche-4 propagation extended to the whole literal) — plus the enum
    // shorthand composing INSIDE an anonymous literal, and a struct-typed
    // struct field (part1 §5.5 nested POD structs) carrying a nested anon.
    var ok = try parseAndCheck(gpa,
        \\enum Grade { low, high }
        \\struct Pt { x: int y: int }
        \\struct Spec { hp: int grade: Grade }
        \\struct Box { p: Pt k: int }
        \\component Probe { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Probe
        \\{
        \\  let q: Pt = .{ x: 40, y: 2 }
        \\  let s: Spec = .{ hp: 1, grade: .high }
        \\  let b = Box { p: .{ x: 7, y: 5 }, k: 30 }
        \\  entity.get_mut(Probe).n = q.x + s.hp + b.p.y + b.k
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // No expected type — `.{ … }` is check-mode-only (resolver-types §4).
    var bare = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let x = .{ a: 1 }
        \\}
    );
    defer bare.deinit(gpa);
    try expectAnyCode(bare.diagnostics.items, .ambiguous_type);

    // A non-struct annotation does not supply a struct type.
    var nonstruct = try parseAndCheck(gpa,
        \\rule r(entity: Entity) {
        \\  let x: int = .{ a: 1 }
        \\}
    );
    defer nonstruct.deinit(gpa);
    try expectAnyCode(nonstruct.diagnostics.items, .ambiguous_type);

    // Fn-arg position is NOT a wired context (no differential requires it).
    var fnarg = try parseAndCheck(gpa,
        \\struct Pt { x: int y: int }
        \\fn takes(p: Pt) -> int { p.x }
        \\rule r(entity: Entity) {
        \\  let n = takes(.{ x: 1, y: 2 })
        \\}
    );
    defer fnarg.deinit(gpa);
    try expectAnyCode(fnarg.diagnostics.items, .ambiguous_type);

    // An unknown field on the supplied struct type → the explicit-literal
    // field check, through the same point.
    var badfield = try parseAndCheck(gpa,
        \\struct Pt { x: int y: int }
        \\rule r(entity: Entity) {
        \\  let q: Pt = .{ z: 1 }
        \\}
    );
    defer badfield.deinit(gpa);
    try expectAnyCode(badfield.diagnostics.items, .invalid_field_filter);

    // A struct-typed field must be provided in the literal (E0208 — no
    // declared default the two backends could agree on).
    var missing = try parseAndCheck(gpa,
        \\struct Pt { x: int y: int }
        \\struct Box { p: Pt k: int }
        \\rule r(entity: Entity) {
        \\  let b = Box { k: 1 }
        \\}
    );
    defer missing.deinit(gpa);
    try expectAnyCode(missing.diagnostics.items, .struct_field_missing);

    // POD non-regression: a struct-typed field on a COMPONENT stays
    // rejected (E1 builtin-POD bound, unchanged by the struct unlock).
    var podcomp = try parseAndCheck(gpa,
        \\struct Pt { x: int y: int }
        \\component Holder { p: Pt }
    );
    defer podcomp.deinit(gpa);
    try expectAnyCode(podcomp.diagnostics.items, .undefined_symbol);
}

test "data table: a fully valid table with spread is clean (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\enum Rarity { common, uncommon, rare }
        \\struct Item {
        \\  rarity: Rarity = .common
        \\  weight: float = 0.0
        \\  value: int
        \\}
        \\data ItemDatabase: Item {
        \\  iron_sword: { rarity: .uncommon, weight: 3.5, value: 50 },
        \\  iron_sword_enchanted: { ..ItemDatabase.iron_sword, value: 120 },
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "data table: E1760 empty entries + E0102 unknown entry type (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\data EmptyTable: Missing { }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .data_empty_entries);
    try expectAnyCode(result.diagnostics.items, .undefined_symbol);
}

test "theme: E1640 empty + valid control (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var empty = try parseAndCheck(gpa,
        \\theme "dark" { }
    );
    defer empty.deinit(gpa);
    try expectAnyCode(empty.diagnostics.items, .theme_empty);

    var ok = try parseAndCheck(gpa,
        \\theme "dark" {
        \\  font: "Inter"
        \\  base_size: 14
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "theme: E1641 duplicate entry key (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\theme "dark" {
        \\  font: "Inter"
        \\  font: "Roboto"
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .duplicate_token_name);
}

test "motion: valid control parses + checks clean (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var ok = try parseAndCheck(gpa,
        \\motion MenuPanel {
        \\  states {
        \\    hidden:  { translate_y: 50, opacity: 0, scale: 0.95 }
        \\    visible: { translate_y: 0,  opacity: 1, scale: 1.0 }
        \\  }
        \\  transitions {
        \\    hidden -> visible: animate(0.3s, ease_out_back)
        \\    * -> hidden:       stagger(0.04s, animate(0.2s, ease_in))
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "motion: E1661 duplicate state name (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\motion M {
        \\  states { a: { scale: 1.0 } a: { scale: 0.9 } }
        \\  transitions { a -> a: animate(0.1s) }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .motion_duplicate_state_name);
}

test "motion: E1664 transition references an undeclared state (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\motion M {
        \\  states { a: { scale: 1.0 } }
        \\  transitions { a -> ghost: animate(0.1s) }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .transition_state_not_found);
}

test "motion: E1666 unknown easing (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\motion M {
        \\  states { a: { scale: 1.0 } }
        \\  transitions { a -> a: animate(0.1s, not_an_easing) }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .transition_easing_unknown);
}

test "motion: E1665 negative-literal duration (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\motion M {
        \\  states { a: { scale: 1.0 } }
        \\  transitions { a -> a: animate(-0.1s) }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .transition_duration_invalid);
}

test "input_mapping: valid control parses + checks clean (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var ok = try parseAndCheck(gpa,
        \\input_mapping "Gameplay" {
        \\  context: .gameplay
        \\  priority: 100
        \\  consume_input: true
        \\  action move: Vec2 {
        \\    bind gamepad_left_stick { modifiers: [deadzone_radial(0.15)] }
        \\  }
        \\  action jump: trigger {
        \\    bind gamepad_button_a { triggers: [on_press] }
        \\  }
        \\  combo hadouken: trigger {
        \\    sequence: [.move_down, .move_forward, .action_attack]
        \\    window: 0.4s
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "input_mapping: E1800 empty (only properties) (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\input_mapping "Empty" { context: .gameplay priority: 0 }
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .mapping_empty);
}

test "input_mapping: E1801 duplicate action name (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\input_mapping "M" {
        \\  action fire: trigger { bind mouse_left { triggers: [on_press] } }
        \\  action fire: trigger { bind mouse_right { triggers: [on_press] } }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .duplicate_action_name);
}

test "input_mapping: E1804 unknown modifier (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\input_mapping "M" {
        \\  action move: Vec2 { bind gamepad_left_stick { modifiers: [not_a_modifier(0.1)] } }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .modifier_type_unknown);
}

test "input_mapping: E1805 unknown trigger (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\input_mapping "M" {
        \\  action jump: trigger { bind key_space { triggers: [on_levitate] } }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .trigger_type_unknown);
}

test "input_mapping: E1806 non-int priority (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\input_mapping "M" {
        \\  priority: 1.5
        \\  action jump: trigger { bind key_space { triggers: [on_press] } }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .priority_invalid);
}

test "input_mapping: E1808 non-positive combo window (M0.8 E5)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\input_mapping "M" {
        \\  combo c: trigger { sequence: [.a, .b] window: -0.4s }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .combo_timing_invalid);
}

test "data table: E1762 entry type is not a struct (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\data BadTable: Health {
        \\  a: { current: 1.0 },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .entry_type_mismatch);
}

test "data table: E1761 duplicate entry id (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\data Table: Spec {
        \\  goblin: { value: 1 },
        \\  goblin: { value: 2 },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .duplicate_entry_id);
}

test "data table: E1763 unknown field + E1764 field value type (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\data Table: Spec {
        \\  a: { nope: 1 },
        \\  b: { value: "wrong" },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .entry_field_unknown);
    try expectAnyCode(result.diagnostics.items, .entry_field_type_invalid);
}

test "data table: E1764 enum-typed field rejects a numeric value (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\enum Rarity { common, rare }
        \\struct Spec { rarity: Rarity = .common }
        \\data Table: Spec {
        \\  a: { rarity: 3 },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .entry_field_type_invalid);
}

test "data table: E0105 unknown enum variant in entry value (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\enum Rarity { common, rare }
        \\struct Spec { rarity: Rarity = .common }
        \\data Table: Spec {
        \\  a: { rarity: .legendary },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .enum_variant_not_found);
}

test "data table: E1765 required field missing, spread entry exempt (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int }
        \\data Table: Spec {
        \\  a: { },
        \\  b: { value: 1 },
        \\  c: { ..Table.b },
        \\}
    );
    defer result.deinit(gpa);
    // Exactly one E1765 — entry `a` only; `c` inherits `value` via its spread.
    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (d.code == .entry_field_required_missing) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "data table: E1766 spread reference forms (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\data Table: Spec {
        \\  a: { ..Table.missing },
        \\  b: { ..Unknown.x },
        \\  c: { ..1 + 2 },
        \\}
    );
    defer result.deinit(gpa);
    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (d.code == .spread_reference_not_found) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "data table: E1762 cross-table spread with a different entry type (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct SpecA { value: int = 0 }
        \\struct SpecB { value: int = 0 }
        \\data TableA: SpecA {
        \\  a: { value: 1 },
        \\}
        \\data TableB: SpecB {
        \\  b: { ..TableA.a },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .entry_type_mismatch);
}

test "data table: E1767 spread cycle detected, acyclic chain clean (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\data Table: Spec {
        \\  a: { ..Table.b },
        \\  b: { ..Table.a },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .spread_cycle);

    var ok = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\data Table: Spec {
        \\  base: { value: 1 },
        \\  mid: { ..Table.base },
        \\  top: { ..Table.mid },
        \\}
    );
    defer ok.deinit(gpa);
    try expectNoCode(ok.diagnostics.items, .spread_cycle);
}

test "data table: E1768 id format (PascalCase and camelCase rejected) (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\data Table: Spec {
        \\  BadId: { value: 1 },
        \\  badCamel: { value: 2 },
        \\  good_id: { value: 3 },
        \\}
    );
    defer result.deinit(gpa);
    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (d.code == .id_invalid_format) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "data table: E0101 collision with another top-level symbol (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\struct Spec { value: int = 0 }
        \\component Table { x: float = 0.0 }
        \\data Table: Spec {
        \\  a: { value: 1 },
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .duplicate_symbol);
}

test "routine: a fully valid routine is clean (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\event MealCallReceived { }
        \\fn go_to(place: string) { }
        \\fn idle(anim: string) { }
        \\routine BlacksmithDaily {
        \\  segment Working {
        \\    trigger: at 06:00 or after Sleeping
        \\    actions: go_to("forge")
        \\    until: at 12:00 or on_event MealCallReceived
        \\  }
        \\  segment Sleeping {
        \\    trigger: at 22:00
        \\    actions: go_to("bed") then idle("sleeping")
        \\    until: at 06:00
        \\  }
        \\  on_dialogue_request -> pause_segment
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "routine: E1520 empty + E1521 duplicate segment names (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var empty = try parseAndCheck(gpa,
        \\routine Empty { }
    );
    defer empty.deinit(gpa);
    try expectAnyCode(empty.diagnostics.items, .routine_empty_segments);

    var dup = try parseAndCheck(gpa,
        \\fn go_to(place: string) { }
        \\routine R {
        \\  segment A { trigger: at 06:00
        \\    actions: go_to("x")
        \\    until: at 07:00 }
        \\  segment A { trigger: at 08:00
        \\    actions: go_to("y")
        \\    until: at 09:00 }
        \\}
    );
    defer dup.deinit(gpa);
    try expectAnyCode(dup.diagnostics.items, .duplicate_segment_name);
}

test "routine: E1522 trigger / E1523 until time out of range (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\fn go_to(place: string) { }
        \\routine R {
        \\  segment A {
        \\    trigger: at 25:00
        \\    actions: go_to("x")
        \\    until: at 12:75
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .trigger_invalid);
    try expectAnyCode(result.diagnostics.items, .until_invalid);
}

test "routine: E1524 unknown 'after' segment reference (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\fn go_to(place: string) { }
        \\routine R {
        \\  segment A {
        \\    trigger: after Missing
        \\    actions: go_to("x")
        \\    until: at 12:00
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .segment_reference_not_found);
}

test "routine: E1525 on_event references no declared event (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\fn go_to(place: string) { }
        \\component NotAnEvent { x: float = 0.0 }
        \\routine R {
        \\  segment A {
        \\    trigger: on_event Missing
        \\    actions: go_to("x")
        \\    until: on_event NotAnEvent
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (d.code == .event_type_unknown) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "routine: E1526 interrupt target neither behavior nor pause_segment (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\fn go_to(place: string) { }
        \\component Health { current: float = 0.0 }
        \\routine R {
        \\  segment A {
        \\    trigger: at 06:00
        \\    actions: go_to("x")
        \\    until: at 12:00
        \\  }
        \\  on_threat -> Missing
        \\  on_panic -> Health
        \\}
    );
    defer result.deinit(gpa);
    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (d.code == .interrupt_target_invalid) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "routine: E1527 action calling a non-void fn + E0102 unknown action (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\fn returns_int() -> int { 42 }
        \\routine R {
        \\  segment A {
        \\    trigger: at 06:00
        \\    actions: returns_int() then unknown_fn()
        \\    until: at 12:00
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .action_invalid_return);
    try expectAnyCode(result.diagnostics.items, .undefined_symbol);
}

test "when-surface: non-bool general filter is E1211, fields-only scope (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Counter { value: int = 0 }
        \\rule bad_type(entity: Entity)
        \\  when entity has Counter { value + 1 }
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .invalid_field_filter);

    var unknown = try parseAndCheck(gpa,
        \\component Counter { value: int = 0 }
        \\rule bad_name(entity: Entity)
        \\  when entity has Counter { nope > 1 }
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    );
    defer unknown.deinit(gpa);
    try expectAnyCode(unknown.diagnostics.items, .undefined_symbol);
}

test "when-surface: non-bool bare condition is E0200 (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Counter { value: int = 0 }
        \\rule bad(entity: Entity)
        \\  when entity has Counter and entity.get(Counter).value + 1
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .type_mismatch);
}

test "when-surface: the differential-64 shapes check clean (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Counter {
        \\  value: int = 0
        \\  limit: int = 10
        \\}
        \\resource Config {
        \\  threshold: int = 2
        \\  enabled: bool = true
        \\}
        \\rule r1(entity: Entity)
        \\  when entity has Counter { value * 2 < limit }
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
        \\rule r2(entity: Entity)
        \\  when resource Config { enabled and threshold < 3 } and entity has Counter and entity.get(Counter).value > 4
        \\{
        \\  entity.get_mut(Counter).value += 100
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "named args: binding failures are E0203, valid bindings clean (M0.8 E4 item 16)" {
    const gpa = std.testing.allocator;
    var ok = try parseAndCheck(gpa,
        \\component Acc { out: int = 0 }
        \\fn score(a: int, b: int) -> int { a * 10 + b }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).out = score(b: 3, a: 2)
        \\  entity.get_mut(Acc).out += score(2, b: 3)
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    var bad = try parseAndCheck(gpa,
        \\component Acc { out: int = 0 }
        \\fn score(a: int, b: int) -> int { a * 10 + b }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let w = score(a: 1, nope: 2)
        \\  let x = score(a: 1, a: 2)
        \\  let y = score(1, a: 2)
        \\  let z = score(b: 1)
        \\}
    );
    defer bad.deinit(gpa);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .arg_count_mismatch) count += 1;
    }
    // unknown name, duplicate binding, positional re-bind, arity short.
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "named args: closure and builtin callees are an M0.8 bound, E0203 (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Acc { out: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let double = |x: int| x * 2
        \\  let y = double(x: 5)
        \\  let s = "abc"
        \\  let n = s.len(pad: 1)
        \\}
    );
    defer result.deinit(gpa);
    var count: usize = 0;
    for (result.diagnostics.items) |d| {
        if (d.code == .arg_count_mismatch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "behavior: canonical tree with ambient self/target checks clean (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health {
        \\  current: float = 100.0
        \\  max: float = 100.0
        \\}
        \\event Fled { who: int }
        \\fn find_cover(threat: Entity) -> int { 1 }
        \\fn move_to(spot: int) { }
        \\fn attack_melee(threat: Entity) { }
        \\routine IdleDaily {
        \\  segment Idle {
        \\    trigger: at 06:00
        \\    actions: move_to(0)
        \\    until: at 22:00
        \\  }
        \\}
        \\behavior Patrol {
        \\  sequence {
        \\    action: run_routine(IdleDaily)
        \\  }
        \\}
        \\behavior CombatBehavior {
        \\  selector {
        \\    sequence when self has Health { current < max * 0.2 } {
        \\      action: let cover = find_cover(target)
        \\      action: move_to(cover)
        \\      action: emit Fled { who: 1 }
        \\    }
        \\    condition: self.get(Health).current > 0.0
        \\    action: attack_melee(target)
        \\    action: run_behavior(Patrol)
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "behavior: E1500/E1501/E1503/E1504/E1505 structural codes (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var leaf_root = try parseAndCheck(gpa,
        \\fn f() { }
        \\behavior B { action: f() }
    );
    defer leaf_root.deinit(gpa);
    try expectAnyCode(leaf_root.diagnostics.items, .behavior_root_missing);

    var empty = try parseAndCheck(gpa,
        \\behavior B { selector { } }
    );
    defer empty.deinit(gpa);
    try expectAnyCode(empty.diagnostics.items, .behavior_empty_composite);

    var bad = try parseAndCheck(gpa,
        \\component Health { current: float = 0.0 }
        \\fn scored() -> int { 1 }
        \\behavior B {
        \\  selector when self.get(Health).current + 1.0 {
        \\    condition: self.get(Health).current + 1.0
        \\    action: scored()
        \\    action: 42
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .behavior_when_clause_not_bool);
    try expectAnyCode(bad.diagnostics.items, .behavior_condition_not_bool);
    var e1504: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .behavior_action_invalid_return) e1504 += 1;
    }
    // `scored()` (non-void fn) and `42` (value expression).
    try std.testing.expectEqual(@as(usize, 2), e1504);
}

test "behavior: E1502 unknown intrinsic targets + E1506 recursion (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var unknown = try parseAndCheck(gpa,
        \\behavior B {
        \\  selector {
        \\    action: run_behavior(Missing)
        \\    action: run_routine(AlsoMissing)
        \\  }
        \\}
    );
    defer unknown.deinit(gpa);
    var e1502: usize = 0;
    for (unknown.diagnostics.items) |d| {
        if (d.code == .behavior_invalid_leaf) e1502 += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), e1502);

    var cyclic = try parseAndCheck(gpa,
        \\behavior A {
        \\  selector { action: run_behavior(B) }
        \\}
        \\behavior B {
        \\  selector { action: run_behavior(A) }
        \\}
    );
    defer cyclic.deinit(gpa);
    try expectAnyCode(cyclic.diagnostics.items, .behavior_recursion);

    var acyclic = try parseAndCheck(gpa,
        \\behavior Leaf {
        \\  selector { condition: true }
        \\}
        \\behavior Root {
        \\  selector { action: run_behavior(Leaf) }
        \\}
    );
    defer acyclic.deinit(gpa);
    try expectNoCode(acyclic.diagnostics.items, .behavior_recursion);
}

test "quest: canonical quest with ambient player checks clean (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\event DialogueStart { npc: int }
        \\tags { quest { merchant_intro_done } }
        \\fn interact_with(who: string) -> bool { true }
        \\fn reward_xp(amount: int) { }
        \\quest EscortMerchant {
        \\  display_name: "Escorting the Merchant"
        \\  required_level: 5
        \\  requires: player has_tag .quest.merchant_intro_done
        \\  stage talk {
        \\    objective main: interact_with("merchant_01")
        \\    on_complete: emit DialogueStart { npc: 1 }
        \\  }
        \\  stage wrap_up {
        \\    objective main: player.get(Health).current > 0.0
        \\    on_fail: player.get(Health).current <= 0.0 -> restart_stage
        \\    on_complete: {
        \\      reward_xp(500)
        \\    }
        \\    branch hard_path when player has Health { current < 10.0 } {
        \\      stage survive {
        \\        objective main: interact_with("medic")
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "quest: structural codes E1540/E1541/E1542/E1546/E1547/E1548 (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var empty = try parseAndCheck(gpa,
        \\quest Q { }
    );
    defer empty.deinit(gpa);
    try expectAnyCode(empty.diagnostics.items, .quest_empty_stages);

    var bad = try parseAndCheck(gpa,
        \\fn done() -> bool { true }
        \\quest Q {
        \\  display_name: 42
        \\  requires: 1 + 2
        \\  stage a {
        \\    objective main: done()
        \\    branch empty_branch when true { }
        \\    branch bad_when when 1 + 2 {
        \\      stage a {
        \\        objective main: done()
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .property_invalid_type);
    try expectAnyCode(bad.diagnostics.items, .quest_requires_not_bool);
    try expectAnyCode(bad.diagnostics.items, .branch_empty);
    try expectAnyCode(bad.diagnostics.items, .branch_condition_not_bool);
    try expectAnyCode(bad.diagnostics.items, .duplicate_stage_name);
}

test "quest: E1543/E1545/E1550 reference codes + W1541 warning (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parseAndCheck(gpa,
        \\fn check() -> bool { true }
        \\quest Q {
        \\  stage a {
        \\    objective main: 42
        \\    on_fail: check() -> switch_branch(missing_branch)
        \\    on_complete: emit Unknown { x: 1 }
        \\  }
        \\  stage b {
        \\    objective optional extra: check()
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try expectAnyCode(result.diagnostics.items, .objective_invalid_return);
    try expectAnyCode(result.diagnostics.items, .switch_branch_target_not_found);
    try expectAnyCode(result.diagnostics.items, .event_reference_not_found);
    try expectAnyCode(result.diagnostics.items, .no_main_objective);
}

test "dialogue: canonical dialogue checks clean, structural codes fire (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var ok = try parseAndCheck(gpa,
        \\component Health { current: float = 100.0 }
        \\event OpenShopUI { shop: int }
        \\tags { social { met_merchant } }
        \\dialogue MerchantGreeting {
        \\  speaker "merchant" {
        \\    line: @loc:"Welcome!"
        \\    line: "You're hurt!" when player has Health { current < 50.0 }
        \\  }
        \\  choice {
        \\    @loc:"Show me your wares" -> show_wares
        \\    "Goodbye" when player.get(Health).current > 0.0 -> end
        \\  }
        \\  branch show_wares {
        \\    emit OpenShopUI { shop: 1 } when not player has_tag .social.met_merchant
        \\    -> end
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    var bad = try parseAndCheck(gpa,
        \\dialogue Bad {
        \\  speaker "npc" {
        \\    line: "x" when 1 + 2
        \\  }
        \\  choice {
        \\    "a" when 3 + 4 -> nowhere
        \\  }
        \\  emit Missing { x: 1 }
        \\  -> also_nowhere
        \\  branch dup { -> end }
        \\  branch dup { -> end }
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .line_condition_not_bool);
    try expectAnyCode(bad.diagnostics.items, .choice_condition_not_bool);
    try expectAnyCode(bad.diagnostics.items, .choice_target_not_found);
    try expectAnyCode(bad.diagnostics.items, .dialogue_event_type_unknown);
    try expectAnyCode(bad.diagnostics.items, .branch_reference_not_found);
    try expectAnyCode(bad.diagnostics.items, .duplicate_branch_label);

    var empty = try parseAndCheck(gpa,
        \\dialogue Empty { }
    );
    defer empty.deinit(gpa);
    try expectAnyCode(empty.diagnostics.items, .dialogue_empty);
}

test "ability: canonical ability checks clean, structural codes fire (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var ok = try parseAndCheck(gpa,
        \\resource ManaPool { mana: float = 100.0 }
        \\component Mana { current: float = 100.0 }
        \\tags { character { status { alive, stunned, silenced } } }
        \\ability Dash { cooldown: 1.5 }
        \\ability Fireball {
        \\  cost: { mana: 20.0 }
        \\  cooldown: 3.0s
        \\  tags_required: [.character.status.alive]
        \\  tags_blocked: [.character.status.stunned, .character.status.silenced]
        \\  charges: 2
        \\  rule activate(caster: Entity) when caster has Mana { current >= 20.0 } {
        \\    caster.get_mut(Mana).current -= 20.0
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    var bad = try parseAndCheck(gpa,
        \\resource ManaPool { mana: float = 100.0 }
        \\tags { character { status { alive } } }
        \\ability Bad {
        \\  cost: { stamina: 5.0 }
        \\  cooldown: true
        \\  tags_required: [.character.status.alive, .character.status.missing]
        \\  tags_blocked: [.character.status.alive]
        \\}
    );
    defer bad.deinit(gpa);
    try expectAnyCode(bad.diagnostics.items, .cost_invalid);
    try expectAnyCode(bad.diagnostics.items, .cooldown_invalid);
    try expectAnyCode(bad.diagnostics.items, .required_tags_unknown);
    try expectAnyCode(bad.diagnostics.items, .tags_required_blocked_conflict);

    var neg = try parseAndCheck(gpa,
        \\ability NegCooldown { cooldown: -1.0 }
    );
    defer neg.deinit(gpa);
    try expectAnyCode(neg.diagnostics.items, .cooldown_invalid);

    var blocked = try parseAndCheck(gpa,
        \\ability BlockedUnknown { tags_blocked: [.character.status.missing] }
    );
    defer blocked.deinit(gpa);
    try expectAnyCode(blocked.diagnostics.items, .blocked_tags_unknown);

    var empty = try parseAndCheck(gpa,
        \\ability Empty { }
    );
    defer empty.deinit(gpa);
    try expectAnyCode(empty.diagnostics.items, .ability_empty);

    // The embedded rule rides the NORMAL rule validation — a component
    // access without its `has` gate fails like any rule body would.
    var gated = try parseAndCheck(gpa,
        \\component Mana { current: float = 100.0 }
        \\ability Gated {
        \\  rule activate(caster: Entity) {
        \\    caster.get_mut(Mana).current -= 1.0
        \\  }
        \\}
    );
    defer gated.deinit(gpa);
    try std.testing.expect(gated.diagnostics.items.len > 0);
}

test "extension methods type-check on an Entity receiver (M1.0.9 B2)" {
    const gpa = std.testing.allocator;
    // A real (NOT checker-skipped) rule body calling all four extension methods
    // must type-check clean — no `type_mismatch` "no method on an Entity".
    var ok = try parseAndCheck(gpa,
        \\component Health { current: i32 = 100, max: i32 = 100 }
        \\rule probe(entity: Entity) when entity has Health {
        \\  entity.activate_extension("Combat")
        \\  entity.deactivate_extension("Combat")
        \\  let h = entity.has_extension("Combat")
        \\  let xs = entity.active_extensions()
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // Wrong arg count / type is still rejected.
    var bad = try parseAndCheck(gpa,
        \\component Health { current: i32 = 100 }
        \\rule probe(entity: Entity) when entity has Health {
        \\  entity.activate_extension(42)
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expect(bad.diagnostics.items.len > 0);
}

test "E0904 fires on a sub-expression await, not on the statement-head forms (M1.0.11 E3)" {
    const gpa = std.testing.allocator;
    // The four statement-head positions — expr-stmt, `let` init, simple assign
    // RHS, `return` operand — are the allowed placement: no E0904.
    var head = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn f() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let mut x = await f()
        \\  x = await f()
        \\  await f()
        \\  return await f()
        \\}
    );
    defer head.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), head.parse_diags.len);
    try expectNoCode(head.diagnostics.items, .await_not_statement_head);

    // A sub-expression `await` (here, an argument of `some(...)`) is not the full
    // RHS of its statement — E0904 (hoist it into a `let`).
    var sub = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn f() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  return some(await f())
        \\}
    );
    defer sub.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sub.parse_diags.len);
    try expectAnyCode(sub.diagnostics.items, .await_not_statement_head);
}

test "E0904 fires on a statement-head await inside a value-position block, not a statement-position one (M1.0.11 E3)" {
    const gpa = std.testing.allocator;
    // An `if` used as a VALUE (a `let` initializer) is evaluated synchronously by
    // the tree-walker — a statement-head `await` in its branch is inexecutable → E0904.
    var vif = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn f() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let x = if true { await f() } else { await f() }
        \\}
    );
    defer vif.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), vif.parse_diags.len);
    try expectAnyCode(vif.diagnostics.items, .await_not_statement_head);

    // A value block `{ … await … }` (a `let` initializer) — same synchronous
    // evaluation → E0904.
    var vblk = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn f() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let x = { await f() }
        \\}
    );
    defer vblk.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), vblk.parse_diags.len);
    try expectAnyCode(vblk.diagnostics.items, .await_not_statement_head);

    // But the SAME `if`/`let` in STATEMENT position (a frame-driven body the
    // driver pushes as a frame) is fine — no E0904.
    var sif = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn f() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  if true {
        \\    let y = await f()
        \\  }
        \\}
    );
    defer sif.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sif.parse_diags.len);
    try expectNoCode(sif.diagnostics.items, .await_not_statement_head);
}

test "E0901 fires on an async call / await in a non-async context, not on a legal async→async await (M1.0.11 E4)" {
    const gpa = std.testing.allocator;
    const af =
        \\resource Out { n: int = 0 }
        \\async fn af() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\
    ;
    // (a) `async fn` called from a SYNC `fn` → E0901.
    var sfn = try parseAndCheck(gpa, af ++
        \\fn caller() -> int {
        \\  let x = af()
        \\  return x
        \\}
    );
    defer sfn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sfn.parse_diags.len);
    try expectAnyCode(sfn.diagnostics.items, .async_call_in_non_async_context);

    // (b) `async fn` called from a SYNC `rule` → E0901.
    var srule = try parseAndCheck(gpa, af ++
        \\rule caller()
        \\  when resource Out
        \\{
        \\  let x = af()
        \\  let o = get_mut(Out)
        \\  o.n = x
        \\}
    );
    defer srule.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), srule.parse_diags.len);
    try expectAnyCode(srule.diagnostics.items, .async_call_in_non_async_context);

    // (c) `await` used in a SYNC context → E0901.
    var sawait = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\rule caller()
        \\  when resource Out
        \\{
        \\  await wait(0.02s)
        \\}
    );
    defer sawait.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), sawait.parse_diags.len);
    try expectAnyCode(sawait.diagnostics.items, .async_call_in_non_async_context);

    // (d) a legal `async`→`async` call via `await` — no E0901.
    var ok = try parseAndCheck(gpa, af ++
        \\async rule caller()
        \\  when resource Out
        \\{
        \\  let x = await af()
        \\  let o = get_mut(Out)
        \\  o.n = x
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try expectNoCode(ok.diagnostics.items, .async_call_in_non_async_context);
}

test "E0901 fires on the four concurrency constructs outside an async context (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    // §4.2 (the async constructs are only available in an async context) —
    // each of the four forms in a SYNC rule is E0901.
    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\rule r()
        \\  when resource Out
        \\{
        \\  race { }
        \\  sync { }
        \\  branch { }
        \\  spawn { }
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .async_call_in_non_async_context) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    // The same four forms in an ASYNC rule are clean.
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  race { }
        \\  sync { }
        \\  branch { }
        \\  spawn { }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try expectNoCode(ok.diagnostics.items, .async_call_in_non_async_context);
}

test "E0905 fires on every bare async call; await is the sole consumer (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    const af =
        \\resource Out { n: int = 0 }
        \\async fn af() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\
    ;
    // Bare async calls in an async context — statement and let-init forms —
    // leave the `{async}` effect unconsumed → E0905 (NOT E0901: the context
    // IS async).
    var bare = try parseAndCheck(gpa, af ++
        \\async rule r()
        \\  when resource Out
        \\{
        \\  af()
        \\  let t = af()
        \\}
    );
    defer bare.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bare.parse_diags.len);
    var count: usize = 0;
    for (bare.diagnostics.items) |d| {
        if (d.code == .unconsumed_async_effect) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try expectNoCode(bare.diagnostics.items, .async_call_in_non_async_context);

    // §9.2 revision 2: the four constructs RELOCATE the await into a child
    // task, they do not replace it — a bare async call inside their bodies is
    // E0905 like anywhere else (it would hit the sync call path's `is_async`
    // fail-loud gate at execution). One per body → 4 × E0905.
    var inbody = try parseAndCheck(gpa, af ++
        \\async rule r()
        \\  when resource Out
        \\{
        \\  race { af() }
        \\  sync { af() }
        \\  branch { af() }
        \\  spawn { af() }
        \\}
    );
    defer inbody.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), inbody.parse_diags.len);
    count = 0;
    for (inbody.diagnostics.items) |d| {
        if (d.code == .unconsumed_async_effect) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    // Consumed by `await` — at the rule top AND inside each of the four
    // construct bodies — no E0905.
    var ok = try parseAndCheck(gpa, af ++
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let x = await af()
        \\  race {
        \\    await af()
        \\    { let a = await af()
        \\      return }
        \\  }
        \\  sync { await af() }
        \\  branch { let y = await af() }
        \\  spawn { await af() }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try expectNoCode(ok.diagnostics.items, .unconsumed_async_effect);
}

test "E0906 rejects return in sync/branch/spawn, accepts it in a race branch (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    // `return` in a sync branch / branch body / spawn body → E0906 each.
    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  sync { { return } }
        \\  branch { return }
        \\  spawn { return }
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .illegal_return_in_concurrency_branch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    // `return` in a race branch is LEGAL (winner-return propagation, §9.5) —
    // the canonical timeout pattern.
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn fetch() -> int {
        \\  await wait(0.02s)
        \\  return 1
        \\}
        \\async fn with_timeout() -> int {
        \\  race {
        \\    return await fetch()
        \\    { await wait(5.0s)
        \\      return 0 }
        \\  }
        \\  return 0
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try expectNoCode(ok.diagnostics.items, .illegal_return_in_concurrency_branch);
}

test "E0907 rejects break/continue crossing the task boundary, accepts in-branch loops (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    // An unlabeled `break`/`continue` with no in-branch loop, and a labeled
    // `break` targeting a loop OUTSIDE the construct, cross the boundary —
    // E0907 (all four forms exercise the same check; race + spawn shown).
    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  outer: loop {
        \\    race { { break } }
        \\    spawn { continue }
        \\    sync { { break outer } }
        \\    branch { break }
        \\    break
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .control_flow_escapes_task_branch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    // Loops FULLY INSIDE a branch keep working: unlabeled and labeled
    // break/continue targeting in-branch loops are clean.
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  branch {
        \\    for i in 0..3 {
        \\      continue
        \\    }
        \\    inner: loop {
        \\      loop { break inner }
        \\      break
        \\    }
        \\  }
        \\  spawn {
        \\    while true {
        \\      break
        \\    }
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try expectNoCode(ok.diagnostics.items, .control_flow_escapes_task_branch);
}

test "TaskHandle: binding typed, cancel/await accepted, misuse rejected (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    // The bound spawn types `h` as the builtin TaskHandle: `h.cancel()` and
    // `await h` are its two operations (§9.8) — clean.
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn {
        \\    await wait(0.02s)
        \\  }
        \\  h.cancel()
        \\  let h2 = spawn { }
        \\  await h2
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // `cancel` with arguments, and any other method on a TaskHandle → E0200.
    var badm = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = spawn { }
        \\  h.cancel(1)
        \\  h.join()
        \\}
    );
    defer badm.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), badm.parse_diags.len);
    var count: usize = 0;
    for (badm.diagnostics.items) |d| {
        if (d.code == .type_mismatch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // `await` on a non-TaskHandle non-call expression → E0200.
    var badh = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let h = 5
        \\  await h
        \\}
    );
    defer badh.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), badh.parse_diags.len);
    try expectAnyCode(badh.diagnostics.items, .type_mismatch);
}

test "TaskHandle is rejected as a component/resource field type (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    // Non-POD builtin (§2.2) — like `string` on components, a `TaskHandle`
    // field is rejected on both a component and a resource.
    var bad = try parseAndCheck(gpa,
        \\component C { h: TaskHandle }
        \\resource R { h: TaskHandle }
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .undefined_symbol) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "timer: binding typed TimerHandle, cancel accepted, expression arg, non-async rule (M1.0.13 E4)" {
    const gpa = std.testing.allocator;
    // A bound timer types `t` as the builtin TimerHandle; `cancel()` is its
    // only operation (§9.10). Timers carry no `{async}` effect: they are
    // legal in a plain (non-async) rule. The duration argument is a full
    // expression — a `Duration` variable is accepted.
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\event Boom { }
        \\rule r()
        \\  when resource Out
        \\{
        \\  let d = 1.5s
        \\  let t = after(d) {
        \\    emit Boom { }
        \\  }
        \\  t.cancel()
        \\  every(30.0s) { }
        \\  after_unscaled(0.5s) { }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // `cancel` with arguments, and any other method on a TimerHandle → E0200.
    var badm = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\rule r()
        \\  when resource Out
        \\{
        \\  let t = after(1.0s) { }
        \\  t.cancel(1)
        \\  t.join()
        \\}
    );
    defer badm.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), badm.parse_diags.len);
    var count: usize = 0;
    for (badm.diagnostics.items) |d| {
        if (d.code == .type_mismatch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "timer: await on a TimerHandle is rejected — a timer is not a task (M1.0.13 E4)" {
    const gpa = std.testing.allocator;
    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let t = after(1.0s) { }
        \\  await t
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);
}

test "TimerHandle is rejected as a component/resource field type (M1.0.13 E4)" {
    const gpa = std.testing.allocator;
    // Non-POD builtin (§2.2) — the TaskHandle precedent: a `TimerHandle`
    // field is rejected on both a component and a resource.
    var bad = try parseAndCheck(gpa,
        \\component C { t: TimerHandle }
        \\resource R { t: TimerHandle }
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .undefined_symbol) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "timer: non-Duration argument is rejected (M1.0.13 E4)" {
    const gpa = std.testing.allocator;
    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\rule r()
        \\  when resource Out
        \\{
        \\  after(5) { }
        \\  every(true) { }
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .type_mismatch) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "timer body is a synchronous context: await/async call inside is E0901 (M1.0.13 E4)" {
    const gpa = std.testing.allocator;
    // §9.10: the timer body carries no `{async}` effect — an `await` or an
    // async call inside it is E0901 even when the SCHEDULING rule is async.
    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async fn f() {
        \\  await wait(0.02s)
        \\}
        \\async rule r()
        \\  when resource Out
        \\{
        \\  after(1.0s) {
        \\    await wait(0.5s)
        \\  }
        \\  every(1.0s) {
        \\    f()
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    var count: usize = 0;
    for (bad.diagnostics.items) |d| {
        if (d.code == .async_call_in_non_async_context) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // A deferred structural mutation and an emit stay LEGAL in the body —
    // the synchronous context only refuses the async effect.
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\component Health { current: f32 = 100.0 }
        \\event Boom { }
        \\rule r(entity: Entity)
        \\  when entity has Health and resource Out
        \\{
        \\  after(2.0s) {
        \\    emit Boom { }
        \\    entity.remove(Health)
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);
}

test "builtin time resources resolve by name from the descriptor table (M1.0.13 E4)" {
    const gpa = std.testing.allocator;
    // `get(GameTime).dt` / `get_mut(GameTime).time_scale` resolve against
    // `builtin_resources` — no declaration, no `when resource` clause (the
    // time resources are ambient; `Out` alone is in the when).
    var ok = try parseAndCheck(gpa,
        \\resource Out { total: float = 0.0 }
        \\rule r()
        \\  when resource Out
        \\{
        \\  let scaled: float = get(GameTime).dt
        \\  let fixed: float = get(GameTime).fixed_dt
        \\  let frames: int = get(GameTime).frame
        \\  let halted: bool = get(GameTime).paused
        \\  get_mut(GameTime).time_scale = 0.5
        \\  get_mut(GameTime).paused = true
        \\  let u: float = get(UnscaledTime).dt
        \\  let startup: float = get(RealTime).since_startup
        \\  get_mut(Out).total = get(UnscaledTime).total
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // An unknown field on a builtin resource is caught against the table.
    var bad = try parseAndCheck(gpa,
        \\resource Out { total: float = 0.0 }
        \\rule r()
        \\  when resource Out
        \\{
        \\  let x = get(GameTime).nope
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    try expectAnyCode(bad.diagnostics.items, .invalid_field_filter);
}

test "conditional branch guards type-check as bool in the parent scope (M1.0.12 E3)" {
    const gpa = std.testing.allocator;
    // A bool guard referencing a parent local is clean; a non-bool guard is
    // E0200. Guards are evaluated in the parent scope at construct entry
    // (§9.5), synchronously.
    //
    // NB: a guarded BLOCK branch must not END on a bare `await` — a block's
    // trailing expression is its VALUE (synchronously evaluated), so a
    // trailing await sits off the frame spine → E0904 (M1.0.11 placement,
    // unchanged). The §9.5 pattern always ends on a statement (`return`).
    var ok = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  let hard = true
        \\  race {
        \\    await wait(0.02s)
        \\    if hard => await wait(2.0s)
        \\  }
        \\}
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    var bad = try parseAndCheck(gpa,
        \\resource Out { n: int = 0 }
        \\async rule r()
        \\  when resource Out
        \\{
        \\  sync {
        \\    if 42 => await wait(0.02s)
        \\  }
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    try expectAnyCode(bad.diagnostics.items, .type_mismatch);
}

// ─── M1.1.15.2 G1 — declaration files, services, E1901 ──────────────────────

/// `parseAndCheck` for a declaration file. The mode is a property of the
/// arena, so the only difference from `parseAndCheck` is which parser entry
/// point produced it.
fn parseAndCheckDetch(gpa: std.mem.Allocator, source: []const u8) !CheckOutcome {
    var pr = try parser_mod.parseWithMode(gpa, source, .declaration_file);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    try TypeChecker.check(gpa, &pr.ast, &diags);
    return .{ .ast = pr.ast, .parse_diags = pr.diagnostics, .diagnostics = diags };
}

/// Two-file project check: `decl_src` parsed as a `.d.etch`, `caller_src` as a
/// standard `.etch`, both handed to `checkProject` so `collectServices` walks
/// the project's arenas. The arenas are MOVED out of the parse results and
/// owned by the outcome — copying an `AstArena` while its `ParseResult` still
/// owns the same buffers is a double free, and it segfaulted exactly that way
/// when this helper was first written inline.
fn checkServiceProject(gpa: std.mem.Allocator, decl_src: []const u8, caller_src: []const u8) !ServiceProjectOutcome {
    var decl_pr = try parser_mod.parseWithMode(gpa, decl_src, .declaration_file);
    errdefer decl_pr.deinit(gpa);
    var caller_pr = try parser_mod.parse(gpa, caller_src);
    errdefer caller_pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), decl_pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), caller_pr.diagnostics.len);
    // The parse diagnostics are empty slices at this point; free them here so
    // the arenas can be moved without `ParseResult.deinit` ever running.
    gpa.free(decl_pr.diagnostics);
    gpa.free(caller_pr.diagnostics);

    var out: ServiceProjectOutcome = .{
        .arenas = .{ decl_pr.ast, caller_pr.ast },
        .diagnostics = .empty,
    };
    errdefer out.deinit(gpa);
    const ctx: TypeChecker.ProjectContext = .{
        .prefabs = &out.prefabs,
        .uuids = &out.uuids,
        .module_index = &out.module_index,
        .exports = &out.exports,
        .arenas = &out.arenas,
    };
    try TypeChecker.checkProject(gpa, &out.arenas[1], &out.diagnostics, &ctx);
    return out;
}

const ServiceProjectOutcome = struct {
    arenas: [2]AstArena,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    prefabs: std.StringHashMapUnmanaged(void) = .empty,
    uuids: std.StringHashMapUnmanaged(void) = .empty,
    module_index: std.StringHashMapUnmanaged(usize) = .empty,
    exports: [2]TypeChecker.ExportTable = .{ .empty, .empty },

    fn deinit(self: *ServiceProjectOutcome, gpa: std.mem.Allocator) void {
        for (self.diagnostics.items) |*d| d.deinit(gpa);
        self.diagnostics.deinit(gpa);
        for (&self.arenas) |*a| a.deinit(gpa);
        for (&self.exports) |*e| e.deinit(gpa);
        self.prefabs.deinit(gpa);
        self.uuids.deinit(gpa);
        self.module_index.deinit(gpa);
    }
};

test "E1901 on disallowed top-level construct in .d.etch" {
    const gpa = std.testing.allocator;

    // A `rule` is §20.2's first forbidden construct. Its body parses normally —
    // E1900 covers `fn` bodies, not rule bodies — so this is genuinely the
    // post-parse identity check and not E1900 under another name.
    var bad = try parseAndCheckDetch(gpa,
        \\fn ping(x: int) -> int
        \\rule r() {
        \\  let n = 1
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), bad.parse_diags.len);
    try expectAnyCode(bad.diagnostics.items, .construct_not_allowed_in_declaration_file);
    try std.testing.expectEqual(@as(usize, 1), bad.diagnostics.items.len);
    try std.testing.expectEqualStrings("E1901", bad.diagnostics.items[0].code.code());

    // COUNTERFACTUAL ON THE OBJECT, not on the expected constant: the very same
    // source in a standard `.etch` is clean. Were the check unconditional, or
    // keyed on anything but the arena's mode, this would fail too.
    var same_source_standard = try parseAndCheck(gpa,
        \\fn ping(x: int) -> int { x }
        \\rule r() {
        \\  let n = 1
        \\}
    );
    defer same_source_standard.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), same_source_standard.parse_diags.len);
    try expectNoCode(same_source_standard.diagnostics.items, .construct_not_allowed_in_declaration_file);

    // Every occurrence is reported, not just the first (§20.2's "à la première
    // occurrence" read as WHEN the error is raised, not as a one-per-file
    // budget). Two forbidden constructs, two diagnostics.
    var two = try parseAndCheckDetch(gpa,
        \\rule a() { let n = 1 }
        \\rule b() { let n = 2 }
    );
    defer two.deinit(gpa);
    var n_e1901: usize = 0;
    for (two.diagnostics.items) |d| {
        if (d.code == .construct_not_allowed_in_declaration_file) n_e1901 += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n_e1901);

    // The constructs §20.1 refuses and §20.2 does not name are refused on the
    // ALLOW-LIST. Asserted per construct: a count would pass if one of them were
    // admitted and another double-reported. `event` was in this list until the
    // G1 amendment moved it to the admitted side; `component` and `resource`
    // stay, and the twin test below is what proves the amendment widened the
    // list by exactly one and not by a family.
    for ([_][]const u8{
        "component Health { current: int = 100 }",
        "resource Score { n: int = 0 }",
    }) |src| {
        var r = try parseAndCheckDetch(gpa, src);
        defer r.deinit(gpa);
        try expectAnyCode(r.diagnostics.items, .construct_not_allowed_in_declaration_file);
    }

    // And the ten §20.1 admits are admitted — the other half of an allow-list,
    // without which a check that refused EVERYTHING would pass the tests above.
    var allowed = try parseAndCheckDetch(gpa,
        \\import gameplay.combat
        \\const MAX: int = 10
        \\struct Pair { a: int = 0, b: int = 0 }
        \\enum Mode { fast, slow }
        \\type Alias = int
        \\event Hit { damage: int = 0 }
        \\fn ping(x: int) -> int
        \\service audio_player {
        \\  fn play(path: string) -> int
        \\}
    );
    defer allowed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), allowed.parse_diags.len);
    try expectNoCode(allowed.diagnostics.items, .construct_not_allowed_in_declaration_file);
}

test "unknown service method resolves to a diagnostic" {
    const gpa = std.testing.allocator;

    // Single-arena form: the service and the caller in one declaration file is
    // not the deployed shape (§20.5 puts callers in `.etch`), but it is what an
    // inline test can build, and the resolution path is the same one — the
    // index is keyed by name BYTES either way.
    //
    // A DECLARED method resolves and carries its return type through.
    var ok = try parseAndCheckDetch(gpa,
        \\service audio_player {
        \\  fn play(path: string) -> int
        \\  fn stop(handle: int)
        \\}
        \\fn caller() -> int
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // THE REAL SHAPE, and the only one that can carry a call: the service is
    // declared in a `.d.etch` and called from a standard `.etch`. A single arena
    // cannot hold both — a call needs a body, bodies are refused in a `.d.etch`,
    // and `service` is refused in a `.etch` — so the two files go through
    // `checkProject`, whose `ProjectContext.arenas` is what `collectServices`
    // walks. Built by `checkServiceProject` rather than through
    // `root.validateProject`, which this file cannot reach (tier-up).
    const decl_src =
        \\service audio_player {
        \\  fn play(path: string) -> int
        \\  fn stop(handle: int)
        \\}
    ;

    // EXACTLY ONE diagnostic: `play` resolves, `rewind` does not. Both calls
    // are made in the same body on purpose — a file containing only the failing
    // call would pass against a checker that rejected every service method.
    var unknown_method = try checkServiceProject(gpa, decl_src,
        \\fn caller() -> int {
        \\  let a = audio_player.play("x.wav")
        \\  let b = audio_player.rewind("x.wav")
        \\  a
        \\}
    );
    defer unknown_method.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), unknown_method.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCode.undefined_symbol, unknown_method.diagnostics.items[0].code);
    const msg = unknown_method.diagnostics.items[0].primary_message;
    try std.testing.expect(std.mem.indexOf(u8, msg, "audio_player") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "rewind") != null);

    // ARITY is checked, and separately from the name.
    var arity = try checkServiceProject(gpa, decl_src,
        \\fn caller() -> int {
        \\  audio_player.play("x.wav", 1)
        \\}
    );
    defer arity.deinit(gpa);
    try expectAnyCode(arity.diagnostics.items, .arg_count_mismatch);

    // A LOCAL SHADOWS the service, and the shadow is observable: the same call
    // spelling now reports the receiver as a plain value with no such method,
    // never as a service. Without this, "check locals first" would be an
    // untested comment.
    var shadow = try checkServiceProject(gpa, decl_src,
        \\fn caller() -> int {
        \\  let audio_player = 1
        \\  audio_player.play("x.wav")
        \\}
    );
    defer shadow.deinit(gpa);
    try std.testing.expect(shadow.diagnostics.items.len > 0);
    for (shadow.diagnostics.items) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.primary_message, "service") == null);
    }

    // COUNTERFACTUAL ON THE OBJECT: drop the declaration file and the same
    // caller reports an unknown IDENTIFIER instead — proof the resolution above
    // came from the service index and not from some other tolerance.
    var no_service = try checkServiceProject(gpa, "const UNUSED: int = 0",
        \\fn caller() -> int {
        \\  audio_player.play("x.wav")
        \\}
    );
    defer no_service.deinit(gpa);
    try expectAnyCode(no_service.diagnostics.items, .undefined_symbol);
    try std.testing.expect(std.mem.indexOf(u8, no_service.diagnostics.items[0].primary_message, "unknown identifier") != null);
}

test "an event declared in a .d.etch parses and registers, a component still does not" {
    const gpa = std.testing.allocator;

    // G1 amendment (Claude.ai round-trip): `event_decl` joins §20.1's
    // `decl_file_item`. G4 has to make a Zig-emitted event observable from a
    // rule, and a rule can only observe an event whose type Etch knows.
    //
    // PARSES: no parse diagnostic, and no E1901.
    var ok = try parseAndCheckDetch(gpa, "event Hit { damage: int = 0, critical: bool = false }");
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ok.parse_diags.len);
    try expectNoCode(ok.diagnostics.items, .construct_not_allowed_in_declaration_file);
    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.items.len);

    // The declaration reached the AST with its payload intact — a construct
    // admitted by the allow-list and then dropped would pass the assertions
    // above and be useless to G4.
    try std.testing.expectEqual(@as(usize, 1), ok.ast.event_decls.items.len);
    try std.testing.expectEqualStrings("Hit", ok.ast.strings.slice(ok.ast.event_decls.items[0].name));
    try std.testing.expectEqual(@as(u32, 2), ok.ast.event_decls.items[0].fields_len);

    // REGISTERS: `pass1Collect` put it in the symbol table. Observed through the
    // duplicate-symbol path rather than by reaching into `symbols`, which is
    // private — a second declaration of the same name is E0101, and that answer
    // is only reachable if the first one was recorded.
    var dup = try parseAndCheckDetch(gpa,
        \\event Hit { damage: int = 0 }
        \\event Hit { damage: int = 1 }
    );
    defer dup.deinit(gpa);
    try expectAnyCode(dup.diagnostics.items, .duplicate_symbol);

    // COUNTERFACTUAL ON THE OBJECT: a `component` in the same position is still
    // E1901. Without this, the amendment could have opened the whole ECS family
    // and every assertion above would still pass.
    var comp = try parseAndCheckDetch(gpa, "component Health { current: int = 100 }");
    defer comp.deinit(gpa);
    try expectAnyCode(comp.diagnostics.items, .construct_not_allowed_in_declaration_file);

    // And a `resource`, the other member of the pair §20.2 does not name and
    // §20.1 does not admit. Asserted separately: one construct standing for the
    // family would prove only that the family is not entirely open.
    var res = try parseAndCheckDetch(gpa, "resource Score { n: int = 0 }");
    defer res.deinit(gpa);
    try expectAnyCode(res.diagnostics.items, .construct_not_allowed_in_declaration_file);

    // An event carries FIELDS and no statement run — `ast.EventDecl` has no
    // `body_start` at all — so "a declaration file carries no bodies" holds by
    // the construct's shape and needs no E1900 arm. Pinned structurally so a
    // future body-bearing event form cannot land here unnoticed.
    comptime {
        for (@typeInfo(ast_mod.EventDecl).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "body_start") or std.mem.eql(u8, f.name, "body_len")) {
                @compileError("EventDecl gained a body: E1900 must grow an arm for it, and §20.1's admission of event_decl needs re-arguing");
            }
        }
    }

    // RESIDUAL, stated rather than implied: this establishes that the allow-list
    // no longer BLOCKS the event, not that a `.d.etch`-declared event is visible
    // to a user `.etch`. Cross-file visibility runs through the export index and
    // `imported_symbols`, which a `.d.etch` does not participate in (it is loaded
    // at compiler build, §20.5, never imported). Wiring that is G4's, and G4 is
    // where it gets a test.
}
