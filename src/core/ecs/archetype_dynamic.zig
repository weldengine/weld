//! Compatibility shim for the M0.1 / E2 archetype consolidation.
//!
//! Before M0.1, the S1 comptime-typed `Archetype(Components)` lived in
//! `archetype.zig` and the byte-level `DynamicArchetype` (Etch / runtime-
//! query side) lived here. M0.1 / E2 fuses them into a single byte-level
//! `Archetype` in `archetype.zig`. This file is now a thin re-export so
//! the Etch interpreter, the runtime query, and any other consumer that
//! still imports `archetype_dynamic.DynamicArchetype` keep working without
//! a coordinated rename.
//!
//! The aliases here are deprecated. New code should import the canonical
//! names from `core/ecs/archetype.zig` and `core/ecs/chunk.zig`. A later
//! milestone (Etch alignment cleanup) will retire this file once every
//! caller has been migrated.

const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");

/// Deprecated alias for `archetype.Archetype` — Etch + runtime-query
/// still import this name pending a follow-up rename.
pub const DynamicArchetype = archetype_mod.Archetype;
/// Deprecated alias for `chunk.Chunk`.
pub const Chunk = chunk_mod.Chunk;
/// Deprecated alias for `chunk.ChunkHeader`.
pub const ChunkHeader = chunk_mod.ChunkHeader;
/// Deprecated alias for `chunk.ChunkLayout`.
pub const ChunkLayout = chunk_mod.ChunkLayout;
/// Deprecated alias for `chunk.ChunkSize`.
pub const ChunkSize = chunk_mod.ChunkSize;
/// Deprecated alias for `chunk.ChunkAlignment`.
pub const ChunkAlignment = chunk_mod.ChunkAlignment;
/// Deprecated alias for `chunk.ArchetypeError`.
pub const ArchetypeError = chunk_mod.ArchetypeError;
/// Deprecated alias for `archetype.SpawnResult`.
pub const SpawnResult = archetype_mod.SpawnResult;
