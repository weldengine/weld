//! S4 runtime `Value` representation for the Etch tree-walking interpreter.
//!
//! Stack-allocated tagged union covering the POD types reachable through the
//! S3 subset (`briefs/S4-etch-tree-walking-interpreter.md` Scope — Runtime
//! Value representation). The interpreter operates exclusively on these
//! primitives plus a couple of bridge tags (`entity_id`, `component_ref`,
//! `unit`). The S3 type-checker rejects heap-typed fields on components, so
//! no heap promotion is required at S4.
//!
//! `RuntimeError` is its own type (cf. brief Notes — "Why `RuntimeError` is
//! its own type and not a `Diagnostic` variant"). Compile-time diagnostics
//! live in `etch/diagnostics.zig`.

const std = @import("std");
const token = @import("token.zig");

const SourceSpan = token.SourceSpan;

/// Strongly typed entity handle. Mirrors `core/ecs/components.zig`'s
/// `EntityId` (u64) but adds a sentinel for "absent" used by the bridge.
pub const EntityId = u64;
/// Sentinel `EntityId` reserved for "absent" — used by the Etch
/// bridge to distinguish a missing handle from any valid entity.
pub const invalid_entity: EntityId = std.math.maxInt(EntityId);

/// A handle into a component slot inside a dynamic archetype chunk. The
/// interpreter resolves `entity.get(T)` / `entity.get_mut(T)` into one of
/// these, which the bridge dereferences when the rule body reads or writes
/// a field. `mutable = false` for `get(T)`, `true` for `get_mut(T)`.
pub const ComponentRef = struct {
    component_id: u32,
    chunk_ptr: *anyopaque,
    slot: u32,
    mutable: bool,
};

/// A handle to a resource's backing bytes in the world `ResourceStore`.
/// The interpreter resolves receiver-less `get(T)` / `get_mut(T)` into one
/// of these (D-S3-resource-receiver). `mutable = false` for `get(T)`, `true`
/// for `get_mut(T)`. Unlike `ComponentRef` there is no chunk / slot — a
/// resource is a world singleton keyed by `resource_id`.
pub const ResourceRef = struct {
    resource_id: u32,
    mutable: bool,
};

/// A `start..end` / `start..=end` range value (M0.8 v0.6 foundations).
/// Integer bounds; `for-in` iterates `[start, end)` (exclusive) or
/// `[start, end]` (inclusive).
pub const RangeVal = struct {
    start: i64,
    end: i64,
    inclusive: bool,
};

/// Runtime tag for the S3 primitive value set. Mirrors `BuiltinType` in
/// `src/etch/types.zig` but only carries the values the interpreter touches.
pub const Value = union(enum) {
    int_: i64,
    float_: f64,
    bool_: bool,
    string_id: u32,
    /// Handle into the interpreter's per-rule-body runtime-string store (M0.8
    /// sub-slice C tranche 1b). A string PRODUCED at runtime (concat — and,
    /// 1c, interpolation) cannot be a `string_id` (the AST string table is
    /// immutable input), so it lives as owned bytes in `Interpreter
    /// .run_strings`, reset at the rule-body boundary (rule-arena semantics,
    /// `etch-memory-model.md` §2). Same lifetime rules as `array_ref`.
    string_run: u32,
    entity_id: EntityId,
    component_ref: ComponentRef,
    resource_ref: ResourceRef,
    range: RangeVal,
    /// Handle into the interpreter's per-rule-body collection store (M0.8
    /// collections). Arrays / maps / sets are heap-managed and cannot live
    /// inline in this stack union, so a runtime collection value is a `u32`
    /// index resolved against `Interpreter.collections`. Invalidated at the
    /// rule-body boundary (rule-arena semantics).
    array_ref: u32,
    /// Handle into the interpreter's per-rule-body map store (M0.8
    /// collections). Same lifetime rules as `array_ref`.
    map_ref: u32,
    /// Handle into the interpreter's per-rule-body set store (M0.8 E3-C
    /// tranche 3bis). Same lifetime rules as `array_ref`.
    set_ref: u32,
    /// Handle into the interpreter's per-rule-body closure store (M0.8
    /// closures). Same lifetime rules as `array_ref`.
    closure: u32,
    /// Handle into the interpreter's per-rule-body struct store (M0.8 E2 block
    /// 3). A struct value is a by-value aggregate; the handle resolves against
    /// `Interpreter.structs`. Same lifetime rules as `array_ref` (reset at the
    /// rule-body boundary).
    struct_ref: u32,
    /// Handle into the interpreter's per-rule-body optional store (M0.8 E2 block
    /// 5). An `Optional<T>` value resolves against `Interpreter.optionals` to a
    /// `?Value` (`null` = `none`, else the `some` payload). Same lifetime rules
    /// as `array_ref` (reset at the rule-body boundary).
    optional: u32,
    /// A C-like enum value (M0.8 E2 block 3 tranche B). Carries the enum type
    /// name (interned `StringId`) and the variant's declaration-order index.
    /// Value-typed: compared by `(type_name, variant)` equality.
    enum_value: EnumValue,
    /// A borrowed view over a resource `string` field's persistent-heap bytes
    /// (M1.0.3 E2). The read path returns this without incref'ing the block —
    /// safe for the rule body because the resource (hence the bytes) outlives it
    /// (`etch-memory-model.md` §11 Phase 1; scope-bound incref is Phase 2). Self-
    /// contained `{ptr,len}` so `readBytesAsValue` can build it with no allocator
    /// and no interpreter store; `ptr == 0` ⇔ the empty string. Additive — does
    /// not disturb `string_id` (AST pool) / `string_run` (rule-arena) semantics.
    string_persistent: StrView,
    /// A borrowed view over a resource `T[]` field's persistent-heap container
    /// block (M1.0.17 E2). The `u64` is the block's exposed payload pointer (a
    /// `persistent` `type_array` block whose payload is the owned
    /// `ArrayListUnmanaged(Value)`). Mirrors `.string_persistent`'s persistent-vs-
    /// rule-arena split against `.array_ref`: the zone is known at the tag, no
    /// runtime discriminant, drop dispatched by `type_id`. The read path returns
    /// it without incref — safe for the rule body because the resource (hence the
    /// block) outlives it. Never `0` for a live field (the empty collection is a
    /// real empty block allocated at `addResource`). String elements are stored
    /// as owned `.string_persistent`; POD elements inline.
    array_persistent: u64,
    /// A borrowed view over a resource `[K: V]` field's persistent-heap container
    /// block (M1.0.17 E3). The `u64` is a `persistent` `type_map` block whose
    /// payload is the owned insertion-ordered pair list. Same persistent-vs-rule-
    /// arena split as `.map_ref`; the read path borrows it without incref (the
    /// resource outlives the body). String keys and values are stored as owned
    /// `.string_persistent`, POD inline. Never `0` for a live field.
    map_persistent: u64,
    /// A `TaskHandle` (M1.0.12 E5, `etch-grammar.md` §2.2): the pool index of
    /// a spawned task in `Interpreter.async_tasks`. Safe as a bare index —
    /// the pool is MONOTONIC (no slot reuse; a finished task parks as a husk),
    /// so no generation is needed in Phase 1. Copyable/storable as a value;
    /// its operations are `h.cancel()` (idempotent) and `await h` (§9.8).
    task_handle: u32,
    /// A `TimerHandle` (M1.0.13 E6, `etch-grammar.md` §2.2): the registry
    /// index of a scheduled timer in `Interpreter.timers`. Safe as a bare
    /// index — the registry is MONOTONIC (no slot reuse; a fired one-shot or
    /// a canceled timer parks as a husk). Copyable/storable as a value; its
    /// ONLY operation is `t.cancel()` (idempotent, §9.10) — a timer is not a
    /// task and is not awaitable.
    timer_handle: u32,
    /// A `Duration` in seconds (M1.0.13 E6): the runtime shape of a
    /// `DURATION_LIT` (`1.5s`), carried so a timer argument can be a full
    /// expression (`after(d)` with `d` a Duration local). Duration
    /// arithmetic stays out of the M1.0.13 surface.
    duration: f64,
    /// The current test's World handle (M1.0.15): returned by `test_world()`,
    /// receiver of `spawn_with`/`emit`/`tick`. v0.6 is MONO-WORLD — the payload
    /// is a marker (`void`); the interpreter operates on the `world` already
    /// threaded through `execStmt`, so repeated `test_world()` calls denote the
    /// same world. Not field-storable, not comparable in Etch.
    world_handle,
    unit,

    pub fn fromInt(x: i64) Value {
        return .{ .int_ = x };
    }

    pub fn fromFloat(x: f64) Value {
        return .{ .float_ = x };
    }

    pub fn fromBool(x: bool) Value {
        return .{ .bool_ = x };
    }

    pub fn fromEntity(id: EntityId) Value {
        return .{ .entity_id = id };
    }

    /// Equality between two `Value`s of compatible tag. Returns `false`
    /// when the active tags differ — Etch comparisons across types are
    /// rejected at type-check time, so a runtime tag mismatch indicates a
    /// bug or a value reaching the interpreter through an `unsupported`
    /// path that S4 must reject.
    pub fn eql(self: Value, other: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .int_ => |a| a == other.int_,
            .float_ => |a| a == other.float_,
            .bool_ => |a| a == other.bool_,
            .string_id => |a| a == other.string_id,
            .string_run => false, // string equality is not in the M0.8 minimal subset (Eq/Ord deferred)
            .entity_id => |a| a == other.entity_id,
            .component_ref => false,
            .resource_ref => false,
            .range => false,
            .array_ref => false,
            .array_persistent => false, // collection equality is not an Etch v0.6 op (as with array_ref)
            .map_persistent => false, // as with map_ref
            .map_ref => false,
            .set_ref => false, // set equality is not in the M0.8 minimal subset
            .closure => false,
            .struct_ref => false,
            .optional => false, // optional equality is not exercised in M0.8 (unwrap via if/while let)
            .enum_value => |a| a.type_name == other.enum_value.type_name and a.variant == other.enum_value.variant,
            .string_persistent => |a| blk: {
                const b = other.string_persistent;
                if (a.len != b.len) break :blk false;
                if (a.len == 0) break :blk true;
                const ab: [*]const u8 = @ptrFromInt(a.ptr);
                const bb: [*]const u8 = @ptrFromInt(b.ptr);
                break :blk std.mem.eql(u8, ab[0..a.len], bb[0..b.len]);
            },
            // Handle equality is not an Etch v0.6 operation (no `==` on
            // TaskHandle/TimerHandle); identity comparison is reserved for a
            // later spec.
            .task_handle => false,
            .timer_handle => false,
            .duration => |a| a == other.duration,
            // Mono-world: the sole world handle is equal to itself; `==` on world
            // handles is not an Etch v0.6 operation regardless.
            .world_handle => true,
            .unit => true,
        };
    }
};

/// Payload of a C-like enum `Value` (M0.8 E2 block 3 tranche B).
pub const EnumValue = struct {
    type_name: u32,
    variant: u32,
};

/// Borrowed view over persistent-heap string bytes (M1.0.3 E2). `ptr` is the
/// raw address of the bytes (`0` for the empty string); `len` the byte count.
pub const StrView = struct {
    ptr: u64 = 0,
    len: u32 = 0,
};

/// Typed sum carrying a `SourceSpan` resolved from the AST `NodeId` that
/// triggered the failure. The interpreter never silently masks runtime
/// errors — it reports them through this type plus the `RuntimeReport`
/// counter (cf. `interp.zig`).
pub const RuntimeError = struct {
    kind: RuntimeErrorKind,
    span: SourceSpan,
};

/// Closed enum of runtime failure causes surfaced by the interpreter.
pub const RuntimeErrorKind = enum {
    DivisionByZero,
    IntegerOverflow,
    UnsupportedExpr,
    /// Bridge-level type incoherence (M0.8 E3-D, D-S4-runtime-report —
    /// the typed-report home of `BridgeError.TypeMismatch`, closing the
    /// D-S4-ecs-bridge-panic letter: the bridge returns the error, the
    /// report carries the kind).
    TypeMismatch,
    /// An Etch `throw` that reached the rule top level uncaught (M0.8
    /// E3-D). The span covers the thrown value expression.
    UncaughtThrow,
    /// A failed `assert(...)` / assertion-family builtin (M1.0.15). The span
    /// covers the failing condition; the message (compared values, custom
    /// reason) travels alongside via the interpreter's `pending_message`.
    AssertFailed,
};

// ─── Arithmetic helpers ──────────────────────────────────────────────────

/// Integer division with division-by-zero check. Returns `null` on divide
/// by zero — the caller turns the error into a `RuntimeError`.
pub fn intDiv(lhs: i64, rhs: i64) ?i64 {
    if (rhs == 0) return null;
    // `i64.min / -1` overflows; let the caller surface as IntegerOverflow.
    if (lhs == std.math.minInt(i64) and rhs == -1) return null;
    return @divTrunc(lhs, rhs);
}

/// Integer remainder with division-by-zero and `i64.min % -1`
/// guards. Returns `null` on divide-by-zero; the caller turns the
/// `null` into a `RuntimeError`.
pub fn intRem(lhs: i64, rhs: i64) ?i64 {
    if (rhs == 0) return null;
    if (lhs == std.math.minInt(i64) and rhs == -1) return 0;
    return @rem(lhs, rhs);
}

/// Wrapping-checked integer addition — returns `null` on overflow so
/// the interpreter can surface `IntegerOverflow` cleanly.
pub fn intAddChecked(lhs: i64, rhs: i64) ?i64 {
    return std.math.add(i64, lhs, rhs) catch null;
}

/// Wrapping-checked integer subtraction — returns `null` on overflow.
pub fn intSubChecked(lhs: i64, rhs: i64) ?i64 {
    return std.math.sub(i64, lhs, rhs) catch null;
}

/// Wrapping-checked integer multiplication — returns `null` on overflow.
pub fn intMulChecked(lhs: i64, rhs: i64) ?i64 {
    return std.math.mul(i64, lhs, rhs) catch null;
}

// ─── tests ────────────────────────────────────────────────────────────────

test "Value arithmetic int + int yields int" {
    const a = Value.fromInt(2);
    const b = Value.fromInt(3);
    try std.testing.expectEqual(@as(i64, 5), a.int_ + b.int_);
}

test "Value arithmetic int + float forbidden (no implicit coercion)" {
    // The S3 type-checker rejects this; the interpreter never sees the
    // expression. We assert that tag mismatch fails `Value.eql` so that
    // the contract is explicit at runtime.
    const a = Value.fromInt(2);
    const b = Value.fromFloat(2.0);
    try std.testing.expect(!a.eql(b));
}

test "DivisionByZero on int" {
    try std.testing.expectEqual(@as(?i64, null), intDiv(10, 0));
}

test "DivisionByZero on float yields NaN/Inf per IEEE 754" {
    const inf = @as(f64, 1.0) / @as(f64, 0.0);
    try std.testing.expect(std.math.isInf(inf));
    const nan = @as(f64, 0.0) / @as(f64, 0.0);
    try std.testing.expect(std.math.isNan(nan));
}

test "IntegerOverflow detected in ReleaseSafe" {
    try std.testing.expectEqual(@as(?i64, null), intAddChecked(std.math.maxInt(i64), 1));
    try std.testing.expectEqual(@as(?i64, null), intMulChecked(std.math.maxInt(i64), 2));
    try std.testing.expectEqual(@as(?i64, null), intDiv(std.math.minInt(i64), -1));
}

test "comparison between incompatible Values is a compile-time impossibility (asserts)" {
    // The type-checker is the gate. At runtime, comparing values of
    // different tags returns `false` — the test documents the contract.
    const a = Value.fromInt(1);
    const b = Value.fromBool(true);
    try std.testing.expect(!a.eql(b));
}

test "compound assignment +=, -=, *=, /=, %= behave per spec" {
    // Compound ops are de-sugared by the interpreter into "load + op + store"
    // before this module is involved. The test confirms the underlying
    // helpers behave correctly.
    try std.testing.expectEqual(@as(?i64, 7), intAddChecked(5, 2));
    try std.testing.expectEqual(@as(?i64, 3), intSubChecked(5, 2));
    try std.testing.expectEqual(@as(?i64, 10), intMulChecked(5, 2));
    try std.testing.expectEqual(@as(?i64, 2), intDiv(5, 2));
    try std.testing.expectEqual(@as(?i64, 1), intRem(5, 2));
}
