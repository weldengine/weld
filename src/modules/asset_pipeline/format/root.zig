//! Asset Pipeline `format/` namespace — the two day-1-frozen on-disk
//! surfaces.
//!
//! - `asset_type` — the `AssetType` category enum shared by both formats.
//! - `runtime_bin` — the runtime `.<type>.bin` 40-byte header.
//! - `intermediate` — the intermediate `<type>.asset.etch` document model
//!   and its ad-hoc Etch-subset reader/writer.

const asset_type = @import("asset_type.zig");
const runtime_bin = @import("runtime_bin.zig");

/// Intermediate `<type>.asset.etch` document model + reader/writer.
pub const intermediate = @import("intermediate.zig");

/// Frozen asset category enum (`AssetType`).
pub const AssetType = asset_type.AssetType;

/// Runtime `.<type>.bin` 40-byte header.
pub const RuntimeHeader = runtime_bin.RuntimeHeader;
/// Target platform tag stored in the header.
pub const Platform = runtime_bin.Platform;
/// `WELD` file signature.
pub const magic = runtime_bin.magic;
/// On-disk header size in bytes (40).
pub const header_size = runtime_bin.header_size;
/// Current header format version.
pub const current_version = runtime_bin.current_version;

/// Intermediate-document value node.
pub const Value = intermediate.Value;
/// Intermediate-document `key: value` field.
pub const Field = intermediate.Field;
/// Intermediate-document root schema.
pub const AssetDoc = intermediate.AssetDoc;

// Pins so the inline tests of every sub-file are analysed
// (engine-zig-conventions.md §13 module-rooting guard).
comptime {
    _ = asset_type;
    _ = runtime_bin;
    _ = intermediate;
}
