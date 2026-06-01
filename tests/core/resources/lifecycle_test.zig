//! M0.2 / E3 — Resources lifecycle tag tests.
//!
//! Resources may declare a lifecycle via `pub const lifecycle:
//! Lifecycle = .{config | state | transient};` in the struct
//! itself. `rtti.buildTypeInfo(T, .resource)` reads this
//! declaration at comptime; absent declaration defaults to
//! `.transient` (cf. brief § Notes — technical decision E3 /
//! lifecycle inference).

const std = @import("std");
const weld_core = @import("weld_core");

const rtti = weld_core.rtti;
const Lifecycle = rtti.Lifecycle;
const Category = rtti.Category;

const ConfigResource = extern struct {
    pub const lifecycle: Lifecycle = .config;
    value: u32 = 0,
};

const StateResource = extern struct {
    pub const lifecycle: Lifecycle = .state;
    score: i64 = 0,
};

const TransientResource = extern struct {
    pub const lifecycle: Lifecycle = .transient;
    cache: [16]u8 = [_]u8{0} ** 16,
};

const UnannotatedResource = extern struct {
    seed: u64 = 0,
};

const NotAResource = extern struct {
    payload: u32 = 0,
};

test "lifecycle .config surfaces in TypeInfo for a resource" {
    const info = comptime rtti.buildTypeInfo(ConfigResource, .resource);
    try std.testing.expectEqual(Category.resource, info.category);
    try std.testing.expect(info.lifecycle != null);
    try std.testing.expectEqual(Lifecycle.config, info.lifecycle.?);
}

test "lifecycle .state surfaces in TypeInfo for a resource" {
    const info = comptime rtti.buildTypeInfo(StateResource, .resource);
    try std.testing.expectEqual(Category.resource, info.category);
    try std.testing.expectEqual(Lifecycle.state, info.lifecycle.?);
}

test "lifecycle .transient surfaces in TypeInfo for a resource" {
    const info = comptime rtti.buildTypeInfo(TransientResource, .resource);
    try std.testing.expectEqual(Category.resource, info.category);
    try std.testing.expectEqual(Lifecycle.transient, info.lifecycle.?);
}

test "unannotated resource defaults to .transient" {
    const info = comptime rtti.buildTypeInfo(UnannotatedResource, .resource);
    try std.testing.expectEqual(Category.resource, info.category);
    try std.testing.expectEqual(Lifecycle.transient, info.lifecycle.?);
}

test "non-resource category leaves lifecycle null" {
    const info_component = comptime rtti.buildTypeInfo(NotAResource, .component);
    try std.testing.expectEqual(Category.component, info_component.category);
    try std.testing.expect(info_component.lifecycle == null);

    const info_event = comptime rtti.buildTypeInfo(NotAResource, .event);
    try std.testing.expect(info_event.lifecycle == null);

    const info_message = comptime rtti.buildTypeInfo(NotAResource, .message);
    try std.testing.expect(info_message.lifecycle == null);
}

test "inferLifecycle is comptime-foldable" {
    const c = comptime rtti.inferLifecycle(ConfigResource, .resource);
    const s = comptime rtti.inferLifecycle(StateResource, .resource);
    const t = comptime rtti.inferLifecycle(UnannotatedResource, .resource);
    try std.testing.expectEqual(Lifecycle.config, c.?);
    try std.testing.expectEqual(Lifecycle.state, s.?);
    try std.testing.expectEqual(Lifecycle.transient, t.?);
    try std.testing.expect(comptime rtti.inferLifecycle(NotAResource, .component) == null);
}
