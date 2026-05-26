//! Shader cache disque — Phase 0 / M0.4.
//!
//! Hash sur `(source + defines + glslc_version)` (brief §Scope). Phase 0 :
//! cache stocké sous `.weld-cache/shaders/<hash>.spv`. Lookup → `LoadResult.hit`
//! avec les bytes SPIR-V ; miss → caller compile + insert.
//!
//! Format hash : SHA-1 hex (160 bits → 40 char). Phase 1+ : passer à
//! blake3 si profilo justifie (le hash n'est pas critique perf — quelques
//! ms par shader).

const std = @import("std");

const CACHE_ROOT = ".weld-cache/shaders";

/// Clé de lookup dans le cache — hash sur (source + defines + glslc_version).
pub const LookupKey = struct {
    source: []const u8,
    defines: []const u8 = "",
    glslc_version: []const u8 = "unknown",
};

/// Résultat d'un lookup — hit avec bytes SPIR-V owned par le caller, ou miss.
pub const LookupResult = union(enum) {
    hit: []u8,
    miss,
};

/// Set d'erreurs du cache (alias des erreurs std.fs + alloc + custom).
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

/// Calcule le hash d'une clé de lookup.
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
    _ = std.fmt.bufPrint(&hex, "{x}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return hex;
}

/// Lookup dans le cache disque. Retourne `.hit` avec les bytes SPIR-V
/// (owned by caller) ou `.miss`. Allocation via `allocator`.
pub fn lookup(allocator: std.mem.Allocator, key: LookupKey) Error!LookupResult {
    const hash = hashKey(key);
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.spv", .{ CACHE_ROOT, hash }) catch return error.OutOfMemory;

    const file = std.fs.cwd().openFile(path, .{}) catch return .miss;
    defer file.close();

    const stat = file.stat() catch return .miss;
    const size: usize = @intCast(stat.size);
    if (size == 0) return .miss;

    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    const n = file.readAll(buf) catch return error.InputOutput;
    if (n != size) return .miss;
    return .{ .hit = buf };
}

/// Insert dans le cache disque. Crée `.weld-cache/shaders/` si nécessaire.
pub fn insert(allocator: std.mem.Allocator, key: LookupKey, spv: []const u8) Error!void {
    _ = allocator;
    const hash = hashKey(key);
    std.fs.cwd().makePath(CACHE_ROOT) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.AccessDenied,
    };
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.spv", .{ CACHE_ROOT, hash }) catch return error.OutOfMemory;

    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return error.AccessDenied;
    defer file.close();
    file.writeAll(spv) catch return error.InputOutput;
}

/// Supprime tout le cache (debug / clean build). Pas exposé en CLI Phase 0.
pub fn clear(allocator: std.mem.Allocator) Error!void {
    _ = allocator;
    std.fs.cwd().deleteTree(CACHE_ROOT) catch |e| switch (e) {
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
