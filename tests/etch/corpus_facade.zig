//! Corpus facade — exposes every fixture file under
//! `tests/etch/corpus/{valid,invalid}/` as a `[]const u8` constant so
//! that the bench binary (`bench/etch_parse.zig`) and the corpus driver
//! (`tests/etch/corpus_test.zig`) can both reach the same bytes through
//! a single module root. `@embedFile` is restricted to the package path
//! of the importing root, so this facade — sitting beside the corpus
//! tree — is the only module allowed to bake the fixtures in.

/// One row of the valid-corpus table. `name` is the relative path
/// under `corpus/valid/`; `source` is the `@embedFile`'d bytes
/// already bound at build time so the test target needs no I/O.
pub const Entry = struct {
    name: []const u8,
    source: []const u8,
};

/// Embedded entry for an invalid S3 corpus fixture — adds the expected
/// diagnostic code parsed from the filename prefix.
pub const InvalidEntry = struct {
    name: []const u8,
    /// Canonical short code (e.g. "E0001", "E1210") parsed from the
    /// filename prefix and asserted against the diagnostics emitted by
    /// the type-checker.
    expected_code: []const u8,
    source: []const u8,
};

/// Embedded list of the valid S3 corpus fixtures consumed by
/// `tests/etch/corpus_test.zig`. Each entry pins one `.etch` file
/// the parser + type-checker must accept without diagnostics.
pub const valid = [_]Entry{
    .{ .name = "components/health.etch", .source = @embedFile("corpus/valid/components/health.etch") },
    .{ .name = "components/transform.etch", .source = @embedFile("corpus/valid/components/transform.etch") },
    .{ .name = "components/inventory.etch", .source = @embedFile("corpus/valid/components/inventory.etch") },
    .{ .name = "components/combat.etch", .source = @embedFile("corpus/valid/components/combat.etch") },
    .{ .name = "components/movement.etch", .source = @embedFile("corpus/valid/components/movement.etch") },
    .{ .name = "components/minimal.etch", .source = @embedFile("corpus/valid/components/minimal.etch") },
    .{ .name = "components/multi_decl.etch", .source = @embedFile("corpus/valid/components/multi_decl.etch") },
    .{ .name = "components/annotated.etch", .source = @embedFile("corpus/valid/components/annotated.etch") },
    .{ .name = "components/sparse_tag.etch", .source = @embedFile("corpus/valid/components/sparse_tag.etch") },

    .{ .name = "resources/game_mode.etch", .source = @embedFile("corpus/valid/resources/game_mode.etch") },
    .{ .name = "resources/physics_config.etch", .source = @embedFile("corpus/valid/resources/physics_config.etch") },
    .{ .name = "resources/weather.etch", .source = @embedFile("corpus/valid/resources/weather.etch") },
    .{ .name = "resources/world_clock.etch", .source = @embedFile("corpus/valid/resources/world_clock.etch") },
    .{ .name = "resources/multi.etch", .source = @embedFile("corpus/valid/resources/multi.etch") },

    .{ .name = "rules/regen.etch", .source = @embedFile("corpus/valid/rules/regen.etch") },
    .{ .name = "rules/movement.etch", .source = @embedFile("corpus/valid/rules/movement.etch") },
    .{ .name = "rules/damage.etch", .source = @embedFile("corpus/valid/rules/damage.etch") },
    .{ .name = "rules/resource_only.etch", .source = @embedFile("corpus/valid/rules/resource_only.etch") },
    .{ .name = "rules/composition.etch", .source = @embedFile("corpus/valid/rules/composition.etch") },
    .{ .name = "rules/annotated.etch", .source = @embedFile("corpus/valid/rules/annotated.etch") },
    .{ .name = "rules/forward_ref.etch", .source = @embedFile("corpus/valid/rules/forward_ref.etch") },
    .{ .name = "rules/no_when.etch", .source = @embedFile("corpus/valid/rules/no_when.etch") },
    .{ .name = "rules/resource_access.etch", .source = @embedFile("corpus/valid/rules/resource_access.etch") },

    .{ .name = "whens/has_only.etch", .source = @embedFile("corpus/valid/whens/has_only.etch") },
    .{ .name = "whens/with_filter.etch", .source = @embedFile("corpus/valid/whens/with_filter.etch") },
    .{ .name = "whens/resource_when.etch", .source = @embedFile("corpus/valid/whens/resource_when.etch") },
    .{ .name = "whens/composition.etch", .source = @embedFile("corpus/valid/whens/composition.etch") },
    .{ .name = "whens/multi_entity.etch", .source = @embedFile("corpus/valid/whens/multi_entity.etch") },

    .{ .name = "exprs/arithmetic.etch", .source = @embedFile("corpus/valid/exprs/arithmetic.etch") },
    .{ .name = "exprs/float_math.etch", .source = @embedFile("corpus/valid/exprs/float_math.etch") },
    .{ .name = "exprs/comparisons.etch", .source = @embedFile("corpus/valid/exprs/comparisons.etch") },
    .{ .name = "exprs/literals.etch", .source = @embedFile("corpus/valid/exprs/literals.etch") },

    .{ .name = "data/item_database.etch", .source = @embedFile("corpus/valid/data/item_database.etch") },

    .{ .name = "routines/blacksmith_daily.etch", .source = @embedFile("corpus/valid/routines/blacksmith_daily.etch") },

    .{ .name = "behaviors/combat.etch", .source = @embedFile("corpus/valid/behaviors/combat.etch") },

    .{ .name = "quests/escort.etch", .source = @embedFile("corpus/valid/quests/escort.etch") },

    .{ .name = "dialogues/merchant.etch", .source = @embedFile("corpus/valid/dialogues/merchant.etch") },
    .{ .name = "abilities/fireball.etch", .source = @embedFile("corpus/valid/abilities/fireball.etch") },
};

/// Embedded list of the invalid S3 corpus fixtures. Each entry pins
/// an `.etch` file plus the diagnostic code (`E0xxx`) the corpus
/// driver expects the parser / type-checker to emit.
pub const invalid = [_]InvalidEntry{
    .{ .name = "E0001_unsupported_effect.etch", .expected_code = "E0001", .source = @embedFile("corpus/invalid/E0001_unsupported_effect.etch") },
    .{ .name = "E0001_unexpected_top_level.etch", .expected_code = "E0001", .source = @embedFile("corpus/invalid/E0001_unexpected_top_level.etch") },
    .{ .name = "E0101_duplicate_component.etch", .expected_code = "E0101", .source = @embedFile("corpus/invalid/E0101_duplicate_component.etch") },
    .{ .name = "E0102_unknown_field_type.etch", .expected_code = "E0102", .source = @embedFile("corpus/invalid/E0102_unknown_field_type.etch") },
    .{ .name = "E0102_string_field.etch", .expected_code = "E0102", .source = @embedFile("corpus/invalid/E0102_string_field.etch") },
    .{ .name = "E0200_int_plus_float.etch", .expected_code = "E0200", .source = @embedFile("corpus/invalid/E0200_int_plus_float.etch") },
    .{ .name = "E0301_resource_expected_component_given.etch", .expected_code = "E0301", .source = @embedFile("corpus/invalid/E0301_resource_expected_component_given.etch") },
    .{ .name = "E0302_component_expected_resource_given.etch", .expected_code = "E0302", .source = @embedFile("corpus/invalid/E0302_component_expected_resource_given.etch") },
    .{ .name = "E0502_annotation_misapplied.etch", .expected_code = "E0502", .source = @embedFile("corpus/invalid/E0502_annotation_misapplied.etch") },
    .{ .name = "E0503_storage_value_out_of_domain.etch", .expected_code = "E0503", .source = @embedFile("corpus/invalid/E0503_storage_value_out_of_domain.etch") },
    .{ .name = "E0504_storage_arg_not_const.etch", .expected_code = "E0504", .source = @embedFile("corpus/invalid/E0504_storage_arg_not_const.etch") },
    .{ .name = "E1101_non_const_default.etch", .expected_code = "E1101", .source = @embedFile("corpus/invalid/E1101_non_const_default.etch") },
    .{ .name = "E1210_unknown_component_in_when.etch", .expected_code = "E1210", .source = @embedFile("corpus/invalid/E1210_unknown_component_in_when.etch") },
    .{ .name = "E1211_field_filter_type_mismatch.etch", .expected_code = "E1211", .source = @embedFile("corpus/invalid/E1211_field_filter_type_mismatch.etch") },
    .{ .name = "E1213_resource_expected_in_when.etch", .expected_code = "E1213", .source = @embedFile("corpus/invalid/E1213_resource_expected_in_when.etch") },
    .{ .name = "E1540_quest_empty_stages.etch", .expected_code = "E1540", .source = @embedFile("corpus/invalid/E1540_quest_empty_stages.etch") },
    .{ .name = "E1541_duplicate_stage_name.etch", .expected_code = "E1541", .source = @embedFile("corpus/invalid/E1541_duplicate_stage_name.etch") },
    .{ .name = "E1542_quest_requires_not_bool.etch", .expected_code = "E1542", .source = @embedFile("corpus/invalid/E1542_quest_requires_not_bool.etch") },
    .{ .name = "E1543_objective_invalid_return.etch", .expected_code = "E1543", .source = @embedFile("corpus/invalid/E1543_objective_invalid_return.etch") },
    .{ .name = "E1545_switch_branch_target_not_found.etch", .expected_code = "E1545", .source = @embedFile("corpus/invalid/E1545_switch_branch_target_not_found.etch") },
    .{ .name = "E1546_branch_empty.etch", .expected_code = "E1546", .source = @embedFile("corpus/invalid/E1546_branch_empty.etch") },
    .{ .name = "E1547_branch_condition_not_bool.etch", .expected_code = "E1547", .source = @embedFile("corpus/invalid/E1547_branch_condition_not_bool.etch") },
    .{ .name = "E1548_property_invalid_type.etch", .expected_code = "E1548", .source = @embedFile("corpus/invalid/E1548_property_invalid_type.etch") },
    .{ .name = "E1550_event_reference_not_found.etch", .expected_code = "E1550", .source = @embedFile("corpus/invalid/E1550_event_reference_not_found.etch") },
    .{ .name = "E1560_dialogue_empty.etch", .expected_code = "E1560", .source = @embedFile("corpus/invalid/E1560_dialogue_empty.etch") },
    .{ .name = "E1561_duplicate_branch_label.etch", .expected_code = "E1561", .source = @embedFile("corpus/invalid/E1561_duplicate_branch_label.etch") },
    .{ .name = "E1562_branch_reference_not_found.etch", .expected_code = "E1562", .source = @embedFile("corpus/invalid/E1562_branch_reference_not_found.etch") },
    .{ .name = "E1564_choice_target_not_found.etch", .expected_code = "E1564", .source = @embedFile("corpus/invalid/E1564_choice_target_not_found.etch") },
    .{ .name = "E1565_line_condition_not_bool.etch", .expected_code = "E1565", .source = @embedFile("corpus/invalid/E1565_line_condition_not_bool.etch") },
    .{ .name = "E1566_choice_condition_not_bool.etch", .expected_code = "E1566", .source = @embedFile("corpus/invalid/E1566_choice_condition_not_bool.etch") },
    .{ .name = "E1567_dialogue_event_unknown.etch", .expected_code = "E1567", .source = @embedFile("corpus/invalid/E1567_dialogue_event_unknown.etch") },
    .{ .name = "E1580_ability_empty.etch", .expected_code = "E1580", .source = @embedFile("corpus/invalid/E1580_ability_empty.etch") },
    .{ .name = "E1581_cost_invalid.etch", .expected_code = "E1581", .source = @embedFile("corpus/invalid/E1581_cost_invalid.etch") },
    .{ .name = "E1582_cooldown_invalid.etch", .expected_code = "E1582", .source = @embedFile("corpus/invalid/E1582_cooldown_invalid.etch") },
    .{ .name = "E1583_required_tags_unknown.etch", .expected_code = "E1583", .source = @embedFile("corpus/invalid/E1583_required_tags_unknown.etch") },
    .{ .name = "E1584_blocked_tags_unknown.etch", .expected_code = "E1584", .source = @embedFile("corpus/invalid/E1584_blocked_tags_unknown.etch") },
    .{ .name = "E1586_tags_required_blocked_conflict.etch", .expected_code = "E1586", .source = @embedFile("corpus/invalid/E1586_tags_required_blocked_conflict.etch") },
    .{ .name = "E1760_data_empty_entries.etch", .expected_code = "E1760", .source = @embedFile("corpus/invalid/E1760_data_empty_entries.etch") },
    .{ .name = "E1761_duplicate_entry_id.etch", .expected_code = "E1761", .source = @embedFile("corpus/invalid/E1761_duplicate_entry_id.etch") },
    .{ .name = "E1762_entry_type_not_struct.etch", .expected_code = "E1762", .source = @embedFile("corpus/invalid/E1762_entry_type_not_struct.etch") },
    .{ .name = "E1763_entry_field_unknown.etch", .expected_code = "E1763", .source = @embedFile("corpus/invalid/E1763_entry_field_unknown.etch") },
    .{ .name = "E1764_entry_field_type_invalid.etch", .expected_code = "E1764", .source = @embedFile("corpus/invalid/E1764_entry_field_type_invalid.etch") },
    .{ .name = "E1765_entry_field_required_missing.etch", .expected_code = "E1765", .source = @embedFile("corpus/invalid/E1765_entry_field_required_missing.etch") },
    .{ .name = "E1766_spread_reference_not_found.etch", .expected_code = "E1766", .source = @embedFile("corpus/invalid/E1766_spread_reference_not_found.etch") },
    .{ .name = "E1767_spread_cycle.etch", .expected_code = "E1767", .source = @embedFile("corpus/invalid/E1767_spread_cycle.etch") },
    .{ .name = "E1768_id_invalid_format.etch", .expected_code = "E1768", .source = @embedFile("corpus/invalid/E1768_id_invalid_format.etch") },
    .{ .name = "E1500_behavior_root_missing.etch", .expected_code = "E1500", .source = @embedFile("corpus/invalid/E1500_behavior_root_missing.etch") },
    .{ .name = "E1501_behavior_empty_composite.etch", .expected_code = "E1501", .source = @embedFile("corpus/invalid/E1501_behavior_empty_composite.etch") },
    .{ .name = "E1502_behavior_invalid_leaf.etch", .expected_code = "E1502", .source = @embedFile("corpus/invalid/E1502_behavior_invalid_leaf.etch") },
    .{ .name = "E1503_behavior_condition_not_bool.etch", .expected_code = "E1503", .source = @embedFile("corpus/invalid/E1503_behavior_condition_not_bool.etch") },
    .{ .name = "E1504_behavior_action_invalid_return.etch", .expected_code = "E1504", .source = @embedFile("corpus/invalid/E1504_behavior_action_invalid_return.etch") },
    .{ .name = "E1505_behavior_when_not_bool.etch", .expected_code = "E1505", .source = @embedFile("corpus/invalid/E1505_behavior_when_not_bool.etch") },
    .{ .name = "E1506_behavior_recursion.etch", .expected_code = "E1506", .source = @embedFile("corpus/invalid/E1506_behavior_recursion.etch") },
    .{ .name = "E1520_routine_empty_segments.etch", .expected_code = "E1520", .source = @embedFile("corpus/invalid/E1520_routine_empty_segments.etch") },
    .{ .name = "E1521_duplicate_segment_name.etch", .expected_code = "E1521", .source = @embedFile("corpus/invalid/E1521_duplicate_segment_name.etch") },
    .{ .name = "E1522_trigger_invalid.etch", .expected_code = "E1522", .source = @embedFile("corpus/invalid/E1522_trigger_invalid.etch") },
    .{ .name = "E1523_until_invalid.etch", .expected_code = "E1523", .source = @embedFile("corpus/invalid/E1523_until_invalid.etch") },
    .{ .name = "E1524_segment_reference_not_found.etch", .expected_code = "E1524", .source = @embedFile("corpus/invalid/E1524_segment_reference_not_found.etch") },
    .{ .name = "E1525_event_type_unknown.etch", .expected_code = "E1525", .source = @embedFile("corpus/invalid/E1525_event_type_unknown.etch") },
    .{ .name = "E1526_interrupt_target_invalid.etch", .expected_code = "E1526", .source = @embedFile("corpus/invalid/E1526_interrupt_target_invalid.etch") },
    .{ .name = "E1527_action_invalid_return.etch", .expected_code = "E1527", .source = @embedFile("corpus/invalid/E1527_action_invalid_return.etch") },
};
