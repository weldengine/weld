//! `examples/arena/` — the M1.1.15.2 bidirectional Etch slice, driven end to end
//! (G7).
//!
//! **A mechanism nothing executes is the defect M1.1.15 named and this milestone
//! has closed twice.** So the slice is not a directory to read: `run` is called
//! by a test, and what it returns is what the rules observed.
//!
//! The tick order is the one the whole milestone is built on, and it is written
//! out here because a slice is where a reader looks for it:
//!
//! ```
//!   step        — Forge simulates and computes its two sensor deltas
//!   publish     — the deltas become TriggerEnter / TriggerExit on the Tier 0 bus
//!   interpreter — drains its event sources at the tick head, then runs the rules
//! ```
//!
//! ONE TICK of latency between a crossing and the rule that sees it, for the
//! reason `sensor_events.zig` states: the deltas exist only after step 10 bis and
//! the sources drain at the head of a tick.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const weld_etch = @import("weld_etch");
const module = @import("forge_module");
const physics = @import("forge_services");
const sensor_events = @import("forge_sensor_events");

const World = core.ecs.World;
const EventQueue = core.events.EventQueue;
const services = weld_etch.services;
const types = weld_etch.types;
const AstArena = weld_etch.Ast;
const Diagnostic = weld_etch.diagnostics.Diagnostic;

/// The rules, compiled into the slice so the example is one artefact.
pub const gameplay_source = @embedFile("gameplay.etch");

/// What the rules observed, read back from the resource they write.
pub const Observed = struct {
    /// Etch → Zig: the service answered that something is on the ray.
    wall_seen: i64,
    /// Zig → Etch: how many `TriggerEnter` events a rule saw.
    entered: i64,
    /// Checker diagnostics. Zero, or the slice does not compile.
    diagnostics: usize,
};

fn av3(x: f32, y: f32, z: f32) @import("foundation").math.Vec3 {
    return @import("foundation").math.Vec3.fromArray(.{ x, y, z });
}

/// Build the arena, run `ticks` frames, and report what the rules observed.
pub fn run(gpa: std.mem.Allocator, ticks: u32) !Observed {
    // --- the three declaration files, EMITTED and guarded by `bindgen-check` ---
    // The four arenas are MOVED out of their parse results and owned by the array
    // below. Copying one while its `ParseResult` still owns the same buffers is a
    // double free the moment the checker's `ensureErrorBuiltins` reallocates a list
    // — measured, it segfaulted exactly that way the first time this was written.
    var phys_decl = try weld_etch.parser.parseWithMode(gpa, physics.declaration_source, .declaration_file);
    errdefer phys_decl.deinit(gpa);
    var enter_decl = try weld_etch.parser.parseWithMode(gpa, sensor_events.enter_declaration_source, .declaration_file);
    errdefer enter_decl.deinit(gpa);
    var exit_decl = try weld_etch.parser.parseWithMode(gpa, sensor_events.exit_declaration_source, .declaration_file);
    errdefer exit_decl.deinit(gpa);
    var rules = try weld_etch.parser.parse(gpa, gameplay_source);
    errdefer rules.deinit(gpa);
    for (rules.diagnostics) |d| std.debug.print("arena parse {s}: {s}\n", .{ d.code.code(), d.primary_message });
    if (rules.diagnostics.len != 0) return error.ArenaRulesDoNotParse;
    gpa.free(phys_decl.diagnostics);
    gpa.free(enter_decl.diagnostics);
    gpa.free(exit_decl.diagnostics);
    gpa.free(rules.diagnostics);

    var arenas = [_]AstArena{ phys_decl.ast, enter_decl.ast, exit_decl.ast, rules.ast };
    defer for (&arenas) |*a| a.deinit(gpa);
    var exports = [_]types.TypeChecker.ExportTable{ .empty, .empty, .empty, .empty };
    defer for (&exports) |*e| e.deinit(gpa);
    var prefabs: std.StringHashMapUnmanaged(void) = .empty;
    defer prefabs.deinit(gpa);
    var uuids: std.StringHashMapUnmanaged(void) = .empty;
    defer uuids.deinit(gpa);
    var module_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer module_index.deinit(gpa);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    const ctx: types.TypeChecker.ProjectContext = .{
        .prefabs = &prefabs,
        .uuids = &uuids,
        .module_index = &module_index,
        .exports = &exports,
        .arenas = &arenas,
    };
    try types.TypeChecker.checkProject(gpa, &arenas[3], &diags, &ctx);
    for (diags.items) |d| std.debug.print("arena check {s}: {s}\n", .{ d.code.code(), d.primary_message });

    // --- the world, the module, the service ---
    var ecs = World.init();
    defer ecs.deinit(gpa);
    var scheduler = core.ecs.SystemScheduler.init();
    defer scheduler.deinit(gpa);
    var mod_ctx = core.ModuleContext{
        .world = &ecs,
        .persistent_allocator = gpa,
        .system_scheduler = &scheduler,
        .job_scheduler = @ptrFromInt(@alignOf(core.jobs.scheduler.Scheduler)),
    };
    var m = try module.Forge3DModule.init(&mod_ctx);
    defer m.deinit();

    const box = try m.createShape(.{ .box = .{ .half_extents = av3(1, 1, 1) } });

    // A WALL on the ray — what the Etch → Zig direction finds.
    _ = try m.addBody(.{
        .entity = .{ .index = 1, .generation = 0 },
        .body_type = .static,
        .shape = box,
        .position = av3(10, 0, 0),
    });
    // A TRIGGER, and a body inside it — what the Zig → Etch direction reports.
    _ = try m.addBody(.{
        .entity = .{ .index = 2, .generation = 0 },
        .body_type = .static,
        .shape = box,
        .position = av3(0, 20, 0),
        .is_trigger = true,
    });
    _ = try m.addBody(.{
        .entity = .{ .index = 3, .generation = 0 },
        .body_type = .kinematic,
        .shape = box,
        .position = av3(0, 20, 0),
    });

    var svc_ctx: physics.Ctx = .{ .m = &m };
    var registry: services.Registry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, &physics.spec, &svc_ctx);

    // --- the bus, and the bridge that puts its events in front of the rules ---
    const enter_q = try EventQueue(sensor_events.TriggerPair).init(gpa, 32, core.events.Lifetime.tick);
    defer enter_q.deinit(gpa);
    const exit_q = try EventQueue(sensor_events.TriggerPair).init(gpa, 32, core.events.Lifetime.tick);
    defer exit_q.deinit(gpa);

    var interp = try weld_etch.Interpreter.compile(gpa, &arenas[3], &ecs);
    defer interp.deinit();
    interp.setServiceRegistry(&registry);

    var enter_bridge = weld_etch.event_bridge.Bridge(sensor_events.TriggerPair).init(enter_q, .{
        .type_id = core.rtti.computeTypeId(sensor_events.TriggerPair),
        .last_read = enter_q.currentHead(),
        .epoch = enter_q.currentEpoch(),
    }, "TriggerEnter");
    try interp.addEventSource(enter_bridge.source());

    // --- the frames ---
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        try m.step(1.0 / 60.0);
        _ = sensor_events.publish(&m.world, enter_q, exit_q);
        _ = try interp.runFor(&ecs, 1);
    }

    const rid = ecs.registry.idOf("ArenaState").?;
    const bytes = ecs.resources.getResource(rid).?;
    var wall: i64 = 0;
    var entered: i64 = 0;
    @memcpy(std.mem.asBytes(&wall), bytes[0..8]);
    @memcpy(std.mem.asBytes(&entered), bytes[8..16]);
    return .{ .wall_seen = wall, .entered = entered, .diagnostics = diags.items.len };
}
