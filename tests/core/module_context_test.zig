//! M1.1.15.1 / gate A — acceptance for `core.ModuleContext`
//! (`engine-tier-interfaces.md` §0).
//!
//! Two tests, and the second is the NEGATIVE TWIN of the first. The first says the context
//! carries four named fields; on its own that is satisfied by four fields chosen at random.
//! The second says what the four are FOR: exactly one of them — `world` — reaches component
//! registration, resources, the event bus and the observer registry, and the other three
//! reach none of them. That is the property `registrar` and `event_bus` violated, and a
//! count alone would not have caught them since a six-field context still has a count.

const std = @import("std");
const testing = std.testing;

const core = @import("weld_core");

const ecs = core.ecs;
const events = core.events;
const jobs = core.jobs;
const ModuleContext = core.ModuleContext;

/// The four field names `engine-tier-interfaces.md` §0 declares, in declaration order.
const expected_field_names = [_][]const u8{
    "world",
    "persistent_allocator",
    "system_scheduler",
    "job_scheduler",
};

test "ModuleContext carries exactly four fields" {
    const fields = @typeInfo(ModuleContext).@"struct".fields;

    // BY COUNT. A fifth field is a scope change, and this is what makes it fail rather
    // than pass silently.
    try testing.expectEqual(expected_field_names.len, fields.len);

    // BY NAME, in both directions. Checking only that the four expected names are PRESENT
    // would pass a context that also carries a fifth; checking only the count would pass a
    // rename. The two directions together admit exactly one field set.
    inline for (expected_field_names, 0..) |name, i| {
        try testing.expectEqualStrings(name, fields[i].name);
    }
    inline for (fields) |f| {
        var found = false;
        inline for (expected_field_names) |name| {
            if (comptime std.mem.eql(u8, name, f.name)) found = true;
        }
        if (!found) {
            std.debug.print("unexpected ModuleContext field: {s}\n", .{f.name});
            return error.UnexpectedField;
        }
    }

    // BY TYPE. `registrar: *Registry` renamed to `world` would satisfy every check above.
    try testing.expectEqual(*ecs.World, fields[0].type);
    try testing.expectEqual(std.mem.Allocator, fields[1].type);
    try testing.expectEqual(*ecs.SystemScheduler, fields[2].type);
    try testing.expectEqual(*jobs.scheduler.Scheduler, fields[3].type);
}

// --- the negative twin -------------------------------------------------------

/// Strip one pointer level, if there is one. A context field is either a pointer to a Tier 0
/// service or a value (`std.mem.Allocator`); nothing here is a slice or a many-pointer.
fn pointee(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) return info.pointer.child;
    return T;
}

/// Does holding a value of this type give its holder a route to component registration,
/// resources, the event bus, or the observer registry?
///
/// TWO mechanisms, deliberately, because neither alone covers the refused shape.
/// STRUCTURAL catches an aggregate that CARRIES those services as state — which is what
/// `World` does and what any future "context holder" would do. NOMINAL catches a pointer to
/// one of the services ITSELF, which carries none of them as a field and would slip past a
/// purely structural walk: `Registry` is caught structurally by its `registerComponent`
/// declaration, but `EventBus`, `ResourceStore` and `ObserverRegistry` are not.
fn reachesRegistrationOrEvents(comptime T: type) bool {
    const P = pointee(T);
    if (@typeInfo(P) != .@"struct") return false;

    // Nominal: the field IS one of the four services.
    if (P == ecs.registry.Registry) return true;
    if (P == ecs.resources.ResourceStore) return true;
    if (P == events.bus.EventBus) return true;
    if (P == ecs.observers.ObserverRegistry) return true;

    // Structural: the field HOLDS them, or declares component registration itself.
    if (@hasDecl(P, "registerComponent")) return true;
    if (@hasDecl(P, "registerComponentRaw")) return true;
    if (@hasField(P, "registry")) return true;
    if (@hasField(P, "resources")) return true;
    if (@hasField(P, "singleton_resources")) return true;
    if (@hasField(P, "event_bus")) return true;
    if (@hasField(P, "observer_registry")) return true;

    return false;
}

/// Names of the fields of `T` that reach registration or events. Comptime, so the caller can
/// assert on the SET and not merely on a count — a count of one would not say which one.
fn reachingFieldNames(comptime T: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            if (reachesRegistrationOrEvents(f.type)) names = names ++ [_][]const u8{f.name};
        }
        return names;
    }
}

/// The eight-field shape `engine-tier-interfaces.md` §0 REFUSED, reduced to the two fields
/// that carry the defect. It exists here as the counter-factual for the walk below: an
/// oracle that judges a field set is tested by a change of the FIELD SET, never by a change
/// of its own expected constant.
const RefusedShape = struct {
    world: *ecs.World,
    persistent_allocator: std.mem.Allocator,
    system_scheduler: *ecs.SystemScheduler,
    job_scheduler: *jobs.scheduler.Scheduler,
    /// D11: a second declarant of an act `World` already owns.
    registrar: *ecs.registry.Registry,
    /// D11: a second route to the bus `World` already carries.
    event_bus: *events.bus.EventBus,
};

test "ModuleContext exposes no second path to registration or events" {
    // POSITIVE WITNESS, first — an assertion of absence is satisfied by an apparatus that
    // finds nothing. `world` really is the path, so the absence asserted below is the
    // absence of a SECOND one and not the absence of any.
    try testing.expect(@hasDecl(ecs.World, "registerComponent"));
    try testing.expect(@hasField(ecs.World, "registry"));
    try testing.expect(@hasField(ecs.World, "resources"));
    try testing.expect(@hasField(ecs.World, "singleton_resources"));
    try testing.expect(@hasField(ecs.World, "event_bus"));
    try testing.expect(@hasField(ecs.World, "observer_registry"));
    try testing.expect(reachesRegistrationOrEvents(*ecs.World));

    // THE VERDICT, and the SIZE of what it was rendered on: four fields walked, exactly one
    // of them reaching, and that one is `world`.
    const walked = @typeInfo(ModuleContext).@"struct".fields.len;
    try testing.expectEqual(@as(usize, 4), walked);

    const reaching = comptime reachingFieldNames(ModuleContext);
    try testing.expectEqual(@as(usize, 1), reaching.len);
    try testing.expectEqualStrings("world", reaching[0]);

    // The three others reach nothing — stated per field rather than deduced from the count,
    // so a failure names the offender.
    try testing.expect(!reachesRegistrationOrEvents(std.mem.Allocator));
    try testing.expect(!reachesRegistrationOrEvents(*ecs.SystemScheduler));
    try testing.expect(!reachesRegistrationOrEvents(*jobs.scheduler.Scheduler));

    // `SystemScheduler` declares `registerSystem`, and that is NOT what this walk looks for.
    // Registering a system is precisely what that field exists to do; the refused act is a
    // second route to COMPONENT registration and to the bus. Asserted so the distinction
    // survives a future author widening the predicate to any `register*`.
    try testing.expect(@hasDecl(ecs.SystemScheduler, "registerSystem"));

    // COUNTER-FACTUAL. Same walk, different object: the refused shape has three reaching
    // fields. Without this, a walk that always answered "one" would pass.
    const refused = comptime reachingFieldNames(RefusedShape);
    try testing.expectEqual(@as(usize, 3), refused.len);
    try testing.expectEqualStrings("world", refused[0]);
    try testing.expectEqualStrings("registrar", refused[1]);
    try testing.expectEqualStrings("event_bus", refused[2]);

    // And the two removed names are absent from the real context, by name. The exhaustive
    // set check in the first test already forbids them; this states WHICH absence is
    // load-bearing, at the site that explains why.
    try testing.expect(!@hasField(ModuleContext, "registrar"));
    try testing.expect(!@hasField(ModuleContext, "event_bus"));
    // The other two removals of §0, same form: a tier inversion and a field with no
    // producer and no consumer.
    try testing.expect(!@hasField(ModuleContext, "asset_loader"));
    try testing.expect(!@hasField(ModuleContext, "frame_allocator"));
}
