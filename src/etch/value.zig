//! Runtime `Value` representation for the Etch tree-walking interpreter.
//!
//! Stack-allocated tagged union covering the POD types reachable through the
//! language subset. The interpreter operates exclusively on these
//! primitives plus a couple of bridge tags (`entity_id`, `component_ref`,
//! `unit`). The type-checker rejects heap-typed fields on components, so no
//! heap promotion is required here.
//!
//! `RuntimeError` is its own type and not a `Diagnostic` variant.
//! Compile-time diagnostics live in `etch/diagnostics.zig`.

const std = @import("std");
const builtin = @import("builtin");
const token = @import("token.zig");

const SourceSpan = token.SourceSpan;

/// Strongly typed entity handle. Mirrors `core/ecs/components.zig`'s
/// `EntityId` (u64) but adds a sentinel for "absent" used by the bridge.
pub const EntityId = u64;
/// Sentinel `EntityId` reserved for "absent" — used by the Etch
/// bridge to distinguish a missing handle from any valid entity.
pub const invalid_entity: EntityId = std.math.maxInt(EntityId);

/// A handle onto one entity's component bytes.
///
/// **A ref designates an `(entity, component)` PAIR, never a memory location**
/// (`etch-reference-part1.md` §5.3 a): it is re-resolved at EVERY access through
/// `World.componentBytes`, so no migration, compaction or swap-remove can make
/// it designate another entity's bytes. **`@storage` therefore has no semantic
/// effect**, which is the property this shape holds.
///
/// **Liveness and carriage are checked at each dereference**, not only at the
/// `get`/`get_mut` that produced the handle (§5.3 c), in every build mode; a
/// stale one answers `BridgeError.StaleComponentRef`.
///
/// **A ref held beyond its rule body is therefore safe** (§5.3 corollary): a
/// scope snapshot copies a `Value` VERBATIM and `AsyncTask.locals` retains it
/// across a suspension, so the handle outlives the tick BY CONSTRUCTION and its
/// safety cannot rest on the deferral of structural ops.
///
/// Rule-arena handles — a runtime-produced string, array, map or set — have the
/// opposite lifetime: their store is reset at the body boundary, so the resolver
/// refuses their capture with `E0223`.
///
/// `mutable = false` for `get(T)`, `true` for `get_mut(T)`.
pub const ComponentRef = struct {
    /// The Etch wire form; `@bitCast` to the core packed handle at use.
    entity: EntityId,
    component_id: u32,
    mutable: bool,
};

/// A handle to a resource's backing bytes in the world `ResourceStore`.
/// The interpreter resolves receiver-less `get(T)` / `get_mut(T)` into one
/// of these. `mutable = false` for `get(T)`, `true`
/// for `get_mut(T)`. Unlike `ComponentRef` there is no chunk / slot — a
/// resource is a world singleton keyed by `resource_id`.
pub const ResourceRef = struct {
    resource_id: u32,
    mutable: bool,
};

/// A `start..end` / `start..=end` range value.
/// Integer bounds; `for-in` iterates `[start, end)` (exclusive) or
/// `[start, end]` (inclusive).
pub const RangeVal = struct {
    start: i64,
    end: i64,
    inclusive: bool,
};

/// Runtime tag for the primitive value set. Mirrors `BuiltinType` in
/// `src/etch/types.zig` but only carries the values the interpreter touches.
pub const Value = union(enum) {
    int_: i64,
    float_: f64,
    bool_: bool,
    string_id: u32,
    /// Handle into the interpreter's per-rule-body runtime-string store. A string
    /// PRODUCED at runtime (concat — and, 1c, interpolation) cannot be a `string_id`
    /// (the AST string table is immutable input), so it lives as owned bytes in
    /// `Interpreter.run_strings`, reset at the rule-body boundary (rule-arena
    /// semantics, `etch-memory-model.md` §2). Same lifetime rules as `array_ref`.
    string_run: u32,
    entity_id: EntityId,
    component_ref: ComponentRef,
    resource_ref: ResourceRef,
    range: RangeVal,
    /// Handle into the interpreter's per-rule-body collection store.
    /// Arrays / maps / sets are heap-managed and cannot live
    /// inline in this stack union, so a runtime collection value is a `u32`
    /// index resolved against `Interpreter.collections`. Invalidated at the
    /// rule-body boundary (rule-arena semantics).
    array_ref: u32,
    /// Handle into the interpreter's per-rule-body map store. Same
    /// lifetime rules as `array_ref`.
    map_ref: u32,
    /// Handle into the interpreter's per-rule-body set store. Same
    /// lifetime rules as `array_ref`.
    set_ref: u32,
    /// Handle into the interpreter's per-rule-body closure store. Same
    /// lifetime rules as `array_ref`.
    closure: u32,
    /// Handle into the interpreter's per-rule-body struct store. A struct
    /// value is a by-value aggregate; the handle resolves against
    /// `Interpreter.structs`. Same lifetime rules as `array_ref` (reset at the
    /// rule-body boundary).
    struct_ref: u32,
    /// Handle into the interpreter's per-rule-body optional store. An
    /// `Optional<T>` value resolves against `Interpreter.optionals` to a
    /// `?Value` (`null` = `none`, else the `some` payload). Same lifetime rules
    /// as `array_ref` (reset at the rule-body boundary).
    optional: u32,
    /// A C-like enum value. Carries the enum type
    /// name (interned `StringId`) and the variant's declaration-order index.
    /// Value-typed: compared by `(type_name, variant)` equality.
    enum_value: EnumValue,
    /// A view over a resource `string` field's persistent-heap bytes. The read takes
    /// no reference; every holder that keeps the value counts one
    /// (`etch-memory-model.md` §4.4). Self-contained `{ptr,len}` so
    /// `readBytesAsValue` can build it with no allocator and no interpreter store;
    /// `ptr == 0` ⇔ the empty string. Additive — does not disturb `string_id` (AST
    /// pool) / `string_run` (rule-arena) semantics.
    string_persistent: StrView,
    /// A view over string bytes owned outside the persistent heap: an event
    /// store copy, a captured event filter value, a world extension name. It
    /// has no block header, so it is never incref'd or decref'd. `ptr == 0` ⇔
    /// the empty string.
    string_view: StrView,
    /// A borrowed view over a resource `T[]` field's persistent-heap container
    /// block. The `u64` is the block's exposed payload pointer (a
    /// `persistent` `type_array` block whose payload is the owned
    /// `ArrayListUnmanaged(Value)`). Mirrors `.string_persistent`'s persistent-vs-
    /// rule-arena split against `.array_ref`: the zone is known at the tag, no
    /// runtime discriminant, drop dispatched by `type_id`. Counted like
    /// `.string_persistent`. Never `0` for a live field (the empty collection is a
    /// real empty block allocated with the resource's store buffer). String
    /// elements are stored as owned `.string_persistent`; POD elements inline.
    array_persistent: u64,
    /// A borrowed view over a resource `[K: V]` field's persistent-heap block,
    /// whose payload is the owned insertion-ordered pair list. Same borrowing and
    /// storage rules as `array_persistent`; never `0` for a live field.
    map_persistent: u64,
    /// A borrowed view over a resource `Set<T>` field's persistent-heap block,
    /// whose payload is the owned insertion-ordered unique-element list — the
    /// same `ArrayListUnmanaged(Value)` shape as `array_persistent`, sharing its
    /// drop and its borrowing rules. Never `0` for a live field.
    set_persistent: u64,
    /// A `TaskHandle` (`etch-grammar.md` §2.2): the pool index of
    /// a spawned task in `Interpreter.async_tasks`. Safe as a bare index —
    /// the pool is MONOTONIC (no slot reuse; a finished task parks as a husk),
    /// so no generation is needed. Copyable/storable as a value;
    /// its operations are `h.cancel()` (idempotent) and `await h` (§9.8).
    task_handle: u32,
    /// A `TimerHandle` (`etch-grammar.md` §2.2): the registry
    /// index of a scheduled timer in `Interpreter.timers`. Safe as a bare
    /// index — the registry is MONOTONIC (no slot reuse; a fired one-shot or
    /// a canceled timer parks as a husk). Copyable/storable as a value; its
    /// ONLY operation is `t.cancel()` (idempotent, §9.10) — a timer is not a
    /// task and is not awaitable.
    timer_handle: u32,
    /// A `Duration` in seconds: the runtime shape of a
    /// `DURATION_LIT` (`1.5s`), carried so a timer argument can be a full
    /// expression (`after(d)` with `d` a Duration local). Duration
    /// arithmetic is not supported.
    duration: f64,
    /// The current test's World handle: returned by `test_world()`,
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
    /// path the interpreter must reject.
    pub fn eql(self: Value, other: Value) bool {
        if (byteView(self)) |a| if (byteView(other)) |b| return viewEql(a, b);
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .int_ => |a| a == other.int_,
            .float_ => |a| a == other.float_,
            .bool_ => |a| a == other.bool_,
            .string_id => |a| a == other.string_id,
            .string_run => false, // string equality is not in the minimal subset
            .entity_id => |a| a == other.entity_id,
            .component_ref => false,
            .resource_ref => false,
            .range => false,
            .array_ref => false,
            .array_persistent => false, // collection equality is not an Etch v0.6 op (as with array_ref)
            .map_persistent => false, // as with map_ref
            .map_ref => false,
            .set_ref => false, // set equality is not in the minimal subset
            .set_persistent => false, // as with set_ref
            .closure => false,
            .struct_ref => false,
            .optional => false, // optional equality is unexercised (unwrap via if/while let)
            .enum_value => |a| a.type_name == other.enum_value.type_name and a.variant == other.enum_value.variant,
            .string_persistent, .string_view => unreachable,
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

/// Payload of a C-like enum `Value`.
pub const EnumValue = struct {
    type_name: u32,
    variant: u32,
};

/// Borrowed view over persistent-heap string bytes. `ptr` is the
/// raw address of the bytes (`0` for the empty string); `len` the byte count.
pub const StrView = struct {
    ptr: u64 = 0,
    len: u32 = 0,
};

/// The view of a string held outside the AST and the rule arena, whichever
/// memory owns it; null for any other value.
fn byteView(v: Value) ?StrView {
    return switch (v) {
        .string_persistent, .string_view => |s| s,
        else => null,
    };
}

fn viewEql(a: StrView, b: StrView) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    const ab: [*]const u8 = @ptrFromInt(a.ptr);
    const bb: [*]const u8 = @ptrFromInt(b.ptr);
    return std.mem.eql(u8, ab[0..a.len], bb[0..b.len]);
}

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
    /// Bridge-level type incoherence — the typed-report home of
    /// `BridgeError.TypeMismatch`: the bridge returns the error, the report
    /// carries the kind.
    TypeMismatch,
    /// An Etch `throw` that reached the rule top level uncaught. The
    /// span covers the thrown value expression.
    UncaughtThrow,
    /// A failed `assert(...)` / assertion-family builtin. The span
    /// covers the failing condition; the message (compared values, custom
    /// reason) travels alongside via the interpreter's `pending_message`.
    AssertFailed,
    /// A component ref dereferenced after its entity died or lost the component.
    /// Its own kind rather than `UnsupportedExpr`, because §5.3 c requires a
    /// CLEAR message: the expression is supported and the handle is not.
    StaleComponentRef,
};

/// Whether integer overflow wraps rather than panics: `ReleaseFast` and
/// `ReleaseSmall`, the modes without runtime safety, wrap; `Debug` and
/// `ReleaseSafe` panic (`etch-reference-part1.md` §12.4). An integer division by
/// zero panics in every mode.
pub const overflow_wraps = switch (builtin.mode) {
    .Debug, .ReleaseSafe => false,
    .ReleaseFast, .ReleaseSmall => true,
};

/// Integer division. `null` on a zero divisor, and on `i64.min / -1` where
/// overflow panics; that quotient wraps to `i64.min` otherwise.
pub fn intDiv(lhs: i64, rhs: i64) ?i64 {
    if (rhs == 0) return null;
    if (lhs == std.math.minInt(i64) and rhs == -1) return if (overflow_wraps) lhs else null;
    return @divTrunc(lhs, rhs);
}

/// Integer remainder. `null` on a zero divisor; `i64.min % -1` is 0.
pub fn intRem(lhs: i64, rhs: i64) ?i64 {
    if (rhs == 0) return null;
    if (rhs == -1) return 0;
    return @rem(lhs, rhs);
}

/// Integer addition; `null` on overflow where overflow panics.
pub fn intAdd(lhs: i64, rhs: i64) ?i64 {
    if (overflow_wraps) return lhs +% rhs;
    return std.math.add(i64, lhs, rhs) catch null;
}

/// Integer subtraction; `null` on overflow where overflow panics.
pub fn intSub(lhs: i64, rhs: i64) ?i64 {
    if (overflow_wraps) return lhs -% rhs;
    return std.math.sub(i64, lhs, rhs) catch null;
}

/// Integer multiplication; `null` on overflow where overflow panics.
pub fn intMul(lhs: i64, rhs: i64) ?i64 {
    if (overflow_wraps) return lhs *% rhs;
    return std.math.mul(i64, lhs, rhs) catch null;
}

/// Integer negation; `null` on `-i64.min` where overflow panics.
pub fn intNeg(x: i64) ?i64 {
    if (overflow_wraps) return 0 -% x;
    return std.math.negate(x) catch null;
}

/// `x` truncated toward zero, when that integer fits `T`; `null` otherwise, NaN
/// and the infinities included. A float has no wrap to fall back on, so this
/// refuses in every mode.
pub fn floatTrunc(comptime T: type, x: f64) ?i64 {
    if (!std.math.isFinite(x)) return null;
    const t = @trunc(x);
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(@as(i128, std.math.maxInt(T)) + 1);
    if (t < lo or t >= hi) return null;
    return @intFromFloat(t);
}

/// `x` narrowed to the integer type `T`, held as an `i64`: `null` when it does
/// not fit and overflow panics, the two's-complement truncation otherwise
/// (`etch-grammar.md` §2.6).
pub fn intNarrow(comptime T: type, x: i64) ?i64 {
    if (std.math.cast(T, x)) |n| return n;
    if (!overflow_wraps) return null;
    const bits: std.meta.Int(.unsigned, @bitSizeOf(T)) = @truncate(@as(u64, @bitCast(x)));
    return @as(T, @bitCast(bits));
}

test "Value arithmetic int + int yields int" {
    const a = Value.fromInt(2);
    const b = Value.fromInt(3);
    try std.testing.expectEqual(@as(i64, 5), a.int_ + b.int_);
}

test "Value arithmetic int + float forbidden (no implicit coercion)" {
    // The type-checker rejects this and the interpreter never sees it; what is
    // asserted is that a tag mismatch fails `eql`, making the contract explicit
    // at runtime too.
    const a = Value.fromInt(2);
    const b = Value.fromFloat(2.0);
    try std.testing.expect(!a.eql(b));
}

test "DivisionByZero on float yields NaN/Inf per IEEE 754" {
    const inf = @as(f64, 1.0) / @as(f64, 0.0);
    try std.testing.expect(std.math.isInf(inf));
    const nan = @as(f64, 0.0) / @as(f64, 0.0);
    try std.testing.expect(std.math.isNan(nan));
}

test "integer overflow panics where the mode has runtime safety and wraps where it does not" {
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    if (overflow_wraps) {
        try std.testing.expectEqual(@as(?i64, min), intAdd(max, 1));
        try std.testing.expectEqual(@as(?i64, max), intSub(min, 1));
        try std.testing.expectEqual(@as(?i64, -2), intMul(max, 2));
        try std.testing.expectEqual(@as(?i64, min), intNeg(min));
        try std.testing.expectEqual(@as(?i64, min), intDiv(min, -1));
        try std.testing.expectEqual(@as(?i64, -2147483648), intNarrow(i32, 2147483648));
        try std.testing.expectEqual(@as(?i64, 4294967295), intNarrow(u32, -1));
    } else {
        try std.testing.expectEqual(@as(?i64, null), intAdd(max, 1));
        try std.testing.expectEqual(@as(?i64, null), intSub(min, 1));
        try std.testing.expectEqual(@as(?i64, null), intMul(max, 2));
        try std.testing.expectEqual(@as(?i64, null), intNeg(min));
        try std.testing.expectEqual(@as(?i64, null), intDiv(min, -1));
        try std.testing.expectEqual(@as(?i64, null), intNarrow(i32, 2147483648));
        try std.testing.expectEqual(@as(?i64, null), intNarrow(u32, -1));
    }
}

test "integer division by zero is refused in every mode" {
    try std.testing.expectEqual(@as(?i64, null), intDiv(1, 0));
    try std.testing.expectEqual(@as(?i64, null), intRem(1, 0));
    try std.testing.expectEqual(@as(?i64, 0), intRem(std.math.minInt(i64), -1));
}

test "a float converts to an integer only when its truncation fits" {
    try std.testing.expectEqual(@as(?i64, -3), floatTrunc(i64, -3.9));
    try std.testing.expectEqual(@as(?i64, 2147483647), floatTrunc(i32, 2147483647.5));
    try std.testing.expectEqual(@as(?i64, null), floatTrunc(i32, 2147483648.0));
    try std.testing.expectEqual(@as(?i64, null), floatTrunc(u32, -1.0));
    try std.testing.expectEqual(@as(?i64, null), floatTrunc(i64, 9223372036854775808.0));
    try std.testing.expectEqual(@as(?i64, null), floatTrunc(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(?i64, null), floatTrunc(i64, std.math.inf(f64)));
}

test "a value that fits is narrowed unchanged" {
    try std.testing.expectEqual(@as(?i64, -5), intNarrow(i32, -5));
    try std.testing.expectEqual(@as(?i64, 4294967295), intNarrow(u32, 4294967295));
}

test "comparison between incompatible Values is a compile-time impossibility (asserts)" {
    // The type-checker is the gate; at runtime a tag mismatch is `false`.
    const a = Value.fromInt(1);
    const b = Value.fromBool(true);
    try std.testing.expect(!a.eql(b));
}

test "compound assignment +=, -=, *=, /=, %= behave per spec" {
    // The interpreter de-sugars these into "load + op + store" before this
    // module is involved; what is checked here are the underlying helpers.
    try std.testing.expectEqual(@as(?i64, 7), intAdd(5, 2));
    try std.testing.expectEqual(@as(?i64, 3), intSub(5, 2));
    try std.testing.expectEqual(@as(?i64, 10), intMul(5, 2));
    try std.testing.expectEqual(@as(?i64, 2), intDiv(5, 2));
    try std.testing.expectEqual(@as(?i64, 1), intRem(5, 2));
}
