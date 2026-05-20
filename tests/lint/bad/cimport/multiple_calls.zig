const std = @import("std");

/// Two separate @cImport calls — both must be flagged.
pub const stdio = @cImport(@cInclude("stdio.h"));
/// Second offending @cImport.
pub const stdlib = @cImport(@cInclude("stdlib.h"));
