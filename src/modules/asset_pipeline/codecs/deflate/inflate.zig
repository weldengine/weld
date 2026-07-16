//! RFC 1951 DEFLATE inflate — native, from scratch, table-driven Huffman.
//!
//! Written from the RFC and the structure of `puff.c` (Mark Adler) / miniz;
//! no `std.compress.flate` code adapted. Target class is "correct +
//! table-driven", **not** zlib-ng (no 64-bit refill, no SIMD copy fast
//! paths). Rationale (brief §Notes): API stability across Zig `std` churn
//! and an owned, homogeneous codec surface for PNG (and later EXR) — not
//! performance; decode runs once at cook time.
//!
//! Supports all three block types: stored (BTYPE 00), fixed Huffman (01),
//! and dynamic Huffman (10). The whole decoded output is kept in one growing
//! buffer, so LZ77 back-references index directly into it (no 32 KiB ring).

const std = @import("std");

/// Errors raised by `inflate`.
pub const Error = error{
    /// Input ended before the stream was complete.
    UnexpectedEnd,
    /// Reserved block type (BTYPE = 11).
    BadBlockType,
    /// Stored-block length check (`LEN == ~NLEN`) failed.
    BadStoredLength,
    /// A bit pattern matched no Huffman code.
    BadHuffmanCode,
    /// A literal/length symbol outside the valid range.
    BadSymbol,
    /// A back-reference distance reaches before the start of output.
    DistanceTooFar,
    /// A Huffman code length exceeded 15 bits.
    OversizedCode,
    /// The decompressed output would exceed the caller's `max_out` budget — a
    /// decompression bomb, or a stream inconsistent with the expected size
    /// (R3, M1.1.1-HF3). The output buffer never grows past `max_out`.
    OutputLimitExceeded,
    /// Allocation failed.
    OutOfMemory,
};

// RFC 1951 §3.2.5 — length codes 257..285.
const length_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [_]u3{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

// RFC 1951 §3.2.5 — distance codes 0..29.
const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [_]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

// RFC 1951 §3.2.7 — order the code-length code lengths are stored in.
const cl_order = [_]u5{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

const max_code_len = 15;

/// LSB-first bit reader over the compressed input.
const BitReader = struct {
    src: []const u8,
    byte_pos: usize = 0,
    bit_buf: u32 = 0,
    bit_count: u32 = 0,

    fn fill(self: *BitReader, need: u32) void {
        while (self.bit_count < need and self.byte_pos < self.src.len) {
            self.bit_buf |= std.math.shl(u32, self.src[self.byte_pos], self.bit_count);
            self.byte_pos += 1;
            self.bit_count += 8;
        }
    }

    /// Consume `n` bits (n ≤ 16), LSB-first. Errors if the input is exhausted.
    fn take(self: *BitReader, n: u32) Error!u32 {
        self.fill(n);
        if (self.bit_count < n) return error.UnexpectedEnd;
        const mask = std.math.shl(u32, 1, n) -% 1;
        const v = self.bit_buf & mask;
        self.bit_buf = std.math.shr(u32, self.bit_buf, n);
        self.bit_count -= n;
        return v;
    }

    /// Look at the next `n` bits without consuming (zero-filled past EOF).
    fn peek(self: *BitReader, n: u32) u32 {
        self.fill(n);
        const mask = std.math.shl(u32, 1, n) -% 1;
        return self.bit_buf & mask;
    }

    fn drop(self: *BitReader, n: u32) void {
        self.bit_buf = std.math.shr(u32, self.bit_buf, n);
        self.bit_count -= n;
    }

    fn alignToByte(self: *BitReader) void {
        const rem = self.bit_count % 8;
        self.drop(rem);
    }
};

/// Single-level canonical Huffman decode table. `table[bits]` (the next
/// `max_len` stream bits, LSB-first) yields the symbol and its code length.
const HuffmanTable = struct {
    table: []Entry,
    max_len: u32,

    const Entry = struct { symbol: u16 = 0, len: u8 = 0 };

    fn build(gpa: std.mem.Allocator, code_lengths: []const u8) Error!HuffmanTable {
        var bl_count = [_]u16{0} ** (max_code_len + 1);
        var max_len: u32 = 0;
        for (code_lengths) |l| {
            if (l > max_code_len) return error.OversizedCode;
            if (l > 0) {
                bl_count[l] += 1;
                if (l > max_len) max_len = l;
            }
        }
        if (max_len == 0) {
            // No codes — an empty (unused) table. One zero entry so `decode`
            // reports `BadHuffmanCode` if it is ever consulted.
            const empty = try gpa.alloc(Entry, 1);
            empty[0] = .{};
            return .{ .table = empty, .max_len = 0 };
        }

        // Canonical first code per length (RFC 1951 §3.2.2).
        var next_code = [_]u16{0} ** (max_code_len + 1);
        var code: u16 = 0;
        var bits: u32 = 1;
        while (bits <= max_len) : (bits += 1) {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = code;
        }

        const size = std.math.shl(usize, 1, max_len);
        const table = try gpa.alloc(Entry, size);
        @memset(table, .{});

        for (code_lengths, 0..) |l, sym| {
            if (l == 0) continue;
            const canonical = next_code[l];
            next_code[l] += 1;
            const reversed = bitReverse(canonical, l);
            // Fill every max_len-bit pattern whose low `l` bits are `reversed`.
            var slot: usize = reversed;
            const stride = std.math.shl(usize, 1, l);
            while (slot < size) : (slot += stride) {
                table[slot] = .{ .symbol = @intCast(sym), .len = @intCast(l) };
            }
        }
        return .{ .table = table, .max_len = max_len };
    }

    fn deinit(self: *HuffmanTable, gpa: std.mem.Allocator) void {
        gpa.free(self.table);
        self.* = undefined;
    }

    fn decode(self: *const HuffmanTable, br: *BitReader) Error!u16 {
        const bits = br.peek(self.max_len);
        const entry = self.table[bits];
        if (entry.len == 0) return error.BadHuffmanCode;
        if (entry.len > br.bit_count) return error.UnexpectedEnd;
        br.drop(entry.len);
        return entry.symbol;
    }
};

fn bitReverse(value: u16, len: u32) u16 {
    var v = value;
    var r: u16 = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

/// Append `byte` to `out`, enforcing the `max_out` output budget FIRST so the
/// buffer never grows past it (R3, M1.1.1-HF3): a decompression bomb is stopped
/// at the ceiling instead of exhausting memory. The single write choke point
/// for every block type.
fn appendByte(gpa: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8, max_out: usize) Error!void {
    if (out.items.len >= max_out) return error.OutputLimitExceeded;
    try out.append(gpa, byte);
}

/// Inflate a raw DEFLATE (RFC 1951) stream into a freshly allocated,
/// caller-owned byte slice. `max_out` bounds the decompressed size: production
/// beyond it is `error.OutputLimitExceeded` and the buffer never exceeds it (the
/// caller — the PNG codec — computes the exact expected size from IHDR).
pub fn inflate(gpa: std.mem.Allocator, src: []const u8, max_out: usize) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var br = BitReader{ .src = src };
    while (true) {
        const bfinal = try br.take(1);
        const btype = try br.take(2);
        switch (btype) {
            0 => try inflateStored(&br, &out, gpa, max_out),
            1 => try inflateFixed(gpa, &br, &out, max_out),
            2 => try inflateDynamic(gpa, &br, &out, max_out),
            else => return error.BadBlockType,
        }
        if (bfinal == 1) break;
    }
    return out.toOwnedSlice(gpa);
}

fn inflateStored(br: *BitReader, out: *std.ArrayList(u8), gpa: std.mem.Allocator, max_out: usize) Error!void {
    br.alignToByte();
    const len: u16 = @intCast(try br.take(16));
    const nlen: u16 = @intCast(try br.take(16));
    if (len != ~nlen) return error.BadStoredLength;
    var i: u16 = 0;
    while (i < len) : (i += 1) {
        const byte: u8 = @intCast(try br.take(8));
        try appendByte(gpa, out, byte, max_out);
    }
}

fn inflateFixed(gpa: std.mem.Allocator, br: *BitReader, out: *std.ArrayList(u8), max_out: usize) Error!void {
    // RFC 1951 §3.2.6 — fixed code lengths.
    var litlen_lengths = [_]u8{0} ** 288;
    for (0..288) |i| {
        litlen_lengths[i] = if (i < 144) 8 else if (i < 256) 9 else if (i < 280) 7 else 8;
    }
    const dist_lengths = [_]u8{5} ** 30;

    var litlen = try HuffmanTable.build(gpa, &litlen_lengths);
    defer litlen.deinit(gpa);
    var dist = try HuffmanTable.build(gpa, &dist_lengths);
    defer dist.deinit(gpa);
    try decodeBlock(gpa, br, out, &litlen, &dist, max_out);
}

fn inflateDynamic(gpa: std.mem.Allocator, br: *BitReader, out: *std.ArrayList(u8), max_out: usize) Error!void {
    const hlit = try br.take(5) + 257; // # literal/length codes (257..286)
    const hdist = try br.take(5) + 1; // # distance codes (1..32)
    const hclen = try br.take(4) + 4; // # code-length codes (4..19)

    // Read the code-length code lengths in their shuffled order.
    var cl_lengths = [_]u8{0} ** 19;
    var i: usize = 0;
    while (i < hclen) : (i += 1) {
        cl_lengths[cl_order[i]] = @intCast(try br.take(3));
    }
    var cl_table = try HuffmanTable.build(gpa, &cl_lengths);
    defer cl_table.deinit(gpa);

    // Decode the literal/length + distance code lengths as one sequence.
    var lengths = [_]u8{0} ** (288 + 32);
    const total = hlit + hdist;
    i = 0;
    while (i < total) {
        const sym = try cl_table.decode(br);
        switch (sym) {
            0...15 => {
                lengths[i] = @intCast(sym);
                i += 1;
            },
            16 => {
                if (i == 0) return error.BadSymbol;
                const repeat: usize = 3 + try br.take(2);
                // A repeat that overruns `total` is a corrupt stream, not a
                // value to silently clamp.
                const end = @as(usize, i) + repeat;
                if (end > total) return error.BadSymbol;
                const prev = lengths[i - 1];
                while (i < end) : (i += 1) lengths[i] = prev;
            },
            17 => {
                const repeat: usize = 3 + try br.take(3);
                const end = @as(usize, i) + repeat;
                if (end > total) return error.BadSymbol;
                while (i < end) : (i += 1) lengths[i] = 0;
            },
            18 => {
                const repeat: usize = 11 + try br.take(7);
                const end = @as(usize, i) + repeat;
                if (end > total) return error.BadSymbol;
                while (i < end) : (i += 1) lengths[i] = 0;
            },
            else => return error.BadSymbol,
        }
    }

    var litlen = try HuffmanTable.build(gpa, lengths[0..hlit]);
    defer litlen.deinit(gpa);
    var dist = try HuffmanTable.build(gpa, lengths[hlit..total]);
    defer dist.deinit(gpa);
    try decodeBlock(gpa, br, out, &litlen, &dist, max_out);
}

fn decodeBlock(
    gpa: std.mem.Allocator,
    br: *BitReader,
    out: *std.ArrayList(u8),
    litlen: *const HuffmanTable,
    dist: *const HuffmanTable,
    max_out: usize,
) Error!void {
    while (true) {
        const sym = try litlen.decode(br);
        if (sym < 256) {
            try appendByte(gpa, out, @intCast(sym), max_out);
        } else if (sym == 256) {
            return; // end of block
        } else if (sym <= 285) {
            const li = sym - 257;
            const length = length_base[li] + try br.take(length_extra[li]);
            const dsym = try dist.decode(br);
            if (dsym >= dist_base.len) return error.BadSymbol;
            const distance = dist_base[dsym] + try br.take(dist_extra[dsym]);
            if (distance > out.items.len) return error.DistanceTooFar;
            const start = out.items.len - distance;
            var k: usize = 0;
            while (k < length) : (k += 1) {
                const byte = out.items[start + k];
                try appendByte(gpa, out, byte, max_out);
            }
        } else {
            return error.BadSymbol;
        }
    }
}

test "inflate decodes a stored block" {
    const gpa = std.testing.allocator;
    // BFINAL=1, BTYPE=00, LEN=3, NLEN=~3, "abc".
    const stream = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'a', 'b', 'c' };
    const got = try inflate(gpa, &stream, 3);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("abc", got);
}

test "inflate stops at max_out with OutputLimitExceeded" {
    const gpa = std.testing.allocator;
    // Same stored "abc" stream, but a budget of 2 bytes — the third append trips.
    const stream = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'a', 'b', 'c' };
    try std.testing.expectError(error.OutputLimitExceeded, inflate(gpa, &stream, 2));
}
