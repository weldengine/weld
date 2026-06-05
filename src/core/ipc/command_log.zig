//! Editor-side command log for best-effort replay after a runtime crash
//! (`engine-ipc.md` §7, `engine-tools-editor.md` §2.7.3). A fixed-capacity
//! ring of the editor→runtime commands sent, each retaining its encoded
//! frame so it can be re-sent verbatim to a freshly restarted runtime.
//!
//! `last_clean_line` is advanced to the current head when a `SaveProject`
//! ack (`ProjectSaved`) arrives — everything appended up to that point is
//! durable on disk (the runtime's minimal snapshot, §7.1) and need not be
//! replayed. After a crash + restart the editor replays the entries since
//! `last_clean_line` that the runtime never acked (§7.2). No idempotence
//! is attempted (§7.3): a replay that nacks or times out stops hard.
//!
//! M0.7 scope: this is the IPC-replay materialization the brief E4 calls
//! for. The richer Islandz `Command` model (`engine-tools-editor.md`
//! §2.4) is Phase 2 — here an entry is just the wire frame + status.

const std = @import("std");

/// Ring capacity (`engine-tools-editor.md` §2.7.3). The oldest entry is
/// FIFO-dropped once exceeded.
pub const capacity: usize = 1024;

/// Max encoded-frame bytes retained per entry. The largest editor→runtime
/// command frame is `LoadScene` / `SaveScene` at `16 + 8 + 256 = 280` B;
/// 512 leaves headroom for future commands without resizing the ring.
pub const max_frame_bytes: usize = 512;

/// Lifecycle of a logged command relative to the runtime.
pub const EntryStatus = enum(u8) { pending, acked, nacked };

/// One logged command. `frame` holds the full encoded frame exactly as
/// sent, so replay re-sends it byte-for-byte (same `seq_id`).
pub const Entry = struct {
    seq_id: u32,
    msg_type: u16,
    status: EntryStatus,
    issued_at_us: u64,
    /// 0 until `markAcked`.
    acked_at_us: u64,
    frame_len: u32,
    frame: [max_frame_bytes]u8,

    /// The encoded frame as sent, ready to re-send verbatim on replay.
    pub fn frameBytes(self: *const Entry) []const u8 {
        return self.frame[0..self.frame_len];
    }
};

/// Errors raised by `CommandLog` operations.
pub const Error = error{FrameTooLarge} || std.mem.Allocator.Error;

/// Ring of `capacity` command entries plus the `last_clean_line` anchor.
/// `head` is the monotone count of commands ever appended; ring slot is
/// `head % capacity`. Entries older than `head - capacity` are gone.
pub const CommandLog = struct {
    gpa: std.mem.Allocator,
    entries: []Entry,
    head: u64 = 0,
    last_clean_line: u64 = 0,

    /// Allocate the ring. Caller owns it; pair with `deinit`.
    pub fn init(gpa: std.mem.Allocator) Error!CommandLog {
        const entries = try gpa.alloc(Entry, capacity);
        return .{ .gpa = gpa, .entries = entries };
    }

    /// Free the ring and poison the value.
    pub fn deinit(self: *CommandLog) void {
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    /// Record a sent command. FIFO: once `capacity` is exceeded the oldest
    /// entry is overwritten. `frame` is the full encoded frame as sent.
    pub fn append(
        self: *CommandLog,
        seq_id: u32,
        msg_type: u16,
        frame: []const u8,
        now_us: u64,
    ) Error!void {
        if (frame.len > max_frame_bytes) return error.FrameTooLarge;
        const e = &self.entries[self.head % capacity];
        e.seq_id = seq_id;
        e.msg_type = msg_type;
        e.status = .pending;
        e.issued_at_us = now_us;
        e.acked_at_us = 0;
        e.frame_len = @intCast(frame.len);
        @memcpy(e.frame[0..frame.len], frame);
        self.head += 1;
    }

    /// Index of the oldest still-retained entry; entries before it were
    /// FIFO-dropped.
    fn oldestRetained(self: *const CommandLog) u64 {
        return if (self.head > capacity) self.head - capacity else 0;
    }

    /// Mark the pending entry carrying `seq_id` as acked. No-op if it is
    /// not in the retained window (already dropped / unknown seq).
    pub fn markAcked(self: *CommandLog, seq_id: u32, now_us: u64) void {
        var i = self.oldestRetained();
        while (i < self.head) : (i += 1) {
            const e = &self.entries[i % capacity];
            if (e.seq_id == seq_id and e.status == .pending) {
                e.status = .acked;
                e.acked_at_us = now_us;
                return;
            }
        }
    }

    /// Mark the pending entry carrying `seq_id` as nacked (runtime refused).
    pub fn markNacked(self: *CommandLog, seq_id: u32) void {
        var i = self.oldestRetained();
        while (i < self.head) : (i += 1) {
            const e = &self.entries[i % capacity];
            if (e.seq_id == seq_id and e.status == .pending) {
                e.status = .nacked;
                return;
            }
        }
    }

    /// Advance `last_clean_line` to the current head — call when the
    /// `ProjectSaved` ack arrives (§7.1). Everything appended so far is
    /// now durable and excluded from replay.
    pub fn markCleanLine(self: *CommandLog) void {
        self.last_clean_line = self.head;
    }

    /// True when a command appended after the last clean line has been
    /// FIFO-dropped (the ring overflowed since the last save). Those are
    /// unrecoverable for replay; the editor warns the user (§7.1).
    pub fn droppedUnsaved(self: *const CommandLog) bool {
        return self.oldestRetained() > self.last_clean_line;
    }

    /// Iterator over the entries to replay after a crash: those appended
    /// since `last_clean_line` and still `pending` (never acked/nacked),
    /// in send order, clamped to the retained window.
    pub const ReplayIterator = struct {
        log: *const CommandLog,
        i: u64,

        /// Next pending entry to replay, or `null` when exhausted.
        pub fn next(self: *ReplayIterator) ?*const Entry {
            while (self.i < self.log.head) {
                const e = &self.log.entries[self.i % capacity];
                self.i += 1;
                if (e.status == .pending) return e;
            }
            return null;
        }
    };

    /// Iterator over the commands to replay after a crash (pending,
    /// appended since `last_clean_line`, in send order).
    pub fn replaySince(self: *const CommandLog) ReplayIterator {
        return .{ .log = self, .i = @max(self.last_clean_line, self.oldestRetained()) };
    }
};

// ---------------------------------------------------------------- tests --

fn dummyFrame(seq: u32) [16]u8 {
    var f: [16]u8 = undefined;
    std.mem.writeInt(u32, f[0..4], 0x57454C44, .little); // 'WELD'
    std.mem.writeInt(u32, f[4..8], seq, .little);
    @memset(f[8..], 0);
    return f;
}

test "append records a pending entry with the frame bytes" {
    var log = try CommandLog.init(std.testing.allocator);
    defer log.deinit();

    const f = dummyFrame(7);
    try log.append(7, 5, &f, 1000);
    try std.testing.expectEqual(@as(u64, 1), log.head);

    var it = log.replaySince();
    const e = it.next().?;
    try std.testing.expectEqual(@as(u32, 7), e.seq_id);
    try std.testing.expectEqual(@as(u16, 5), e.msg_type);
    try std.testing.expectEqual(EntryStatus.pending, e.status);
    try std.testing.expectEqualSlices(u8, &f, e.frameBytes());
    try std.testing.expect(it.next() == null);
}

test "append rejects an over-large frame" {
    var log = try CommandLog.init(std.testing.allocator);
    defer log.deinit();
    const big = [_]u8{0} ** (max_frame_bytes + 1);
    try std.testing.expectError(error.FrameTooLarge, log.append(1, 1, &big, 0));
}

test "acked entries are excluded from replay" {
    var log = try CommandLog.init(std.testing.allocator);
    defer log.deinit();

    const f1 = dummyFrame(1);
    const f2 = dummyFrame(2);
    try log.append(1, 5, &f1, 100);
    try log.append(2, 5, &f2, 200);
    log.markAcked(1, 150);

    var it = log.replaySince();
    const e = it.next().?;
    try std.testing.expectEqual(@as(u32, 2), e.seq_id); // only the unacked one
    try std.testing.expect(it.next() == null);
}

test "markCleanLine excludes pre-save commands from replay" {
    var log = try CommandLog.init(std.testing.allocator);
    defer log.deinit();

    const a = dummyFrame(1);
    const b = dummyFrame(2);
    const c = dummyFrame(3);
    try log.append(1, 5, &a, 1); // before save (e.g. acked by ProjectSaved chain)
    try log.append(2, 21, &b, 2); // SaveProject itself
    log.markCleanLine(); // ProjectSaved ack arrived
    try log.append(3, 5, &c, 3); // after save — the only replayable one

    var it = log.replaySince();
    const e = it.next().?;
    try std.testing.expectEqual(@as(u32, 3), e.seq_id);
    try std.testing.expect(it.next() == null);
}

test "ring overflow FIFO-drops oldest and flags dropped-unsaved" {
    var log = try CommandLog.init(std.testing.allocator);
    defer log.deinit();

    // Fill past capacity: append capacity + 5 commands, never saving.
    var i: u32 = 0;
    while (i < capacity + 5) : (i += 1) {
        const f = dummyFrame(i);
        try log.append(i, 5, &f, i);
    }
    try std.testing.expectEqual(@as(u64, capacity + 5), log.head);
    // last_clean_line is still 0 but the first 5 entries were dropped.
    try std.testing.expect(log.droppedUnsaved());

    // Replay yields exactly the retained `capacity` entries, oldest first.
    var it = log.replaySince();
    const first = it.next().?;
    try std.testing.expectEqual(@as(u32, 5), first.seq_id); // 0..4 dropped
    var count: usize = 1;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(capacity, count);
}

test "nacked entries are excluded from replay" {
    var log = try CommandLog.init(std.testing.allocator);
    defer log.deinit();
    const f = dummyFrame(9);
    try log.append(9, 5, &f, 0);
    log.markNacked(9);
    var it = log.replaySince();
    try std.testing.expect(it.next() == null);
}
