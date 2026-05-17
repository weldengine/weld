//! `etch_synth` — deterministic synthetic Etch corpus generator. Produces
//! N `.etch` files seeded for byte-identical reproducibility (same `--seed`
//! across runs / platforms ⇒ same outputs). Each file has 5–10 components
//! and 3–5 rules drawn from the S3 subset, exercising arithmetic, when
//! clauses with single and multi-component filters, and a couple of
//! resource gates so the cooked corpus stresses every codegen path the
//! `bench-etch-compile` bench cares about.
//!
//! CLI:
//!     etch_synth --output <dir> --count <N> --seed <S>
//!
//! Outputs `<dir>/000.etch` … `<dir>/{N-1}.etch` (3-digit zero-padded
//! basenames so the lexicographic order on disk matches the program
//! number).

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena.allocator());

    var output_dir: ?[]const u8 = null;
    var count: u32 = 100;
    var seed: u64 = 0x5ec0_d_e0_a_5_5; // arbitrary deterministic seed

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            output_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--count")) {
            i += 1;
            count = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            i += 1;
            seed = try std.fmt.parseInt(u64, argv[i], 0);
        }
    }
    if (output_dir == null) {
        std.debug.print("etch_synth: missing --output\n", .{});
        return error.InvalidArgs;
    }

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, output_dir.?) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try cwd.openDir(io, output_dir.?, .{});
    defer dir.close(io);

    var prng = std.Random.DefaultPrng.init(seed);
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        try emitProgram(gpa, &buf, n, prng.random());
        var fname_buf: [16]u8 = undefined;
        const fname = try std.fmt.bufPrint(&fname_buf, "{d:0>3}.etch", .{n});
        var file = try dir.createFile(io, fname, .{});
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        try fw.interface.writeAll(buf.items);
        try fw.interface.flush();
    }
}

const ComponentSpec = struct {
    name: [16]u8,
    name_len: u8,
    fields: [4]FieldSpec,
    field_count: u8,
};

const FieldSpec = struct {
    name: [12]u8,
    name_len: u8,
    kind: FieldKind,
};

const FieldKind = enum { int_, float_, bool_ };

fn emitProgram(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), program_idx: u32, rand: std.Random) !void {
    var w = Writer{ .out = out, .gpa = gpa };

    const comp_count: u8 = 5 + @as(u8, @intCast(rand.uintLessThan(u8, 6))); // 5..10
    var comps: [12]ComponentSpec = undefined;
    for (0..comp_count) |i| {
        comps[i] = pickComponent(program_idx, @intCast(i), rand);
    }

    // Always emit one resource so the corpus exercises the `resource T`
    // gate path on roughly half the rules.
    try w.printLine("resource Cfg_{d} {{ enabled: bool = true }}", .{program_idx});
    try w.blank();

    for (comps[0..comp_count]) |c| {
        try emitComponent(&w, c);
        try w.blank();
    }

    const rule_count: u8 = 3 + @as(u8, @intCast(rand.uintLessThan(u8, 3))); // 3..5
    for (0..rule_count) |r| {
        try emitRule(&w, comps[0..comp_count], @intCast(r), program_idx, rand);
        try w.blank();
    }
}

fn pickComponent(program_idx: u32, idx: u8, rand: std.Random) ComponentSpec {
    var c: ComponentSpec = .{
        .name = undefined,
        .name_len = 0,
        .fields = undefined,
        .field_count = 0,
    };
    // Component name `Cmp_<prog>_<idx>` — short, unique across the corpus.
    var name_buf: [16]u8 = undefined;
    const fmt_res = std.fmt.bufPrint(&name_buf, "Cmp_{d}_{d}", .{ program_idx, idx }) catch unreachable;
    @memcpy(c.name[0..fmt_res.len], fmt_res);
    c.name_len = @intCast(fmt_res.len);

    const field_count: u8 = 2 + @as(u8, @intCast(rand.uintLessThan(u8, 2))); // 2..3
    c.field_count = field_count;
    for (0..field_count) |i| {
        var f: FieldSpec = .{ .name = undefined, .name_len = 0, .kind = .int_ };
        const fname = std.fmt.bufPrint(&f.name, "f{d}", .{i}) catch unreachable;
        f.name_len = @intCast(fname.len);
        // First field is always numeric so the rule emitter never has to
        // fall back to a placeholder `let _x = 1` (Zig errors on the
        // resulting unused local). Subsequent fields draw uniformly.
        const pick: u8 = if (i == 0) rand.uintLessThan(u8, 2) else rand.uintLessThan(u8, 3);
        f.kind = switch (pick) {
            0 => .int_,
            1 => .float_,
            else => .bool_,
        };
        c.fields[i] = f;
    }
    return c;
}

fn emitComponent(w: *Writer, c: ComponentSpec) !void {
    try w.print("component {s} {{", .{c.name[0..c.name_len]});
    var first = true;
    for (c.fields[0..c.field_count]) |f| {
        if (!first) try w.write(",");
        first = false;
        const tname = switch (f.kind) {
            .int_ => "int",
            .float_ => "float",
            .bool_ => "bool",
        };
        const default = switch (f.kind) {
            .int_ => "0",
            .float_ => "0.0",
            .bool_ => "true",
        };
        try w.print(" {s}: {s} = {s}", .{ f.name[0..f.name_len], tname, default });
    }
    try w.write(" }\n");
}

fn emitRule(w: *Writer, comps: []const ComponentSpec, r_idx: u8, program_idx: u32, rand: std.Random) !void {
    // Pick 1..3 components for the rule (`when entity has A and entity has B and ...`).
    const max_when: u8 = if (comps.len < 3) @intCast(comps.len) else 3;
    const when_count: u8 = 1 + @as(u8, @intCast(rand.uintLessThan(u8, max_when)));
    const include_resource = (rand.uintLessThan(u8, 2) == 1);

    try w.print("rule rule_{d}_{d}(entity: Entity)\n  when ", .{ program_idx, r_idx });

    var first_comp_idx: u8 = 0;
    for (0..when_count) |k| {
        if (k > 0) try w.write(" and ");
        const ci: u8 = @intCast(rand.uintLessThan(u8, @intCast(comps.len)));
        if (k == 0) first_comp_idx = ci;
        try w.print("entity has {s}", .{comps[ci].name[0..comps[ci].name_len]});
    }
    if (include_resource) {
        try w.print(" and resource Cfg_{d}", .{program_idx});
    }
    try w.write("\n{\n");
    // Body: read+write the first chosen component's first numeric field.
    const first = comps[first_comp_idx];
    var f_picked: ?FieldSpec = null;
    for (first.fields[0..first.field_count]) |f| {
        if (f.kind == .int_ or f.kind == .float_) {
            f_picked = f;
            break;
        }
    }
    if (f_picked) |f| {
        const lit = switch (f.kind) {
            .int_ => "1",
            .float_ => "0.5",
            else => unreachable,
        };
        try w.print("  entity.get_mut({s}).{s} += {s}\n", .{
            first.name[0..first.name_len],
            f.name[0..f.name_len],
            lit,
        });
    } else {
        // No numeric field — emit a no-op so the body is non-empty.
        try w.write("  let _x = 1\n");
    }
    try w.write("}\n");
}

const Writer = struct {
    out: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,

    fn write(self: *Writer, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        const tmp = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(tmp);
        try self.out.appendSlice(self.gpa, tmp);
    }

    fn printLine(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.print(fmt, args);
        try self.write("\n");
    }

    fn blank(self: *Writer) !void {
        try self.write("\n");
    }
};
