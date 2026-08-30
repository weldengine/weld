//! The toy Tier 1 service M1.1.15.2 G2 is proven on (`etch-abi-zig.md` §8.7,
//! whose closing line says the interop gates prove themselves on a toy service
//! and never on the physics, which is only the first consumer).
//!
//! It is deliberately not physics-shaped: three methods covering the three
//! things the tree-walker path has to get right — a value comes back, a Zig
//! error union becomes an Etch `throw`, and a string crosses in both directions.

const std = @import("std");
const services = @import("weld_etch").services;

/// State the methods share, reached through the registry's opaque `ctx`. The
/// call counter is what proves a call actually happened rather than a value
/// being conjured somewhere on the way.
pub const Ctx = struct {
    calls: u32 = 0,
    base: i64 = 100,
    /// Owned by the service, which is what lets `label` return a borrow: the
    /// interpreter copies a returned string on receipt, and a slice into a
    /// stack frame would already be gone by then.
    label_buf: [32]u8 = undefined,
};

/// Returns `base + n`. The plain, infallible case.
pub fn echo(ctx: *Ctx, n: i64) i64 {
    ctx.calls += 1;
    return ctx.base + n;
}

/// Fails for `n > 2` and succeeds otherwise, so one method exercises BOTH sides
/// of the error channel — a method that only ever failed would not tell a
/// working call apart from a dispatch that never ran.
pub fn risky(ctx: *Ctx, n: i64) !i64 {
    ctx.calls += 1;
    if (n > 2) return error.TooBig;
    return n * 10;
}

/// Takes a string and returns one, so the conversion is exercised in both
/// directions in a single call.
pub fn label(ctx: *Ctx, prefix: []const u8) []const u8 {
    ctx.calls += 1;
    const n = @min(prefix.len, ctx.label_buf.len - 1);
    @memcpy(ctx.label_buf[0..n], prefix[0..n]);
    ctx.label_buf[n] = '!';
    return ctx.label_buf[0 .. n + 1];
}

/// The toy's `ServiceSpec` (`etch-abi-zig.md` §8.1). Parameter NAMES are
/// declared because Zig carries none; every type and the `throws` flag are
/// derived from the implementations above.
pub const spec = services.ServiceSpec{
    .name = "toy",
    .version = 1,
    .methods = &.{
        services.method("echo", "Add the service's base to n.", *Ctx, &.{"n"}, echo),
        services.method("risky", "Fail when n is greater than two.", *Ctx, &.{"n"}, risky),
        services.method("label", null, *Ctx, &.{"prefix"}, label),
    },
};

/// The `.d.etch` a G3 emitter would produce for `spec`. Hand-written HERE and
/// only here, because G3 does not exist yet and the checker needs a declaration
/// to resolve against. G3 replaces this constant with the emitted artifact and
/// `bindgen-check` then guards it; until then the divergence between this text
/// and `spec` is exactly what E1902 will confront, and it is unguarded.
pub const declaration_source =
    \\service toy {
    \\  /// Add the service's base to n.
    \\  fn echo(n: int) -> int
    \\  /// Fail when n is greater than two.
    \\  fn risky(n: int) throws -> int
    \\  fn label(prefix: string) -> string
    \\}
;
