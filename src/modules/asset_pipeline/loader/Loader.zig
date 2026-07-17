//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
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
const hash = @import("../hash.zig");
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
    /// The header failed structural validation (unsupported version, a
    /// section out of bounds / overflowing) or the data-section hash did not
    /// match the header hash (M1.1.1-HF1 / D6).
    MalformedAsset,
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
    // C3 (M1.1.1-HF2): reserve the payload-map slot BEFORE allocating the
    // registry handle, so the post-alloc insert is infallible. Reserve-then-
    // mutate — on the reservation's OOM, free the buffer and return with NO
    // handle allocated, so there is no undischargeable slot. The old order
    // allocated the handle first, then a fallible `payloads.put`; its OOM path
    // tried to unwind via `registry.unload`, but `unload`→`freeSlot` itself
    // allocates and can OOM, and the `catch {}` swallowed it — stranding a live
    // handle with no payload and an already-freed buffer.
    self.payloads.ensureUnusedCapacity(gpa, 1) catch |err| {
        gpa.free(raw.bin);
        return err;
    };
    const handle = self.registry.allocWithUuid(gpa, asset_type, 0) catch |err| switch (err) {
        error.OutOfMemory => {
            gpa.free(raw.bin);
            return error.OutOfMemory;
        },
        // `alloc` reserves a fresh slot; it never validates an existing handle
        // (`StaleHandle`) nor increments a refcount (`ReferenceCountOverflow`).
        error.StaleHandle, error.ReferenceCountOverflow => unreachable,
    };
    // Infallible — capacity reserved above. A fresh handle index is unmapped
    // (unload/reload remove the payload entry), so this inserts, not overwrites.
    self.payloads.putAssumeCapacity(handle.index, .{ .header = raw.header, .bin = raw.bin });
    return handle;
}

/// Blocking convenience: `beginLoad` + `wait` + `finish`. The error set
/// is the explicit named union of its three steps — `std.Io.ConcurrentError`
/// (worker spawn), `LoadError` (the async read: `ReadFailed` /
/// `ShortBuffer` / `BadMagic` / `OutOfMemory`) and `FinishError`
/// (`UnknownAssetType` / `OutOfMemory`). **Pinned**, not inferred, so the
/// frozen contract cannot silently widen when a callee's set changes; a
/// Phase-1 change is a `WELD_ASSET_PIPELINE_PROTOCOL_VERSION` bump
/// (cf. C0.5).
pub fn load(self: *Loader, gpa: std.mem.Allocator, io: std.Io, path: []const u8) (std.Io.ConcurrentError || LoadError || FinishError)!AssetHandle {
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
/// when `handle` is no longer alive; `error.AssetTypeMismatch` when the
/// re-read `.bin`'s category differs from the handle's; otherwise surfaces
/// `LoadError` from the re-read (`readBin`) plus `OutOfMemory` from the
/// payload-map insert. **Pinned** named set
/// `LoadError || error{StaleHandle, AssetTypeMismatch}` (see `load`): a
/// Phase-1 change is a `WELD_ASSET_PIPELINE_PROTOCOL_VERSION` bump (cf. C0.5).
///
/// R7 (M1.1.1-HF3): the re-read `.bin`'s `asset_type` is validated against the
/// slot's `AssetHandle.type_tag` BEFORE any payload mutation — reloading from a
/// `.bin` of a different category is rejected (its bytes freed) instead of
/// serving a mismatched payload under the old handle.
pub fn reload(self: *Loader, gpa: std.mem.Allocator, io: std.Io, handle: AssetHandle, path: []const u8) (LoadError || error{ StaleHandle, AssetTypeMismatch })!void {
    if (!self.registry.isAlive(handle)) return error.StaleHandle;
    const raw = try readBin(gpa, io, self.dir, path);
    // R7: category must match the handle before we touch the payload. Both are
    // the raw 16-bit type tag (`RuntimeHeader.asset_type` / `AssetHandle.type_tag`).
    if (raw.header.asset_type != handle.type_tag) {
        gpa.free(raw.bin);
        return error.AssetTypeMismatch;
    }
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
    // D6: structural validation (version + section bounds) then data-hash
    // integrity. Both map to error.MalformedAsset; `bin`'s errdefer frees it.
    header.validate(bin.len) catch return error.MalformedAsset;
    const data = bin[header.data_offset..][0..header.data_size];
    if (header.hash != hash.u64Of(data)) return error.MalformedAsset;
    return .{ .header = header, .bin = bin };
}

// ─── tests (M1.1.1-HF1 / D6) ────────────────────────────────────────────

test "a malformed .bin loads as error.MalformedAsset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "payload-bytes";

    const H = struct {
        // Assemble [40-byte header][payload] into an owned buffer.
        fn build(a: std.mem.Allocator, header: RuntimeHeader, body: []const u8) ![]u8 {
            const buf = try a.alloc(u8, format.header_size + body.len);
            const hb = header.toBytes();
            @memcpy(buf[0..format.header_size], &hb);
            @memcpy(buf[format.header_size..], body);
            return buf;
        }
        fn writeFile(i: std.Io, dir: std.Io.Dir, name: []const u8, bin: []const u8) !void {
            const file = try dir.createFile(i, name, .{ .truncate = true });
            defer file.close(i);
            try file.writeStreamingAll(i, bin);
        }
    };

    var loader = Loader.init(tmp.dir);
    defer loader.deinit(gpa);

    // A well-formed header used as the template for each corruption.
    const valid = RuntimeHeader.init(.{
        .asset_type = .texture,
        .metadata_offset = format.header_size,
        .metadata_size = 0,
        .data_offset = format.header_size,
        .data_size = payload.len,
        .hash = hash.u64Of(payload),
    });

    // 1. Unsupported header version.
    {
        var h = valid;
        h.version = format.current_version + 1;
        const bin = try H.build(gpa, h, payload);
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "bad_version.bin", bin);
        try std.testing.expectError(error.MalformedAsset, loader.load(gpa, io, "bad_version.bin"));
    }

    // 2. Truncated data section (header claims more data than the file holds).
    {
        var h = valid;
        h.data_size = payload.len + 1000;
        const bin = try H.build(gpa, h, payload);
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "truncated.bin", bin);
        try std.testing.expectError(error.MalformedAsset, loader.load(gpa, io, "truncated.bin"));
    }

    // 3. Out-of-bounds metadata section.
    {
        var h = valid;
        h.metadata_size = 1000;
        const bin = try H.build(gpa, h, payload);
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "oob_meta.bin", bin);
        try std.testing.expectError(error.MalformedAsset, loader.load(gpa, io, "oob_meta.bin"));
    }

    // 4. Wrong data-section hash (structure valid, integrity fails).
    {
        var h = valid;
        h.hash = valid.hash ^ 1;
        const bin = try H.build(gpa, h, payload);
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "bad_hash.bin", bin);
        try std.testing.expectError(error.MalformedAsset, loader.load(gpa, io, "bad_hash.bin"));
    }

    // Positive control: the untouched valid header loads cleanly.
    {
        const bin = try H.build(gpa, valid, payload);
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "valid.bin", bin);
        const handle = try loader.load(gpa, io, "valid.bin");
        try std.testing.expectEqualSlices(u8, payload, loader.get(handle).?);
        try loader.release(gpa, handle);
    }
}

test "finish under payload-reservation OOM allocates no handle and frees the buffer (M1.1.1-HF2 C3)" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var loader = Loader.init(tmp.dir);
    defer loader.deinit(gpa);

    // A completed read: a valid header (known asset_type) + an owned buffer.
    // `finish` stores `raw.header` and takes ownership of `raw.bin`; it does not
    // re-parse the buffer, so its content is irrelevant here.
    const bin = try gpa.alloc(u8, 8);
    @memset(bin, 0);
    const raw: Raw = .{
        .header = RuntimeHeader.init(.{
            .asset_type = .texture,
            .metadata_offset = format.header_size,
            .metadata_size = 0,
            .data_offset = format.header_size,
            .data_size = 0,
            .hash = 0,
        }),
        .bin = bin,
    };

    // Fail the FIRST allocation `finish` makes — the payload-map reservation,
    // which now precedes the registry handle allocation (C3). The buffer must be
    // freed and NO handle allocated. Under the pre-fix code the handle was
    // allocated first, then a `payloads.put` OOM tried to unwind via `unload`
    // (whose `freeSlot` can itself OOM, swallowed by `catch {}`) — stranding a
    // live handle with a freed buffer.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, loader.finish(failing.allocator(), raw));

    // No handle allocated; the buffer was freed (a stranded `bin` would trip the
    // testing allocator's leak detection at scope end).
    try std.testing.expectEqual(@as(usize, 0), loader.registry.liveCount());
}

test "reload with a mismatched asset_type returns AssetTypeMismatch and keeps the old payload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const H = struct {
        fn build(a: std.mem.Allocator, at: format.AssetType, body: []const u8) ![]u8 {
            const header = RuntimeHeader.init(.{
                .asset_type = at,
                .metadata_offset = format.header_size,
                .metadata_size = 0,
                .data_offset = format.header_size,
                .data_size = @intCast(body.len),
                .hash = hash.u64Of(body),
            });
            const buf = try a.alloc(u8, format.header_size + body.len);
            const hb = header.toBytes();
            @memcpy(buf[0..format.header_size], &hb);
            @memcpy(buf[format.header_size..], body);
            return buf;
        }
        fn writeFile(i: std.Io, dir: std.Io.Dir, name: []const u8, bin: []const u8) !void {
            const file = try dir.createFile(i, name, .{ .truncate = true });
            defer file.close(i);
            try file.writeStreamingAll(i, bin);
        }
    };

    var loader = Loader.init(tmp.dir);
    defer loader.deinit(gpa);

    // Load a texture asset.
    const tex_payload = "texture-pixels";
    {
        const bin = try H.build(gpa, .texture, tex_payload);
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "tex.bin", bin);
    }
    const handle = try loader.load(gpa, io, "tex.bin");
    defer loader.release(gpa, handle) catch {};
    try std.testing.expectEqualSlices(u8, tex_payload, loader.get(handle).?);

    // Write a .bin of a DIFFERENT category (mesh) and reload the texture handle
    // from it — R7 rejects the category mismatch before swapping the payload.
    {
        const bin = try H.build(gpa, .mesh, "mesh-verts");
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "mesh.bin", bin);
    }
    try std.testing.expectError(error.AssetTypeMismatch, loader.reload(gpa, io, handle, "mesh.bin"));

    // The old texture payload is untouched — the reject happened before any swap.
    try std.testing.expectEqualSlices(u8, tex_payload, loader.get(handle).?);

    // A same-category reload still succeeds.
    {
        const bin = try H.build(gpa, .texture, "new-pixels");
        defer gpa.free(bin);
        try H.writeFile(io, tmp.dir, "tex2.bin", bin);
    }
    try loader.reload(gpa, io, handle, "tex2.bin");
    try std.testing.expectEqualSlices(u8, "new-pixels", loader.get(handle).?);
}
