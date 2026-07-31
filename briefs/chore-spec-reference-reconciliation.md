# Chore — Spec Reference Reconciliation (`engine-spec.md §x` → `ARCH-nnn`)

> **Status:** PLANNED
> **Branch:** `chore/spec-reference-reconciliation`
> **Tag:** none — pure maintenance chore, merged to `main` without a tag (precedent: `chore-language-normalization`, commit `8434b6e`). Sits **before M1.1.11.1**.
> **Depends on:** M1.1.11 (`main` at `09bd386`, tag `v0.11.11-plane-halfspace`). Blocks nothing functionally; should land before M1.1.11.1 so the next milestone starts from a tree whose spec references resolve.
> **Language of this brief:** English (`engine-development-workflow.md` §4.2).
> **KB files attached to the Claude Code prompt:** `engine-invariants.md`, `engine-audit-checklist.md`, `engine-corpus-map.md`.

## Context

The knowledge-base restructuring of 2026-07-30 renumbered `engine-spec.md` from 27 sections to 10, migrated its cross-cutting decisions into a citable registry `ARCH-001`..`ARCH-028` (`engine-invariants.md`), and extracted the roadmap, the Phase −1 archive and the corpus changelog into their own documents. `engine-invariants.md` §1.2 states the resulting referencing policy:

```text
Cross-cutting architectural decision → ARCH-nnn
Domain detail                        → canonical filename + named anchor
Roadmap                              → engine-roadmap.md + phase id
History                              → the relevant archive
```

and forbids any inter-file reference of the form `engine-spec.md §x`. The same paragraph records that the KB files live outside the repository, so the **only** surface on which the policy is mechanically checkable is the versioned one: `briefs/`, `CLAUDE.md`, code comments. That surface was never migrated.

Two reasons it survived. First, the `chore-language-normalization` pass explicitly listed doc-comment cross-references of the form `engine-*.md §X` under **Preserve verbatim**, which was correct at the time and had the side effect of freezing them. Second, no milestone since has owned the repository side of the restructuring.

Measured on `main` at `09bd386`:

- **69** citations of the form `engine-spec.md §x`, over **38 files** — 13 source/tool files plus `examples/triangle/build.zig`, 22 briefs, `CLAUDE.md`, `validation/s5-go-nogo.md`.
- Of those, **1 dangling pointer** (`§26.1` — section 26 was dissolved) and **5 wrong-section references** (`§4`, "Système de plugins", cited for the component SoA/POD invariant, which lived in `§2.1`).
- `CLAUDE.md` § *Quick links spec* lists **45 of the 75** corpus files. Missing: `engine-corpus-map.md` (the entry point of every recon), `engine-invariants.md` (where every `ARCH-nnn` is defined), `engine-roadmap.md`, `engine-phase-minus-1-archive.md`, `spec-changelog.md`, `engine-audit-checklist.md`, and 15 of the 17 `etch-*` files. The section's own closing instruction — stop and ask Guy if a spec is not in the list — turns a 40 % incomplete list into a generator of unjustified stops.

This is **not** a numbered milestone: zero new capability, nothing to gate on behaviour. It is a maintenance pass, merged untagged.

## Objective

Make every spec reference in the repository resolve under the current corpus, with **zero semantic change** to code, contracts, measurements or acceptance records. References only.

## Scope — IN

1. **Code comments (`.zig`)** — 14 files:
   - `src/core/ecs/chunk.zig`, `comptime_query.zig`, `registry.zig`
   - `src/core/resources/api.zig`, `root.zig`
   - `src/core/rtti/root.zig`, `type_info.zig`
   - `src/core/scene/loader.zig`, `root.zig`
   - `src/etch/test_runner.zig`
   - `src/foundation/root.zig`
   - `src/modules/forge/forge_3d/root.zig`
   - `tools/etch_test/main.zig`
   - `examples/triangle/build.zig`
2. **Closed briefs** — 22 files: `S0`, `S1`, `S2`, `S3`, `S4`, `S5`, `S6`, `M0.0`, `M0.2`, `M0.3`, `M0.4`, `M0.7`, `M0.8`, `m0.6`, `M1.0.3`, `M1.0.4`, `M1.0.5`, `M1.0.6`, `M1.0.13`, `M1.0.15`, `M1.1.0`, `M1.1.5`. References only — see *What must not be touched*.
3. **`validation/s5-go-nogo.md`** — one reference. Same rule as the briefs.
4. **`CLAUDE.md`** — the three in-line references plus a full rewrite of § *Quick links spec* (replacement text supplied below).

## Scope — OUT

- **No `weld_lint` rule.** Decided by Guy: the substitution is a one-off, and a permanent rule is not warranted for a doctrine whose enforcement surface is three directories. The exit check is the acceptance grep, run by hand before the gate signal.
- **No code change.** No identifier, no logic, no signature, no test. The diff must contain only comment lines (`//`, `///`, `//!`) and markdown.
- **No figure, measurement, verdict, acceptance line, recorded deviation or reading date edited** — in any file, and in particular not in the closed briefs.
- **No KB file edited.** The KB is Claude.ai's channel; this chore is the repository side only.
- **No new tag.**

## Substitution table

Deterministic. Replace the **reference**, never reword the sentence carrying it.

| Old reference | Subject | New reference |
|---|---|---|
| `§1.6` | C keepers | `ARCH-024`; detail `engine-c-bindings.md` |
| `§2` | ECS overview | `ARCH-005`; detail `engine-ecs-internals.md` |
| `§2.3` | Archetype storage, 16 KB chunks | `ARCH-005`; detail `engine-ecs-internals.md` |
| `§2.5` | RTTI / component registry | `ARCH-007`; detail `engine-ecs-internals.md` |
| `§2.9` | Resources | `ARCH-006`; detail `engine-ecs-internals.md` |
| `§3.1` | Tier 0 / re-export convention | `engine-zig-conventions.md` § "Fichier racine : `root.zig` (module) vs `main.zig` (exécutable)" |
| `§3.5` | Everything in-tree, no separable libs | `ARCH-017` |
| `§4` | Component SoA/POD invariant | `ARCH-004` — **corrects a wrong-section reference** |
| `§5` | Render module | `engine-render.md` |
| `§16` | Asset Pipeline | `engine-asset-pipeline.md` |
| `§19`, `§19.1` | Scene serialization | `engine-scene-serialization.md` |
| `§22.2`, `§22.3`, `§22.3.0` | see disambiguation rule | see disambiguation rule |
| `§24.10` | `dt` as an injected rule parameter | `etch-reference-part1.md` |
| `§25`, `§25.3` | see disambiguation rule | see disambiguation rule |
| `§26.1` | `weld` CLI | `engine-platform.md` |

The five `§4` sites are `src/core/ecs/registry.zig:52`, `:65`, `:77`, `briefs/M1.0.3-resource-nonpod-fields.md:154`, `briefs/M1.0.6-prefabs-crossrefs-extensions.md:39` and `:223`. Every one of them cites `§4` ("Système de plugins") for the POD invariant, which lived in `§2.1`. `briefs/M1.0.6:223` even annotates it "POD/SoA en §511-519", i.e. the master's line range, which confirms the intent. The target is `ARCH-004`.

**Named anchors are deliberately not used** except on `§3.1`. An anchor is a second thing that can go stale, and verifying one requires holding the target document. Where the file *is* the domain owner — which `engine-corpus-map.md` §2 establishes — the filename alone is unambiguous. `engine-zig-conventions.md` covers fifteen unrelated topics, so it is the one case where the filename designates nothing on its own; the section *number* is dropped there too, since a shifting number is the exact failure mode being repaired.

## Disambiguation rule — `§22.x` and `§25.x`

Those belong to two successive numberings of the same "Stratégie & Roadmap" section (`engine-audit-checklist.md` §1.2 carries the trap note). Decide on what the citation **designates**, never on the number:

- it names a spike (`S0`..`S6`) or the spike list → `engine-phase-minus-1-archive.md`
- it designates a phase or a roadmap line → `engine-roadmap.md` §3
- it designates the per-module phase map → `engine-roadmap.md` §4

Verified examples: `briefs/S0-bootstrap.md:52` reads "§22.3.0 (Phase −1 spike list, S0 entry)" → archive. `briefs/S5-etch-codegen-zig.md:19` reads "§25.3 / S5" → archive. `briefs/M0.0-lint-custom.md:38` must be read on its own line before deciding.

## List-form citations

A citation may group several sections after one filename — `engine-spec.md` (§3.5, §5, §22.2). Only the first `§` is adjacent to the filename, so a grep keyed on the filename undercounts. **Every member of such a list is in scope.** Known instances: `M0.4:304`, `M1.0.4:144`, `M1.0.5:145`, `M1.0.6:223`, `S0:250`, `S1:55`, `S1:154`, `S2:245`, `S3:300`, `S4:228`, `S6:295`, `m0.6:198`, `M0.2:390`. Establish the full set with `grep -rn "engine-spec.md" --include=*.zig --include=*.md .` and read each hit line whole.

## Bare references

A bare `engine-spec.md` with no section number stays as it is — a file-level reference is legal. **Exception:** if the sentence attributes to the master a domain it no longer holds (roadmap, a module specification, Etch, the editor), retarget the file. Two known cases:

- `CLAUDE.md:150` — "Anything else requires a dedicated derogation in `engine-spec.md`": the derogation now belongs with `ARCH-024` and `engine-c-bindings.md`.
- `CLAUDE.md:158` — "`engine-spec.md` — top-level architecture, modules, roadmap (§22)": the master carries no roadmap; this line is absorbed by the *Quick links* rewrite below.

## What must not be touched

A closed brief is a closed record, and `validation/s5-go-nogo.md` is one too. That doctrine governs their **content** — measurements, figures, verdicts, acceptance lines, recorded deviations, reading timestamps like "read 2026-06-28 09:40". None of it is corrected here, **not even a value now known to be wrong**. Repairing a broken pointer is not rewriting the record. The diff of a brief must contain references and nothing else.

## `CLAUDE.md` § *Quick links spec* — replacement text

Replace the whole section with:

```markdown
## Quick links spec

The full specification lives in the claude.ai knowledge base — 75 files
(54 `engine-*`, 17 `etch-*`, 4 others), referenced by name (no repo path —
`spec/` is not in the repo).

Reading order is not free: it follows ownership.

1. `engine-corpus-map.md` — which file owns which domain (§2) and what spec
   status it carries (§1). Entry point of every recon.
2. `engine-invariants.md` — the 28 cross-cutting decisions, citable as
   `ARCH-001` … `ARCH-028`. Where every `ARCH-nnn` used in this repo is
   defined.
3. the owner document — all detailed normative content for its domain.
4. `engine-spec.md` — constitution only (architecture, ECS, tiers, plugins)
   plus the canonical catalogue of the 18 Tier 1 modules. It holds no module
   mini-spec and no roadmap.

**Never cite `engine-spec.md §x`.** The master's numbering has shifted several
times and silently invalidated references — that is why the `ARCH-nnn` registry
exists. Cross-cutting decision → `ARCH-nnn`. Domain detail → canonical filename
+ named anchor. Roadmap → `engine-roadmap.md` + phase id. History → the relevant
archive.

Process and conventions: `engine-development-workflow.md`,
`engine-zig-conventions.md`, `engine-audit-checklist.md`,
`engine-directory-structure.md`, `engine-terminologie.md`, `spec-changelog.md`

Phases: `engine-roadmap.md`, `engine-phase-minus-1-archive.md`,
`engine-phase-0-criteria.md`, `engine-phase-0-plan.md`,
`engine-phase-1-criteria.md`, `engine-phase-1-plan.md`,
`engine-phase-2-criteria.md`

Tier 0 and foundation: `engine-tier-interfaces.md`, `engine-c-api.md`,
`engine-c-bindings.md`, `engine-ecs-internals.md`, `engine-ipc.md`,
`engine-platform.md`, `engine-coordinate-system.md`, `engine-units.md`,
`engine-simd.md`, `engine-layout.md`

Tier 1 owner documents: `engine-render.md`, `engine-physics-forge.md`,
`engine-physics-forge-2d.md`, `engine-audio-pulse.md`, `engine-ai-cortex.md`,
`engine-animation-kinesis.md`, `engine-vfx-ember.md`,
`engine-networking-relay.md`, `engine-ui.md`, `engine-tools-editor.md`,
`engine-sequencer.md`, `engine-sprite.md`, `engine-input-system.md`,
`engine-debug.md`, `engine-media.md`, `engine-asset-pipeline.md`,
`engine-synapse.md`, `engine-conduit.md`, `engine-git-integration.md`

Etch — 17 files: `etch-grammar.md`, `etch-reference-part1.md`,
`etch-reference-part2.md`, `etch-reference-part3.md`, `etch-parser.md`,
`etch-ast-ir.md`, `etch-bytecode.md`, `etch-resolver-types.md`,
`etch-diagnostics.md`, `etch-stdlib.md`, `etch-memory-model.md`,
`etch-abi-zig.md`, `etch-validation-ecs.md`, `etch-style-guide.md`,
`etch-language-server.md`, `etch-visual-scripting.md`, `etch-crdt-ops.md`

Cross-cutting topics: `engine-scene-serialization.md`,
`engine-gameplay-systems.md`, `engine-movement.md`, `engine-vr-ar.md`,
`engine-collaboration.md`, `engine-compression-zlc.md`,
`engine-motion-design.md`, `engine-project-settings.md`,
`engine-color-picker.md`, `engine-mach-reference.md`

Templates and mockups: `brief-milestone_template.md`,
`prompt-claude-code_template.md`, `prompt-editor-mockups.md`

**Never guess a spec filename.** The list above is the whole corpus; if a spec
named in a brief or in conversation is not in it, stop and ask Guy.
```

## Execution steps

Each `Ei` ends at a **STOP point**: push, then halt and await review + GO. Grep cannot verify that an `ARCH-nnn` matches the subject of the sentence it lands in; that check is a human read of the diff.

- **E1 — Source, tools, example.** The 14 files of Scope IN §1. Includes the three `§4` → `ARCH-004` corrections and the `§26.1` dangling pointer. → **STOP / review / GO**
- **E2 — `CLAUDE.md`.** The three in-line references plus the *Quick links* rewrite. → **STOP / review / GO**
- **E3 — Closed briefs and validation record.** The 22 briefs plus `validation/s5-go-nogo.md`, references only. → **STOP / review / GO**
- **E4 — Final verification.** Acceptance greps, `zig build lint`, `zig fmt --check src tests build.zig`, `zig build test`, `zig build test-forge-3d -Dphysics_f64=true`. Open the PR.

Rationale for the split: E1 carries the semantic corrections and must be read closely; E3 is the largest volume but the lowest risk and the strictest constraint (references only); separating them keeps each review batch tractable.

## Acceptance criteria

1. `grep -rn "engine-spec.md" --include=*.zig --include=*.md . | grep "§"` → zero lines.
2. `grep -rnE "engine-spec\.md.{0,6}(section|Section) [0-9]" --include=*.zig --include=*.md .` → zero lines (the alternative spelling of the same fault).
3. Every `ARCH-nnn` introduced lies in `[ARCH-001, ARCH-028]` and its title, read in `engine-invariants.md` §2, matches the subject of the sentence it lands in. Numbering is append-only; no identifier outside that range exists.
4. Every KB filename introduced is one of the 75 listed in the rewritten *Quick links* section. No invented filename.
5. `git diff` contains only comment lines (`//`, `///`, `//!`) and markdown. No `.zig` statement, declaration or signature changed.
6. The diffs of the 22 briefs and of `validation/s5-go-nogo.md` contain references only — no figure, measurement, date, verdict or acceptance line.
7. `zig build lint` green, `zig fmt --check src tests build.zig` green, `zig build test` green, `zig build test-forge-3d -Dphysics_f64=true` green.
8. Any site that does not fall under the substitution table is raised at the STOP point **before** being substituted — never resolved by guessing.

## Out of scope (explicit, not debt)

- The `etch-diagnostics.md` registry divergence — `E0304`, `E0305`, `E0306`, `E0307` absent from the whole corpus, `E0910` and `E0001` absent from the owner registry while present elsewhere. That is paid on the KB side by Claude.ai, not in the repository.
- `src/modules/audio/` → `src/modules/pulse/` (`engine-directory-structure.md` §9.1 and `engine-zig-conventions.md` both name `pulse/`; `forge/` sets the precedent that the directory carries the module name, not the `weld.toml` slot). A rename touching `build.zig` and imports is not a comment-only chore.
- `CLAUDE.md` § *Current state* being stale by one milestone after every merge, and the two dead entries in § *Open / deferred decisions* (Codeberg, retired in July 2026 per `engine-development-workflow.md` §7.2; and the `engine-zig-conventions.md` `solvers_{2d,3d}` reconciliation, now paid). Same file, different fault class — owned by the M1.1.11.1 CLAUDE.md patch.
- The `-Dphysics_f64=true` CI leg, absent from `.github/workflows/` across twelve forge milestones. Owned by whoever next opens `ci.yml`.
- The residual wall-clock latency assertions (`tests/ipc/handshake.zig:135` and four others), same class as the four removed at M1.1.9. Owned by the next milestone that opens `tests/ipc/`.

---

## Acted deviations

Everything below was decided during execution, at a STOP point, and is recorded
here rather than by editing the frozen body above.

### A1 — Scope widened from 14 to 17 source files

The survey in *Context* was run with `--include=*.zig --include=*.md`, so three
sites carrying the same fault were invisible to it. They would have survived a
green acceptance grep, since criterion 1 filters on the same two extensions:

- `examples/triangle/build.zig.zon:8` — `§3.5` → `ARCH-017`
- `bench/fixtures/synth_100/build.zig.zon:8` — `§3.5` → `ARCH-017`
- `tests/etch/corpus/invalid/E0502_annotation_misapplied.etch:2` — `§2.9` →
  `ARCH-006`. The fixture keeps its line count, so the E0502 span is unchanged;
  `tests/etch/corpus_facade.zig` asserts the code alone in any case.

Two language residues sat on lines already being touched and went with them
(same extension blind spot, this time in the `chore-language-normalization`
pass): `Phase 0 monolithique` → `monolithic`, and `Path local` → `Local path` in
both `.zon` files.

### A2 — Acceptance criterion 1 is amended, and this supersedes the body

The body states criterion 1 as `→ zero lines`. **That is false and unreachable**,
by construction rather than by omission, and this append carries the amended
form:

> The literal grep returns **30** lines, every one of them enumerated
> `file:line` with its exemption class, and no other. The number is a
> *consequence* of the list, not the gate. A 31st line is a defect; a 29th is a
> damaged record.

Six classes, five of which the body could not have anticipated:

| Class | Count | Lines |
|---|---|---|
| This chore's own brief — a doctrine cannot forbid a form without quoting it | 8 | `briefs/chore-spec-reference-reconciliation.md:1 :12 :21 :27 :99 :106 :135 :196` |
| Dated reading acts, checkbox form | 14 | `M0.2:390` `M0.4:304` `M0.8:207` `M1.0.4:144` `M1.0.5:145` `M1.0.6:223` `m0.6:198` `S0:250` `S1:154` `S2:245` `S3:300` `S4:228` `S5:266` `S6:295` |
| Dated reading acts, prose form | 2 | `S0:258` `M0.8:215` |
| Historical prose whose subject *is* the stale numbers | 4 | `M0.0:19` `:29` `:136` `M0.8:218` |
| Bare filename recording which files were patched | 1 | `M0.3:186` |
| The referencing policy itself | 1 | `CLAUDE.md:170` |

The exemption of historical prose rests on `engine-audit-checklist.md` §1.1,
which excludes "une phrase explicitement historique" from the drift predicate —
not on a judgement call made here.

### A3 — D8 is stated by function, not by form

> Any line recording a **dated reading act** is exempt, whatever its shape —
> checkbox `- [x] … — read <timestamp>` or prose `- <date> — … read (<file> §x,
> …)`. Substituting the current target would make the record claim a milestone
> read a file that did not exist on its date. The exemption attaches to the
> evidential function, not to the template.

Consequence: `S0:258` and `M0.8:215` are reading acts in prose, not historical
prose about numbering. `M0.8:215` was first classified as the latter and is
reclassified here. The total is unchanged; the decomposition is not.

### A4 — "corrects a wrong-section reference" is REFUTED for the five `§4` sites

The substitution table asserts that the five `§4` citations pointed at "Système
de plugins" for the POD invariant, "which lived in `§2.1`". Measured on the
27-section master — the numbering in force when those comments were written —
that is wrong. `§4.3` carries the POD rule **in full**, at lines 492–500:

> `**Règle stricte 100% POD pour les composants :** les composants doivent être
> strictement Plain Old Data pour garantir que la migration par memcpy
> fonctionne toujours sans fuite mémoire ni double-free.` — followed by the
> allowed list, the fixed-buffer-or-POD-handle rule for dynamic data, and
> `Un composant non-POD ne compile pas — erreur, pas warning.`

`§2.1` line 175 carries only a one-line summary. The body of `ARCH-004`
corroborates independently, reproducing that clause and not the summary: same
forbidden/allowed lists, same recursive `comptime` check, same "erreur, pas
avertissement".

So `ARCH-004` was extracted from `§4.3`, the five citations pointed at a real
and correct location, and only the *qualification* was wrong — the target is
unaffected. `registry.zig:52`, `:65`, `:77`, `M1.0.3:154` and `M1.0.6:39` are
plain repairs, not corrections. The commit message of the source gate asserts
the refuted qualification; it is already pushed and stays as part of the record,
with the correction carried here and in the squash message.

### A5 — Six sections absent from the substitution table

Resolved at the STOP points, never by guessing:

| Old | Subject in the 27-section master | Target |
|---|---|---|
| `§2.7` | Sérialisation versionnée | `ARCH-008` |
| `§2.8` | Gestion mémoire | `ARCH-011` |
| `§1.3` | Communication éditeur ↔ runtime | `ARCH-012` |
| `§1` | Architecture fondamentale | `ARCH-001`–`ARCH-006` |
| `§3.1` cited as "Tier 0 catalog" | Tier 0 — Noyau incompressible | `ARCH-013` |
| `§22 Layer 2` | see A6 | `engine-tools-editor.md`, named anchor |

The `§3.1` row is the chore's own fault class caught in the act: one number, two
subjects. The table's `§3.1` target — the root-file convention of
`engine-zig-conventions.md` — is right for `rtti/root.zig:10`, which cites it
for a re-export convention, and wrong for `M0.2:191`, which cites it for the
Tier 0 catalogue. Only reading each line settles it.

### A6 — `§22 Layer 2` (S3:158) resolved by measurement

The only `Couche N` / `Layer N` decomposition in the whole corpus is line 2448
of the 27-section master:

> `**Couche 2 — Parsing (parser hybride LR(1) + Pratt, Zig natif in-tree)**` …
> `**Spec dédiée :** etch-parser.md`.

It sits inside `### 23.10 Panneau Etch Text — Éditeur de code`, whose intro
reads "Il est construit en 6 couches" (Rendu, Text buffer, **Parsing**,
Intelligence, Bidirectionnalité, Collaboration). There is no layer
decomposition in `§24` Langage Etch nor in `§25` Stratégie & Roadmap, so neither
of the two readings first considered — Etch, or Roadmap — has a referent at all.

The precedent was already closed: `engine-corpus-map.md` anomaly 10 records
`§22 Couche 3` in `etch-language-server.md` as a false target, corrected at lot
E towards `engine-tools-editor.md`; anomalies 8 and 19 record the migration of
`§23.10` itself. `engine-audit-checklist.md` §1.2 row 23 carries it too.

`etch-parser.md` was considered and rejected: it is that layer's own dedicated
spec, but S3's word is "context" and the block cited is the description of the
stack. The pointer lands where the cited block lives.

### A7 — `§25.3` split by what the citation designates

`§25.3` was both the roadmap and the home of the Phase −1 spike paragraphs, and
the two go to different files. Sites naming a spike or the spike list →
`engine-phase-minus-1-archive.md`; sites naming a roadmap line →
`engine-roadmap.md` §3; `M0.2:191`, which names both in one parenthetical, gets
both.

### A8 — `§24.10`: the table holds, and the measurement is recorded

`§24.10` was "Standard Library", whose owner is `etch-stdlib.md`. Its Time
bullet reads literally `dt` (paramètre optionnel déclaré dans la signature de
rule, ex. `rule tick(entity: Entity, dt: float)`), so `M1.0.13:57` cited it
precisely. The retarget still goes to `etch-reference-part1.md`, per the table:
the pointer follows the current owner of the *assertion* — `dt` as an injected
rule parameter — not the historical descendant of the section. `etch-stdlib.md`
owns `time.dt`, a different surface.

### A9 — Rendering conventions, and the anchor policy of the body WITHDRAWN

The body states that "named anchors are deliberately not used except on `§3.1`".
**That policy is withdrawn.** It contradicts `engine-invariants.md` §1.2, which
prescribes "fichier canonique + ancre nommée" for domain detail with no
exception, and it would have left twenty-five pointers resolving to a whole
document. Every domain-detail target now carries a named anchor, **read in the
owning document and never inferred from the subject**, with the section number
dropped everywhere — a shifting number is the failure mode being repaired, and
"6 bis" has already moved once.

| Target | Anchor, read | Sites |
|---|---|---|
| `engine-platform.md` | § "Build System — CLI `weld`" | `test_runner.zig:20` · `tools/etch_test:4` · `CLAUDE.md:120` · `M1.0.15:39` |
| `engine-scene-serialization.md` | § "Resources de scène — install-or-overwrite" | `loader.zig:716` · `M1.0.5:163` · `:173` |
| `engine-scene-serialization.md` | § "Architecture" | `M1.0.4:66` · `M1.0.5:62` · `M1.0.6:136` |
| `engine-ecs-internals.md` | § "Archetype Chunk Layout (SoA par composant)" | `chunk.zig:56` |
| `engine-ecs-internals.md` | § "Architecture" | `S1:55` |
| `engine-c-bindings.md` | § "Liste des `.api.zig` manuels" | `CLAUDE.md:150` ×2 · `M0.2:191` · `S2:67` |
| `engine-render.md` | § "GPU Abstraction Layer (GAL)" + § "V-Buffer (Visibility Buffer)" | `M0.4:80` |
| `engine-asset-pipeline.md` | § "Architecture" | `m0.6:84` |
| `etch-reference-part1.md` | § "`async fn` et `async rule`" | `M1.0.13:57` |
| `engine-roadmap.md` | § "Contenu des phases" | `M0.0:38` · `M0.2:191` |
| `engine-roadmap.md` | § "Carte globale des phases par module" | `M0.8:109` |
| `engine-zig-conventions.md` | § "Fichier racine : `root.zig` (module) vs `main.zig` (exécutable)" | `rtti/root.zig:10` |
| `engine-tools-editor.md` | § "Panneau Etch Text — éditeur de code" | `S3:158` |
| `engine-simd.md` | § "Relation avec `foundation/math/`" | `foundation/root.zig:3` |

`engine-zig-conventions.md` and `engine-tools-editor.md` were already anchored
and carried no number, so the withdrawal took nothing back from them. They are
named rather than pointed at by position: the table has since grown twice, and a
positional reference into a growing table is this chore's own fault in miniature.

**An anchor must be unique in its file, and that is checked, not assumed.**
`engine-render.md` carries **four** headings titled "Architecture" (lines 29, 634,
1036, 1351), so § "Architecture" localises nothing there — `M0.4:80` cites the two
named sections its own gloss designates instead. Every anchor in the table above
was then counted mechanically in its owning document. The table holds **fifteen
anchors over fourteen rows** — the `engine-render.md` row carries two — and **all
fifteen resolve to exactly one heading**, including the three remaining
§ "Architecture" targets, which are unique in `engine-scene-serialization.md`,
`engine-ecs-internals.md` and `engine-asset-pipeline.md`. One site, not a class.

The count was run against the `weld-spec/` mirror after the two anchors this work
introduced were synchronised into it, so **all fifteen rest on the same warrant**
— counted here, in the published corpus, not cited from someone else's reading.
That closes two caveats an earlier revision of this section carried: the
install-or-overwrite anchor, which the corpus did not yet publish, and the
`engine-simd.md` anchor, which had been attested by the reviewer rather than
measured.

**The instrument was proven before its result was trusted.** A first count
returned 14 of 15, reporting § "Panneau Etch Text — éditeur de code" absent. The
heading is present — `## 6 bis. Panneau Etch Text — éditeur de code` — and the
count was wrong: the ordinal strip choked on "6 bis", which is exactly the number
this section notes has already moved once. The corrected pass also verifies that a
deliberately wrong anchor still returns zero, so the tool can distinguish absence
from a normalisation bug. A measurement that cannot fail on purpose is not a
measurement.

Three exemptions, each motivated rather than granted:

1. **The archive plus a spike id** — `` `engine-phase-minus-1-archive.md` S6 `` —
   because the archive is indexed by spike: the id *is* the anchor. Side effect:
   no `§` reintroduced anywhere on those 27 sites.
2. **A bare `ARCH-nnn`**, because §1.2 explicitly allows the short form in prose,
   and because `engine-invariants.md` followed by an id already *is* the full
   `engine-invariants.md#arch-nnn` link its preamble rule asks for — the `#` is a
   rendering detail. Nothing to add on `M0.2:191`.
3. **`engine-roadmap.md`**, where §1.2 asks for a phase identifier rather than a
   section number. None of the three roadmap sites designates a single phase —
   `M0.0:38` and `M0.2:191` designate the roadmap's phase content, `M0.8:109` the
   per-module map — so each takes the named anchor of the section it designates,
   which is §1.2's primary rule rather than a departure from it.

One `; detail <owner>` survives, on `chunk.zig`: the 16 KiB chunk dimension is
content `ARCH-005` explicitly disclaims in the admission test of §1.3, so the id
alone would have been a *wrong* pointer, not merely a terse one. The second such
pointer, on `rtti/type_info.zig:48`, is **removed**: the resource lifecycle tags
are stated in `ARCH-006`'s own decision ("Trois tags de cycle de vie — `@config`,
`@state`, `@transient` — déterminent le comportement de sérialisation et de
réplication"), so it is not disclaimed detail and needs no owner. It also has no
anchor available — the tag table is not in `engine-ecs-internals.md`, and
`engine-project-settings.md` was not in the attached set.

**Two sibling comments state the same rule and must attribute it the same way.**
`scene/root.zig` and `scene/loader.zig` both declare that the module imports
`weld_core` only and never `weld_etch`. After the `ARCH-016` removal of A10, the
first read "(tier discipline, `ARCH-013` / the M1.0.4 brief Notes)" while the
second read "(`ARCH-013`)" placed *after* the import sentence — where the bare id
reads as covering the import rule, which A10 had just declared it does not. The
divergence between the two mattered more than either variant: `loader.zig` now
carries the same form as its sibling. Citing where a decision was taken is not
the same act as citing a normative owner, and the provenance is worth keeping —
so the M1.0.4 brief is named rather than the sentence left uncited.

Two textual side effects, both visible in the diff: the word "table" was dropped
from "§2.9 table" because `ARCH-006` carries none, and `rtti/root.zig` reads
"the Tier 0 convention of X" rather than "the X Tier 0 convention" because the
anchor is too long for the original word order. No other word moved anywhere.

### A10 — The gloss audit, and the one arbitration that had to be revoked

Every `ARCH-nnn` introduced was re-audited against the **decision** of the id
cited, read in `engine-invariants.md` §2 — not against the section the id was
extracted from. Of **34** glossed references, **26** are covered and **8** were
defects. The count of glossed references is 34 and not 25: a grep motif keyed on
a parenthesis immediately following the id missed six sites whose gloss precedes
it or is the sentence's own subject. (An earlier statement of this arithmetic
said 25 covered and 9 defects; 34 = 26 + 8 is the correct decomposition.)

The eight, and what each one shows:

| Site | Gloss | Why it failed |
|---|---|---|
| `M0.2:191` | `ARCH-024` "Tier 0/1 catalog, 7 C keepers" | `ARCH-024` carries only the keepers. The catalogue half goes to `ARCH-013` + `ARCH-014`, which is where the Tier 0 model and the canonical Tier 1 list live — so no word of a closed record's gloss is deleted to make a target fit |
| `S2:67` | `ARCH-024` "8 keepers list" | `ARCH-024` fixes 7, going to 6. No id carries 8; the only document that carries the 8 → 7 transition is `engine-c-bindings.md`, in the Phase −1 tree-sitter note of § "Liste des `.api.zig` manuels". The gloss is the record and does not change |
| `S0:52` | `ARCH-017` "in-tree default, no `spec/` in repo" | `ARCH-017` carries the in-tree default and the absence of `libs/`, nothing about `spec/`. Verified: `spec/` appears nowhere in `engine-directory-structure.md`. There is no KB owner — the decision lives in `CLAUDE.md` § *Open / deferred decisions* — so the clause is qualified as historical rather than given an invented target |
| `M1.1.5:19` | `ARCH-017` "the spec directory tree … reserves for 'semi-implicit Euler, sleep, CCD'" | `ARCH-017` carries no directory tree at all: the bullets of `§3.5` that named `src/modules/forge/solvers_{2d,3d}/<backend>/` — a path itself made stale by the M1.1.1 flatten — did not survive into the invariant. `engine-directory-structure.md`, already cited on the same line, is the owner, and the `ARCH-017` half is dropped as a mis-attribution |
| `S1:55` | `ARCH-005` "ECS overview" | An overview of the ECS spans `ARCH-003` to `ARCH-010`. The gloss reattaches to the owner, `engine-ecs-internals.md` § "Architecture"; `ARCH-005` stays alongside, unglossed |
| `foundation/root.zig:3` | `ARCH-017` "sibling submodules with no mutual dependency" | → no id at all (see below) |
| `scene/root.zig:8` | `ARCH-017` "tier discipline, imports `weld_core` only, never `weld_etch`" | → `ARCH-013` alone |
| `scene/loader.zig:12` | `ARCH-017` "Tier discipline: imports `weld_core` internals only" | → `ARCH-013` alone |

**The last three revoke the GO given at the source gate** — twice over, as it
turned out, and that is worth recording plainly.

*First revocation.* At E1 the three were verified against the *source text* of the
27-section `§3.5`, whose "Discipline d'API in-tree" literally requires "Zero
coupling avec d'autres modules Weld", and `ARCH-017` was accepted on that
measurement. The rule written afterwards is stricter and asks whether the gloss
is covered by the **decision of the id cited** — and `ARCH-017` does not carry the
coupling clause, it *delegates* it: "couplage déclaré et acyclique (`ARCH-016`)".
The two readings cannot both hold; the property of the cited id is what a reader
resolves, so the stricter rule wins and `ARCH-016` — "un module n'accède qu'à
`foundation`, au Tier 0, et aux modules explicitement déclarés dans son
`b.addModule`" — is what those three sentences actually assert. What made the
revocation possible was raising the tension rather than silently applying
whichever rule was most recent.

*Second revocation — `ARCH-016` does not apply either.* Its **`Portée`** field
reads "Tier 1, Tier 3". `foundation` and `core/scene` are Tier 0, so the id was
out of scope at all three sites. The cause is the same one three times running,
and naming it is the point of this entry: an id had been validated on its
**decision text alone** — `ARCH-024` on its subject without its perimeter,
`ARCH-017` on a clause it delegates, `ARCH-016` on a decision that describes the
constraint exactly while its scope excludes the tier. **A citation is admissible
only if the decision AND the `Portée` both hold.**

No invariant carries the Tier 0 import graph, so the remedy is to **stop citing**
for that half rather than find a third id — the same call already made on
`rtti/type_info.zig:48`. A comment may state a local discipline without invoking
an invariant. `foundation/root.zig` keeps `engine-simd.md`, which carries the
sister-module clause on the same line and takes its named anchor at E7; the two
scene files keep `ARCH-013` (`Portée : Global`) for tier membership, and their
import constraint is attributed to the M1.0.4 brief Notes rather than to an
invariant — see the sibling-comment paragraph of A9 for the final form.

The sweep this produced was run over every id used as a target, cross-checking
each `Portée` against the tier of the cited subject. Six registry entries have a
`Portée` that excludes Tier 0 (`ARCH-014`, `-015`, `-016`, `-019`, `-020`, `-021`);
two of them are used here. `ARCH-016` was the only violation. `ARCH-014` surfaces
as a mechanical candidate and is resolved by reading: it is cited for the **Tier
1** half of "Tier 0/1 catalog", so its scope is satisfied, with `ARCH-013`
(Global) carrying the Tier 0 half on the same line.

### A11 — A stale gloss is QUALIFIED as historical, never retargeted

Two sites carried a gloss that was true when written and is false against today's
corpus. Retargeting them to the living owner makes the gloss *testable* against
that owner — and it fails, so repairing the pointer would have manufactured the
contradiction:

- `M0.2:364` whitelisted two documents for a `tools/vk_gen/` reference. Today
  `vk_gen` is named in five KB files. The C4 retarget of the previous gate is
  **annulled**: the recorded text is restored verbatim and marked "historical
  whitelist".
- `M1.1.5:19` states that the directory tree reserves one file for "semi-implicit
  Euler, sleep, CCD". Today `engine-directory-structure.md` gives
  `integration.zig # semi-implicit Euler (M1.1.5), CCD` with a **separate**
  `sleep.zig`. The pointer is dropped for that half and the claim marked "as read
  at M1.1.5 — historical".

**Rule, a generalisation of drift pattern D4:** when the gloss of a closed record
is stale against the living owner, qualify it as historical; do not retarget.
Retargeting would make the record assert a falsehood about today's corpus, while
the qualification tells the truth about both dates. The recorded words do not
move in either case — only a short marker is added.

This also settles a residual the previous gate left implicit: `engine-directory-
structure.md` is no longer a target of this chore at all, and `ARCH-016` is no
longer used anywhere in the tree.

### A12 — Acceptance criterion 5 is amended: the Debug legs lose the Zig cache

The body states criterion 5 as "`git diff` contains only comment lines (`//`,
`///`, `//!`) and markdown. No `.zig` statement, declaration or signature
changed." E9 edits `.github/workflows/ci.yml` — neither a comment line nor
markdown — so the criterion as written is violated, and the deviation is recorded
here rather than smoothed over.

**What the criterion meant** is that the chore changes nothing semantic about the
engine. That still holds exactly: removing a cache from a workflow changes how
fast CI runs, not what it verifies. The Debug legs execute the same `zig fmt
--check`, `zig build`, `zig build test`, `zig build test-etch` and
`zig build bindgen-verify` against the same sources; the verification surface is
identical, byte for byte. Zig's cache is content-hashed and self-invalidating, so
a cold leg and a warm leg compile the same program. Criterion 5 is amended to
"no semantic change to the engine, and no `.zig` file touched" — the second half
still holds literally: **no `.zig` file is in the E9 diff.**

**Why the edit was necessary rather than optional.** `ci-gate` was red and branch
protection blocks the merge, so the chore could not land. `build-and-test
(windows-2025, Debug)` was killed at its 20-minute ceiling on two consecutive
runs (25m0s, 25m1s — reproducible, not variance), and the measurement isolates the
cause: against the last green run of the same leg the work is flat — `zig build`
~3 min, `zig build test` ~8 min — while `Save Zig cache (post-build)` went 39s →
5m23s → 7m39s. Cache steps consumed ~8m40s for ~10m52s of useful work. The
`bench.yml` log on the same head names the mechanism: `Zig cache exceeded
2147483648 bytes (was 6214569092); purged contents before save` — 6.2 GB purged
to a 2 GB cap on every save. The two failures had different victims (the first
died in the final save with every build and test step green; the second lost
`zig build test` to the ceiling), which is budget exhaustion rather than a defect.

**Why the budget was not raised instead.** The comment block being edited records
that same assumption breaking three times already — 10 → 20 at M0.1, 20 → 40 at
the M0.8 close, 40 → 55 at the cache refresh chore. A fourth raise would buy one
more milestone. A cache that does not fit under its own cap is not a cache, it is
a tax, and the Debug legs are the ones paying it for nothing: a cold Debug leg is
~11 min of work, ~45 % inside its budget on the slowest runner. ReleaseSafe keeps
the cache — its near-cold recompile is the case the cache was added for, and what
the 55-minute budget exists to cover.

One addition beyond the fix: the timing artefact now reports `cache_enabled`
next to `cache_matched_key`. Since the cache is ReleaseSafe-only, a Debug leg
reports `cache_matched_key=none` **by design**, and without that line a future
reader would diagnose a deliberately cold leg as a broken cache — the exact
class of misreading this chore exists to prevent.

## Execution notes

Gate by gate, each ending at a STOP with an explicit GO before the next.

| Gate | Commit | Content |
|---|---|---|
| brief | `52f666a` | committed verbatim before any substitution |
| E1 | `31bff8e` | 18 references, 14 source/tool/example files |
| E1bis | `e4a605c` | 3 references outside the `.zig`/`.md` set (A1) |
| E1ter | `4efe8ad` | the second language fix (A1) |
| E2 | `88c2b1c` | `CLAUDE.md` — 4 references + § *Quick links spec* rewritten |
| E3 | `feebb78` | 52 references over 51 lines, 21 briefs + the S5 record |
| E5 | `2b9c0cc` | named anchors (A9), the 8 gloss defects (A10) |
| E6 | `229b13d` | `ARCH-016` out of scope (A10), two stale glosses qualified (A11), the render anchor (A9) |
| E7 | `155c0f6` | the two sibling comments agree, the `engine-simd.md` anchor (A9) |
| E8 | `a5755f9` | the anchor count corrected to fifteen and re-measured against the synchronised mirror (A9) |
| E9 | this commit | the Zig cache restricted to the ReleaseSafe legs, unblocking `ci-gate` (A12) |

**77 references repaired.** `engine-spec.md` occurrences across the tree: 97 in
38 files at open, 37 in 18 files at close. Twelve distinct ARCH ids used as
targets — `ARCH-004`, `-005`, `-006`, `-007`, `-008`, `-011`, `-012`, `-013`,
`-014`, `-017`, `-024` — plus the `ARCH-001`–`ARCH-006` range at `S2:67`.
`ARCH-014` enters at E5 through the gloss audit (A10), not through the
substitution table; `ARCH-016` entered there too and left again at E6 on its
`Portée` (A10), so it is used nowhere in the tree.

**A2, A9 and A10 were rewritten in place** rather than corrected by further
appends:
the body's anchor policy is withdrawn, so the section that recorded it had to
state the withdrawal, and a patch of a patch would have left two contradictory
renderings of the same rule in the same file. The frozen body is untouched
either way — only the append changed.

**Verification that references alone moved.** For each of the 51 changed lines
in E3, the reference tokens (`§n.n`, `ARCH-nnn`, `*.md`) were neutralised and the
ordered sequence of every remaining number compared old against new: 51/51
identical, including `S0:279`, which carries nineteen of them (`429de07`,
`0.16.0`, `404`, `x86_64`, …). Backtick and bold parity: no regression. E1 was
checked the same way at line granularity: 0 non-comment changed lines across all
14 files. No line was added or removed in any brief — 51 insertions against 51
deletions.

**`CLAUDE.md` § *Quick links spec*.** The 75 filenames it now lists were checked
against the whitelist of `engine-audit-checklist.md` §4.1 and form an exact
bijection with it — nothing invented, nothing missing. The section previously
listed 45 of 75 while instructing the reader to stop and ask Guy for anything
absent from it.

**Gates**, all reproduced independently at close: `zig build lint` 0 ·
`zig fmt --check src tests build.zig` 0 (and `examples tools bench` 0) ·
`zig build test` 264/264 steps, 1523/1540 tests passed, 17 skipped ·
`zig build test-forge-3d -Dphysics_f64=true` 4/4 steps, 356/356. Acceptance
criterion 2 returns zero; nothing outside `.md`/`.zig` still carries a citation.

## Closing notes

**Verbatim French spec citations — the count moves in two places, and the second
is the larger.** In *source*, the M1.1.10 language audit counted twelve; the two
named anchors of A9 add one each, taking the source-side count to **14**. In
*this brief*, the append above quotes considerably more: **20 French-bearing
lines**, measured with a Python detector and not a byte-wise grep class, carrying
some eighteen distinct fragments — section titles, the `§4.3` POD clause of A4,
the `Couche 2` block of A6, the `§24.10` Time bullet of A8, and one clause each
from `engine-invariants.md` §1.2 and `engine-audit-checklist.md` §1.1. Every one
is a verbatim citation, the category that audit established as licit, and they
are here deliberately: a measurement that cannot be re-read against its source
is an assertion. No French prose of my own was introduced — checked with the same
detector. Two French residues left the tree in the same pass ("monolithique",
"Path local").

**KB debt, owed by Claude.ai, deliberately not interleaved with this chore.**
The trap note of `engine-audit-checklist.md` §1.2 states only the Roadmap
reading of `§22`, while the corpus carries three: Roadmap (`§22.1`–`§22.4`),
Éditeur (`§22.10` and `§22 Couche N`, per A6), and Outils de Debug Avancés in
the 27-section numbering. Producing the amendment mid-chore is the exact
mechanism that manufactures the drift being paid off here.

**No `weld_lint` rule**, per the body. The exit check is the amended criterion 1
of A2, run by hand: the grep must return the 30 enumerated lines and nothing
else. Anything that changes that list — a new brief citing the old form, a
reading record edited — is a defect on one side or a damaged record on the
other, and both are visible from the same command.
