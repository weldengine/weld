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

/// Runtime tag for the S3 primitive value set. Mirrors `BuiltinType` in
/// `src/etch/types.zig` but only carries the values the interpreter touches.
pub const Value = union(enum) {
    int_: i64,
    float_: f64,
    bool_: bool,
    string_id: u32,
    entity_id: EntityId,
    component_ref: ComponentRef,
    resource_ref: ResourceRef,
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
            .entity_id => |a| a == other.entity_id,
            .component_ref => false,
            .resource_ref => false,
            .unit => true,
        };
    }
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
