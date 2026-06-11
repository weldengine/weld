//! Etch parser diagnostics — typed `Diagnostic`, stable `DiagnosticCode`
//! names cross-version, and on-demand `(line, column)` computation from a
//! `LineIndex` built once per source.
//!
//! The S3 subset emits the codes listed in `briefs/S3-etch-parser-subset.md`
//! Scope / Diagnostics typed API. Codes are stable cross-version per the
//! reference catalogue in `etch-diagnostics.md` §1; new variants may be
//! added in later phases without renumbering existing ones.

const std = @import("std");
const token = @import("token.zig");

const SourceSpan = token.SourceSpan;

/// Severity classes recognised by the S3 type-checker. The brief carves
/// `error_` and `warning`; the wider catalogue (`note`, `hint`) is
/// documented for forward compatibility but unused in S3.
pub const Severity = enum {
    error_,
    warning,
};

/// Stable cross-version diagnostic codes. The variant name (e.g.
/// `parse_error`) maps to the canonical short code (`E0001`) via
/// `code()` and to the canonical PascalCase name (`ParseError`) via
/// `name()`. S3 emits only the variants commented `S3`; the others are
/// reserved here so the enum can be extended additively in later phases.
pub const DiagnosticCode = enum {
    // ── Parse / lex errors (E0001-E0099) ──
    parse_error, // S3 — E0001 ParseError

    // ── Resolver — symbols / paths (E0100-E0199) ──
    duplicate_symbol, // S3 — E0101 DuplicateSymbol
    undefined_symbol, // S3 — E0102 UndefinedSymbol
    enum_variant_not_found, // M0.8 — E0105 EnumVariantNotFound

    // ── Type errors (E0200-E0299) ──
    type_mismatch, // S3 — E0200 TypeMismatch
    arg_count_mismatch, // M0.8 E4 — E0203 ArgCountMismatch (unfolded from E0200, E3 gate flag 5; also named-arg binding failures)
    return_type_mismatch, // M0.8 E4 — E0204 ReturnTypeMismatch (unfolded from E0200, E3 gate flag 5)
    struct_field_missing, // M0.8 — E0208 StructFieldMissing
    ambiguous_type, // M0.8 — E0210 AmbiguousType
    ambiguous_trait_method, // M0.8 — E0211 AmbiguousTraitMethod
    incomplete_trait_impl, // M0.8 — E0214 IncompleteTraitImpl
    conditional_impl_condition_not_proven, // M0.8 — E0215 ConditionalImplConditionNotProven
    orphan_impl, // M0.8 — E0217 OrphanImpl
    immutable_receiver_for_mut_self, // M0.8 — E0220 ImmutableReceiverForMutSelfMethod
    closure_cannot_mutate_capture, // M0.8 — E0221 ClosureCannotMutateCapture

    // ── ECS access errors (E0300-E0399) ──
    resource_expected_component_given, // M0.8 — E0301 ResourceExpectedComponentGiven
    component_expected_resource_given, // M0.8 — E0302 ComponentExpectedResourceGiven

    // ── Annotation errors (E0500-E0599) ──
    annotation_misapplied, // M0.8 — E0502 AnnotationMisapplied

    // ── Generics (E0600-E0699) ──
    bound_not_satisfied, // M0.8 — E0601 BoundNotSatisfied
    generic_type_annotation_required, // M0.8 — E0603 GenericTypeAnnotationRequired
    inconsistent_generic_inference, // M0.8 — E0604 InconsistentGenericInference

    // ── Tags (E0800-E0899) ──
    tag_path_invalid, // M0.8 E3 — E0830 TagPathInvalid (path not declared, general/mutation context)
    tag_path_conflict, // M0.8 E3 — E0831 TagPathConflict (leaf vs namespace, or duplicate leaf)
    tag_bitfield_overflow, // M0.8 E3 — E0832 TagBitfieldOverflow
    tag_invalid_operation, // M0.8 E3 — E0833 TagInvalidOperation (tag op on non-Entity)

    // ── Const eval errors (E1100-E1199) ──
    not_const_evaluable, // S3 — E1101 NotConstEvaluable

    // ── Rule-specific errors (E1200-E1299) ──
    on_event_type_mismatch, // M0.8 E3 — E1203 OnEventTypeMismatch (@on_event(T) ↔ event binding type)
    unknown_component_in_when, // S3 — E1210 UnknownComponentInWhen
    invalid_field_filter, // S3 — E1211 InvalidFieldFilter
    unknown_tag, // M0.8 E3 — E1212 UnknownTag (tag path in a `when` clause)
    resource_expected_in_when, // S3 — E1213 ResourceExpectedInWhen
    non_exhaustive_match, // M0.8 — E1230 NonExhaustiveMatch

    // ── behavior (E1500-E1519, M0.8 E4 — etch-validation-ecs.md §8) ──
    behavior_root_missing, // M0.8 E4 — E1500 BehaviorRootMissing
    behavior_empty_composite, // M0.8 E4 — E1501 BehaviorEmptyComposite
    behavior_invalid_leaf, // M0.8 E4 — E1502 BehaviorInvalidLeaf (unknown behavior/routine referenced by a leaf intrinsic)
    behavior_condition_not_bool, // M0.8 E4 — E1503 BehaviorConditionNotBool
    behavior_action_invalid_return, // M0.8 E4 — E1504 BehaviorActionInvalidReturn (void per the item-3 ruling)
    behavior_when_clause_not_bool, // M0.8 E4 — E1505 BehaviorWhenClauseNotBool
    behavior_recursion, // M0.8 E4 — E1506 BehaviorRecursion

    // ── quest (E1540-E1559, M0.8 E4 — etch-validation-ecs.md §10) ──
    quest_empty_stages, // M0.8 E4 — E1540 QuestEmptyStages
    duplicate_stage_name, // M0.8 E4 — E1541 DuplicateStageName
    quest_requires_not_bool, // M0.8 E4 — E1542 QuestRequiresNotBool
    objective_invalid_return, // M0.8 E4 — E1543 ObjectiveInvalidReturn
    on_fail_action_invalid, // M0.8 E4 — E1544 OnFailActionInvalid (parse-enforced terminal set; no post-parse case)
    switch_branch_target_not_found, // M0.8 E4 — E1545 SwitchBranchTargetNotFound
    branch_empty, // M0.8 E4 — E1546 BranchEmpty
    branch_condition_not_bool, // M0.8 E4 — E1547 BranchConditionNotBool
    property_invalid_type, // M0.8 E4 — E1548 PropertyInvalidType
    objective_modifier_invalid, // M0.8 E4 — E1549 ObjectiveModifierInvalid (parse-enforced; no post-parse case)
    event_reference_not_found, // M0.8 E4 — E1550 EventReferenceNotFound
    no_main_objective, // M0.8 E4 — W1541 NoMainObjective (warning)

    // ── routine (E1520-E1539, M0.8 E4 — etch-validation-ecs.md §9) ──
    routine_empty_segments, // M0.8 E4 — E1520 RoutineEmptySegments
    duplicate_segment_name, // M0.8 E4 — E1521 DuplicateSegmentName
    trigger_invalid, // M0.8 E4 — E1522 TriggerInvalid
    until_invalid, // M0.8 E4 — E1523 UntilInvalid
    segment_reference_not_found, // M0.8 E4 — E1524 SegmentReferenceNotFound
    event_type_unknown, // M0.8 E4 — E1525 EventTypeUnknown
    interrupt_target_invalid, // M0.8 E4 — E1526 InterruptTargetInvalid
    action_invalid_return, // M0.8 E4 — E1527 ActionInvalidReturn

    // ── dialogue (E1560-E1579, M0.8 E4 — etch-validation-ecs.md §11) ──
    dialogue_empty, // M0.8 E4 — E1560 DialogueEmpty
    duplicate_branch_label, // M0.8 E4 — E1561 DuplicateBranchLabel
    branch_reference_not_found, // M0.8 E4 — E1562 BranchReferenceNotFound
    speaker_not_found, // M0.8 E4 — E1563 SpeakerNotFound (vacuous in E4: scene/prefab context is E7; any string is referencable — recorded)
    choice_target_not_found, // M0.8 E4 — E1564 ChoiceTargetNotFound
    line_condition_not_bool, // M0.8 E4 — E1565 LineConditionNotBool
    choice_condition_not_bool, // M0.8 E4 — E1566 ChoiceConditionNotBool
    dialogue_event_type_unknown, // M0.8 E4 — E1567 EventTypeUnknown (dialogue emit)

    // ── ability (E1580-E1599, M0.8 E4 — etch-validation-ecs.md §12, the
    // items 12-15 ruling transposition onto the §8.5 grammar shape; E1585
    // HandlerInvalidReturn and W1580 DuplicateHandler are RESERVED — the
    // ruled shape has no handlers) ──
    ability_empty, // M0.8 E4 — E1580 AbilityEmpty (neither property nor rule; transposed from AbilityEmptyHandlers)
    cost_invalid, // M0.8 E4 — E1581 CostInvalid (cost key is not a numeric field of a declared resource)
    cooldown_invalid, // M0.8 E4 — E1582 CooldownInvalid (non-numeric or negative-literal cooldown)
    required_tags_unknown, // M0.8 E4 — E1583 RequiresTagsUnknown (keyed on the §8.5 name `tags_required`)
    blocked_tags_unknown, // M0.8 E4 — E1584 RequiresNotTagsUnknown (keyed on the §8.5 name `tags_blocked`)
    tags_required_blocked_conflict, // M0.8 E4 — E1586 TagsRequiredBlockedConflict

    // ── data tables (E1760-E1779, M0.8 E4 — etch-validation-ecs.md §22) ──
    data_empty_entries, // M0.8 E4 — E1760 DataEmptyEntries
    duplicate_entry_id, // M0.8 E4 — E1761 DuplicateEntryId
    entry_type_mismatch, // M0.8 E4 — E1762 EntryTypeMismatch
    entry_field_unknown, // M0.8 E4 — E1763 EntryFieldUnknown
    entry_field_type_invalid, // M0.8 E4 — E1764 EntryFieldTypeInvalid
    entry_field_required_missing, // M0.8 E4 — E1765 EntryFieldRequiredMissing
    spread_reference_not_found, // M0.8 E4 — E1766 SpreadReferenceNotFound
    spread_cycle, // M0.8 E4 — E1767 SpreadCycle
    id_invalid_format, // M0.8 E4 — E1768 IdInvalidFormat

    // ── theme (E1640-E1645, M0.8 E5 — etch-grammar.md §10.2; the E5 ruling 1:
    // the grammar `theme STRING_LITERAL { IDENT ":" expression }` shape WINS
    // over the validation-ecs §16.1 typed-token shape, so E1642
    // TokenTypeInvalid / E1643 TokenDefaultMissing are RESERVED — the grammar
    // entries are untyped `key: expr` with no defaults) ──
    theme_empty, // M0.8 E5 — E1640 ThemeEmpty (no entries)
    duplicate_token_name, // M0.8 E5 — E1641 DuplicateTokenName (duplicate entry key)
    token_type_invalid, // M0.8 E5 — E1642 TokenTypeInvalid (RESERVED: no typed tokens in the grammar shape)
    token_default_missing, // M0.8 E5 — E1643 TokenDefaultMissing (RESERVED: no token defaults in the grammar shape)

    // ── motion (E1660-E1668, M0.8 E5 — etch-grammar.md §10.3; E5 ruling 2:
    // the grammar `motion TYPE_IDENT { [states {…}] transitions {…} }` shape
    // WINS over the validation-ecs §17 shape. RESERVED with rationale:
    // E1660 (the grammar makes the `states` block optional, so the relaxed
    // ≥1 check would reject a grammar-valid stateless motion), E1662/E1663
    // (state-field typing + cross-state interpolation consistency are a
    // Kinesis Phase-1 semantic, not a declarative M0.8 validation — part2's
    // own canonical example violates E1663), E1667/E1668 (the grammar has no
    // `initial` clause). W1660/W1661 (heuristic Phase-3 warnings) are
    // DEFERRED per validation-ecs §27, not reserved (the W1640 precedent) ──
    motion_empty_states, // M0.8 E5 — E1660 MotionEmptyStates (RESERVED: states block optional in the grammar)
    motion_duplicate_state_name, // M0.8 E5 — E1661 DuplicateStateName (duplicate state name)
    state_field_type_invalid, // M0.8 E5 — E1662 StateFieldTypeInvalid (RESERVED: field typing needs resolution — Kinesis Phase-1)
    state_field_inconsistent, // M0.8 E5 — E1663 StateFieldInconsistent (RESERVED: cross-state consistency — Kinesis Phase-1)
    transition_state_not_found, // M0.8 E5 — E1664 TransitionStateNotFound (source/target not a declared state)
    transition_duration_invalid, // M0.8 E5 — E1665 TransitionDurationInvalid (non-numeric or negative-literal duration)
    transition_easing_unknown, // M0.8 E5 — E1666 TransitionEasingUnknown (easing not in the part2 §22 catalog)
    initial_state_not_found, // M0.8 E5 — E1667 InitialStateNotFound (RESERVED: no `initial` clause in the grammar)
    motion_initial_missing, // M0.8 E5 — E1668 MotionInitialMissing (RESERVED: no `initial` clause in the grammar)

    // ── input_mapping (E1800-E1808 + W1801, M0.8 E5 — etch-grammar.md §16,
    // Level-B STRICT; E5 rulings 7/8: the grammar shape WINS (context is a
    // PROPERTY, not a named block). RESERVED with rationale: E1802
    // DuplicateContextName + W1801 EmptyContext (no context BLOCKS in the
    // grammar — context is a property), E1807 ComboActionRefNotFound (the §16
    // `sequence: [tokens]` shape has NO `.previous_action(.x)` action-ref form
    // — the ability E1585 precedent; sequence tokens are structural input
    // tokens, their catalogue = Input module Phase 1, consistent with the
    // E1803 deferral). E1803 InvalidBinding is DEFERRED (input_source catalogue
    // = engine-input-system.md, not attached — ruling 8) — not added ──
    mapping_empty, // M0.8 E5 — E1800 MappingEmpty (no action and no combo)
    duplicate_action_name, // M0.8 E5 — E1801 DuplicateActionName
    duplicate_context_name, // M0.8 E5 — E1802 DuplicateContextName (RESERVED: context is a property, not a block)
    modifier_type_unknown, // M0.8 E5 — E1804 ModifierTypeUnknown (vs the §16 l.1752 catalogue)
    trigger_type_unknown, // M0.8 E5 — E1805 TriggerTypeUnknown (vs the §16 l.1754 catalogue)
    priority_invalid, // M0.8 E5 — E1806 PriorityInvalid (not a non-negative INT_LITERAL)
    combo_action_ref_not_found, // M0.8 E5 — E1807 ComboActionRefNotFound (RESERVED: no action-ref form in the §16 combo shape)
    combo_timing_invalid, // M0.8 E5 — E1808 ComboTimingInvalid (window not a positive duration)
    empty_context, // M0.8 E5 — W1801 EmptyContext (RESERVED: context is a property, not a block)

    // ── widget (E1620-E1628, M0.8 E5 — etch-grammar.md §10.1; E5 rulings 9/10:
    // the grammar+part2 shape WINS (annotations are OPTIONAL — 2v1 over
    // validation-ecs §15.2). Deliver E1620 WidgetEmptyTree + E1621
    // ScreenWorldspaceConflict (the only enforced annotation rule — `@screen`
    // and `@worldspace` are `.custom`-kind annotations, mutually exclusive,
    // detected by name). RESERVED with rationale: E1622
    // WidgetMissingScreenOrWorldspace (annotation OPTIONAL — a normal widget
    // with no placement annotation is grammar-valid, so the "missing" check
    // would wrongly reject — the motion-E1660 shape precedent, ruling 9).
    // DEFERRED (no enum variant, the input_mapping-E1803 precedent): E1623
    // WidgetChildTypeInvalid + E1628 FocusOrderConflict (child-type / focus
    // catalogue = engine-ui.md, not attached), E1624 BindingTargetNotFound +
    // E1625 BindingTypeIncompatible + E1626 OnClickInvalidReturn (`bind
    // Component.field` has NO EBNF production — defer-structural, ruling 10;
    // handler-return typing needs the UI module), E1627 LocKeyNotFound
    // (vacuous — `@loc` key resolution = the `weld-extract-locale` extractor
    // tool, deferred, ruling 5). The numeric slots E1623-E1628 are reserved in
    // the catalogue (never reused); they get no enum variant here ──
    widget_empty_tree, // M0.8 E5 — E1620 WidgetEmptyTree (no ui_element in the tree)
    widget_screen_worldspace_conflict, // M0.8 E5 — E1621 WidgetScreenWorldspaceConflict (@screen and @worldspace both present)
    widget_missing_screen_or_worldspace, // M0.8 E5 — E1622 WidgetMissingScreenOrWorldspace (RESERVED: placement annotation is optional, ruling 9)

    // ── locale (E1820-E1822, M0.8 E5 — etch-grammar.md §10.4; E5 rulings 4/5/6:
    // the grammar shape WINS (IDENT name, flat `STRING = STRING` entries).
    // Deliver E1820 LocaleEmpty + E1821 LocaleCodeInvalid (an ISO-639 FORM
    // check — 2-3 lowercase letters + an optional `_XX` / `-XX` regional
    // variant, NOT an embedded code table, ruling 4) + E1822 DuplicateKey.
    // Fingerprint generation is the `weld-extract-locale` tool's job (ruling 5:
    // deferred — Level B is declaration + IR only). DEFERRED (no enum variant,
    // the input_mapping-E1803 precedent): E1823 InterpolationVariableMismatch +
    // E1824 PluralRuleInvalid + E1825 PluralOtherMissing (ICU plurals /
    // interpolation = validation-ecs §27 Phase 3, ruling 6). Their slots are
    // reserved in the catalogue (never reused) ──
    locale_empty, // M0.8 E5 — E1820 LocaleEmpty (no entries)
    locale_code_invalid, // M0.8 E5 — E1821 LocaleCodeInvalid (name is not a well-formed ISO-639 code)
    locale_duplicate_key, // M0.8 E5 — E1822 DuplicateKey (duplicate translation key)

    // ── effect (E1600/E1601/E1604, M0.8 E6 — etch-grammar.md §9.2, Level-B
    //    VFX. The structural checks DELIVER; the Ember-semantic ones are
    //    DEFERRED-no-variant: E1602 ParamTypeInvalid / E1603 SpawnRateInvalid /
    //    E1605 EmitterEventUnknown / E1606 RendererInvalid / W1600
    //    EffectNoRenderer / W1601 NestedEffectDepth all need the Ember catalogue
    //    (renderers, particle-event names, GPU param types) which is not
    //    attached — Phase 2+.) ──
    effect_empty_emitters, // M0.8 E6 — E1600 EffectEmptyEmitters (no emitter)
    duplicate_emitter_name, // M0.8 E6 — E1601 DuplicateEmitterName
    emitter_ref_not_found, // M0.8 E6 — E1604 EmitterRefNotFound (on X.event where X is not an emitter of this effect)

    // ── audio_graph (E1700/E1701, M0.8 E6 — etch-grammar.md §12.2, Level-B
    //    audio. Both RESERVED-with-variant: the grammar's single mandatory
    //    `output(...)` sink makes "no output" a parse error and "multiple
    //    outputs" impossible, so neither check ever fires. The DSP-semantic
    //    codes E1702-E1706/W1700 (node catalogue, connection types, asset refs,
    //    feedback DAG) are DEFERRED-no-variant — the Pulse catalogue is not
    //    attached, Phase 2+.) ──
    audio_graph_no_output, // M0.8 E6 — E1700 AudioGraphNoOutput (RESERVED: output is parser-mandatory)
    audio_graph_multiple_outputs, // M0.8 E6 — E1701 MultipleOutputs (RESERVED: the grammar has a single sink)

    /// Canonical short code, e.g. `"E0001"`.
    pub fn code(self: DiagnosticCode) []const u8 {
        return switch (self) {
            .parse_error => "E0001",
            .duplicate_symbol => "E0101",
            .undefined_symbol => "E0102",
            .enum_variant_not_found => "E0105",
            .type_mismatch => "E0200",
            .arg_count_mismatch => "E0203",
            .return_type_mismatch => "E0204",
            .struct_field_missing => "E0208",
            .ambiguous_type => "E0210",
            .ambiguous_trait_method => "E0211",
            .incomplete_trait_impl => "E0214",
            .conditional_impl_condition_not_proven => "E0215",
            .orphan_impl => "E0217",
            .immutable_receiver_for_mut_self => "E0220",
            .closure_cannot_mutate_capture => "E0221",
            .resource_expected_component_given => "E0301",
            .component_expected_resource_given => "E0302",
            .annotation_misapplied => "E0502",
            .bound_not_satisfied => "E0601",
            .generic_type_annotation_required => "E0603",
            .inconsistent_generic_inference => "E0604",
            .tag_path_invalid => "E0830",
            .tag_path_conflict => "E0831",
            .tag_bitfield_overflow => "E0832",
            .tag_invalid_operation => "E0833",
            .not_const_evaluable => "E1101",
            .on_event_type_mismatch => "E1203",
            .unknown_component_in_when => "E1210",
            .invalid_field_filter => "E1211",
            .unknown_tag => "E1212",
            .resource_expected_in_when => "E1213",
            .non_exhaustive_match => "E1230",
            .behavior_root_missing => "E1500",
            .behavior_empty_composite => "E1501",
            .behavior_invalid_leaf => "E1502",
            .behavior_condition_not_bool => "E1503",
            .behavior_action_invalid_return => "E1504",
            .behavior_when_clause_not_bool => "E1505",
            .behavior_recursion => "E1506",
            .quest_empty_stages => "E1540",
            .duplicate_stage_name => "E1541",
            .quest_requires_not_bool => "E1542",
            .objective_invalid_return => "E1543",
            .on_fail_action_invalid => "E1544",
            .switch_branch_target_not_found => "E1545",
            .branch_empty => "E1546",
            .branch_condition_not_bool => "E1547",
            .property_invalid_type => "E1548",
            .objective_modifier_invalid => "E1549",
            .event_reference_not_found => "E1550",
            .no_main_objective => "W1541",
            .routine_empty_segments => "E1520",
            .duplicate_segment_name => "E1521",
            .trigger_invalid => "E1522",
            .until_invalid => "E1523",
            .segment_reference_not_found => "E1524",
            .event_type_unknown => "E1525",
            .interrupt_target_invalid => "E1526",
            .action_invalid_return => "E1527",
            .dialogue_empty => "E1560",
            .duplicate_branch_label => "E1561",
            .branch_reference_not_found => "E1562",
            .speaker_not_found => "E1563",
            .choice_target_not_found => "E1564",
            .line_condition_not_bool => "E1565",
            .choice_condition_not_bool => "E1566",
            .dialogue_event_type_unknown => "E1567",
            .ability_empty => "E1580",
            .cost_invalid => "E1581",
            .cooldown_invalid => "E1582",
            .required_tags_unknown => "E1583",
            .blocked_tags_unknown => "E1584",
            .tags_required_blocked_conflict => "E1586",
            .data_empty_entries => "E1760",
            .duplicate_entry_id => "E1761",
            .entry_type_mismatch => "E1762",
            .entry_field_unknown => "E1763",
            .entry_field_type_invalid => "E1764",
            .entry_field_required_missing => "E1765",
            .spread_reference_not_found => "E1766",
            .spread_cycle => "E1767",
            .id_invalid_format => "E1768",
            .theme_empty => "E1640",
            .duplicate_token_name => "E1641",
            .token_type_invalid => "E1642",
            .token_default_missing => "E1643",
            .motion_empty_states => "E1660",
            .motion_duplicate_state_name => "E1661",
            .state_field_type_invalid => "E1662",
            .state_field_inconsistent => "E1663",
            .transition_state_not_found => "E1664",
            .transition_duration_invalid => "E1665",
            .transition_easing_unknown => "E1666",
            .initial_state_not_found => "E1667",
            .motion_initial_missing => "E1668",
            .mapping_empty => "E1800",
            .duplicate_action_name => "E1801",
            .duplicate_context_name => "E1802",
            .modifier_type_unknown => "E1804",
            .trigger_type_unknown => "E1805",
            .priority_invalid => "E1806",
            .combo_action_ref_not_found => "E1807",
            .combo_timing_invalid => "E1808",
            .empty_context => "W1801",
            .widget_empty_tree => "E1620",
            .widget_screen_worldspace_conflict => "E1621",
            .widget_missing_screen_or_worldspace => "E1622",
            .locale_empty => "E1820",
            .locale_code_invalid => "E1821",
            .locale_duplicate_key => "E1822",
            .effect_empty_emitters => "E1600",
            .duplicate_emitter_name => "E1601",
            .emitter_ref_not_found => "E1604",
            .audio_graph_no_output => "E1700",
            .audio_graph_multiple_outputs => "E1701",
        };
    }

    /// Canonical PascalCase name, e.g. `"ParseError"`.
    pub fn name(self: DiagnosticCode) []const u8 {
        return switch (self) {
            .parse_error => "ParseError",
            .duplicate_symbol => "DuplicateSymbol",
            .undefined_symbol => "UndefinedSymbol",
            .enum_variant_not_found => "EnumVariantNotFound",
            .type_mismatch => "TypeMismatch",
            .arg_count_mismatch => "ArgCountMismatch",
            .return_type_mismatch => "ReturnTypeMismatch",
            .struct_field_missing => "StructFieldMissing",
            .ambiguous_type => "AmbiguousType",
            .ambiguous_trait_method => "AmbiguousTraitMethod",
            .incomplete_trait_impl => "IncompleteTraitImpl",
            .conditional_impl_condition_not_proven => "ConditionalImplConditionNotProven",
            .orphan_impl => "OrphanImpl",
            .immutable_receiver_for_mut_self => "ImmutableReceiverForMutSelfMethod",
            .closure_cannot_mutate_capture => "ClosureCannotMutateCapture",
            .resource_expected_component_given => "ResourceExpectedComponentGiven",
            .component_expected_resource_given => "ComponentExpectedResourceGiven",
            .annotation_misapplied => "AnnotationMisapplied",
            .bound_not_satisfied => "BoundNotSatisfied",
            .generic_type_annotation_required => "GenericTypeAnnotationRequired",
            .inconsistent_generic_inference => "InconsistentGenericInference",
            .tag_path_invalid => "TagPathInvalid",
            .tag_path_conflict => "TagPathConflict",
            .tag_bitfield_overflow => "TagBitfieldOverflow",
            .tag_invalid_operation => "TagInvalidOperation",
            .not_const_evaluable => "NotConstEvaluable",
            .on_event_type_mismatch => "OnEventTypeMismatch",
            .unknown_component_in_when => "UnknownComponentInWhen",
            .invalid_field_filter => "InvalidFieldFilter",
            .unknown_tag => "UnknownTag",
            .resource_expected_in_when => "ResourceExpectedInWhen",
            .non_exhaustive_match => "NonExhaustiveMatch",
            .behavior_root_missing => "BehaviorRootMissing",
            .behavior_empty_composite => "BehaviorEmptyComposite",
            .behavior_invalid_leaf => "BehaviorInvalidLeaf",
            .behavior_condition_not_bool => "BehaviorConditionNotBool",
            .behavior_action_invalid_return => "BehaviorActionInvalidReturn",
            .behavior_when_clause_not_bool => "BehaviorWhenClauseNotBool",
            .behavior_recursion => "BehaviorRecursion",
            .quest_empty_stages => "QuestEmptyStages",
            .duplicate_stage_name => "DuplicateStageName",
            .quest_requires_not_bool => "QuestRequiresNotBool",
            .objective_invalid_return => "ObjectiveInvalidReturn",
            .on_fail_action_invalid => "OnFailActionInvalid",
            .switch_branch_target_not_found => "SwitchBranchTargetNotFound",
            .branch_empty => "BranchEmpty",
            .branch_condition_not_bool => "BranchConditionNotBool",
            .property_invalid_type => "PropertyInvalidType",
            .objective_modifier_invalid => "ObjectiveModifierInvalid",
            .event_reference_not_found => "EventReferenceNotFound",
            .no_main_objective => "NoMainObjective",
            .routine_empty_segments => "RoutineEmptySegments",
            .duplicate_segment_name => "DuplicateSegmentName",
            .trigger_invalid => "TriggerInvalid",
            .until_invalid => "UntilInvalid",
            .segment_reference_not_found => "SegmentReferenceNotFound",
            .event_type_unknown => "EventTypeUnknown",
            .interrupt_target_invalid => "InterruptTargetInvalid",
            .action_invalid_return => "ActionInvalidReturn",
            .dialogue_empty => "DialogueEmpty",
            .duplicate_branch_label => "DuplicateBranchLabel",
            .branch_reference_not_found => "BranchReferenceNotFound",
            .speaker_not_found => "SpeakerNotFound",
            .choice_target_not_found => "ChoiceTargetNotFound",
            .line_condition_not_bool => "LineConditionNotBool",
            .choice_condition_not_bool => "ChoiceConditionNotBool",
            .dialogue_event_type_unknown => "EventTypeUnknown",
            .ability_empty => "AbilityEmpty",
            .cost_invalid => "CostInvalid",
            .cooldown_invalid => "CooldownInvalid",
            .required_tags_unknown => "RequiresTagsUnknown",
            .blocked_tags_unknown => "RequiresNotTagsUnknown",
            .tags_required_blocked_conflict => "TagsRequiredBlockedConflict",
            .data_empty_entries => "DataEmptyEntries",
            .duplicate_entry_id => "DuplicateEntryId",
            .entry_type_mismatch => "EntryTypeMismatch",
            .entry_field_unknown => "EntryFieldUnknown",
            .entry_field_type_invalid => "EntryFieldTypeInvalid",
            .entry_field_required_missing => "EntryFieldRequiredMissing",
            .spread_reference_not_found => "SpreadReferenceNotFound",
            .spread_cycle => "SpreadCycle",
            .id_invalid_format => "IdInvalidFormat",
            .theme_empty => "ThemeEmpty",
            .duplicate_token_name => "DuplicateTokenName",
            .token_type_invalid => "TokenTypeInvalid",
            .token_default_missing => "TokenDefaultMissing",
            .motion_empty_states => "MotionEmptyStates",
            .motion_duplicate_state_name => "DuplicateStateName",
            .state_field_type_invalid => "StateFieldTypeInvalid",
            .state_field_inconsistent => "StateFieldInconsistent",
            .transition_state_not_found => "TransitionStateNotFound",
            .transition_duration_invalid => "TransitionDurationInvalid",
            .transition_easing_unknown => "TransitionEasingUnknown",
            .initial_state_not_found => "InitialStateNotFound",
            .motion_initial_missing => "MotionInitialMissing",
            .mapping_empty => "MappingEmpty",
            .duplicate_action_name => "DuplicateActionName",
            .duplicate_context_name => "DuplicateContextName",
            .modifier_type_unknown => "ModifierTypeUnknown",
            .trigger_type_unknown => "TriggerTypeUnknown",
            .priority_invalid => "PriorityInvalid",
            .combo_action_ref_not_found => "ComboActionRefNotFound",
            .combo_timing_invalid => "ComboTimingInvalid",
            .empty_context => "EmptyContext",
            .widget_empty_tree => "WidgetEmptyTree",
            .widget_screen_worldspace_conflict => "WidgetScreenWorldspaceConflict",
            .widget_missing_screen_or_worldspace => "WidgetMissingScreenOrWorldspace",
            .locale_empty => "LocaleEmpty",
            .locale_code_invalid => "LocaleCodeInvalid",
            .locale_duplicate_key => "DuplicateKey",
            .effect_empty_emitters => "EffectEmptyEmitters",
            .duplicate_emitter_name => "DuplicateEmitterName",
            .emitter_ref_not_found => "EmitterRefNotFound",
            .audio_graph_no_output => "AudioGraphNoOutput",
            .audio_graph_multiple_outputs => "MultipleOutputs",
        };
    }
};

/// A single diagnostic. Owns its `primary_message` slice — duplicated via
/// the caller's allocator when constructed; the type-checker / parser keep
/// the diagnostic list in an `ArrayListUnmanaged(Diagnostic)` and free
/// each `primary_message` at `deinit`.
pub const Diagnostic = struct {
    code: DiagnosticCode,
    severity: Severity,
    primary_span: SourceSpan,
    primary_message: []const u8,

    pub fn deinit(self: *Diagnostic, gpa: std.mem.Allocator) void {
        gpa.free(self.primary_message);
    }
};

/// `LineIndex` precomputes the byte offset of each line start so that
/// `(line, column)` can be resolved in `O(log n)` from a `SourceSpan`.
/// Built once per source.
pub const LineIndex = struct {
    /// `line_starts[i]` is the byte offset of the first character on
    /// line `i` (1-indexed: `line_starts[0]` is the start of line 1).
    line_starts: std.ArrayListUnmanaged(u32),
    source_len: u32,

    pub fn init(gpa: std.mem.Allocator, source: []const u8) !LineIndex {
        var line_starts: std.ArrayListUnmanaged(u32) = .empty;
        errdefer line_starts.deinit(gpa);
        try line_starts.append(gpa, 0);
        var i: u32 = 0;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\n') {
                try line_starts.append(gpa, i + 1);
            }
        }
        return .{
            .line_starts = line_starts,
            .source_len = @intCast(source.len),
        };
    }

    pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void {
        self.line_starts.deinit(gpa);
    }

    /// 1-indexed (line, column). Column counts bytes from the start of
    /// the line; for ASCII / single-byte spans this matches the visual
    /// column. Multi-byte UTF-8 in string literals is reported by its
    /// leading byte offset, which is sufficient for S3 diagnostics.
    pub const LineColumn = struct {
        line: u32,
        column: u32,
    };

    pub fn lineColumn(self: *const LineIndex, byte_offset: u32) LineColumn {
        // Binary search for the largest line_starts[i] <= byte_offset.
        const starts = self.line_starts.items;
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= byte_offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return .{
            .line = @intCast(lo + 1),
            .column = byte_offset - starts[lo] + 1,
        };
    }
};

test "Diagnostic line/column computed correctly from byte span" {
    const gpa = std.testing.allocator;
    const source = "abc\ndef\nghijkl\nmno";
    var idx = try LineIndex.init(gpa, source);
    defer idx.deinit(gpa);

    // 'a' → line 1 col 1
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 1, .column = 1 }, idx.lineColumn(0));
    // 'd' (line 2, col 1)
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 2, .column = 1 }, idx.lineColumn(4));
    // 'i' on line 3 col 3
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 3, .column = 3 }, idx.lineColumn(10));
    // 'm' on line 4 col 1
    try std.testing.expectEqual(LineIndex.LineColumn{ .line = 4, .column = 1 }, idx.lineColumn(15));
}

test "DiagnosticCode code and name are stable cross-version" {
    try std.testing.expectEqualStrings("E0001", DiagnosticCode.parse_error.code());
    try std.testing.expectEqualStrings("ParseError", DiagnosticCode.parse_error.name());
    try std.testing.expectEqualStrings("E0101", DiagnosticCode.duplicate_symbol.code());
    try std.testing.expectEqualStrings("E1210", DiagnosticCode.unknown_component_in_when.code());
    try std.testing.expectEqualStrings("UnknownComponentInWhen", DiagnosticCode.unknown_component_in_when.name());
    try std.testing.expectEqualStrings("E1213", DiagnosticCode.resource_expected_in_when.code());
}
