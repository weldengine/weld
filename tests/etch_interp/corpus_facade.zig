//! Comptime-enumerated registry of the S4 differential corpus. Same idea
//! as `tests/etch/corpus_facade.zig` (S3): the facade sits next to the
//! corpus so `@embedFile` works against the local package, and exposes a
//! single `programs` array consumed by the test driver.
//!
//! Each entry pairs a `.etch` source file with its `.expected.zig`
//! sidecar (declaring `config`, `initial`, `expected` constants). The
//! generic driver `diff_runner.zig` runs through every entry; S5 will
//! reuse this same facade with a codegen runner.

const driver = @import("diff_runner");

/// One differential corpus program — Etch source plus the sidecar's
/// `(config, initial, expected)` triplet consumed by `diff_runner`.
pub const Program = struct {
    name: []const u8,
    source: []const u8,
    config: driver.Config,
    initial: driver.WorldSpec,
    expected: driver.ExpectedWorld,
};

const p01 = @import("programs/01_arith_int_let.expected.zig");
const p02 = @import("programs/02_arith_float_compound.expected.zig");
const p03 = @import("programs/03_arith_div_mod.expected.zig");
const p04 = @import("programs/04_mutation_counter_inc.expected.zig");
const p05 = @import("programs/05_mutation_health_decay.expected.zig");
const p06 = @import("programs/06_mutation_two_components.expected.zig");
const p07 = @import("programs/07_when_single_component.expected.zig");
const p08 = @import("programs/08_when_single_float.expected.zig");
const p09 = @import("programs/09_when_and.expected.zig");
const p10 = @import("programs/10_when_and_not.expected.zig");
const p11 = @import("programs/11_when_or.expected.zig");
const p12 = @import("programs/12_filter_int_eq.expected.zig");
const p13 = @import("programs/13_filter_bool_eq.expected.zig");
const p14 = @import("programs/14_filter_float_eq.expected.zig");
const p15 = @import("programs/15_resource_gate.expected.zig");
const p16 = @import("programs/16_resource_with_component.expected.zig");
const p17 = @import("programs/17_resource_changed_dirty.expected.zig");
const p18 = @import("programs/18_resource_changed_clean.expected.zig");
const p19 = @import("programs/19_rule_order_sees_mutation.expected.zig");
const p20 = @import("programs/20_rule_order_sees_previous.expected.zig");
const p21 = @import("programs/21_cast_int_to_float.expected.zig");
const p22 = @import("programs/22_type_alias_field.expected.zig");
const p23 = @import("programs/23_assert_guard.expected.zig");
const p24 = @import("programs/24_match_dispatch.expected.zig");
const p25 = @import("programs/25_for_range_sum.expected.zig");
const p26 = @import("programs/26_array_index.expected.zig");
const p27 = @import("programs/27_array_slice.expected.zig");
const p28 = @import("programs/28_for_array_sum.expected.zig");
const p29 = @import("programs/29_closure_apply.expected.zig");
const p30 = @import("programs/30_loop_break_value.expected.zig");
const p31 = @import("programs/31_labeled_break.expected.zig");

/// Embedded list of the 20 differential corpus programs consumed by
/// the S4 interpreter test and the S5 codegen parity test.
pub const programs = [_]Program{
    .{ .name = "01_arith_int_let", .source = @embedFile("programs/01_arith_int_let.etch"), .config = p01.config, .initial = p01.initial, .expected = p01.expected },
    .{ .name = "02_arith_float_compound", .source = @embedFile("programs/02_arith_float_compound.etch"), .config = p02.config, .initial = p02.initial, .expected = p02.expected },
    .{ .name = "03_arith_div_mod", .source = @embedFile("programs/03_arith_div_mod.etch"), .config = p03.config, .initial = p03.initial, .expected = p03.expected },
    .{ .name = "04_mutation_counter_inc", .source = @embedFile("programs/04_mutation_counter_inc.etch"), .config = p04.config, .initial = p04.initial, .expected = p04.expected },
    .{ .name = "05_mutation_health_decay", .source = @embedFile("programs/05_mutation_health_decay.etch"), .config = p05.config, .initial = p05.initial, .expected = p05.expected },
    .{ .name = "06_mutation_two_components", .source = @embedFile("programs/06_mutation_two_components.etch"), .config = p06.config, .initial = p06.initial, .expected = p06.expected },
    .{ .name = "07_when_single_component", .source = @embedFile("programs/07_when_single_component.etch"), .config = p07.config, .initial = p07.initial, .expected = p07.expected },
    .{ .name = "08_when_single_float", .source = @embedFile("programs/08_when_single_float.etch"), .config = p08.config, .initial = p08.initial, .expected = p08.expected },
    .{ .name = "09_when_and", .source = @embedFile("programs/09_when_and.etch"), .config = p09.config, .initial = p09.initial, .expected = p09.expected },
    .{ .name = "10_when_and_not", .source = @embedFile("programs/10_when_and_not.etch"), .config = p10.config, .initial = p10.initial, .expected = p10.expected },
    .{ .name = "11_when_or", .source = @embedFile("programs/11_when_or.etch"), .config = p11.config, .initial = p11.initial, .expected = p11.expected },
    .{ .name = "12_filter_int_eq", .source = @embedFile("programs/12_filter_int_eq.etch"), .config = p12.config, .initial = p12.initial, .expected = p12.expected },
    .{ .name = "13_filter_bool_eq", .source = @embedFile("programs/13_filter_bool_eq.etch"), .config = p13.config, .initial = p13.initial, .expected = p13.expected },
    .{ .name = "14_filter_float_eq", .source = @embedFile("programs/14_filter_float_eq.etch"), .config = p14.config, .initial = p14.initial, .expected = p14.expected },
    .{ .name = "15_resource_gate", .source = @embedFile("programs/15_resource_gate.etch"), .config = p15.config, .initial = p15.initial, .expected = p15.expected },
    .{ .name = "16_resource_with_component", .source = @embedFile("programs/16_resource_with_component.etch"), .config = p16.config, .initial = p16.initial, .expected = p16.expected },
    .{ .name = "17_resource_changed_dirty", .source = @embedFile("programs/17_resource_changed_dirty.etch"), .config = p17.config, .initial = p17.initial, .expected = p17.expected },
    .{ .name = "18_resource_changed_clean", .source = @embedFile("programs/18_resource_changed_clean.etch"), .config = p18.config, .initial = p18.initial, .expected = p18.expected },
    .{ .name = "19_rule_order_sees_mutation", .source = @embedFile("programs/19_rule_order_sees_mutation.etch"), .config = p19.config, .initial = p19.initial, .expected = p19.expected },
    .{ .name = "20_rule_order_sees_previous", .source = @embedFile("programs/20_rule_order_sees_previous.etch"), .config = p20.config, .initial = p20.initial, .expected = p20.expected },
    .{ .name = "21_cast_int_to_float", .source = @embedFile("programs/21_cast_int_to_float.etch"), .config = p21.config, .initial = p21.initial, .expected = p21.expected },
    .{ .name = "22_type_alias_field", .source = @embedFile("programs/22_type_alias_field.etch"), .config = p22.config, .initial = p22.initial, .expected = p22.expected },
    .{ .name = "23_assert_guard", .source = @embedFile("programs/23_assert_guard.etch"), .config = p23.config, .initial = p23.initial, .expected = p23.expected },
    .{ .name = "24_match_dispatch", .source = @embedFile("programs/24_match_dispatch.etch"), .config = p24.config, .initial = p24.initial, .expected = p24.expected },
    .{ .name = "25_for_range_sum", .source = @embedFile("programs/25_for_range_sum.etch"), .config = p25.config, .initial = p25.initial, .expected = p25.expected },
    .{ .name = "26_array_index", .source = @embedFile("programs/26_array_index.etch"), .config = p26.config, .initial = p26.initial, .expected = p26.expected },
    .{ .name = "27_array_slice", .source = @embedFile("programs/27_array_slice.etch"), .config = p27.config, .initial = p27.initial, .expected = p27.expected },
    .{ .name = "28_for_array_sum", .source = @embedFile("programs/28_for_array_sum.etch"), .config = p28.config, .initial = p28.initial, .expected = p28.expected },
    .{ .name = "29_closure_apply", .source = @embedFile("programs/29_closure_apply.etch"), .config = p29.config, .initial = p29.initial, .expected = p29.expected },
    .{ .name = "30_loop_break_value", .source = @embedFile("programs/30_loop_break_value.etch"), .config = p30.config, .initial = p30.initial, .expected = p30.expected },
    .{ .name = "31_labeled_break", .source = @embedFile("programs/31_labeled_break.etch"), .config = p31.config, .initial = p31.initial, .expected = p31.expected },
};
