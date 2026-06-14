//! Runtime registry of `TypeInfo` records.
//!
//! `Registry` indexes RTTI metadata by `TypeId` (primary key) and by
//! `type_name` (secondary lookup). `register` is idempotent on the
//! `(type_id, schema_hash)` pair — calling it twice with the same
//! schema is a silent no-op; calling it twice with different schemas
//! returns `error.SchemaMismatch`.
//!
//! Storage is unmanaged — the `Allocator` is provided to `init` and
//! threaded through `register` internally. The `gpa`, `types`, and
//! `name_index` fields are implementation detail and are NOT part of
//! the frozen public contract: Zig has no field-level visibility, so
//! they are technically reachable, but consumers must go through the
//! `Registry` methods only (`register` / `lookup` / `lookupByName` /
//! `count`). The internal container types may change in Phase 1+
//! without a `*_PROTOCOL_VERSION` bump.
//!
//! `lookup` and `lookupByName` return pointers into the `types`
//! hashmap. These pointers are stable until the next `register` call
//! that grows the underlying storage; callers that retain pointers
//! across mutations must re-resolve.

const std = @import("std");
const type_info = @import("type_info.zig");

const TypeId = type_info.TypeId;
const SchemaHash = type_info.SchemaHash;
const TypeInfo = type_info.TypeInfo;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Errors returned by `Registry.register`.
pub const RegisterError = error{
    /// A previous registration of the same `TypeId` had a different
    /// `SchemaHash`. The caller's metadata is incompatible with the
    /// stored record.
    SchemaMismatch,
    /// Underlying hashmap allocation failed.
    OutOfMemory,
};

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
/// Public Tier 0 registry. Owned by `World` once Phase 0 wires it up
/// (E3+); E1 ships the standalone type with its own tests.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    types: std.AutoHashMapUnmanaged(TypeId, TypeInfo) = .empty,
    name_index: std.StringHashMapUnmanaged(TypeId) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.types.deinit(self.gpa);
        self.name_index.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register `info` in the type index. Returns silently when an
    /// equivalent record (same `type_id` and same `schema_hash`) is
    /// already present; returns `error.SchemaMismatch` when the
    /// `type_id` is present but the `schema_hash` differs.
    pub fn register(self: *Registry, info: TypeInfo) RegisterError!void {
        if (self.types.get(info.type_id)) |existing| {
            if (existing.schema_hash != info.schema_hash) {
                return error.SchemaMismatch;
            }
            return; // idempotent — same schema, no-op.
        }
        try self.types.put(self.gpa, info.type_id, info);
        try self.name_index.put(self.gpa, info.type_name, info.type_id);
    }

    /// Returns the stored record for `id`, or `null` if the type has
    /// never been registered. The returned pointer is invalidated by
    /// any subsequent `register` call that grows the storage.
    pub fn lookup(self: *const Registry, id: TypeId) ?*const TypeInfo {
        return self.types.getPtr(id);
    }

    /// Returns the stored record matching `name`, or `null` if no
    /// type with that `type_name` has been registered. Same
    /// pointer-stability caveat as `lookup`.
    pub fn lookupByName(self: *const Registry, name: []const u8) ?*const TypeInfo {
        const id = self.name_index.get(name) orelse return null;
        return self.types.getPtr(id);
    }

    /// Number of distinct types currently registered.
    pub fn count(self: *const Registry) u32 {
        return @intCast(self.types.count());
    }
};
