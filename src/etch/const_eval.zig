//! Folds a constant expression: numeric and boolean literals, and arithmetic,
//! comparison and logic over constants. The checker and the interpreter fold
//! through this one function, so a constant the checker admits is the constant
//! the interpreter stores.
//!
//! Integer arithmetic is checked in every build mode. The `ReleaseFast` wrap of
//! `etch-reference-part1.md` §12.4 applies to execution; a constant that
//! overflows is refused at compilation instead (`etch-resolver-types.md` §11).

const std = @import("std");
const ast_mod = @import("ast.zig");

const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;

/// A folded constant.
pub const Const = union(enum) {
    int_: i64,
    float_: f64,
    bool_: bool,
};

/// Why an expression does not fold.
pub const FoldError = error{
    /// Not a constant this folder evaluates: an identifier, a call, a string, a
    /// `.variant`, a cast, `??`, `!`.
    NotConstant,
    /// Operands of different kinds, which the checker reports as a type error.
    KindMismatch,
    /// An integer literal outside `int`, or a float literal that is not finite.
    LiteralOutOfRange,
    IntegerOverflow,
    DivisionByZero,
    /// A float result that is not finite.
    FloatOverflow,
} || std.mem.Allocator.Error;

/// The magnitude an integer literal's text denotes, or null past `u64`. The
/// lexer keeps `_` separators anywhere in the digit run.
pub fn intLiteralMagnitude(text: []const u8) ?u64 {
    var v: u64 = 0;
    for (text) |c| {
        if (c == '_') continue;
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, c - '0') catch return null;
    }
    return v;
}

/// The value an integer literal denotes, negated when `negated`, or null outside
/// `int`. `-9223372036854775808` is the one magnitude that fits only negated.
pub fn intLiteralValue(text: []const u8, negated: bool) ?i64 {
    const mag = intLiteralMagnitude(text) orelse return null;
    const min_mag: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    if (negated) {
        if (mag == min_mag) return std.math.minInt(i64);
        if (mag > std.math.maxInt(i64)) return null;
        return -@as(i64, @intCast(mag));
    }
    if (mag > std.math.maxInt(i64)) return null;
    return @intCast(mag);
}

/// The value a float literal's text denotes, or null when it is not finite.
pub fn floatLiteralValue(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?f64 {
    const v = if (std.mem.indexOfScalar(u8, text, '_') == null)
        std.fmt.parseFloat(f64, text) catch return null
    else blk: {
        const digits = try gpa.alloc(u8, text.len);
        defer gpa.free(digits);
        var n: usize = 0;
        for (text) |c| {
            if (c == '_') continue;
            digits[n] = c;
            n += 1;
        }
        break :blk std.fmt.parseFloat(f64, digits[0..n]) catch return null;
    };
    if (!std.math.isFinite(v)) return null;
    return v;
}

/// Folds the expression at `id`.
pub fn fold(gpa: std.mem.Allocator, ast: *const AstArena, id: NodeId) FoldError!Const {
    const data = ast.exprData(id);
    switch (ast.exprKind(id)) {
        .int_lit => return .{ .int_ = intLiteralValue(ast.strings.slice(data), false) orelse return error.LiteralOutOfRange },
        .float_lit => return .{ .float_ = (try floatLiteralValue(gpa, ast.strings.slice(data))) orelse return error.LiteralOutOfRange },
        .bool_lit => return .{ .bool_ = std.mem.eql(u8, ast.strings.slice(data), "true") },
        .unary => {
            const u = ast.unary_exprs.items[data];
            switch (u.op) {
                .neg => {
                    if (ast.exprKind(u.operand) == .int_lit) {
                        const text = ast.strings.slice(ast.exprData(u.operand));
                        return .{ .int_ = intLiteralValue(text, true) orelse return error.LiteralOutOfRange };
                    }
                    return switch (try fold(gpa, ast, u.operand)) {
                        .int_ => |x| .{ .int_ = std.math.negate(x) catch return error.IntegerOverflow },
                        .float_ => |x| .{ .float_ = -x },
                        .bool_ => error.KindMismatch,
                    };
                },
                .logical_not => return switch (try fold(gpa, ast, u.operand)) {
                    .bool_ => |x| .{ .bool_ = !x },
                    else => error.KindMismatch,
                },
                .force_unwrap => return error.NotConstant,
            }
        },
        .binary => {
            const b = ast.binary_exprs.items[data];
            if (b.op == .coalesce) return error.NotConstant;
            const lhs = try fold(gpa, ast, b.lhs);
            const rhs = try fold(gpa, ast, b.rhs);
            return binary(b.op, lhs, rhs);
        },
        else => return error.NotConstant,
    }
}

fn binary(op: ast_mod.BinaryOp, lhs: Const, rhs: Const) FoldError!Const {
    switch (lhs) {
        .int_ => |a| {
            if (rhs != .int_) return error.KindMismatch;
            const c = rhs.int_;
            return switch (op) {
                .add => .{ .int_ = std.math.add(i64, a, c) catch return error.IntegerOverflow },
                .sub => .{ .int_ = std.math.sub(i64, a, c) catch return error.IntegerOverflow },
                .mul => .{ .int_ = std.math.mul(i64, a, c) catch return error.IntegerOverflow },
                .div => .{ .int_ = std.math.divTrunc(i64, a, c) catch |e| return switch (e) {
                    error.DivisionByZero => error.DivisionByZero,
                    error.Overflow => error.IntegerOverflow,
                } },
                .rem => blk: {
                    if (c == 0) return error.DivisionByZero;
                    if (c == -1) break :blk .{ .int_ = 0 };
                    break :blk .{ .int_ = @rem(a, c) };
                },
                .eq => .{ .bool_ = a == c },
                .neq => .{ .bool_ = a != c },
                .lt => .{ .bool_ = a < c },
                .gt => .{ .bool_ = a > c },
                .le => .{ .bool_ = a <= c },
                .ge => .{ .bool_ = a >= c },
                .logical_and, .logical_or => error.KindMismatch,
                .coalesce => unreachable,
            };
        },
        .float_ => |a| {
            if (rhs != .float_) return error.KindMismatch;
            const c = rhs.float_;
            const r: f64 = switch (op) {
                .add => a + c,
                .sub => a - c,
                .mul => a * c,
                .div => a / c,
                .rem => @rem(a, c),
                .eq => return .{ .bool_ = a == c },
                .neq => return .{ .bool_ = a != c },
                .lt => return .{ .bool_ = a < c },
                .gt => return .{ .bool_ = a > c },
                .le => return .{ .bool_ = a <= c },
                .ge => return .{ .bool_ = a >= c },
                .logical_and, .logical_or => return error.KindMismatch,
                .coalesce => unreachable,
            };
            if (!std.math.isFinite(r)) return error.FloatOverflow;
            return .{ .float_ = r };
        },
        .bool_ => |a| {
            if (rhs != .bool_) return error.KindMismatch;
            const c = rhs.bool_;
            return switch (op) {
                .logical_and => .{ .bool_ = a and c },
                .logical_or => .{ .bool_ = a or c },
                .eq => .{ .bool_ = a == c },
                .neq => .{ .bool_ = a != c },
                else => error.KindMismatch,
            };
        },
    }
}

test "an integer literal's magnitude ignores its separators" {
    try std.testing.expectEqual(@as(?u64, 1000000), intLiteralMagnitude("1_000_000"));
    try std.testing.expectEqual(@as(?u64, 1), intLiteralMagnitude("1_"));
    try std.testing.expectEqual(@as(?u64, null), intLiteralMagnitude("18446744073709551616"));
}

test "the int range is asymmetric: the minimum fits only negated" {
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), intLiteralValue("9223372036854775807", false));
    try std.testing.expectEqual(@as(?i64, null), intLiteralValue("9223372036854775808", false));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), intLiteralValue("9223372036854775808", true));
    try std.testing.expectEqual(@as(?i64, null), intLiteralValue("9223372036854775809", true));
}

test "a float literal that is not finite has no value" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(@as(?f64, 1000.5), try floatLiteralValue(gpa, "1_000.5"));
    try std.testing.expectEqual(@as(?f64, 1.5), try floatLiteralValue(gpa, "1_.5_"));
    const huge = "1" ++ "0" ** 400 ++ ".0";
    try std.testing.expectEqual(@as(?f64, null), try floatLiteralValue(gpa, huge));
}
