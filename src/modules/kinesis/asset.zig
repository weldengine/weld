//! The skeleton asset: its byte format, its reader, and the refusals that make
//! the runtime's assumptions true.
//!
//! **LOADING REFUSES A MALFORMED HIERARCHY, it never repairs one.** That is the
//! whole reason this file is written before anything walks a skeleton. A loader
//! that silently reroots an orphan, or clamps a parent index into range, makes
//! every downstream invariant untestable: the pass that depends on the
//! invariant can no longer be told apart from the repair that hid its absence.
//!
//! **The topological order is an ASSET INVARIANT, checked here.** A parent's
//! index is strictly lower than its children's, so forward kinematics is a
//! single ascending pass with no sort, no recursion and no visited set. It also
//! makes a cycle unrepresentable rather than merely detected — a cycle needs
//! some bone to point forward, and pointing forward is what this refuses. The
//! two are therefore ONE check and ONE error, because a cycle is an instance of
//! a parent that does not precede its child and not a separate fact; a caller
//! told two different codes for one fault would look for two faults.
//!
//! **The root is bone zero, and that is derived rather than decreed.** Exactly
//! one bone carries `no_parent`; every other has a parent with a strictly lower
//! index. Bone zero is the only index with nothing below it, so it is the only
//! one that can be the root. No rule says so and none is needed.
//!
//! **Reading is sequential and bounds-checked, never a cast over the buffer.**
//! Every field is read little-endian through a cursor, so no alignment
//! assumption reaches the caller's bytes and a truncated file is refused at the
//! field that runs off the end instead of reading whatever follows it in
//! memory.

const std = @import("std");

const anim = @import("weld_interfaces_animation");

const BoneIndex = anim.BoneIndex;
const BoneRole = anim.BoneRole;
const BoneTransform = anim.BoneTransform;
const Mat4 = anim.Mat4;
const Vec3 = anim.Vec3;
const Quat = anim.Quat;

/// Four bytes at the head of every skeleton asset.
pub const magic = [4]u8{ 'W', 'S', 'K', 'L' };

/// The layout revision this build reads and writes.
///
/// A version it does not know is REFUSED rather than guessed at, on the scene
/// codec's precedent: a reader that tolerates an unknown version has to invent
/// what the unknown fields mean.
pub const format_version: u16 = 1;

/// The parent of a root bone — no bone at all.
///
/// All-ones, so that no legal bone index can be mistaken for it. Zero cannot
/// serve: bone zero is a real bone and, as it happens, always the root.
pub const no_parent: BoneIndex = std.math.maxInt(BoneIndex);

/// How many bones a skeleton may carry.
///
/// Bounded so that a corrupt count cannot make the reader attempt an enormous
/// allocation before the bytes run out. It is above any rig the engine targets
/// and below `no_parent`, which must stay unreachable as an index.
pub const max_bones: u32 = 4096;

/// What a skeleton asset can be refused for.
pub const ParseError = error{
    /// The head of the buffer is not a skeleton asset.
    BadMagic,
    /// The layout revision is not the one this build reads.
    BadVersion,
    /// A field runs past the end of the buffer, or trailing bytes remain.
    MalformedSkeleton,
    /// Zero bones, or more than `max_bones`.
    BadBoneCount,
    /// A parent index names no bone.
    ParentIndexOutOfRange,
    /// A bone's parent does not precede it. Covers a cycle, which is one
    /// instance of this and not a separate fault.
    ParentAfterChild,
    /// More than one bone carries `no_parent`.
    MultipleRoots,
    /// The profile maps one role twice, so a role would resolve ambiguously.
    DuplicateRole,
    /// The profile maps a role onto a bone that does not exist.
    ProfileBoneOutOfRange,
    /// The profile names a role this build's vocabulary does not carry.
    UnknownRole,
};

/// Where a profile's mapping came from.
pub const Provenance = enum(u8) {
    /// Derived from bone names at import.
    inferred,
    /// Written by hand.
    authored,
};

/// What a profile's vocabulary describes.
pub const ProfileKind = enum(u8) {
    humanoid,
    quadruped,
    custom,
};

/// One role mapped onto one bone.
pub const RoleMapping = struct {
    role: BoneRole,
    bone: BoneIndex,
};

/// The optional role → bone mapping an asset may carry.
///
/// PARTIAL by construction: a role absent from `mappings` is absent, full stop.
/// A skeleton with no profile at all stays fully usable through bone names.
pub const SkeletonProfile = struct {
    kind: ProfileKind,
    provenance: Provenance,
    mappings: []const RoleMapping,
};

/// A parsed skeleton. Owns everything it points at.
pub const SkeletonAsset = struct {
    /// Parent of each bone, `no_parent` for the root. Strictly lower than the
    /// bone's own index everywhere else — the invariant forward kinematics
    /// rests on.
    parents: []BoneIndex,
    /// Where each bone's name starts and ends inside `name_bytes`.
    name_spans: []NameSpan,
    /// Every bone name, concatenated.
    name_bytes: []u8,
    /// The bind pose, each bone relative to its parent.
    bind_local: []BoneTransform,
    /// The inverse of each bone's bind transform in model space.
    ///
    /// STORED rather than derived from `bind_local`, because the pose a mesh
    /// was bound in is not always the rest pose the hierarchy carries — the
    /// same reason glTF ships both. Deriving would force the two to coincide
    /// and would silently re-skin any asset where they do not.
    inverse_bind: []Mat4,
    /// The role mapping, when the asset carries one.
    profile: ?SkeletonProfile,
    /// Backing storage for `profile.mappings`.
    profile_mappings: []RoleMapping,

    /// Where one bone's name sits inside `name_bytes`.
    pub const NameSpan = struct { start: u32, len: u16 };

    /// How many bones this skeleton has.
    pub fn boneCount(self: SkeletonAsset) u32 {
        return @intCast(self.parents.len);
    }

    /// The name of bone `i`.
    pub fn boneName(self: SkeletonAsset, i: BoneIndex) []const u8 {
        const span = self.name_spans[i];
        return self.name_bytes[span.start..][0..span.len];
    }

    /// Release everything the parse allocated.
    pub fn deinit(self: *SkeletonAsset, gpa: std.mem.Allocator) void {
        gpa.free(self.parents);
        gpa.free(self.name_spans);
        gpa.free(self.name_bytes);
        gpa.free(self.bind_local);
        gpa.free(self.inverse_bind);
        gpa.free(self.profile_mappings);
        self.* = undefined;
    }
};

// --- reading -----------------------------------------------------------------

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Cursor, n: usize) ParseError![]const u8 {
        if (self.at + n > self.bytes.len) return error.MalformedSkeleton;
        defer self.at += n;
        return self.bytes[self.at..][0..n];
    }
    fn u8At(self: *Cursor) ParseError!u8 {
        return (try self.take(1))[0];
    }
    fn u16At(self: *Cursor) ParseError!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
    fn u32At(self: *Cursor) ParseError!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn f32At(self: *Cursor) ParseError!f32 {
        return @bitCast(try self.u32At());
    }
};

/// Read a skeleton asset, refusing anything the runtime would have to assume
/// away.
///
/// The order of the checks is deliberate: SHAPE before CONTENT. Every byte is
/// read and bounded first, then the hierarchy is judged — so a truncated file
/// is never diagnosed as a bad hierarchy, which would send a reader looking at
/// the wrong thing.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !SkeletonAsset {
    var c = Cursor{ .bytes = bytes };

    if (!std.mem.eql(u8, try c.take(4), &magic)) return error.BadMagic;
    if (try c.u16At() != format_version) return error.BadVersion;

    const bone_count_raw = try c.u16At();
    const flags = try c.u16At();
    _ = try c.u16At(); // reserved, must be read so the cursor stays aligned with the writer
    if (bone_count_raw == 0 or bone_count_raw > max_bones) return error.BadBoneCount;
    const bone_count: usize = bone_count_raw;
    const has_profile = (flags & 1) != 0;

    const parents = try gpa.alloc(BoneIndex, bone_count);
    errdefer gpa.free(parents);
    for (parents) |*p| p.* = try c.u16At();

    const name_spans = try gpa.alloc(SkeletonAsset.NameSpan, bone_count);
    errdefer gpa.free(name_spans);
    var name_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer name_buf.deinit(gpa);
    for (name_spans) |*span| {
        const len = try c.u16At();
        const text = try c.take(len);
        span.* = .{ .start = @intCast(name_buf.items.len), .len = len };
        try name_buf.appendSlice(gpa, text);
    }

    const bind_local = try gpa.alloc(BoneTransform, bone_count);
    errdefer gpa.free(bind_local);
    for (bind_local) |*b| b.* = try readBoneTransform(&c);

    const inverse_bind = try gpa.alloc(Mat4, bone_count);
    errdefer gpa.free(inverse_bind);
    for (inverse_bind) |*m| {
        for (&m.m) |*e| e.* = try c.f32At();
    }

    var profile_mappings: []RoleMapping = &.{};
    var profile: ?SkeletonProfile = null;
    if (has_profile) {
        const kind_raw = try c.u8At();
        const prov_raw = try c.u8At();
        const count = try c.u16At();
        if (kind_raw > @intFromEnum(ProfileKind.custom)) return error.MalformedSkeleton;
        if (prov_raw > @intFromEnum(Provenance.authored)) return error.MalformedSkeleton;
        profile_mappings = try gpa.alloc(RoleMapping, count);
        errdefer gpa.free(profile_mappings);
        for (profile_mappings) |*m| {
            const role_raw = try c.u16At();
            if (role_raw >= @typeInfo(BoneRole).@"enum".fields.len) return error.UnknownRole;
            m.* = .{ .role = @enumFromInt(role_raw), .bone = try c.u16At() };
        }
        profile = .{
            .kind = @enumFromInt(kind_raw),
            .provenance = @enumFromInt(prov_raw),
            .mappings = profile_mappings,
        };
    }
    errdefer gpa.free(profile_mappings);

    // Trailing bytes are a refusal and not slack. A file longer than its own
    // declared contents is a file this reader did not understand, and reading
    // it anyway is how a version skew becomes a silent partial load.
    if (c.at != bytes.len) return error.MalformedSkeleton;

    try validateHierarchy(parents);
    if (profile) |p| try validateProfile(p, bone_count);

    const owned_names = try name_buf.toOwnedSlice(gpa);
    return .{
        .parents = parents,
        .name_spans = name_spans,
        .name_bytes = owned_names,
        .bind_local = bind_local,
        .inverse_bind = inverse_bind,
        .profile = profile,
        .profile_mappings = profile_mappings,
    };
}

fn readBoneTransform(c: *Cursor) ParseError!BoneTransform {
    const px = try c.f32At();
    const py = try c.f32At();
    const pz = try c.f32At();
    const rx = try c.f32At();
    const ry = try c.f32At();
    const rz = try c.f32At();
    const rw = try c.f32At();
    const sx = try c.f32At();
    const sy = try c.f32At();
    const sz = try c.f32At();
    return .{
        .position = Vec3.fromArray(.{ px, py, pz }),
        .rotation = .{ .x = rx, .y = ry, .z = rz, .w = rw },
        .scale = Vec3.fromArray(.{ sx, sy, sz }),
    };
}

/// Judge the hierarchy, refusing every shape the runtime would otherwise have
/// to defend against.
///
/// Exported so the importer that will produce these assets can refuse the same
/// shapes at the point it builds them, instead of writing a file it knows the
/// loader rejects.
pub fn validateHierarchy(parents: []const BoneIndex) ParseError!void {
    // Checked HERE and not only in `parse`, because this entry is exported for
    // the importer and an exported judge that trusts its caller for the one
    // input it cannot survive is not a judge.
    if (parents.len == 0 or parents.len > max_bones) return error.BadBoneCount;

    var roots: usize = 0;
    for (parents, 0..) |p, i| {
        if (p == no_parent) {
            roots += 1;
            continue;
        }
        if (p >= parents.len) return error.ParentIndexOutOfRange;
        // `>=` and not `>`: a bone that is its own parent is a one-element
        // cycle, and it is this comparison that catches it.
        if (p >= i) return error.ParentAfterChild;
    }

    // **THERE IS NO `NoRoot` REFUSAL, and the reason is that no input reaches
    // it.** Bone zero has no index below it, so its parent is either
    // `no_parent` — and there is a root — or a real index, and `p >= i` at
    // `i == 0` is then true for every value, so the loop has already refused.
    // An error variant no caller can provoke is an assertion wearing an error's
    // clothes, and the codebase has removed one such variant before rather than
    // leave a refusal nobody can test.
    std.debug.assert(roots >= 1);
    if (roots > 1) return error.MultipleRoots;
}

fn validateProfile(p: SkeletonProfile, bone_count: usize) ParseError!void {
    var seen = std.StaticBitSet(@typeInfo(BoneRole).@"enum".fields.len).initEmpty();
    for (p.mappings) |m| {
        const ord = @intFromEnum(m.role);
        if (seen.isSet(ord)) return error.DuplicateRole;
        seen.set(ord);
        if (m.bone >= bone_count) return error.ProfileBoneOutOfRange;
    }
}

// --- writing -----------------------------------------------------------------

/// What an encoder is given. The same shape the importer will hand it.
pub const SkeletonDescription = struct {
    parents: []const BoneIndex,
    names: []const []const u8,
    bind_local: []const BoneTransform,
    inverse_bind: []const Mat4,
    profile: ?SkeletonProfile = null,
};

/// Serialise a description into the byte format `parse` reads.
///
/// It lives beside the reader so the format has ONE declarant: a writer in the
/// test tree and a reader in the source tree are two descriptions of one layout
/// and they drift. It VALIDATES NOTHING — that is the reader's job, and an
/// encoder that refused malformed input could not produce the fixtures the
/// reader's refusals are tested with.
pub fn encode(gpa: std.mem.Allocator, desc: SkeletonDescription) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = &out;

    try w.appendSlice(gpa, &magic);
    try putU16(gpa, w, format_version);
    try putU16(gpa, w, @intCast(desc.parents.len));
    try putU16(gpa, w, if (desc.profile != null) 1 else 0);
    try putU16(gpa, w, 0);

    for (desc.parents) |p| try putU16(gpa, w, p);
    for (desc.names) |n| {
        try putU16(gpa, w, @intCast(n.len));
        try w.appendSlice(gpa, n);
    }
    for (desc.bind_local) |b| {
        for (b.position.toArray()) |e| try putF32(gpa, w, e);
        for (b.rotation.toArray()) |e| try putF32(gpa, w, e);
        for (b.scale.toArray()) |e| try putF32(gpa, w, e);
    }
    for (desc.inverse_bind) |m| {
        for (m.m) |e| try putF32(gpa, w, e);
    }
    if (desc.profile) |p| {
        try w.append(gpa, @intFromEnum(p.kind));
        try w.append(gpa, @intFromEnum(p.provenance));
        try putU16(gpa, w, @intCast(p.mappings.len));
        for (p.mappings) |m| {
            try putU16(gpa, w, @intFromEnum(m.role));
            try putU16(gpa, w, m.bone);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn putU16(gpa: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try w.appendSlice(gpa, &b);
}

fn putF32(gpa: std.mem.Allocator, w: *std.ArrayListUnmanaged(u8), v: f32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @bitCast(v), .little);
    try w.appendSlice(gpa, &b);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "validateHierarchy accepts a well-formed chain and names each refusal" {
    // The positive first, and it is not decoration: every refusal below is
    // vacuous against a validator that refuses everything.
    try validateHierarchy(&.{ no_parent, 0, 1, 1 });

    try testing.expectError(error.ParentIndexOutOfRange, validateHierarchy(&.{ no_parent, 9 }));
    try testing.expectError(error.ParentAfterChild, validateHierarchy(&.{ no_parent, 2, 0 }));
    // A one-element cycle: bone 1 is its own parent.
    try testing.expectError(error.ParentAfterChild, validateHierarchy(&.{ no_parent, 1 }));
    // A two-element cycle: bone 1 points at 2, which points back at 1. It is
    // caught as a forward reference, which is what a cycle has to contain.
    try testing.expectError(error.ParentAfterChild, validateHierarchy(&.{ no_parent, 2, 1 }));
    try testing.expectError(error.MultipleRoots, validateHierarchy(&.{ no_parent, no_parent }));
    // A rootless hierarchy is not a distinct refusal: bone zero pointing at a
    // real bone is bone zero pointing at itself or forward, which the ordering
    // check has already refused. This case is what establishes that, and it is
    // why `NoRoot` does not exist.
    try testing.expectError(error.ParentAfterChild, validateHierarchy(&.{ 0, 0 }));
    try testing.expectError(error.BadBoneCount, validateHierarchy(&.{}));
}

test "a description round-trips through encode and parse" {
    const gpa = testing.allocator;
    const parents = [_]BoneIndex{ no_parent, 0, 1 };
    const names = [_][]const u8{ "root", "spine", "head" };
    const bind = [_]BoneTransform{
        .{ .position = Vec3.fromArray(.{ 0, 0, 0 }) },
        .{ .position = Vec3.fromArray(.{ 0, 1, 0 }) },
        .{ .position = Vec3.fromArray(.{ 0, 0.5, 0 }) },
    };
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity, Mat4.identity };

    const bytes = try encode(gpa, .{
        .parents = &parents,
        .names = &names,
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
    defer gpa.free(bytes);

    var asset = try parse(gpa, bytes);
    defer asset.deinit(gpa);

    try testing.expectEqual(@as(u32, 3), asset.boneCount());
    try testing.expectEqual(no_parent, asset.parents[0]);
    try testing.expectEqual(@as(BoneIndex, 1), asset.parents[2]);
    try testing.expectEqualStrings("root", asset.boneName(0));
    try testing.expectEqualStrings("head", asset.boneName(2));
    try testing.expectApproxEqAbs(@as(f32, 1), asset.bind_local[1].position.data[1], 1e-6);
    try testing.expect(asset.profile == null);
}

test "a truncated buffer is refused as malformed, never as a bad hierarchy" {
    const gpa = testing.allocator;
    const parents = [_]BoneIndex{ no_parent, 0 };
    const names = [_][]const u8{ "a", "b" };
    const bind = [_]BoneTransform{ .{}, .{} };
    const inv = [_]Mat4{ Mat4.identity, Mat4.identity };
    const bytes = try encode(gpa, .{
        .parents = &parents,
        .names = &names,
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
    defer gpa.free(bytes);

    // Cut anywhere past the header and the cursor must run out before the
    // hierarchy is ever judged. Shape before content, asserted rather than
    // asserted-once: one cut length could land on a boundary by luck.
    var cut: usize = 12;
    while (cut < bytes.len) : (cut += 7) {
        try testing.expectError(error.MalformedSkeleton, parse(gpa, bytes[0..cut]));
    }
}

test "trailing bytes are refused" {
    const gpa = testing.allocator;
    const parents = [_]BoneIndex{no_parent};
    const names = [_][]const u8{"only"};
    const bind = [_]BoneTransform{.{}};
    const inv = [_]Mat4{Mat4.identity};
    const bytes = try encode(gpa, .{
        .parents = &parents,
        .names = &names,
        .bind_local = &bind,
        .inverse_bind = &inv,
    });
    defer gpa.free(bytes);

    const longer = try gpa.alloc(u8, bytes.len + 1);
    defer gpa.free(longer);
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    try testing.expectError(error.MalformedSkeleton, parse(gpa, longer));
}
