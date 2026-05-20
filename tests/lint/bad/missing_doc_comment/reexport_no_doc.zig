const std = @import("std");

// Pure re-exports — previously exempted by `isPureReExport`, now
// rejected: the doc_comments rule treats every root-level `pub` the
// same regardless of the initialiser shape. All three must surface.
pub const ArrayList = std.ArrayList;
pub const mem = std.mem;
pub const child_module = @import("../../good/doc_pub_fn.zig");
