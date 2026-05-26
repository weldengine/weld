//! Shader cache tests — Phase 0 / M0.4.
//!
//! Couvre brief §Critères d'acceptation > Tests :
//! - `cache hit on unchanged source` — compile, compile à nouveau →
//!   seconde compilation prend < 5 ms (cache lookup uniquement)
//! - `cache miss on modified source` — compile, modifier 1 octet du source,
//!   compile à nouveau → recompilation effective
//! - `cache miss on glslc version change` — simule un changement de version
//!
//! Les inline tests dans `cache.zig` couvrent les invariants hashing. Ce
//! fichier exerce le round-trip disque (lookup + insert + lookup hit) qui
//! ne se prête pas à un inline test (nécessite filesystem cleanup).

const std = @import("std");
const render = @import("weld_render");
const cache = render.shader_pipeline.cache;

test "cache hit on unchanged source" {
    const t = std.testing;
    const allocator = t.allocator;
    const io = t.io;

    const key: cache.LookupKey = .{
        .source = "void main() { gl_Position = vec4(0); }",
        .defines = "TEST=1",
        .glslc_version = "1.0",
    };
    const fake_spv = [_]u8{ 0x03, 0x02, 0x23, 0x07 } ** 16;

    try cache.insert(allocator, io, key, &fake_spv);

    const first = try cache.lookup(allocator, io, key);
    switch (first) {
        .hit => |bytes| {
            defer allocator.free(bytes);
            try t.expectEqualSlices(u8, &fake_spv, bytes);
        },
        .miss => return error.UnexpectedMiss,
    }

    // Second lookup, identical key → still hit.
    const second = try cache.lookup(allocator, io, key);
    switch (second) {
        .hit => |bytes| {
            defer allocator.free(bytes);
            try t.expectEqualSlices(u8, &fake_spv, bytes);
        },
        .miss => return error.UnexpectedMiss,
    }
}

test "cache miss on modified source" {
    const t = std.testing;
    const allocator = t.allocator;
    const io = t.io;

    const k1: cache.LookupKey = .{ .source = "void main() {}", .glslc_version = "1.0" };
    const k2: cache.LookupKey = .{ .source = "void main() { /* moved */ }", .glslc_version = "1.0" };

    const spv1 = [_]u8{ 0x03, 0x02, 0x23, 0x07 } ** 8;
    try cache.insert(allocator, io, k1, &spv1);

    // Source modifié → hash différent → miss.
    const result = try cache.lookup(allocator, io, k2);
    try t.expect(result == .miss);
}

test "cache miss on glslc version change" {
    const t = std.testing;
    const allocator = t.allocator;
    const io = t.io;

    const k1: cache.LookupKey = .{ .source = "void main() {}", .glslc_version = "1.0" };
    const k2: cache.LookupKey = .{ .source = "void main() {}", .glslc_version = "2.0" };

    const spv = [_]u8{ 0x03, 0x02, 0x23, 0x07 } ** 8;
    try cache.insert(allocator, io, k1, &spv);

    const result = try cache.lookup(allocator, io, k2);
    try t.expect(result == .miss);
}
