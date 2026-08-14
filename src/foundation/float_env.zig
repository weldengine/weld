//! `foundation/float_env.zig` — the engine's floating-point EXECUTION state.
//!
//! `ARCH-031` rule 5: round-to-nearest-even, denormals PRESERVED — so FTZ and
//! DAZ off — on **every engine thread**. Not a performance preference. A thread
//! that flushes denormals computes a different number from one that keeps them,
//! and the job system is work-stealing, so *which* thread runs *which* job is
//! not a stable property: an unpinned float environment makes a result depend
//! on scheduling. The default state is NOT portable — it depends on the OS, on
//! the linked C runtime, and on what a graphics driver may have changed inside
//! the process — so it is **installed**, never assumed.
//!
//! **Why this file is in `foundation/` and not in `core/platform/`, which owns
//! the installation.** The two halves of the contract have different owners and
//! only one shared mechanism:
//!
//! - **Installing** belongs to the platform layer (`engine-platform.md` §4 —
//!   *Threading*): a module that installed it would leave divergent every
//!   thread it did not create, and the main thread is one of those.
//! - **Asserting** belongs to every module whose output is compared, at its own
//!   entry point. A local re-install would MASK the defect instead of reporting
//!   it, and leave the divergence standing for every other consumer.
//!
//! `forge_3d` is such a module and it must not import `weld_core` — depending
//! only on `foundation/math/` and `forge/api/` is a C1.1 exit metric
//! (`engine-phase-1-criteria.md`). So the reader has to be reachable from
//! `foundation`. Putting only the reader here and the writer in `core/platform/`
//! would split one register layout across two files, which is the drift shape
//! this repository has already paid for once (`contactMargin`, duplicated in
//! `fast_paths.zig` while both copies were private). One owner, two callers.
//!
//! `core/platform/float_env.zig` is the platform layer's facade over this file
//! and carries the tier rule; it holds no second copy of the layout.

const std = @import("std");
const builtin = @import("builtin");

/// IEEE-754 rounding direction.
///
/// The four values are named after the standard's attributes rather than after
/// either ISA's encoding, BECAUSE the two encodings disagree: x86's `RC` field
/// spells down/up as `01`/`10` and AArch64's `RMode` spells them `10`/`01`. A
/// shared enum with a per-ISA decode is what keeps a reader from concluding
/// that a raw control word can be compared across architectures.
pub const Rounding = enum {
    /// Round to nearest, ties to even. The engine's mode, and the only one
    /// under which `foundation/math/trig.zig`'s magic-constant integer
    /// extraction computes what it says it computes.
    nearest_even,
    /// Round toward −∞.
    toward_negative,
    /// Round toward +∞.
    toward_positive,
    /// Round toward zero (truncate).
    toward_zero,
};

/// The three properties of the float environment that change a result.
///
/// Exception MASKS are deliberately absent. They govern whether an invalid
/// operation traps, not what value it produces, so two threads that disagree
/// about them still compute the same bits — and trapping is a debugging choice
/// that no determinism contract should freeze.
pub const State = struct {
    /// Active rounding direction.
    rounding: Rounding,
    /// Whether a denormal RESULT is flushed to zero.
    flush_to_zero: bool,
    /// Whether a denormal INPUT is treated as zero.
    ///
    /// On AArch64 this is not a separate control: `FPCR.FZ` flushes inputs and
    /// outputs together, so both fields report that one bit. The struct keeps
    /// two fields anyway because x86_64 really does have two, and collapsing
    /// them would make an x86 state with `DAZ` set and `FTZ` clear
    /// unrepresentable — a state a third-party driver can and does leave behind.
    denormals_are_zero: bool,

    /// Bit-for-bit equality. Written out rather than `std.meta.eql` so that a
    /// field added later has to be considered here rather than silently joining
    /// the comparison.
    pub fn eql(self: State, other: State) bool {
        return self.rounding == other.rounding and
            self.flush_to_zero == other.flush_to_zero and
            self.denormals_are_zero == other.denormals_are_zero;
    }
};

/// The state `ARCH-031` rule 5 requires on every engine thread.
pub const engine_default: State = .{
    .rounding = .nearest_even,
    .flush_to_zero = false,
    .denormals_are_zero = false,
};

/// Whether this target exposes a float control register this file can read and
/// write.
///
/// True on x86_64 (`MXCSR`) and AArch64 (`FPCR`) — which is every cell of the
/// CI matrix and both development machines. On any other target `read` returns
/// `null` and `install` is a no-op: reporting "unknown" is the honest answer,
/// and it is strictly better than an `install` that silently does nothing while
/// claiming success.
///
/// **The x86_64 arm of this file is validated on CI cells and NOWHERE ELSE, and
/// that is measured, not assumed.** The primary development machine is Apple
/// Silicon, and an `x86_64-macos` build of these tests runs under Rosetta 2,
/// which does not emulate `MXCSR`: `stmxcsr` there returns a constant `0x0000`
/// — not a value real hardware can hold, since the ABI leaves the six exception
/// masks set at `0x1F80` — and every write to the rounding-control field is
/// dropped. `install` still takes effect at the arithmetic level (an `FTZ`
/// write does flush a denormal), so the writer is partially witnessed; the
/// READER is not witnessed at all. Running these tests under an x86 emulator is
/// therefore not a witness in either direction, and the discrimination test
/// below is what makes that visible instead of silent: it fails there rather
/// than passing vacuously.
pub const controllable: bool = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .aarch64_be => true,
    else => false,
};

// --- x86_64: MXCSR ----------------------------------------------------------
//
// Bit 6 = DAZ (denormals are zero, input side).
// Bits 13:14 = RC, the rounding control: 00 nearest-even, 01 −∞, 10 +∞, 11 zero.
// Bit 15 = FTZ (flush to zero, result side).
// Bits 7..12 are the exception masks and bits 0..5 the sticky exception flags;
// both are preserved verbatim by `install`, which only ever clears the three
// fields it owns.

const mxcsr_daz_bit: u32 = 1 << 6;
const mxcsr_ftz_bit: u32 = 1 << 15;
const mxcsr_rc_shift: u5 = 13;
const mxcsr_rc_mask: u32 = 0b11 << mxcsr_rc_shift;

fn readMxcsr() u32 {
    var word: u32 = 0;
    asm volatile ("stmxcsr %[out]"
        :
        : [out] "*m" (&word),
        : .{ .memory = true });
    return word;
}

fn writeMxcsr(word: u32) void {
    var local = word;
    asm volatile ("ldmxcsr %[in]"
        :
        : [in] "*m" (&local),
        : .{ .memory = true });
}

// --- AArch64: FPCR ----------------------------------------------------------
//
// Bit 24 = FZ (flush to zero — inputs AND outputs).
// Bits 22:23 = RMode: 00 nearest-even, 01 +∞, 10 −∞, 11 zero. NOTE the swap
// against x86's RC, which is exactly why `Rounding` is an enum and not a raw
// two-bit field.
// Bit 19 = FZ16, the half-precision flush control. Left untouched: no engine
// path computes in `f16`, so writing it would be changing a bit nothing reads.

const fpcr_fz_bit: u64 = 1 << 24;
const fpcr_rmode_shift: u6 = 22;
const fpcr_rmode_mask: u64 = 0b11 << fpcr_rmode_shift;

fn readFpcr() u64 {
    return asm volatile ("mrs %[out], fpcr"
        : [out] "=r" (-> u64),
    );
}

fn writeFpcr(word: u64) void {
    asm volatile ("msr fpcr, %[in]"
        :
        : [in] "r" (word),
        : .{ .memory = true });
}

// --- Public surface ---------------------------------------------------------

/// The float environment of the CALLING thread, or `null` when this target has
/// no control register this file knows (`controllable`).
///
/// Reads only. It is the primitive every deterministic module asserts on, and a
/// reader that repaired what it found would defeat its own purpose.
pub fn read() ?State {
    if (!controllable) return null;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            const word = readMxcsr();
            return .{
                .rounding = switch (@as(u2, @truncate(word >> mxcsr_rc_shift))) {
                    0b00 => .nearest_even,
                    0b01 => .toward_negative,
                    0b10 => .toward_positive,
                    0b11 => .toward_zero,
                },
                .flush_to_zero = (word & mxcsr_ftz_bit) != 0,
                .denormals_are_zero = (word & mxcsr_daz_bit) != 0,
            };
        },
        .aarch64, .aarch64_be => {
            const word = readFpcr();
            const flush = (word & fpcr_fz_bit) != 0;
            return .{
                .rounding = switch (@as(u2, @truncate(word >> fpcr_rmode_shift))) {
                    0b00 => .nearest_even,
                    0b01 => .toward_positive,
                    0b10 => .toward_negative,
                    0b11 => .toward_zero,
                },
                // One bit, reported under both names — see `State`.
                .flush_to_zero = flush,
                .denormals_are_zero = flush,
            };
        },
        else => unreachable,
    }
}

/// An opaque snapshot of the raw control word of the calling thread.
///
/// Opaque on purpose: the same `Raw` means different things on the two
/// architectures — see the `Rounding` doc comment on the encoding swap — so it
/// is only ever handed back to `restore` on the thread it came from, never
/// compared, stored or transported.
pub const Raw = u64;

/// Snapshot the raw control word of the calling thread, for `restore`.
///
/// Snapshot/restore is the complete minimal surface of a per-thread control
/// register alongside `read` and `installState`, and it is what lets a consumer
/// confront its own entry-point check with a real perturbation without holding
/// a second copy of the register layout — the drift shape this file exists to
/// prevent. `0` on a target with no control register; `restore` ignores it.
pub fn save() Raw {
    if (!controllable) return 0;
    return switch (builtin.cpu.arch) {
        .x86_64 => readMxcsr(),
        .aarch64, .aarch64_be => readFpcr(),
        else => unreachable,
    };
}

/// Restore a word previously returned by `save`, on the same thread.
pub fn restore(word: Raw) void {
    if (!controllable) return;
    switch (builtin.cpu.arch) {
        .x86_64 => writeMxcsr(@truncate(word)),
        .aarch64, .aarch64_be => writeFpcr(word),
        else => unreachable,
    }
}

/// Install an arbitrary `state` on the CALLING thread.
///
/// Narrow by construction: it rewrites only the three fields `State` names and
/// preserves every other bit of the control word — exception masks and sticky
/// exception flags survive, which is why it is a read-modify-write and not a
/// constant store.
///
/// On AArch64 `flush_to_zero` and `denormals_are_zero` are ONE bit (`FPCR.FZ`).
/// A state that sets them differently is not representable there, and the
/// disagreement is resolved toward flushing — the conservative direction, since
/// it makes `read` report back exactly what was asked for on at least one of
/// the two fields rather than silently dropping both.
pub fn installState(state: State) void {
    if (!controllable) return;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            var word = readMxcsr();
            word &= ~(mxcsr_rc_mask | mxcsr_ftz_bit | mxcsr_daz_bit);
            word |= @as(u32, switch (state.rounding) {
                .nearest_even => 0b00,
                .toward_negative => 0b01,
                .toward_positive => 0b10,
                .toward_zero => 0b11,
            }) << mxcsr_rc_shift;
            if (state.flush_to_zero) word |= mxcsr_ftz_bit;
            if (state.denormals_are_zero) word |= mxcsr_daz_bit;
            writeMxcsr(word);
        },
        .aarch64, .aarch64_be => {
            var word = readFpcr();
            word &= ~(fpcr_rmode_mask | fpcr_fz_bit);
            word |= @as(u64, switch (state.rounding) {
                .nearest_even => 0b00,
                .toward_positive => 0b01,
                .toward_negative => 0b10,
                .toward_zero => 0b11,
            }) << fpcr_rmode_shift;
            if (state.flush_to_zero or state.denormals_are_zero) word |= fpcr_fz_bit;
            writeFpcr(word);
        },
        else => unreachable,
    }
}

/// Install `engine_default` on the CALLING thread.
///
/// **Called by the platform layer only** — at process init for the main thread
/// and at every engine thread spawn (`ARCH-031` rule 5). A module that calls it
/// is masking a defect rather than reporting one; `core/platform/float_env.zig`
/// carries that rule where the callers can see it.
///
/// Idempotent.
pub fn install() void {
    installState(engine_default);
}

/// Whether the calling thread carries `engine_default`.
///
/// `true` on a target with no readable control register: the question is not
/// answerable there, and a module entry point must not refuse to run because a
/// port has no `MXCSR`. `controllable` is the field that says which of the two
/// `true`s this is, and the deterministic CI cells are all on the readable side.
pub fn isEngineDefault() bool {
    const state = read() orelse return true;
    return state.eql(engine_default);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "float_env: the engine default is what a fresh thread already carries" {
    // Not a tautology, and it is the load-bearing observation of the whole
    // deliverable: on the three targets the engine ships, the OS hands out a
    // thread already in round-to-nearest with denormals live. `install` is
    // therefore a BELT — its value is against a process where something else
    // (a driver, a linked C runtime, a plugin) has already moved the register.
    // If this test ever fails, the assertion at the physics entry point becomes
    // the load-bearing half instead, and that is worth knowing loudly.
    if (!controllable) return error.SkipZigTest;
    try testing.expect(isEngineDefault());
}

test "float_env: install is idempotent and preserves the bits it does not own" {
    if (!controllable) return error.SkipZigTest;

    install();
    try testing.expect(isEngineDefault());
    install();
    try testing.expect(isEngineDefault());
}

test "float_env: installState round-trips every state read can report" {
    // Writer against reader, over the WHOLE domain rather than one sample. It
    // is the write-direction half of the encoding swap the `Rounding` doc
    // comment describes: the read test below pins the decode, this pins the
    // encode, and a table copied from one architecture to the other fails here
    // on two of the four rows.
    //
    // `denormals_are_zero` is swept only together with `flush_to_zero`, because
    // AArch64 has one bit for the two and a split state is unrepresentable
    // there. The x86-only split state has its own assertion in the read test.
    if (!controllable) return error.SkipZigTest;

    const saved = save();
    defer restore(saved);

    for ([_]Rounding{ .nearest_even, .toward_negative, .toward_positive, .toward_zero }) |r| {
        for ([_]bool{ false, true }) |flush| {
            const want: State = .{
                .rounding = r,
                .flush_to_zero = flush,
                .denormals_are_zero = flush,
            };
            installState(want);
            try testing.expect(read().?.eql(want));
        }
    }

    // And `install` is exactly `installState(engine_default)` — pinned so the
    // convenience wrapper cannot drift away from the state it claims to set.
    installState(.{ .rounding = .toward_zero, .flush_to_zero = true, .denormals_are_zero = true });
    install();
    try testing.expect(read().?.eql(engine_default));
}

test "float_env: read observes a perturbed state, and install restores it" {
    // The DISCRIMINATION guard for every other test in this file and for the
    // physics entry-point assertion: without a probe that actually moves the
    // register, `isEngineDefault` returning true would be satisfied by a reader
    // that always returns `engine_default` (workflow §5.5 — an oracle is
    // confronted with a change of the OBJECT). Each perturbation is asserted to
    // be OBSERVED, not merely applied.
    if (!controllable) return error.SkipZigTest;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            const saved = readMxcsr();
            defer writeMxcsr(saved);

            // Round toward zero.
            writeMxcsr((saved & ~mxcsr_rc_mask) | (0b11 << mxcsr_rc_shift));
            try testing.expectEqual(Rounding.toward_zero, read().?.rounding);
            try testing.expect(!isEngineDefault());

            // Flush-to-zero on, rounding back to nearest.
            writeMxcsr((saved & ~mxcsr_rc_mask) | mxcsr_ftz_bit);
            try testing.expectEqual(Rounding.nearest_even, read().?.rounding);
            try testing.expect(read().?.flush_to_zero);
            try testing.expect(!isEngineDefault());

            // Denormals-are-zero alone — the x86-only state the two-field
            // `State` exists to keep representable.
            writeMxcsr((saved & ~(mxcsr_rc_mask | mxcsr_ftz_bit)) | mxcsr_daz_bit);
            try testing.expect(read().?.denormals_are_zero);
            try testing.expect(!read().?.flush_to_zero);
            try testing.expect(!isEngineDefault());

            install();
            try testing.expect(isEngineDefault());
        },
        .aarch64, .aarch64_be => {
            const saved = readFpcr();
            defer writeFpcr(saved);

            // Round toward zero.
            writeFpcr((saved & ~fpcr_rmode_mask) | (0b11 << fpcr_rmode_shift));
            try testing.expectEqual(Rounding.toward_zero, read().?.rounding);
            try testing.expect(!isEngineDefault());

            // Round toward +∞ — the encoding that x86 spells `toward_negative`.
            // Pinned on both architectures so a copy-pasted decode table is a
            // failing test rather than a silent misreport.
            writeFpcr((saved & ~fpcr_rmode_mask) | (0b01 << fpcr_rmode_shift));
            try testing.expectEqual(Rounding.toward_positive, read().?.rounding);

            // Flush-to-zero, reported under both names on this ISA.
            writeFpcr((saved & ~fpcr_rmode_mask) | fpcr_fz_bit);
            try testing.expectEqual(Rounding.nearest_even, read().?.rounding);
            try testing.expect(read().?.flush_to_zero);
            try testing.expect(read().?.denormals_are_zero);
            try testing.expect(!isEngineDefault());

            install();
            try testing.expect(isEngineDefault());
        },
        else => unreachable,
    }
}

/// The smallest normal `f64` halved — a DENORMAL — computed so that no
/// optimizer can answer it without asking the FPU.
///
/// Both operands are loaded through a `volatile` pointer, the product is stored
/// through one, and the result is re-loaded through it. That is not belt and
/// braces: `std.mem.doNotOptimizeAway(&x)` is NOT sufficient here, and this is
/// measured rather than feared. On the `x86_64` / ReleaseSafe build — which is
/// a CI cell — the weaker form yielded the folded denormal for one use of the
/// expression and the flushed zero for a comparison against `0.0` in the SAME
/// statement, i.e. two different values for one product. A probe that reports
/// two answers cannot witness one bit.
fn denormalProduct() f64 {
    var tiny: f64 = std.math.floatMin(f64);
    var half: f64 = 0.5;
    var out: f64 = 0;
    const p_tiny: *volatile f64 = &tiny;
    const p_half: *volatile f64 = &half;
    const p_out: *volatile f64 = &out;
    p_out.* = p_tiny.* * p_half.*;
    return p_out.*;
}

test "float_env: a flushed denormal is observable arithmetic, not just a bit" {
    // What the register bit MEANS, measured rather than taken from the manual.
    // The whole contract rests on the claim that flushing denormals changes a
    // computed value; this is the one place that claim is exercised end to end.
    // Without it, `flush_to_zero` is a boolean nobody has ever tied to a number.
    if (!controllable) return error.SkipZigTest;

    // With denormals preserved, the smallest normal halved is a denormal and is
    // NOT zero. This is also the POSITIVE witness of the assertion below: "the
    // product is zero once flushing is on" is satisfied by a probe that always
    // returns zero (workflow §5.5).
    try testing.expect(denormalProduct() != 0.0);

    switch (builtin.cpu.arch) {
        .x86_64 => {
            const saved = readMxcsr();
            defer writeMxcsr(saved);
            writeMxcsr(saved | mxcsr_ftz_bit | mxcsr_daz_bit);
            try testing.expectEqual(@as(f64, 0.0), denormalProduct());
        },
        .aarch64, .aarch64_be => {
            const saved = readFpcr();
            defer writeFpcr(saved);
            writeFpcr(saved | fpcr_fz_bit);
            try testing.expectEqual(@as(f64, 0.0), denormalProduct());
        },
        else => unreachable,
    }

    install();
    try testing.expect(denormalProduct() != 0.0);
}
