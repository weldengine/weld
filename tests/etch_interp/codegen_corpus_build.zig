//! S5 build helper — single source of truth for the list of differential
//! corpus programs that get cooked by `tools/etch_cook` at `zig build`
//! time. Both `build.zig` (to drive the `addRunArtifact` invocation) and
//! the unit tests (for assertions about the codegen output) import this
//! file. Kept in `tests/etch_interp/` next to the programs themselves so
//! the namespace ↔ path mapping is co-located with the corpus.

/// Each entry pairs a namespace identifier (the name of the nested struct
/// emitted into the consolidated `corpus_codegen.zig`) with the relative
/// path to the source `.etch` file. The namespace name is also the
/// `Program.name` field looked up by `runner_codegen.lookupByName`.
pub const CodegenProgram = struct {
    name: []const u8,
    etch_path: []const u8,
};

/// Pinned list of the 20 differential programs that `tools/etch_cook`
/// cooks into the consolidated `corpus_codegen.zig` during `zig build`.
pub const programs = [_]CodegenProgram{
    .{ .name = "p01_arith_int_let", .etch_path = "tests/etch_interp/programs/01_arith_int_let.etch" },
    .{ .name = "p02_arith_float_compound", .etch_path = "tests/etch_interp/programs/02_arith_float_compound.etch" },
    .{ .name = "p03_arith_div_mod", .etch_path = "tests/etch_interp/programs/03_arith_div_mod.etch" },
    .{ .name = "p04_mutation_counter_inc", .etch_path = "tests/etch_interp/programs/04_mutation_counter_inc.etch" },
    .{ .name = "p05_mutation_health_decay", .etch_path = "tests/etch_interp/programs/05_mutation_health_decay.etch" },
    .{ .name = "p06_mutation_two_components", .etch_path = "tests/etch_interp/programs/06_mutation_two_components.etch" },
    .{ .name = "p07_when_single_component", .etch_path = "tests/etch_interp/programs/07_when_single_component.etch" },
    .{ .name = "p08_when_single_float", .etch_path = "tests/etch_interp/programs/08_when_single_float.etch" },
    .{ .name = "p09_when_and", .etch_path = "tests/etch_interp/programs/09_when_and.etch" },
    .{ .name = "p10_when_and_not", .etch_path = "tests/etch_interp/programs/10_when_and_not.etch" },
    .{ .name = "p11_when_or", .etch_path = "tests/etch_interp/programs/11_when_or.etch" },
    .{ .name = "p12_filter_int_eq", .etch_path = "tests/etch_interp/programs/12_filter_int_eq.etch" },
    .{ .name = "p13_filter_bool_eq", .etch_path = "tests/etch_interp/programs/13_filter_bool_eq.etch" },
    .{ .name = "p14_filter_float_eq", .etch_path = "tests/etch_interp/programs/14_filter_float_eq.etch" },
    .{ .name = "p15_resource_gate", .etch_path = "tests/etch_interp/programs/15_resource_gate.etch" },
    .{ .name = "p16_resource_with_component", .etch_path = "tests/etch_interp/programs/16_resource_with_component.etch" },
    .{ .name = "p17_resource_changed_dirty", .etch_path = "tests/etch_interp/programs/17_resource_changed_dirty.etch" },
    .{ .name = "p18_resource_changed_clean", .etch_path = "tests/etch_interp/programs/18_resource_changed_clean.etch" },
    .{ .name = "p19_rule_order_sees_mutation", .etch_path = "tests/etch_interp/programs/19_rule_order_sees_mutation.etch" },
    .{ .name = "p20_rule_order_sees_previous", .etch_path = "tests/etch_interp/programs/20_rule_order_sees_previous.etch" },
    .{ .name = "p21_cast_int_to_float", .etch_path = "tests/etch_interp/programs/21_cast_int_to_float.etch" },
};
