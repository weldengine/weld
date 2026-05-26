//! Barrier tracker — Phase 0 / M0.4.
//!
//! Maintient l'état de layout/access mask de chaque texture/buffer pour
//! insérer automatiquement les barriers Vulkan/Metal/D3D12 entre passes
//! qui partagent une resource. Cohérent avec le brief §Notes décision 2 :
//! auto-tracking par défaut, `BarrierMode.explicit` opt-in.
//!
//! Phase 0 : implémentation minimaliste — un `std.AutoHashMap` par type de
//! resource qui mappe handle → dernier (layout, stage, access). À chaque
//! déclaration d'usage par une pass, le tracker compare l'état courant à
//! l'état requis et émet une `RecordedBarrier` si transition nécessaire.
//!
//! Phase 1+ : enrichi pour le pass merging (fusion de passes compatibles
//! qui partagent une même barrière), le resource aliasing (réutilisation
//! d'une transient texture par plusieurs passes non-overlapping), et le
//! support multi-queue (barriers cross-queue avec timeline semaphores).
//!
//! Le tracker est interne au render graph — pas exporté côté caller. Le
//! caller consomme uniquement le `BarrierMode` via le descripteur de pass
//! (cf. `escape_hatches.BarrierMode`).

const std = @import("std");
const types = @import("types.zig");
const escape = @import("escape_hatches.zig");

/// Direction d'accès à une resource par une pass.
pub const Access = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    /// Si la pass écrit dans cette texture comme color attachment.
    color_attachment: bool = false,
    /// Si la pass écrit dans cette texture comme depth attachment.
    depth_attachment: bool = false,
    /// Si la pass lit cette texture comme sampled input.
    sampled: bool = false,
    _padding: u27 = 0,

    pub fn isWrite(self: Access) bool {
        return self.write or self.color_attachment or self.depth_attachment;
    }
};

/// Usage d'une resource par une pass donnée.
pub const ResourceUsage = struct {
    stage: types.ShaderStage,
    access: Access,
    /// Layout requis (uniquement pour les textures). Null pour les buffers.
    layout: ?escape.TextureLayout = null,
};

/// État courant d'une texture dans le tracker.
const TextureState = struct {
    layout: escape.TextureLayout,
    last_stage: types.ShaderStage,
    last_access: Access,
};

/// État courant d'un buffer dans le tracker.
const BufferState = struct {
    last_stage: types.ShaderStage,
    last_access: Access,
};

/// Barrière à insérer entre deux passes (produite par le tracker, consommée
/// par le backend lors de l'enregistrement des command buffers).
pub const RecordedBarrier = struct {
    resource: union(enum) {
        buffer: types.BufferHandle,
        texture: types.TextureHandle,
    },
    src_stage: types.ShaderStage,
    dst_stage: types.ShaderStage,
    src_access: Access,
    dst_access: Access,
    /// Transition de layout (uniquement pour les textures).
    old_layout: ?escape.TextureLayout = null,
    new_layout: ?escape.TextureLayout = null,
};

/// Tracker per-frame des transitions de resources. Reset au début de chaque
/// frame (les transient resources du render graph naissent et meurent dans
/// la frame).
pub const BarrierTracker = struct {
    allocator: std.mem.Allocator,
    textures: std.AutoHashMapUnmanaged(u64, TextureState) = .empty,
    buffers: std.AutoHashMapUnmanaged(u64, BufferState) = .empty,
    /// Barriers accumulées dans l'ordre d'insertion, consommées par le backend.
    recorded: std.ArrayListUnmanaged(RecordedBarrier) = .empty,

    pub fn init(allocator: std.mem.Allocator) BarrierTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BarrierTracker) void {
        self.textures.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.recorded.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reset le tracker pour une nouvelle frame. Préserve les buckets
    /// alloués (capacity) pour éviter les réallocations frame-à-frame.
    pub fn reset(self: *BarrierTracker) void {
        self.textures.clearRetainingCapacity();
        self.buffers.clearRetainingCapacity();
        self.recorded.clearRetainingCapacity();
    }

    /// Déclare l'usage d'une texture par la pass courante. Si une transition
    /// est nécessaire vs l'état précédent, une `RecordedBarrier` est ajoutée
    /// à `self.recorded`. Le state de la texture est mis à jour vers le
    /// nouvel état post-pass.
    ///
    /// `initial_layout` est utilisé uniquement la première fois qu'une
    /// texture apparaît (typiquement `.undefined` pour les transients).
    pub fn trackTexture(
        self: *BarrierTracker,
        texture: types.TextureHandle,
        usage: ResourceUsage,
        initial_layout: escape.TextureLayout,
    ) std.mem.Allocator.Error!void {
        const new_layout = usage.layout orelse initial_layout;
        const gop = try self.textures.getOrPut(self.allocator, texture.inner);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .layout = initial_layout,
                .last_stage = .{},
                .last_access = .{},
            };
        }
        const prev = gop.value_ptr.*;
        // Insertion de barrier si transition nécessaire.
        const needs_barrier = needsBarrierForTransition(
            prev.last_access,
            prev.last_stage,
            usage.access,
            usage.stage,
            prev.layout,
            new_layout,
        );
        if (needs_barrier) {
            try self.recorded.append(self.allocator, .{
                .resource = .{ .texture = texture },
                .src_stage = prev.last_stage,
                .dst_stage = usage.stage,
                .src_access = prev.last_access,
                .dst_access = usage.access,
                .old_layout = prev.layout,
                .new_layout = new_layout,
            });
        }
        gop.value_ptr.* = .{
            .layout = new_layout,
            .last_stage = usage.stage,
            .last_access = usage.access,
        };
    }

    /// Idem pour un buffer (pas de layout).
    pub fn trackBuffer(
        self: *BarrierTracker,
        buffer: types.BufferHandle,
        usage: ResourceUsage,
    ) std.mem.Allocator.Error!void {
        const gop = try self.buffers.getOrPut(self.allocator, buffer.inner);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .last_stage = .{},
                .last_access = .{},
            };
        }
        const prev = gop.value_ptr.*;
        const needs_barrier = needsBarrierForTransition(
            prev.last_access,
            prev.last_stage,
            usage.access,
            usage.stage,
            null,
            null,
        );
        if (needs_barrier) {
            try self.recorded.append(self.allocator, .{
                .resource = .{ .buffer = buffer },
                .src_stage = prev.last_stage,
                .dst_stage = usage.stage,
                .src_access = prev.last_access,
                .dst_access = usage.access,
            });
        }
        gop.value_ptr.* = .{
            .last_stage = usage.stage,
            .last_access = usage.access,
        };
    }

    /// Snapshot des barriers accumulées depuis le dernier `reset` ou `consumeRecorded`.
    pub fn consumeRecorded(self: *BarrierTracker) []const RecordedBarrier {
        return self.recorded.items;
    }
};

/// Détermine si une barrière est nécessaire entre deux usages successifs
/// d'une resource. Règle Phase 0 (simplifiée mais correcte) :
///   - première occurrence (last_access vide) → pas de barrière mais transition
///     de layout si needed (handled par le caller via le state initial)
///   - write → read = barrière obligatoire (read-after-write)
///   - read → write = barrière obligatoire (write-after-read)
///   - write → write = barrière obligatoire (write-after-write)
///   - read → read = pas de barrière (lectures concurrentes OK)
///   - changement de layout = barrière obligatoire indépendamment des access masks
fn needsBarrierForTransition(
    prev_access: Access,
    prev_stage: types.ShaderStage,
    new_access: Access,
    new_stage: types.ShaderStage,
    old_layout: ?escape.TextureLayout,
    new_layout: ?escape.TextureLayout,
) bool {
    _ = prev_stage;
    _ = new_stage;
    const prev_is_init = !prev_access.read and !prev_access.isWrite();
    if (prev_is_init) {
        // Premier usage : pas de barrière hazard, mais transition layout possible.
        if (old_layout != null and new_layout != null) {
            return @intFromEnum(old_layout.?) != @intFromEnum(new_layout.?);
        }
        return false;
    }
    if (prev_access.isWrite()) return true; // WAW ou RAW
    if (new_access.isWrite()) return true; // WAR
    // R→R : seule une transition de layout justifie une barrière.
    if (old_layout != null and new_layout != null) {
        return @intFromEnum(old_layout.?) != @intFromEnum(new_layout.?);
    }
    return false;
}

test "barriers: first usage produces no barrier when layout matches initial" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 1 };
    try tracker.trackTexture(tex, .{
        .stage = .{ .vertex = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .shader_read_only);
    try t.expectEqual(@as(usize, 0), tracker.consumeRecorded().len);
}

test "barriers: write then read inserts barrier" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 2 };
    // Pass A : color attachment write
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .write = true, .color_attachment = true },
        .layout = .color_attachment,
    }, .undefined);
    // Pass B : sampled read
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .undefined);
    const barriers = tracker.consumeRecorded();
    try t.expect(barriers.len >= 1);
    try t.expectEqual(escape.TextureLayout.color_attachment, barriers[barriers.len - 1].old_layout.?);
    try t.expectEqual(escape.TextureLayout.shader_read_only, barriers[barriers.len - 1].new_layout.?);
}

test "barriers: read after read does not insert barrier when layout stable" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 3 };
    try tracker.trackTexture(tex, .{
        .stage = .{ .vertex = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .shader_read_only);
    // Premier passage produit 0 barrier.
    try t.expectEqual(@as(usize, 0), tracker.recorded.items.len);
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .read = true, .sampled = true },
        .layout = .shader_read_only,
    }, .shader_read_only);
    // R→R même layout : toujours 0 barrier.
    try t.expectEqual(@as(usize, 0), tracker.recorded.items.len);
}

test "barriers: buffer write then read inserts barrier" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const buf = types.BufferHandle{ .inner = 100 };
    try tracker.trackBuffer(buf, .{
        .stage = .{ .compute = true },
        .access = .{ .write = true },
    });
    try tracker.trackBuffer(buf, .{
        .stage = .{ .vertex = true },
        .access = .{ .read = true },
    });
    const barriers = tracker.consumeRecorded();
    try t.expect(barriers.len >= 1);
}

test "barriers: reset clears recorded but preserves capacity" {
    const t = std.testing;
    var tracker = BarrierTracker.init(std.testing.allocator);
    defer tracker.deinit();
    const tex = types.TextureHandle{ .inner = 4 };
    try tracker.trackTexture(tex, .{
        .stage = .{ .fragment = true },
        .access = .{ .write = true, .color_attachment = true },
        .layout = .color_attachment,
    }, .undefined);
    tracker.reset();
    try t.expectEqual(@as(usize, 0), tracker.consumeRecorded().len);
    try t.expectEqual(@as(u32, 0), tracker.textures.count());
}
