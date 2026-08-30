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
/// Payload of the toy event a Tier 1 module publishes to Etch (M1.1.15.2 G4).
/// `extern` because it crosses a module boundary; the emitter refuses a struct
/// with no layout guarantee, and the layout is what makes the field ORDER a
/// fact rather than a compiler choice.
pub const Ping = extern struct {
    value: i64 = 0,
    loud: bool = false,
};

/// The toy event's declaration, derived from `Ping` — names, types and defaults
/// all read off the Zig struct, so the Etch declaration cannot drift from the
/// payload the bridge pushes.
pub const ping_event = services.event("ToyPing", "A ping published from Zig.", Ping);

/// The emitted `ToyPing.d.etch`, embedded exactly as the service's is. Nothing
/// about this event's Etch surface is written by hand.
pub const ping_declaration_source = @embedFile("ToyPing.d.etch");

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

/// The toy's `.d.etch`, EMBEDDED from the emitted artifact rather than written
/// here (M1.1.15.2 G3). At G2 this was a hand-written constant, and the file said
/// so; the emitter now produces `toy.d.etch` from `spec` and `zig build
/// bindgen-check` guards it, so the divergence E1902 names cannot survive a
/// build. Nothing about this service's surface is written by hand any more.
pub const declaration_source = @embedFile("toy.d.etch");
