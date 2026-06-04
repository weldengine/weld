//! Shared importer output.

const std = @import("std");
const format = @import("../format/root.zig");

/// An imported asset: the intermediate document and its referenced blob.
/// `arena` owns everything reachable from `doc`; `blob` is `gpa`-owned.
pub const Import = struct {
    /// Owns all of `doc`'s strings/fields.
    arena: std.heap.ArenaAllocator,
    /// The intermediate `<type>.asset.etch` document.
    doc: format.AssetDoc,
    /// The referenced binary blob (decoded payload), `gpa`-owned.
    blob: []u8,

    /// Free the document arena and the blob.
    pub fn deinit(self: *Import, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.free(self.blob);
        self.* = undefined;
    }
};
