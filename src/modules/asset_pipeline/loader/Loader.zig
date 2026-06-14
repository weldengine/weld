//! Async runtime asset loader + lifecycle (M0.6 / E5).
//!
//! Loads a cooked `.<type>.bin` off the main thread and tracks its lifetime
//! through the E1 `Registry`. `beginLoad` spawns the file read on a worker
//! via `io.concurrent` (the §8 "worker thread + async I/O" path); the caller
//! polls `Pending.ready()` and ticks its own loop meanwhile — the load never
//! blocks the main thread. `finish` registers the result (main thread, the
//! registry is single-threaded). `load` is the blocking convenience.
//!
//! Lifecycle (brief §E5): `load → alloc` (uuid 0 at runtime — the `.bin`
//! carries no uuid in M0.6); `retain`/`release` for refcount (release at 0
//! unloads + frees the payload); `unload` is the forced path reserved for
//! hot-reload / eviction; `reload` re-reads and swaps the payload in place.
//!
//! Byte order: the header is parsed with the portable `RuntimeHeader.read`
//! (explicit little-endian). M0.6 does NOT take the zero-copy `@ptrCast` /
//! mmap path, so `RuntimeHeader.read` remains the single byte-order site (the
//! E1 note holds). A future zero-copy mmap path would add a SECOND
//! byte-order-dependent path — correct on the LE Phase 0 targets, but it
//! means `read` is not the universal single byte-swap point once that path
//! exists. The two would coexist; neither is claimed as the sole authority.
//!
//! The Tier 0 Chase-Lev job system is deliberately NOT used: its public
//! surface is ECS-chunk-shaped and using it here would require widening it
//! (a Case 2 blocker per the brief). `std.Io` async is the §8-prescribed,
//! surface-neutral mechanism.

const std = @import("std");
const format = @import("../format/root.zig");
const registry_mod = @import("../registry/root.zig");

const Loader = @This();
const Registry = registry_mod.Registry;
const AssetHandle = registry_mod.AssetHandle;
const RuntimeHeader = format.RuntimeHeader;

/// Base directory cooked `.bin` files are read from.
dir: std.Io.Dir,
/// Identity / refcount / generation table.
registry: Registry,
/// Loaded payloads keyed by `AssetHandle.index`.
payloads: std.AutoHashMapUnmanaged(u32, Payload),

const Payload = struct {
    header: RuntimeHeader,
    /// The whole `.bin` (owned); `data`/`metadata` are slices into it.
    bin: []u8,
};

/// Errors from the async read task (a concrete set so it can ride a Future).
pub const LoadError = error{
    /// Opening / stat-ing / reading the file failed.
    ReadFailed,
    /// The `.bin` was shorter than the 40-byte header.
    ShortBuffer,
    /// The `.bin` did not start with the `WELD` magic.
    BadMagic,
    /// Allocation failed.
    OutOfMemory,
};

/// Errors from registering a completed read into the registry.
pub const FinishError = error{
    /// The header `asset_type` is not a known `AssetType`.
    UnknownAssetType,
    /// Allocation failed.
    OutOfMemory,
};

/// A read produced by the async task: the parsed header + the owned `.bin`.
pub const Raw = struct {
    header: RuntimeHeader,
    bin: []u8,
};

/// A load in flight. Poll `ready()`; collect with `wait()`; abandon with
/// `cancel()`. The `path` passed to `beginLoad` must outlive the `Pending`.
pub const Pending = struct {
    future: std.Io.Future(LoadError!Raw),
    done: *std.atomic.Value(bool),
    gpa: std.mem.Allocator,

    /// Non-blocking: true once the worker has finished (success or error).
    pub fn ready(self: *const Pending) bool {
        return self.done.load(.acquire);
    }

    /// Block until the read completes and return its result. Releases the
    /// done flag. Call exactly once (mutually exclusive with `cancel`).
    pub fn wait(self: *Pending, io: std.Io) LoadError!Raw {
        const result = self.future.await(io);
        self.gpa.destroy(self.done);
        return result;
    }

    /// Abandon the load (teardown path): await it, free any produced buffer,
    /// release the done flag.
    pub fn cancel(self: *Pending, io: std.Io) void {
        if (self.future.cancel(io)) |raw| {
            self.gpa.free(raw.bin);
        } else |_| {}
        self.gpa.destroy(self.done);
    }
};

/// Create an empty loader reading from `dir`.
pub fn init(dir: std.Io.Dir) Loader {
    return .{ .dir = dir, .registry = Registry.init(), .payloads = .empty };
}

/// Free all loaded payloads + the registry, and poison `self`.
pub fn deinit(self: *Loader, gpa: std.mem.Allocator) void {
    var it = self.payloads.valueIterator();
    while (it.next()) |p| gpa.free(p.bin);
    self.payloads.deinit(gpa);
    self.registry.deinit(gpa);
    self.* = undefined;
}

/// Start an asynchronous read of `path` on a worker. Returns immediately —
/// the caller's loop keeps ticking. `path` must outlive the `Pending`.
pub fn beginLoad(self: *Loader, gpa: std.mem.Allocator, io: std.Io, path: []const u8) (std.Io.ConcurrentError || error{OutOfMemory})!Pending {
    const done = try gpa.create(std.atomic.Value(bool));
    done.* = std.atomic.Value(bool).init(false);
    errdefer gpa.destroy(done);
    const future = try io.concurrent(loadTask, .{ gpa, io, self.dir, path, done });
    return .{ .future = future, .done = done, .gpa = gpa };
}

/// Register a completed read into the registry and take ownership of its
/// buffer. Returns the asset handle. (Main thread — the registry is
/// single-threaded.)
pub fn finish(self: *Loader, gpa: std.mem.Allocator, raw: Raw) FinishError!AssetHandle {
    const asset_type = raw.header.assetType() orelse {
        gpa.free(raw.bin);
        return error.UnknownAssetType;
    };
    const handle = self.registry.allocWithUuid(gpa, asset_type, 0) catch |err| switch (err) {
        error.OutOfMemory => {
            gpa.free(raw.bin);
            return error.OutOfMemory;
        },
        // `alloc` reserves a fresh slot; it never validates an existing handle.
        error.StaleHandle => unreachable,
    };
    self.payloads.put(gpa, handle.index, .{ .header = raw.header, .bin = raw.bin }) catch |err| {
        gpa.free(raw.bin);
        self.registry.unload(gpa, handle) catch {};
        return err;
    };
    return handle;
}

/// Blocking convenience: `beginLoad` + `wait` + `finish`. The error set
/// is inferred — the union of `std.Io.ConcurrentError` (worker spawn),
/// `LoadError` (the async read: `ReadFailed` / `ShortBuffer` /
/// `BadMagic` / `OutOfMemory`) and `FinishError` (`UnknownAssetType` /
/// `OutOfMemory`). Phase 0 leaves it inferred rather than a named set; a
/// Phase-1 change to any constituent is a
/// `WELD_ASSET_PIPELINE_PROTOCOL_VERSION` bump (cf. C0.5).
pub fn load(self: *Loader, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !AssetHandle {
    var pending = try self.beginLoad(gpa, io, path);
    const raw = try pending.wait(io);
    return self.finish(gpa, raw);
}

/// The bulk data slice of a loaded asset, or null if the handle is stale /
/// unknown.
pub fn get(self: *const Loader, handle: AssetHandle) ?[]const u8 {
    if (!self.registry.isAlive(handle)) return null;
    const p = self.payloads.get(handle.index) orelse return null;
    return p.bin[p.header.data_offset..][0..p.header.data_size];
}

/// The parsed header of a loaded asset, or null if stale / unknown.
pub fn headerOf(self: *const Loader, handle: AssetHandle) ?RuntimeHeader {
    if (!self.registry.isAlive(handle)) return null;
    const p = self.payloads.get(handle.index) orelse return null;
    return p.header;
}

/// Add a strong reference.
pub fn retain(self: *Loader, handle: AssetHandle) Registry.Error!void {
    return self.registry.retain(handle);
}

/// Drop a strong reference; at refcount 0 the asset unloads and its payload
/// is freed.
pub fn release(self: *Loader, gpa: std.mem.Allocator, handle: AssetHandle) Registry.Error!void {
    try self.registry.release(gpa, handle);
    if (!self.registry.isAlive(handle)) self.freePayload(gpa, handle.index);
}

/// Force-unload (hot-reload / eviction): drop the slot regardless of
/// refcount and free the payload.
pub fn unload(self: *Loader, gpa: std.mem.Allocator, handle: AssetHandle) Registry.Error!void {
    try self.registry.unload(gpa, handle);
    self.freePayload(gpa, handle.index);
}

/// Hot-reload: re-read `path` and swap the payload in place. The handle,
/// generation, and refcount are preserved. Returns `error.StaleHandle`
/// when `handle` is no longer alive; otherwise surfaces `LoadError` from
/// the re-read (`readBin`) plus `OutOfMemory` from the payload-map
/// insert. Inferred error set (see `load`): a Phase-1 change is a
/// `WELD_ASSET_PIPELINE_PROTOCOL_VERSION` bump (cf. C0.5).
///
/// Known Phase-0 limitation: the re-read `.bin`'s `asset_type` is not
/// re-validated against the slot's `AssetHandle.type_tag`, so reloading
/// from a `.bin` of a different category serves a mismatched payload
/// under the old handle. A typed `error.AssetTypeMismatch` is the
/// additive Phase-1 fix.
pub fn reload(self: *Loader, gpa: std.mem.Allocator, io: std.Io, handle: AssetHandle, path: []const u8) !void {
    if (!self.registry.isAlive(handle)) return error.StaleHandle;
    const raw = try readBin(gpa, io, self.dir, path);
    if (self.payloads.getPtr(handle.index)) |p| {
        gpa.free(p.bin);
        p.* = .{ .header = raw.header, .bin = raw.bin };
    } else {
        self.payloads.put(gpa, handle.index, .{ .header = raw.header, .bin = raw.bin }) catch |err| {
            gpa.free(raw.bin);
            return err;
        };
    }
}

fn freePayload(self: *Loader, gpa: std.mem.Allocator, index: u32) void {
    if (self.payloads.fetchRemove(index)) |kv| gpa.free(kv.value.bin);
}

fn loadTask(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, done: *std.atomic.Value(bool)) LoadError!Raw {
    defer done.store(true, .release);
    return readBin(gpa, io, dir, path);
}

fn readBin(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) LoadError!Raw {
    const file = dir.openFile(io, path, .{}) catch return error.ReadFailed;
    defer file.close(io);
    const stat = file.stat(io) catch return error.ReadFailed;
    const size: usize = @intCast(stat.size);

    const bin = gpa.alloc(u8, size) catch return error.OutOfMemory;
    errdefer gpa.free(bin);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var off: usize = 0;
    while (off < size) {
        const n = reader.interface.readSliceShort(bin[off..]) catch return error.ReadFailed;
        if (n == 0) break;
        off += n;
    }
    if (off != size) return error.ReadFailed;

    const header = try RuntimeHeader.read(bin); // portable LE parse
    return .{ .header = header, .bin = bin };
}
