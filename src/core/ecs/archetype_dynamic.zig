//! Compatibility shim: DEPRECATED aliases for the consolidated `archetype.zig` and
//! `chunk.zig` names, to be retired once the Etch consumers are migrated.

const archetype_mod = @import("archetype.zig");
const chunk_mod = @import("chunk.zig");

/// Deprecated alias for `archetype.Archetype`.
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
