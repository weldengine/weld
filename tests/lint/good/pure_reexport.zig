const std = @import("std");

// Pure re-export — exempt from doc_comments per the brief's *Notes*
// ("type aliases" false-positive class). No `///` needed.
pub const ArrayList = std.ArrayList;
pub const mem = std.mem;
pub const child_module = @import("doc_pub_fn.zig");
