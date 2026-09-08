//! FROZEN — see engine-phase-0-criteria.md C0.5. Every public entry below is.
//!
//! Runtime registry of `TypeInfo`, keyed by `TypeId` and by `type_name`.
//! `register` is idempotent on `(type_id, schema_hash)`: the same schema twice is a
//! silent no-op, a different schema is `error.SchemaMismatch`.
//!
//! THE FIELDS ARE NOT PART OF THE FROZEN CONTRACT. Zig has no field-level
//! visibility, so `gpa`, `types` and `name_index` are reachable — consumers must go
//! through the methods, and the containers may change without a version bump.
//!
//! `lookup` and `lookupByName` return pointers INTO the hashmap: they are valid
//! until the next `register` that grows it, and a retained pointer must be
//! re-resolved.

const std = @import("std");
const type_info = @import("type_info.zig");

const TypeId = type_info.TypeId;
const SchemaHash = type_info.SchemaHash;
const TypeInfo = type_info.TypeInfo;

/// Errors returned by `Registry.register`.
pub const RegisterError = error{
    /// The same `TypeId` was registered before with a different schema.
    SchemaMismatch,
    /// Underlying hashmap allocation failed.
    OutOfMemory,
};

/// Public Tier 0 registry.
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

    /// Register `info`. Silent on an identical re-registration, `SchemaMismatch` on a
    /// differing one.
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

    /// The stored record for `id`, or null.
    pub fn lookup(self: *const Registry, id: TypeId) ?*const TypeInfo {
        return self.types.getPtr(id);
    }

    /// The stored record matching `name`, or null.
    pub fn lookupByName(self: *const Registry, name: []const u8) ?*const TypeInfo {
        const id = self.name_index.get(name) orelse return null;
        return self.types.getPtr(id);
    }

    /// Number of distinct types currently registered.
    pub fn count(self: *const Registry) u32 {
        return @intCast(self.types.count());
    }
};
