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

    .{ .name = "whens/has_only.etch", .source = @embedFile("corpus/valid/whens/has_only.etch") },
    .{ .name = "whens/with_filter.etch", .source = @embedFile("corpus/valid/whens/with_filter.etch") },
    .{ .name = "whens/resource_when.etch", .source = @embedFile("corpus/valid/whens/resource_when.etch") },
    .{ .name = "whens/composition.etch", .source = @embedFile("corpus/valid/whens/composition.etch") },
    .{ .name = "whens/multi_entity.etch", .source = @embedFile("corpus/valid/whens/multi_entity.etch") },

    .{ .name = "exprs/arithmetic.etch", .source = @embedFile("corpus/valid/exprs/arithmetic.etch") },
    .{ .name = "exprs/float_math.etch", .source = @embedFile("corpus/valid/exprs/float_math.etch") },
    .{ .name = "exprs/comparisons.etch", .source = @embedFile("corpus/valid/exprs/comparisons.etch") },
    .{ .name = "exprs/literals.etch", .source = @embedFile("corpus/valid/exprs/literals.etch") },
};

/// Embedded list of the invalid S3 corpus fixtures. Each entry pins
/// an `.etch` file plus the diagnostic code (`E0xxx`) the corpus
/// driver expects the parser / type-checker to emit.
pub const invalid = [_]InvalidEntry{
    .{ .name = "E0001_unsupported_fn.etch", .expected_code = "E0001", .source = @embedFile("corpus/invalid/E0001_unsupported_fn.etch") },
    .{ .name = "E0001_unexpected_top_level.etch", .expected_code = "E0001", .source = @embedFile("corpus/invalid/E0001_unexpected_top_level.etch") },
    .{ .name = "E0101_duplicate_component.etch", .expected_code = "E0101", .source = @embedFile("corpus/invalid/E0101_duplicate_component.etch") },
    .{ .name = "E0102_unknown_field_type.etch", .expected_code = "E0102", .source = @embedFile("corpus/invalid/E0102_unknown_field_type.etch") },
    .{ .name = "E0102_string_field.etch", .expected_code = "E0102", .source = @embedFile("corpus/invalid/E0102_string_field.etch") },
    .{ .name = "E0200_int_plus_float.etch", .expected_code = "E0200", .source = @embedFile("corpus/invalid/E0200_int_plus_float.etch") },
    .{ .name = "E0502_annotation_misapplied.etch", .expected_code = "E0502", .source = @embedFile("corpus/invalid/E0502_annotation_misapplied.etch") },
    .{ .name = "E1101_non_const_default.etch", .expected_code = "E1101", .source = @embedFile("corpus/invalid/E1101_non_const_default.etch") },
    .{ .name = "E1210_unknown_component_in_when.etch", .expected_code = "E1210", .source = @embedFile("corpus/invalid/E1210_unknown_component_in_when.etch") },
    .{ .name = "E1211_field_filter_type_mismatch.etch", .expected_code = "E1211", .source = @embedFile("corpus/invalid/E1211_field_filter_type_mismatch.etch") },
    .{ .name = "E1213_resource_expected_in_when.etch", .expected_code = "E1213", .source = @embedFile("corpus/invalid/E1213_resource_expected_in_when.etch") },
};
