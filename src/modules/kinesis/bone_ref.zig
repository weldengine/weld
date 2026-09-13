//! Bone addressing: the ONE path from a `BoneRef` to a bone index.
//!
//! **AN UNMAPPED ROLE RESOLVES TO ABSENCE, NEVER TO A NEIGHBOURING BONE.** That
//! is the whole contract, and the failure it forbids is specific: a solver that
//! cannot find its chain must DEACTIVATE, not act on the wrong bone. A wrong
//! bone produces motion — plausible, animated, and wrong — where an absence
//! produces nothing and is noticed.
//!
//! **The mapping is searched BY ROLE VALUE and never indexed by ordinal.** A
//! profile is PARTIAL by construction, so its entries do not sit at their own
//! ordinals: indexing `mappings[@intFromEnum(role)]` on a profile missing one
//! role shifts every entry after the gap and answers a neighbour for the role
//! that is absent. That is exactly the defect this file's adversarial test
//! attacks, and it is the reason the search is written as a search.
//!
//! **A skeleton with no profile at all stays fully usable by name.** The
//! absence of a profile is not a defect and nothing downstream may treat it as
//! one — a tentacle or a mech has no role, and `ARCH-033` imposes the
//! uniformity of the addressing TYPE, never the obligation of a role.
//!
//! **What this file does NOT give is that `resolveBone` is the only code that
//! CAN map a role.** Zig has no private field, so a caller holding a `Rig` can
//! read its profile and search it by hand. What the type system does give is
//! the uniformity `ARCH-033` actually imposes: the addressing type. The
//! counter-proof corpus pins that, and the limit is stated here rather than
//! claimed away — the same limit the declared-access view records for itself.

const std = @import("std");

const anim = @import("weld_interfaces_animation");
const skeleton_mod = @import("skeleton.zig");

const BoneIndex = anim.BoneIndex;
const BoneRef = anim.BoneRef;
const BoneRole = anim.BoneRole;
const Rig = skeleton_mod.Rig;

/// Resolve a bone reference against a rig — the one resolution path.
///
/// Answers null when the reference names nothing: a role the profile does not
/// map, a role on a rig with no profile at all, or a name no bone carries.
pub fn resolveBone(rig: Rig, ref: BoneRef) ?BoneIndex {
    return switch (ref) {
        .name => |n| resolveName(rig, n),
        .role => |r| resolveRole(rig, r),
    };
}

/// The bone a role names, or null.
///
/// Linear over the mappings, which is what makes it correct on a PARTIAL
/// profile. The vocabulary is twenty-three roles and a profile is smaller
/// still, so the walk is shorter than the indirection an index would need.
pub fn resolveRole(rig: Rig, role: BoneRole) ?BoneIndex {
    const profile = rig.profile orelse return null;
    for (profile.mappings) |m| {
        if (m.role == role) return m.bone;
    }
    return null;
}

/// The bone a literal name identifies, or null.
///
/// Exact bytes, no case folding and no prefix matching: `mixamorig:LeftFoot`
/// and `LeftFoot` are different names, and deciding they are the same is the
/// import-time inference's job, where a human can override it.
///
/// The first match wins, and the rig's names are unique — the loader refuses a
/// rig that carries two bones of one name — so "first" and "only" are the same
/// bone and this tie-break is never exercised.
pub fn resolveName(rig: Rig, name: []const u8) ?BoneIndex {
    for (0..rig.boneCount()) |i| {
        const b: BoneIndex = @intCast(i);
        if (std.mem.eql(u8, rig.boneName(b), name)) return b;
    }
    return null;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const asset_mod = @import("asset.zig");

/// A rig whose profile maps EVERY role except one, built without touching the
/// byte format so the attack below can be read in one screen.
fn profiledRig(gpa: std.mem.Allocator, comptime omitted: BoneRole) !Rig {
    const roles = @typeInfo(BoneRole).@"enum".fields;
    const n = roles.len;

    const parents = try gpa.alloc(BoneIndex, n);
    parents[0] = asset_mod.no_parent;
    for (1..n) |i| parents[i] = @intCast(i - 1);

    const spans = try gpa.alloc(asset_mod.SkeletonAsset.NameSpan, n);
    var names: std.ArrayListUnmanaged(u8) = .empty;
    inline for (roles, 0..) |f, i| {
        spans[i] = .{ .start = @intCast(names.items.len), .len = f.name.len };
        try names.appendSlice(gpa, f.name);
    }

    const bind = try gpa.alloc(anim.BoneTransform, n);
    for (bind) |*b| b.* = .{};
    const inv = try gpa.alloc(anim.Mat4, n);
    for (inv) |*m| m.* = anim.Mat4.identity;

    var mappings: std.ArrayListUnmanaged(asset_mod.RoleMapping) = .empty;
    inline for (roles, 0..) |f, i| {
        const role: BoneRole = @enumFromInt(f.value);
        if (role != omitted) try mappings.append(gpa, .{ .role = role, .bone = @intCast(i) });
    }
    const owned = try mappings.toOwnedSlice(gpa);

    return .{
        .parents = parents,
        .name_spans = spans,
        .name_bytes = try names.toOwnedSlice(gpa),
        .bind_local = bind,
        .inverse_bind = inv,
        .profile = .{ .kind = .humanoid, .provenance = .authored, .mappings = owned },
        .profile_mappings = owned,
    };
}

test "a mapped role resolves to its bone index" {
    const gpa = testing.allocator;
    var rig = try profiledRig(gpa, .toe_r);
    defer rig.deinit(gpa);

    // The positive witness. Without it the absence test below is satisfied by a
    // resolver that answers null for everything.
    try testing.expectEqual(@as(?BoneIndex, 0), resolveBone(rig, .{ .role = .root }));
    try testing.expectEqual(@as(?BoneIndex, 6), resolveBone(rig, .{ .role = .head }));
    try testing.expectEqual(@as(?BoneIndex, 17), resolveBone(rig, .{ .role = .foot_l }));
}

test "an unmapped role resolves to absence, not to a neighbouring bone" {
    // **THE ATTACK.** The profile maps twenty-two of twenty-three roles and
    // omits ONE IN THE MIDDLE, so the mappings array no longer has each entry
    // at its own ordinal. A resolver that indexes by ordinal answers the
    // NEIGHBOUR for the omitted role and stays plausible for the rest — which
    // is why a test that checks `null` against an EMPTY profile measures
    // nothing: an empty array has no neighbour to answer with.
    const gpa = testing.allocator;
    var rig = try profiledRig(gpa, .calf_l);
    defer rig.deinit(gpa);

    try testing.expectEqual(@as(?BoneIndex, null), resolveBone(rig, .{ .role = .calf_l }));

    // And the roles on BOTH SIDES of the gap still resolve to their own bones.
    // Without this half the assertion above is satisfied by a resolver that
    // stopped working at the gap, which is a different defect with the same
    // symptom on one input.
    try testing.expectEqual(@as(?BoneIndex, 15), resolveBone(rig, .{ .role = .thigh_l }));
    try testing.expectEqual(@as(?BoneIndex, 17), resolveBone(rig, .{ .role = .foot_l }));
    try testing.expectEqual(@as(?BoneIndex, 22), resolveBone(rig, .{ .role = .toe_r }));
}

test "a skeleton with no profile resolves by literal name" {
    const gpa = testing.allocator;
    var rig = try profiledRig(gpa, .toe_r);
    // Drop the profile, keeping the same bones: a rig with no roles at all,
    // which is the tentacle-and-mech case the invariant explicitly protects.
    gpa.free(rig.profile_mappings);
    rig.profile = null;
    rig.profile_mappings = &.{};
    defer rig.deinit(gpa);

    try testing.expectEqual(@as(?BoneIndex, 6), resolveBone(rig, .{ .name = "head" }));
    try testing.expectEqual(@as(?BoneIndex, 0), resolveBone(rig, .{ .name = "root" }));
    // Every role is absent now, and absent is not an error.
    try testing.expectEqual(@as(?BoneIndex, null), resolveBone(rig, .{ .role = .head }));
    // A name no bone carries is absent too, not a near match.
    try testing.expectEqual(@as(?BoneIndex, null), resolveBone(rig, .{ .name = "hea" }));
    try testing.expectEqual(@as(?BoneIndex, null), resolveBone(rig, .{ .name = "HEAD" }));
}
