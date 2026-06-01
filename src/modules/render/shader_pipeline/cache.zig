//! Disk shader cache — Phase 0 / M0.4.
//!
//! Hash over `(source + defines + glslc_version)` (brief §Scope). Phase 0:
//! cache stored under `.weld-cache/shaders/<hash>.spv`. Lookup → `LoadResult.hit`
//! with the SPIR-V bytes; miss → caller compiles + inserts.
//!
//! Hash format: SHA-1 hex (160 bits → 40 char). Phase 1+: switch to
//! blake3 if profiling justifies it (the hash is not perf-critical — a few
//! ms per shader).

const std = @import("std");

const CACHE_ROOT = ".weld-cache/shaders";

/// Lookup key in the cache — hash over (source + defines + glslc_version).
pub const LookupKey = struct {
    source: []const u8,
    defines: []const u8 = "",
    glslc_version: []const u8 = "unknown",
};

/// Result of a lookup — hit with SPIR-V bytes owned by the caller, or miss.
pub const LookupResult = union(enum) {
    hit: []u8,
    miss,
};

/// Cache error set (alias of std.fs errors + alloc + custom).
pub const Error = error{
    OutOfMemory,
    AccessDenied,
    FileTooBig,
    FileNotFound,
    InvalidUtf8,
    NotDir,
    Unexpected,
    StreamTooLong,
    PathAlreadyExists,
    ReadOnlyFileSystem,
    NameTooLong,
    SystemResources,
    NoSpaceLeft,
    InputOutput,
    IsDir,
    SharingViolation,
    PipeBusy,
    InvalidWtf8,
    AntivirusInterference,
    InvalidArgument,
    NotOpenForWriting,
    BadPathName,
    NetworkNotFound,
    DeviceBusy,
    SymLinkLoop,
    ProcessNotFound,
    FileLocksNotSupported,
    FileBusy,
    DiskQuota,
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    PathTooLong,
    OutOfBounds,
    UnsupportedReparsePointType,
    WouldBlock,
    LinkQuotaExceeded,
    ReadOnlyDirectory,
    AlreadyExists,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,
    Canceled,
    LockViolation,
    IncorrectAlignment,
    NoSuchProcess,
};

/// Computes the hash of a lookup key.
pub fn hashKey(key: LookupKey) [40]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key.source);
    sha1.update("|defines:");
    sha1.update(key.defines);
    sha1.update("|glslc:");
    sha1.update(key.glslc_version);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    var hex: [40]u8 = undefined;
    const hex_alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_alphabet[b >> 4];
        hex[i * 2 + 1] = hex_alphabet[b & 0x0F];
    }
    return hex;
}

/// Lookup in the disk cache. Returns `.hit` with the SPIR-V bytes
/// (owned by caller) or `.miss`. Allocation via `allocator`.
///
/// Zig 0.16 API: uses `std.Io.Dir.cwd()` which requires `io: std.Io`.
pub fn lookup(allocator: std.mem.Allocator, io: std.Io, key: LookupKey) Error!LookupResult {
    const hash = hashKey(key);
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.spv", .{ CACHE_ROOT, hash }) catch return error.OutOfMemory;

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .miss;
    defer file.close(io);

    const stat = file.stat(io) catch return .miss;
    const size: usize = @intCast(stat.size);
    if (size == 0) return .miss;

    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    reader.interface.readSliceAll(buf) catch return error.InputOutput;
    return .{ .hit = buf };
}

/// Insert into the disk cache. Creates `.weld-cache/shaders/` if necessary.
pub fn insert(allocator: std.mem.Allocator, io: std.Io, key: LookupKey, spv: []const u8) Error!void {
    _ = allocator;
    const hash = hashKey(key);
    std.Io.Dir.cwd().createDirPath(io, CACHE_ROOT) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.AccessDenied,
    };
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.spv", .{ CACHE_ROOT, hash }) catch return error.OutOfMemory;

    var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return error.AccessDenied;
    defer file.close(io);
    file.writeStreamingAll(io, spv) catch return error.InputOutput;
}

/// Removes the entire cache (debug / clean build). Not exposed in CLI Phase 0.
pub fn clear(allocator: std.mem.Allocator, io: std.Io) Error!void {
    _ = allocator;
    std.Io.Dir.cwd().deleteTree(io, CACHE_ROOT) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return error.AccessDenied,
    };
}

test "cache: hashKey is deterministic and version-sensitive" {
    const t = std.testing;
    const k1 = LookupKey{ .source = "void main() {}", .defines = "FOO=1", .glslc_version = "1.0" };
    const k2 = LookupKey{ .source = "void main() {}", .defines = "FOO=1", .glslc_version = "1.0" };
    const k3 = LookupKey{ .source = "void main() {}", .defines = "FOO=1", .glslc_version = "2.0" };
    const h1 = hashKey(k1);
    const h2 = hashKey(k2);
    const h3 = hashKey(k3);
    try t.expectEqualStrings(&h1, &h2);
    try t.expect(!std.mem.eql(u8, &h1, &h3));
}

test "cache: hashKey changes on source modification" {
    const t = std.testing;
    const k1 = LookupKey{ .source = "abc" };
    const k2 = LookupKey{ .source = "abd" };
    const h1 = hashKey(k1);
    const h2 = hashKey(k2);
    try t.expect(!std.mem.eql(u8, &h1, &h2));
}
