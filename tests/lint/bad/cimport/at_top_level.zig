const std = @import("std");

/// Calls @cImport at top level — must be rejected by no_cimport.
pub const c = @cImport(@cInclude("stdio.h"));
