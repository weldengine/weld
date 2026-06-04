//! Asset Pipeline module (Tier 1) — public entry point.
//!
//! M0.6 delivers the minimal Phase 0 pipeline in staged gates. E1 ships the
//! day-1-frozen surfaces every later stage builds on:
//! - `format` — the intermediate `<type>.asset.etch` schema and the runtime
//!   `.<type>.bin` 40-byte header.
//! - `registry` — `AssetHandle` and the slot `Registry` (refcount +
//!   generation invalidation).
//!
//! Later gates add `codecs/` (DEFLATE, PNG, glTF), `importers/`, `cookers/`,
//! `cache/`, and the async `loader/`. The public surface here stays the
//! frozen contract; implementation behind it evolves.
//!
//! Dependencies: `core` (E5 loader consumes the Tier 0 job system) and, from
//! E2, `foundation` (the SIMD kernels). No `weld_etch` dependency
//! (brief §Out-of-scope).

/// On-disk format surfaces: `AssetType`, the runtime `.bin` header, the
/// intermediate `.asset.etch` document model + reader/writer.
pub const format = @import("format/root.zig");

/// Asset identity: `AssetHandle` + the slot `Registry`.
pub const registry = @import("registry/root.zig");

/// Low-level codecs (E2: DEFLATE/zlib; E3: PNG + glTF static).
pub const codecs = @import("codecs/root.zig");

/// Source importers (source → intermediate `AssetDoc` + blob).
pub const importers = @import("importers/root.zig");

/// Cookers (intermediate → runtime `.<type>.bin`).
pub const cookers = @import("cookers/root.zig");

/// Local cooking cache (BLAKE3-keyed).
pub const cache = @import("cache/root.zig");

/// Content hashing (BLAKE3-128 hex / u64).
pub const hash = @import("hash.zig");

/// 64-bit typed asset handle (convenience re-export).
pub const AssetHandle = registry.AssetHandle;
/// Slot registry (convenience re-export).
pub const Registry = registry.Registry;
/// Frozen asset category enum (convenience re-export).
pub const AssetType = format.AssetType;
/// Runtime `.bin` header (convenience re-export).
pub const RuntimeHeader = format.RuntimeHeader;
/// Intermediate-format root schema (convenience re-export).
pub const AssetDoc = format.AssetDoc;

// Pins so the inline tests of both namespaces are analysed when the module
// is built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = format;
    _ = registry;
    _ = codecs;
    _ = importers;
    _ = cookers;
    _ = cache;
    _ = hash;
}
