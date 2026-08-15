//! Fixture — the two remaining flagged operations, and a marker placed TWO lines
//! above its statement, which is out of reach and must not exempt anything.

/// Product of the lanes.
pub fn product(v: @Vector(3, f32)) f32 {
    return @reduce(.Mul, v);
}

/// Smallest lane. The marker below is too far to grant the exemption.
pub fn smallest(v: @Vector(3, f32)) f32 {
    // WELD_INTEGER_LANES

    return @reduce(.Min, v);
}
