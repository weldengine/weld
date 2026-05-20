const std = @import("std");

/// @import("..._c") inside a function body — also forbidden without
/// the AUTO-GENERATED header.
pub fn load() type {
    return @import("opus_c");
}
