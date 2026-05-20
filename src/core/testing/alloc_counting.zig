//! Counting allocator wrapper. Forwards every `alloc` / `resize` / `remap` /
//! `free` to a backing allocator and increments atomic counters in the
//! process. Used by the S1 no-allocation test (asserts the steady-state
//! simulation loop performs zero allocations after init) and by the bench
//! harness (records the allocator activity during a measurement window).
//!
//! Counters are 64-bit atomic so the wrapper can be installed in front of a
//! shared allocator while multiple worker threads operate on it. The bench
//! takes a single thread reading them, but tests may exercise concurrent
//! paths.

const std = @import("std");

/// Allocator wrapper that counts every alloc / free / resize call.
/// Used by `no_alloc_in_simulation_test` to assert zero-allocation
/// steady state on the ECS hot path.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_count: std.atomic.Value(u64) = .init(0),
    free_count: std.atomic.Value(u64) = .init(0),
    resize_ok_count: std.atomic.Value(u64) = .init(0),
    resize_fail_count: std.atomic.Value(u64) = .init(0),
    remap_count: std.atomic.Value(u64) = .init(0),
    bytes_allocated: std.atomic.Value(u64) = .init(0),
    bytes_freed: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct {
        alloc_count: u64,
        free_count: u64,
        resize_ok_count: u64,
        resize_fail_count: u64,
        remap_count: u64,
        bytes_allocated: u64,
        bytes_freed: u64,
    };

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn snapshot(self: *const CountingAllocator) Snapshot {
        return .{
            .alloc_count = self.alloc_count.load(.acquire),
            .free_count = self.free_count.load(.acquire),
            .resize_ok_count = self.resize_ok_count.load(.acquire),
            .resize_fail_count = self.resize_fail_count.load(.acquire),
            .remap_count = self.remap_count.load(.acquire),
            .bytes_allocated = self.bytes_allocated.load(.acquire),
            .bytes_freed = self.bytes_freed.load(.acquire),
        };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.alloc_count.store(0, .release);
        self.free_count.store(0, .release);
        self.resize_ok_count.store(0, .release);
        self.resize_fail_count.store(0, .release);
        self.remap_count.store(0, .release);
        self.bytes_allocated.store(0, .release);
        self.bytes_freed.store(0, .release);
    }

    /// Difference between two snapshots, useful for measuring activity over
    /// a window (`after.delta(before)`).
    pub fn delta(after: Snapshot, before: Snapshot) Snapshot {
        return .{
            .alloc_count = after.alloc_count - before.alloc_count,
            .free_count = after.free_count - before.free_count,
            .resize_ok_count = after.resize_ok_count - before.resize_ok_count,
            .resize_fail_count = after.resize_fail_count - before.resize_fail_count,
            .remap_count = after.remap_count - before.remap_count,
            .bytes_allocated = after.bytes_allocated - before.bytes_allocated,
            .bytes_freed = after.bytes_freed - before.bytes_freed,
        };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = vtAlloc,
        .resize = vtResize,
        .remap = vtRemap,
        .free = vtFree,
    };

    fn vtAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            _ = self.alloc_count.fetchAdd(1, .acq_rel);
            _ = self.bytes_allocated.fetchAdd(len, .acq_rel);
        }
        return result;
    }

    fn vtResize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            _ = self.resize_ok_count.fetchAdd(1, .acq_rel);
            if (new_len > memory.len) {
                _ = self.bytes_allocated.fetchAdd(new_len - memory.len, .acq_rel);
            } else {
                _ = self.bytes_freed.fetchAdd(memory.len - new_len, .acq_rel);
            }
        } else {
            _ = self.resize_fail_count.fetchAdd(1, .acq_rel);
        }
        return ok;
    }

    fn vtRemap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            _ = self.remap_count.fetchAdd(1, .acq_rel);
        }
        return result;
    }

    fn vtFree(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        _ = self.free_count.fetchAdd(1, .acq_rel);
        _ = self.bytes_freed.fetchAdd(memory.len, .acq_rel);
    }
};
