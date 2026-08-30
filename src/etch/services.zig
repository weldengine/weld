//! Tier 1 service registry and the tree-walker invocation path (M1.1.15.2 G2,
//! `etch-abi-zig.md` §8 and §8.7).
//!
//! §8.7 records that the rest of §4, §6 and §8 describes invocation THROUGH THE
//! VM — `CALL_SERVICE`, `VMContext`, `callconv(.c)` trampolines, `service_ref_pool`
//! resolution at `.etchc` load — and that §15 bounds that path to Phase 2. This
//! file is the other path, and only its invocation step differs: the
//! `ServiceSpec`, the emitted `.d.etch`, the registry populated at startup and
//! the version field are the SAME objects under both. That sharing is what makes
//! the Phase 2 replacement invisible to user `.etch` code, which is the one
//! property §8.7 asks this design to hold.
//!
//! Four consequences of having no bytecode, each visible below: the name
//! resolves at the resolver and then by lookup at the call, arguments are
//! converted rather than pushed, the call is an ORDINARY Zig call with no
//! trampoline and no custom convention, and a Zig error union becomes an Etch
//! `throw` the tree-walker's `try` / `catch` consumes.
//!
//! Layering: this file knows nothing of `Value`, of the AST string pool or of
//! the interpreter. Arguments arrive already resolved as `Arg`, results leave as
//! `Ret`, and the conversion in both directions belongs to `interp.zig`, which is
//! the only layer that can resolve a string handle against its own pool.

const std = @import("std");

/// An Etch type as a service signature names it (`etch-abi-zig.md` §8.1). The
/// scalar set is what the Phase 1 tree-walker converts; `ref` names a declared
/// Etch type and is REFUSED at registration rather than at the call, so an
/// unconvertible type can never reach a running rule. Widening it is additive
/// and belongs to the gate that needs the type.
pub const TypeRef = union(enum) {
    void_,
    int_,
    float_,
    bool_,
    string_,
    entity_,
    /// A declared Etch type by name (`Vec3`, `AudioHandle`). Carried so the
    /// `.d.etch` emitter can render it and so a spec can DECLARE one; not
    /// convertible in Phase 1.
    ref: []const u8,

    pub fn isConvertible(self: TypeRef) bool {
        return self != .ref;
    }

    /// The name the `.d.etch` emitter renders for this type
    /// (`etch-grammar.md` §20.1 `function_decl_no_body`).
    pub fn etchName(self: TypeRef) []const u8 {
        return switch (self) {
            .void_ => "void",
            .int_ => "int",
            .float_ => "float",
            .bool_ => "bool",
            .string_ => "string",
            .entity_ => "Entity",
            .ref => |n| n,
        };
    }
};

/// One declared parameter. The NAME cannot be derived — Zig's `@typeInfo` does
/// not carry parameter names — so it is declared and the type is checked
/// against the implementation at comptime by `method`.
pub const ParamSpec = struct {
    name: []const u8,
    type: TypeRef,
};

/// An argument as the interpreter hands it over: already resolved, so a string
/// is bytes and not a handle into a pool this layer cannot see. Borrowed for the
/// duration of the call and never past it.
pub const Arg = union(enum) {
    int_: i64,
    float_: f64,
    bool_: bool,
    string_: []const u8,
    entity_: u64,
};

/// A result on its way back to the interpreter. A `string_` must point at bytes
/// that outlive the call — the interpreter copies it into its own run-string
/// store on receipt, so a slice into service-owned storage is safe and a slice
/// into a stack frame is not.
pub const Ret = union(enum) {
    void_,
    int_: i64,
    float_: f64,
    bool_: bool,
    string_: []const u8,
    entity_: u64,
};

/// The erased entry point. An ORDINARY Zig function pointer returning an
/// ORDINARY Zig error union — §8.7's "appel Zig direct — pas de trampoline, pas
/// de convention custom". The error union is the whole error protocol: there is
/// no `error_flag`, no thread-local, nothing to check after the call.
///
/// `ctx` is whatever the module handed to `register`, cast back by the adapter
/// `method` generates. `args` is positional and its length equals the declared
/// arity — the registry checks that before calling, so an implementation never
/// indexes past its own parameters.
pub const MethodFn = *const fn (ctx: ?*anyopaque, args: []const Arg) anyerror!Ret;

/// One declared method. Everything but `name`, `doc` and the parameter names
/// is derived from the Zig implementation by `method`.
pub const MethodSpec = struct {
    name: []const u8,
    params: []const ParamSpec,
    returns: TypeRef,
    /// Rendered as `throws` in the `.d.etch` and read by the type-checker to
    /// decide `E0902`. DERIVED from the implementation's return type by
    /// `method`, never declared: a hand-written `throws` that disagreed with the
    /// Zig signature is the drift class this milestone exists to close.
    throws: bool,
    /// Propagated to the `.d.etch` as a `///` doc comment (§8.2).
    doc: ?[]const u8 = null,
    /// §8.1 names this field `trampoline` because on the VM path it is one.
    /// Here it is not: no `callconv(.c)`, no stack discipline, no convention.
    call: MethodFn,
};

/// A Tier 1 service as `etch-abi-zig.md` §8.1 declares it: a name, a version
/// and its methods. The same object serves the emitter (§8.2), the registry
/// (§8.4) and, in Phase 2, the VM path — only the invocation step differs.
pub const ServiceSpec = struct {
    name: []const u8,
    /// §8.5 semantics: minor bump = additive, major = breaking. Carried because
    /// the emitter renders it and because both invocation paths share it. The
    /// load-time confrontation §8.5 describes keys on a `.etchc` and has no
    /// Phase 1 site; see the module note in `engine-phase-1-plan.md`.
    version: u32,
    methods: []const MethodSpec,
};

/// Map a Zig type onto the `TypeRef` a signature would name for it. `void` is
/// `.void_`; everything else that is not in the scalar set is a compile error at
/// the `method` call site, which is where an author can still fix it.
fn typeRefOf(comptime T: type) TypeRef {
    return switch (T) {
        void => .void_,
        i64 => .int_,
        f64 => .float_,
        bool => .bool_,
        []const u8 => .string_,
        u64 => .entity_,
        else => @compileError("service parameter/return type '" ++ @typeName(T) ++
            "' has no Etch mapping; the Phase 1 scalar set is {void, i64, f64, bool, []const u8, u64}"),
    };
}

fn argToZig(comptime T: type, a: Arg) !T {
    return switch (T) {
        i64 => if (a == .int_) a.int_ else error.ServiceArgTypeMismatch,
        f64 => switch (a) {
            .float_ => |f| f,
            // An `int` literal reaching a `float` parameter widens, which is the
            // rule Etch already applies at every other numeric boundary.
            .int_ => |i| @floatFromInt(i),
            else => error.ServiceArgTypeMismatch,
        },
        bool => if (a == .bool_) a.bool_ else error.ServiceArgTypeMismatch,
        []const u8 => if (a == .string_) a.string_ else error.ServiceArgTypeMismatch,
        u64 => if (a == .entity_) a.entity_ else error.ServiceArgTypeMismatch,
        else => @compileError("unreachable: typeRefOf refuses this type first"),
    };
}

fn zigToRet(comptime T: type, v: T) Ret {
    return switch (T) {
        void => Ret.void_,
        i64 => Ret{ .int_ = v },
        f64 => Ret{ .float_ = v },
        bool => Ret{ .bool_ = v },
        []const u8 => Ret{ .string_ = v },
        u64 => Ret{ .entity_ = v },
        else => @compileError("unreachable: typeRefOf refuses this type first"),
    };
}

/// Build a `MethodSpec` from an ordinary Zig function.
///
/// `ctx_type` is the pointer type the implementation wants as its first
/// parameter, or `void` for a context-free method. `param_names` names the
/// remaining parameters, in order — the only thing that cannot be derived.
/// Everything else IS derived: the parameter types, the return type, and whether
/// the method throws. A declared-vs-implemented divergence is therefore not
/// caught, it is impossible.
pub fn method(
    comptime name: []const u8,
    comptime doc: ?[]const u8,
    comptime ctx_type: type,
    comptime param_names: []const []const u8,
    comptime impl: anytype,
) MethodSpec {
    const info = @typeInfo(@TypeOf(impl)).@"fn";
    const has_ctx = ctx_type != void;
    const first = if (has_ctx) 1 else 0;

    if (info.params.len - first != param_names.len) {
        @compileError("service method '" ++ name ++ "': " ++
            "param_names has a different length than the implementation's parameter list");
    }
    if (has_ctx and info.params[0].type.? != ctx_type) {
        @compileError("service method '" ++ name ++ "': first parameter is not the declared ctx type");
    }

    const RetT = info.return_type.?;
    const ret_info = @typeInfo(RetT);
    const throws = ret_info == .error_union;
    const Payload = if (throws) ret_info.error_union.payload else RetT;

    const params_const = comptime blk: {
        var params: [param_names.len]ParamSpec = undefined;
        for (param_names, 0..) |pn, i| {
            params[i] = .{ .name = pn, .type = typeRefOf(info.params[first + i].type.?) };
        }
        break :blk params;
    };

    const Adapter = struct {
        fn call(ctx: ?*anyopaque, args: []const Arg) anyerror!Ret {
            var tuple: std.meta.ArgsTuple(@TypeOf(impl)) = undefined;
            if (has_ctx) tuple[0] = @ptrCast(@alignCast(ctx.?));
            inline for (0..param_names.len) |i| {
                tuple[first + i] = try argToZig(@TypeOf(tuple[first + i]), args[i]);
            }
            const raw = @call(.auto, impl, tuple);
            const value = if (throws) try raw else raw;
            return zigToRet(Payload, value);
        }
    };

    return .{
        .name = name,
        .params = &params_const,
        .returns = typeRefOf(Payload),
        .throws = throws,
        .doc = doc,
        .call = Adapter.call,
    };
}

/// One registered service: its spec plus the context every method receives.
pub const Entry = struct {
    spec: *const ServiceSpec,
    ctx: ?*anyopaque,
};

/// Refusals at registration. Both are refused BEFORE the insert, so a rejected
/// service leaves the registry exactly as it was.
pub const RegisterError = error{
    /// Two services registered under one name. Not last-wins: which
    /// implementation a rule reaches would then depend on module init order.
    DuplicateService,
    /// A method declares a `ref` type. Refused HERE and not at the call, so an
    /// unconvertible signature cannot reach a running rule (§8.7's conversion
    /// step has no answer for it, and a plausible-looking substitute is the
    /// defect class §8.7's closing paragraph names).
    UnconvertibleSignature,
    OutOfMemory,
};

/// Failures of the CALL MECHANISM, as opposed to failures returned BY a
/// service. The interpreter treats these as hard runtime failures and never as
/// catchable throws: a broken call site is a defect, not a domain error.
pub const CallError = error{
    /// No service of that name is registered. §8.6's release-mode "skip the
    /// `CALL_SERVICE`" has no tree-walker analogue: skipping an expression still
    /// owes the rule a value, and inventing one is exactly the truncated-prefix
    /// defect §8.7 refuses. So this fails in every build mode.
    ServiceNotRegistered,
    ServiceMethodNotFound,
    ServiceArgCountMismatch,
};

/// Populated once at runtime startup (§8.4) and read-only afterwards. Keyed by
/// name bytes on both levels: a service is named from Etch source, so the key is
/// what the author typed, never an index.
pub const Registry = struct {
    services: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.services.deinit(gpa);
    }

    /// §8.4's `register_from_spec`. The signature scan runs BEFORE the insert,
    /// so a refused service leaves the registry exactly as it was.
    pub fn register(
        self: *Registry,
        gpa: std.mem.Allocator,
        spec: *const ServiceSpec,
        ctx: ?*anyopaque,
    ) RegisterError!void {
        for (spec.methods) |m| {
            if (!m.returns.isConvertible()) return error.UnconvertibleSignature;
            for (m.params) |p| {
                if (!p.type.isConvertible()) return error.UnconvertibleSignature;
            }
        }
        const gop = try self.services.getOrPut(gpa, spec.name);
        if (gop.found_existing) return error.DuplicateService;
        gop.value_ptr.* = .{ .spec = spec, .ctx = ctx };
    }

    pub fn lookup(self: *const Registry, service_name: []const u8) ?Entry {
        return self.services.get(service_name);
    }

    pub fn lookupMethod(self: *const Registry, service_name: []const u8, method_name: []const u8) ?struct {
        entry: Entry,
        spec: *const MethodSpec,
    } {
        const entry = self.services.get(service_name) orelse return null;
        for (entry.spec.methods) |*m| {
            if (std.mem.eql(u8, m.name, method_name)) return .{ .entry = entry, .spec = m };
        }
        return null;
    }

    /// Invoke by name. Arity is checked here so no implementation indexes past
    /// its own parameters; the error union comes back untouched for the caller
    /// to turn into an Etch `throw`.
    pub fn call(
        self: *const Registry,
        service_name: []const u8,
        method_name: []const u8,
        args: []const Arg,
    ) anyerror!Ret {
        const found = self.lookupMethod(service_name, method_name) orelse {
            if (self.services.get(service_name) == null) return error.ServiceNotRegistered;
            return error.ServiceMethodNotFound;
        };
        if (args.len != found.spec.params.len) return error.ServiceArgCountMismatch;
        return found.spec.call(found.entry.ctx, args);
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const TestCtx = struct { calls: u32 = 0, base: i64 = 100 };

fn tEcho(ctx: *TestCtx, n: i64) i64 {
    ctx.calls += 1;
    return ctx.base + n;
}

fn tRisky(ctx: *TestCtx, n: i64) !i64 {
    ctx.calls += 1;
    if (n > 2) return error.TooBig;
    return n * 10;
}

fn tHalf(x: f64) f64 {
    return x / 2.0;
}

fn tNoCtx(flag: bool) bool {
    return !flag;
}

fn tVoid(ctx: *TestCtx) void {
    ctx.calls += 1;
}

fn tRefTyped(ctx: *TestCtx, n: i64) i64 {
    ctx.calls += 1;
    return n;
}

test "method derives its signature from the implementation" {
    const m = method("echo", "doc", *TestCtx, &.{"n"}, tEcho);
    try std.testing.expectEqualStrings("echo", m.name);
    try std.testing.expectEqualStrings("doc", m.doc.?);
    try std.testing.expectEqual(@as(usize, 1), m.params.len);
    try std.testing.expectEqualStrings("n", m.params[0].name);
    try std.testing.expectEqual(TypeRef.int_, m.params[0].type);
    try std.testing.expectEqual(TypeRef.int_, m.returns);
    // DERIVED, not declared: `tEcho` returns a plain `i64`.
    try std.testing.expect(!m.throws);

    // The twin, differing only in its return type, derives `throws = true` and
    // the SAME payload type. Without this pair the derivation could be a
    // constant and every assertion above would still hold.
    const r = method("risky", null, *TestCtx, &.{"n"}, tRisky);
    try std.testing.expect(r.throws);
    try std.testing.expectEqual(TypeRef.int_, r.returns);
    try std.testing.expect(r.doc == null);

    // A context-free method: the first Zig parameter is a real parameter.
    const nc = method("negate", null, void, &.{"flag"}, tNoCtx);
    try std.testing.expectEqual(@as(usize, 1), nc.params.len);
    try std.testing.expectEqual(TypeRef.bool_, nc.params[0].type);
    try std.testing.expectEqual(TypeRef.bool_, nc.returns);

    const v = method("tick", null, *TestCtx, &.{}, tVoid);
    try std.testing.expectEqual(@as(usize, 0), v.params.len);
    try std.testing.expectEqual(TypeRef.void_, v.returns);
}

test "a registered service calls through and its error union comes back intact" {
    const gpa = std.testing.allocator;
    var ctx: TestCtx = .{};
    const spec = ServiceSpec{
        .name = "toy",
        .version = 1,
        .methods = &.{
            method("echo", null, *TestCtx, &.{"n"}, tEcho),
            method("risky", null, *TestCtx, &.{"n"}, tRisky),
            method("tick", null, *TestCtx, &.{}, tVoid),
            method("half", null, void, &.{"x"}, tHalf),
        },
    };

    var reg: Registry = .{};
    defer reg.deinit(gpa);
    try reg.register(gpa, &spec, &ctx);

    const ok = try reg.call("toy", "echo", &.{.{ .int_ = 5 }});
    try std.testing.expectEqual(Ret{ .int_ = 105 }, ok);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);

    // The SAME method succeeds and fails on its argument, so the failure below
    // is the implementation's and not a dispatch that never ran.
    const good = try reg.call("toy", "risky", &.{.{ .int_ = 2 }});
    try std.testing.expectEqual(Ret{ .int_ = 20 }, good);
    try std.testing.expectError(error.TooBig, reg.call("toy", "risky", &.{.{ .int_ = 5 }}));
    try std.testing.expectEqual(@as(u32, 3), ctx.calls);

    // The ctx really is the caller's object and not a copy.
    _ = try reg.call("toy", "tick", &.{});
    try std.testing.expectEqual(@as(u32, 4), ctx.calls);

    // Lookup failures are distinguished, because "the module is absent" and
    // "the method name is wrong" call for different fixes.
    try std.testing.expectError(error.ServiceNotRegistered, reg.call("nope", "echo", &.{.{ .int_ = 1 }}));
    try std.testing.expectError(error.ServiceMethodNotFound, reg.call("toy", "nope", &.{.{ .int_ = 1 }}));
    try std.testing.expectError(error.ServiceArgCountMismatch, reg.call("toy", "echo", &.{}));
    try std.testing.expectError(error.ServiceArgTypeMismatch, reg.call("toy", "echo", &.{.{ .bool_ = true }}));

    // An `int` argument widens into a `float` parameter — the rule Etch already
    // applies at every other numeric boundary — and the reverse does NOT hold,
    // which is what makes the widening a decision rather than a loose check.
    try std.testing.expectEqual(Ret{ .float_ = 2.5 }, try reg.call("toy", "half", &.{.{ .float_ = 5.0 }}));
    try std.testing.expectEqual(Ret{ .float_ = 2.5 }, try reg.call("toy", "half", &.{.{ .int_ = 5 }}));
    try std.testing.expectError(error.ServiceArgTypeMismatch, reg.call("toy", "echo", &.{.{ .float_ = 5.0 }}));
}

test "registration refuses a duplicate name and an unconvertible signature" {
    const gpa = std.testing.allocator;
    var ctx: TestCtx = .{};
    const spec = ServiceSpec{
        .name = "toy",
        .version = 1,
        .methods = &.{method("echo", null, *TestCtx, &.{"n"}, tEcho)},
    };
    var reg: Registry = .{};
    defer reg.deinit(gpa);
    try reg.register(gpa, &spec, &ctx);
    try std.testing.expectError(error.DuplicateService, reg.register(gpa, &spec, &ctx));

    // A `ref` parameter is refused AT REGISTRATION, and the registry is left
    // exactly as it was — the scan runs before the insert. Asserted on the
    // registry's contents and not only on the returned error, since a refusal
    // that had already inserted would return the same error.
    const with_ref = ServiceSpec{
        .name = "vecs",
        .version = 1,
        .methods = &.{.{
            .name = "at",
            .params = &.{.{ .name = "p", .type = .{ .ref = "Vec3" } }},
            .returns = .int_,
            .throws = false,
            .call = method("at", null, *TestCtx, &.{"n"}, tRefTyped).call,
        }},
    };
    try std.testing.expectError(error.UnconvertibleSignature, reg.register(gpa, &with_ref, &ctx));
    try std.testing.expect(reg.lookup("vecs") == null);
    try std.testing.expect(reg.lookup("toy") != null);

    // And the same refusal on the RETURN side, which a params-only scan would
    // let through.
    const ref_ret = ServiceSpec{
        .name = "vecs2",
        .version = 1,
        .methods = &.{.{
            .name = "at",
            .params = &.{.{ .name = "n", .type = .int_ }},
            .returns = .{ .ref = "Vec3" },
            .throws = false,
            .call = method("at", null, *TestCtx, &.{"n"}, tRefTyped).call,
        }},
    };
    try std.testing.expectError(error.UnconvertibleSignature, reg.register(gpa, &ref_ret, &ctx));
    try std.testing.expect(reg.lookup("vecs2") == null);
}

test "etchName renders every TypeRef the emitter can meet" {
    // G3's emitter reads these. Asserted per variant rather than by a count, and
    // the switch in `etchName` is exhaustive, so a new variant is a compile
    // error there before it is a wrong string here.
    try std.testing.expectEqualStrings("void", (TypeRef{ .void_ = {} }).etchName());
    try std.testing.expectEqualStrings("int", (TypeRef{ .int_ = {} }).etchName());
    try std.testing.expectEqualStrings("float", (TypeRef{ .float_ = {} }).etchName());
    try std.testing.expectEqualStrings("bool", (TypeRef{ .bool_ = {} }).etchName());
    try std.testing.expectEqualStrings("string", (TypeRef{ .string_ = {} }).etchName());
    try std.testing.expectEqualStrings("Entity", (TypeRef{ .entity_ = {} }).etchName());
    try std.testing.expectEqualStrings("Vec3", (TypeRef{ .ref = "Vec3" }).etchName());
}
