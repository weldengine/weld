//! Fixture — the three shapes rule `no_float_reduce` must leave alone: an
//! order-free boolean reduction, an integer reduction that declares its lanes,
//! and prose naming the builtin.

/// Whether every lane of `a` is at most the matching lane of `b`. `.And` is
/// boolean and order-free, so it is never a determinism question.
pub fn allAtMost(a: @Vector(3, f32), b: @Vector(3, f32)) bool {
    return @reduce(.And, a <= b);
}

/// Sum of integer lanes. Integer addition is associative and exact, so the
/// backend's reduction order cannot change the result — the site declares it.
pub fn integerSum(v: @Vector(4, u32)) u32 {
    // WELD_INTEGER_LANES: `u32` lanes, exact under any summation order.
    return @reduce(.Add, v);
}

/// Never write `@reduce(.Add, v)` on a float path — this doc comment names the
/// builtin and must not be read as a site, the rule being written on tokens.
pub fn documented() void {}
