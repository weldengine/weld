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
    .{ .name = "p22_type_alias_field", .etch_path = "tests/etch_interp/programs/22_type_alias_field.etch" },
    .{ .name = "p23_assert_guard", .etch_path = "tests/etch_interp/programs/23_assert_guard.etch" },
    .{ .name = "p24_match_dispatch", .etch_path = "tests/etch_interp/programs/24_match_dispatch.etch" },
    .{ .name = "p25_for_range_sum", .etch_path = "tests/etch_interp/programs/25_for_range_sum.etch" },
    .{ .name = "p26_array_index", .etch_path = "tests/etch_interp/programs/26_array_index.etch" },
    .{ .name = "p27_array_slice", .etch_path = "tests/etch_interp/programs/27_array_slice.etch" },
    .{ .name = "p28_for_array_sum", .etch_path = "tests/etch_interp/programs/28_for_array_sum.etch" },
    .{ .name = "p29_closure_apply", .etch_path = "tests/etch_interp/programs/29_closure_apply.etch" },
    .{ .name = "p30_loop_break_value", .etch_path = "tests/etch_interp/programs/30_loop_break_value.etch" },
    .{ .name = "p31_labeled_break", .etch_path = "tests/etch_interp/programs/31_labeled_break.etch" },
    .{ .name = "p32_block_expr_value", .etch_path = "tests/etch_interp/programs/32_block_expr_value.etch" },
    .{ .name = "p33_if_else", .etch_path = "tests/etch_interp/programs/33_if_else.etch" },
    .{ .name = "p34_while_sum", .etch_path = "tests/etch_interp/programs/34_while_sum.etch" },
    .{ .name = "p35_match_block_arm", .etch_path = "tests/etch_interp/programs/35_match_block_arm.etch" },
    .{ .name = "p36_loop_if_break", .etch_path = "tests/etch_interp/programs/36_loop_if_break.etch" },
    .{ .name = "p37_match_stmt_control", .etch_path = "tests/etch_interp/programs/37_match_stmt_control.etch" },
    .{ .name = "p38_fn_free_call", .etch_path = "tests/etch_interp/programs/38_fn_free_call.etch" },
    .{ .name = "p39_struct_method", .etch_path = "tests/etch_interp/programs/39_struct_method.etch" },
    .{ .name = "p40_enum_match", .etch_path = "tests/etch_interp/programs/40_enum_match.etch" },
    .{ .name = "p41_trait_method", .etch_path = "tests/etch_interp/programs/41_trait_method.etch" },
    .{ .name = "p42_optional_if_let", .etch_path = "tests/etch_interp/programs/42_optional_if_let.etch" },
    .{ .name = "p43_tag_filter_mutation", .etch_path = "tests/etch_interp/programs/43_tag_filter_mutation.etch" },
    .{ .name = "p44_changed_filter", .etch_path = "tests/etch_interp/programs/44_changed_filter.etch" },
    .{ .name = "p45_string_len", .etch_path = "tests/etch_interp/programs/45_string_len.etch" },
    .{ .name = "p46_string_concat", .etch_path = "tests/etch_interp/programs/46_string_concat.etch" },
    .{ .name = "p47_string_interp", .etch_path = "tests/etch_interp/programs/47_string_interp.etch" },
    .{ .name = "p48_error_throw_catch", .etch_path = "tests/etch_interp/programs/48_error_throw_catch.etch" },
    .{ .name = "p49_dyn_array_push", .etch_path = "tests/etch_interp/programs/49_dyn_array_push.etch" },
    .{ .name = "p50_map_insert_iterate", .etch_path = "tests/etch_interp/programs/50_map_insert_iterate.etch" },
    .{ .name = "p51_optional_ops", .etch_path = "tests/etch_interp/programs/51_optional_ops.etch" },
    .{ .name = "p52_enum_shorthand_field", .etch_path = "tests/etch_interp/programs/52_enum_shorthand_field.etch" },
    .{ .name = "p53_set_ops", .etch_path = "tests/etch_interp/programs/53_set_ops.etch" },
    .{ .name = "p54_mut_self_method", .etch_path = "tests/etch_interp/programs/54_mut_self_method.etch" },
    .{ .name = "p55_anon_struct_literal", .etch_path = "tests/etch_interp/programs/55_anon_struct_literal.etch" },
    .{ .name = "p56_closure_capture_value", .etch_path = "tests/etch_interp/programs/56_closure_capture_value.etch" },
    .{ .name = "p57_closure_block_return", .etch_path = "tests/etch_interp/programs/57_closure_block_return.etch" },
};
