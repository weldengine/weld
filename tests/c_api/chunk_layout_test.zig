//! The Zig half of the `WeldQueryChunk` drift pin.
//!
//! `tests/c_api/read_column_constness/weld_query_chunk.h` declares the C mirror
//! of `plugin_loader.api.WeldQueryChunk` by hand, because the unified binding
//! generator that is meant to emit `weld_api.h` does not exist in this tree.
//! A hand-written mirror drifts; what stops this one is TWO INDEPENDENT PINS on
//! one layout — `_Static_assert`s in the header, and the assertions here — each
//! written in its own language and neither derived from the other. Either
//! declaration moving alone turns one of them red.
//!
//! What this file does NOT establish is that the constness holds: that is a
//! property of C, and it is `zig build c-api-read-column-constness` which
//! compiles the witness both ways. The layout and the qualifiers are two claims
//! and they have two oracles.

const std = @import("std");
const weld_core = @import("weld_core");
const api = weld_core.plugin_loader.api;

const testing = std.testing;
const Chunk = api.WeldQueryChunk;
const ptr_size = @sizeOf(*anyopaque);

test "the query chunk layout is what the C mirror declares" {
    // Expressed in `sizeof(void*)` rather than in literals, exactly as the
    // header expresses it, so the pin says the same thing on a 32-bit target.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Chunk, "struct_size"));
    try testing.expectEqual(@sizeOf(u32), @offsetOf(Chunk, "count"));
    try testing.expectEqual(ptr_size, @offsetOf(Chunk, "entities"));
    try testing.expectEqual(2 * ptr_size, @offsetOf(Chunk, "reads"));
    try testing.expectEqual(4 * ptr_size, @offsetOf(Chunk, "writes"));
    try testing.expectEqual(8 * ptr_size, @sizeOf(Chunk));
}

test "struct_size defaults to the host's own sizeof" {
    // `ARCH-018`'s mechanism only works if the host fills the field with what
    // the host compiled, and a default of zero would be read by a plugin as
    // "every member is absent". The default is the value.
    const c: Chunk = .{};
    try testing.expectEqual(@as(u32, @sizeOf(Chunk)), c.struct_size);
}

test "a read column is const on both levels and a write column on one" {
    // The layout pin above would pass on a chunk whose two spaces had identical
    // qualifiers — which is the defect `engine-c-api.md` §5.5 exists to close.
    // The qualifiers are therefore asserted here, on the Zig declaration, and
    // the C side asserts the same thing by refusing to compile the witness's
    // counter-proof.
    const reads_info = @typeInfo(@typeInfo(@FieldType(Chunk, "reads")).optional.child);
    const writes_info = @typeInfo(@typeInfo(@FieldType(Chunk, "writes")).optional.child);

    // The outer pointer is const on both: the SLOT is not assignable.
    try testing.expect(reads_info.pointer.is_const);
    try testing.expect(writes_info.pointer.is_const);

    // The inner pointer is const on reads and mutable on writes: the DATA is
    // writable through one space and not the other.
    const read_elem = @typeInfo(@typeInfo(reads_info.pointer.child).optional.child);
    const write_elem = @typeInfo(@typeInfo(writes_info.pointer.child).optional.child);
    try testing.expect(read_elem.pointer.is_const);
    try testing.expect(!write_elem.pointer.is_const);
}

test "query_create declares reads and writes separately" {
    // Without this the two index spaces are shapes nothing fills: a single
    // include list gives the chunk no way to know which columns are read-only,
    // and the constness above would be decoration. The chain holds entire.
    const Api = api.WeldEcsAPI;
    const params = @typeInfo(@typeInfo(@FieldType(Api, "query_create")).pointer.child).@"fn".params;
    // world, reads, read_count, writes, write_count, exclude, exclude_count
    try testing.expectEqual(@as(usize, 7), params.len);
    try testing.expect(params[2].type.? == u32);
    try testing.expect(params[4].type.? == u32);
    try testing.expect(params[6].type.? == u32);
}
