//! Native glTF 2.0 static-mesh decoder.
//!
//! Parses the JSON with `std.json` (no hand-rolled JSON parser, no cgltf C
//! binding) and extracts the first mesh primitive's POSITION / NORMAL /
//! TEXCOORD_0 attributes and indices. Static only — no skinning, no
//! animation, no morph targets (brief §Out-of-scope).
//!
//! Buffers must be embedded base64 `data:` URIs (the M0.6 cooked path);
//! external `.bin` files and `.glb` containers are deferred.

const std = @import("std");

/// Errors raised by `decode`.
pub const Error = error{
    /// `std.json` failed to parse the document.
    BadJson,
    /// The document has no meshes / primitives.
    NoMesh,
    /// The first primitive has no POSITION attribute.
    NoPositions,
    /// An accessor used a component type this decoder does not handle.
    UnsupportedComponentType,
    /// A buffer URI was not an embedded base64 `data:` URI.
    UnsupportedBuffer,
    /// An accessor/bufferView reached past its buffer.
    Truncated,
    /// Allocation failed.
    OutOfMemory,
};

/// A decoded static mesh. All slices are caller-owned.
pub const Mesh = struct {
    /// XYZ positions, 3 floats per vertex.
    positions: []f32,
    /// XYZ normals (3 per vertex), or null if absent.
    normals: ?[]f32,
    /// UV0 coordinates (2 per vertex), or null if absent.
    uvs: ?[]f32,
    /// Triangle indices (synthesized 0..n-1 if the primitive was non-indexed).
    indices: []u32,
    /// Vertex count (== positions.len / 3).
    vertex_count: u32,
    /// Axis-aligned bounds (from the POSITION accessor min/max, else computed).
    bounds_min: [3]f32,
    /// Axis-aligned bounds maximum.
    bounds_max: [3]f32,

    /// Free every owned slice and poison `self`.
    pub fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
        gpa.free(self.positions);
        if (self.normals) |n| gpa.free(n);
        if (self.uvs) |u| gpa.free(u);
        gpa.free(self.indices);
        self.* = undefined;
    }
};

const component_f32 = 5126;

const Gltf = struct {
    buffers: []Buffer,
    bufferViews: []BufferView,
    accessors: []Accessor,
    meshes: []MeshJson,

    const Buffer = struct { uri: ?[]const u8 = null, byteLength: usize = 0 };
    const BufferView = struct { buffer: usize, byteOffset: usize = 0, byteLength: usize = 0, byteStride: ?usize = null };
    const Accessor = struct {
        bufferView: usize,
        byteOffset: usize = 0,
        componentType: u32,
        count: usize,
        type: []const u8,
        min: ?[]f32 = null,
        max: ?[]f32 = null,
    };
    const MeshJson = struct { primitives: []Primitive };
    const Primitive = struct { attributes: Attributes, indices: ?usize = null };
    const Attributes = struct { POSITION: ?usize = null, NORMAL: ?usize = null, TEXCOORD_0: ?usize = null };
};

/// Decode a glTF 2.0 document (`.gltf` JSON) into a static `Mesh`.
pub fn decode(gpa: std.mem.Allocator, src: []const u8) Error!Mesh {
    const parsed = std.json.parseFromSlice(Gltf, gpa, src, .{ .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();
    const doc = parsed.value;

    if (doc.meshes.len == 0 or doc.meshes[0].primitives.len == 0) return error.NoMesh;
    const prim = doc.meshes[0].primitives[0];

    // Decode all buffers (embedded base64) up front.
    const buffers = try gpa.alloc([]u8, doc.buffers.len);
    var decoded: usize = 0;
    defer {
        for (buffers[0..decoded]) |b| gpa.free(b);
        gpa.free(buffers);
    }
    for (doc.buffers) |b| {
        buffers[decoded] = try decodeDataUri(gpa, b.uri orelse return error.UnsupportedBuffer);
        decoded += 1;
    }

    const pos_index = prim.attributes.POSITION orelse return error.NoPositions;
    const positions = try readFloats(gpa, doc, buffers, pos_index, 3);
    errdefer gpa.free(positions);
    const vertex_count: u32 = @intCast(positions.len / 3);

    var normals: ?[]f32 = null;
    errdefer if (normals) |n| gpa.free(n);
    if (prim.attributes.NORMAL) |ni| normals = try readFloats(gpa, doc, buffers, ni, 3);

    var uvs: ?[]f32 = null;
    errdefer if (uvs) |u| gpa.free(u);
    if (prim.attributes.TEXCOORD_0) |ui| uvs = try readFloats(gpa, doc, buffers, ui, 2);

    const indices = if (prim.indices) |ii|
        try readIndices(gpa, doc, buffers, ii)
    else
        try sequentialIndices(gpa, vertex_count);
    errdefer gpa.free(indices);

    var bmin: [3]f32 = .{ 0, 0, 0 };
    var bmax: [3]f32 = .{ 0, 0, 0 };
    computeBounds(doc.accessors[pos_index], positions, &bmin, &bmax);

    return .{
        .positions = positions,
        .normals = normals,
        .uvs = uvs,
        .indices = indices,
        .vertex_count = vertex_count,
        .bounds_min = bmin,
        .bounds_max = bmax,
    };
}

fn decodeDataUri(gpa: std.mem.Allocator, uri: []const u8) Error![]u8 {
    const marker = "base64,";
    const idx = std.mem.indexOf(u8, uri, marker) orelse return error.UnsupportedBuffer;
    if (!std.mem.startsWith(u8, uri, "data:")) return error.UnsupportedBuffer;
    const b64 = uri[idx + marker.len ..];
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return error.BadJson;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    dec.decode(out, b64) catch return error.BadJson;
    return out;
}

fn readFloats(gpa: std.mem.Allocator, doc: Gltf, buffers: []const []u8, accessor_index: usize, comps: usize) Error![]f32 {
    const acc = doc.accessors[accessor_index];
    if (acc.componentType != component_f32) return error.UnsupportedComponentType;
    const view = doc.bufferViews[acc.bufferView];
    const buf = buffers[view.buffer];
    const elem = comps * 4;
    const stride = view.byteStride orelse elem;
    const base = view.byteOffset + acc.byteOffset;

    const out = try gpa.alloc(f32, acc.count * comps);
    errdefer gpa.free(out);
    var i: usize = 0;
    while (i < acc.count) : (i += 1) {
        var c: usize = 0;
        while (c < comps) : (c += 1) {
            const off = base + i * stride + c * 4;
            if (off + 4 > buf.len) return error.Truncated;
            out[i * comps + c] = @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
        }
    }
    return out;
}

fn readIndices(gpa: std.mem.Allocator, doc: Gltf, buffers: []const []u8, accessor_index: usize) Error![]u32 {
    const acc = doc.accessors[accessor_index];
    const csize: usize = switch (acc.componentType) {
        5121 => 1, // u8
        5123 => 2, // u16
        5125 => 4, // u32
        else => return error.UnsupportedComponentType,
    };
    const view = doc.bufferViews[acc.bufferView];
    const buf = buffers[view.buffer];
    const stride = view.byteStride orelse csize;
    const base = view.byteOffset + acc.byteOffset;

    const out = try gpa.alloc(u32, acc.count);
    errdefer gpa.free(out);
    var i: usize = 0;
    while (i < acc.count) : (i += 1) {
        const off = base + i * stride;
        if (off + csize > buf.len) return error.Truncated;
        out[i] = switch (csize) {
            1 => buf[off],
            2 => std.mem.readInt(u16, buf[off..][0..2], .little),
            4 => std.mem.readInt(u32, buf[off..][0..4], .little),
            else => unreachable,
        };
    }
    return out;
}

fn sequentialIndices(gpa: std.mem.Allocator, vertex_count: u32) Error![]u32 {
    const out = try gpa.alloc(u32, vertex_count);
    for (out, 0..) |*v, i| v.* = @intCast(i);
    return out;
}

fn computeBounds(pos_acc: Gltf.Accessor, positions: []const f32, bmin: *[3]f32, bmax: *[3]f32) void {
    if (pos_acc.min) |mn| {
        if (pos_acc.max) |mx| {
            if (mn.len >= 3 and mx.len >= 3) {
                bmin.* = .{ mn[0], mn[1], mn[2] };
                bmax.* = .{ mx[0], mx[1], mx[2] };
                return;
            }
        }
    }
    if (positions.len < 3) return;
    bmin.* = .{ positions[0], positions[1], positions[2] };
    bmax.* = bmin.*;
    var i: usize = 0;
    while (i < positions.len) : (i += 3) {
        for (0..3) |c| {
            bmin[c] = @min(bmin[c], positions[i + c]);
            bmax[c] = @max(bmax[c], positions[i + c]);
        }
    }
}

test "decode static cube glTF extracts positions, normals, uvs, indices" {
    const gpa = std.testing.allocator;
    var mesh = try decode(gpa, cube_gltf);
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 8), mesh.vertex_count);
    try std.testing.expectEqual(@as(usize, 24), mesh.positions.len);
    try std.testing.expectEqual(@as(usize, 36), mesh.indices.len);
    try std.testing.expect(mesh.normals != null);
    try std.testing.expectEqual(@as(usize, 16), mesh.uvs.?.len);
    try std.testing.expectEqual([3]f32{ -1, -1, -1 }, mesh.bounds_min);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, mesh.bounds_max);
    // First corner position is (-1,-1,-1).
    try std.testing.expectEqual(@as(f32, -1), mesh.positions[0]);
    // First triangle references vertices 0,1,2.
    try std.testing.expectEqual([3]u32{ 0, 1, 2 }, mesh.indices[0..3].*);
}

test "decode rejects non-glTF json" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NoMesh, decode(gpa, "{\"buffers\":[],\"bufferViews\":[],\"accessors\":[],\"meshes\":[]}"));
}

const cube_gltf =
    \\{"asset":{"version":"2.0"},"buffers":[{"byteLength":328,"uri":"data:application/octet-stream;base64,AACAvwAAgL8AAIC/AACAPwAAgL8AAIC/AACAPwAAgD8AAIC/AACAvwAAgD8AAIC/AACAvwAAgL8AAIA/AACAPwAAgL8AAIA/AACAPwAAgD8AAIA/AACAvwAAgD8AAIA/Os0TvzrNE786zRO/Os0TPzrNE786zRO/Os0TPzrNEz86zRO/Os0TvzrNEz86zRO/Os0TvzrNE786zRM/Os0TPzrNE786zRM/Os0TPzrNEz86zRM/Os0TvzrNEz86zRM/AAAAAAAAAAAAAIA/AAAAAAAAgD8AAIA/AAAAAAAAgD8AAAAAAAAAAAAAgD8AAAAAAACAPwAAgD8AAAAAAACAPwAAAQACAAAAAgADAAQABgAFAAQABwAGAAAABAAFAAAABQABAAEABQAGAAEABgACAAIABgAHAAIABwADAAMABwAEAAMABAAAAA=="}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":96},{"buffer":0,"byteOffset":96,"byteLength":96},{"buffer":0,"byteOffset":192,"byteLength":64},{"buffer":0,"byteOffset":256,"byteLength":72}],"accessors":[{"bufferView":0,"componentType":5126,"count":8,"type":"VEC3","min":[-1,-1,-1],"max":[1,1,1]},{"bufferView":1,"componentType":5126,"count":8,"type":"VEC3"},{"bufferView":2,"componentType":5126,"count":8,"type":"VEC2"},{"bufferView":3,"componentType":5123,"count":36,"type":"SCALAR"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2},"indices":3}]}]}
;
