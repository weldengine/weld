# Chore — Language Normalization (FR → EN)

> **Status:** PLANNED
> **Branch:** `phase-0/chore/language-normalization`
> **Tag:** none — pure maintenance chore, merged to `main` without a tag (see `engine-development-workflow.md`: maintenance chores are not tagged). Sits **before M0.5**.
> **Depends on:** M0.4 (HEAD). Blocks nothing functionally; should land before M0.5 so the housekeeping milestone starts from an all-English tree.
> **Language of this brief:** English — first brief produced under the new language doctrine (`engine-development-workflow.md` §4.2).

## Context

The post-M0.4 code review measured a direct correlation between the French ratio of milestone briefs and the volume of French comments in the code Claude Code produced:

- Spikes S0/S1/S2 briefs ≈ 0% FR → corresponding code is English.
- Milestones M0.2–M0.4 briefs ≈ 33–37% FR → ~738 lines of French comments across 58 `.zig` files, concentrated in the **render** module (M0.4) and **plugin_loader** (M0.2).

The root cause is now fixed **at the source** (brief produced in English by Claude.ai; conversation/artefact language dissociated in the Claude Code prompt; per-milestone language acceptance criterion — all inscribed in `engine-development-workflow.md`). This chore clears the **existing stock** so the repository is coherent as a single English artefact — a goal in itself for an MIT open-source project read by external contributors.

This is **not** a numbered milestone: zero new capability, nothing to gate. It is a maintenance pass, merged without a tag.

## Objective

Bring the entire repository to **strict English** for all prose and comments, with **zero semantic change** to code, contracts, or measurements. Translation only — never a logic change, never an identifier rename (identifiers are already English).

## Scope — IN

1. **Code comments (`.zig`)** — ~738 FR lines across 58 files. Largest contributors (translate all, not only these):
   - `src/modules/render/gal/` (`types.zig` 50, `barriers.zig` 39, `vulkan/*` ~150 cumulative, `null/*`, `escape_hatches.zig`, `interface.zig`, `main.zig`)
   - `src/modules/render/render_graph/` (`graph.zig` 32, `pass.zig` 20, `passes/*`)
   - `src/modules/render/shader_pipeline/` (`compiler.zig` 19, `cache.zig` 9, `hot_reload.zig` 9)
   - `src/modules/render/instancing/batcher.zig` (35)
   - `src/core/plugin_loader/` (`desc.zig` 45, `loader.zig` 34, `api.zig` 18)
   - `src/core/platform/input/linux_evdev.zig` (10)
   - `tests/**` (`vk_gen/*`, `core/plugin_loader/*`, `render/*`, `ecs/no_alloc_steady_state_stress.zig`, `platform/*`)
   - plus any residual `.zig` under the grep (see Acceptance).
2. **Closed milestone briefs** — `briefs/{S3,S5,S6,M0.1,M0.2,M0.2.1,M0.3,M0.4}-*.md`, FR prose only (~750 lines). Repository-coherence rationale (decided by Guy): a repo with half-EN/half-FR briefs is incoherent regardless of contamination risk.
3. **`CLAUDE.md`** — ~26 FR lines.
4. **`bench/reports/*.md`** — 8 files, ~92 FR lines (benchmark report prose). Included by repo-coherence parity with the closed briefs.

## Scope — OUT

- **No FR-detection linter.** Explicitly dropped: infra cost + false positives on identifiers/strings, for a risk already tarried at the source by the English-brief rule. The exit check is a one-shot manual grep, not a permanent CI rule.
- **No functional change, no refactor, no identifier rename, no logic edit.** Translation of prose/comments only.
- **No bench number / SHA / commit-message edits.** Those are already English or are data, not prose.
- **No new tag.** Merged to `main` untagged.

## Translation rules (load-bearing — a mistranslated comment misleads future readers)

- Translate **only** French prose and comments. Leave English text, code, identifiers, and string literals untouched.
- **Preserve verbatim**: doc-comment cross-references (`engine-*.md §X`, `etch-*.md §X`), section markers and pragmas (e.g. `WELD_LEGACY_VK_DISPATCH`, `WELD_IPC_PROTOCOL_VERSION`), milestone tags (`M0.x / Ey`), SHAs, benchmark figures and units, file paths.
- In closed briefs: translate FR prose, but **do not touch** blocks reproducing tool output, commit messages (already EN), or acceptance-contract wording where a reword could shift meaning — translate faithfully, do not paraphrase.
- Keep doc-comment structure and line correspondence stable where possible (minimise diff noise so the human review at each stop point is tractable).
- When a French comment is ambiguous or its intent is unclear, **flag it at the stop point** rather than guessing.

## Execution steps

Each `Ei` ends at a **STOP point**: Claude Code halts and awaits Guy's review + GO before the next step. Guy's review of the translated diff is mandatory (semantic fidelity cannot be verified by grep alone).

- **E1 — Core code.** Translate `src/core/plugin_loader/*`, `src/core/platform/input/linux_evdev.zig`, and any residual FR in `src/core/**`. → **STOP / review / GO**
- **E2 — Render module.** Translate `src/modules/render/**` (GAL, render_graph, shader_pipeline, instancing) — the bulk of the stock. → **STOP / review / GO**
- **E3 — Tests.** Translate FR comments in `tests/**`. → **STOP / review / GO**
- **E4 — Closed briefs.** Translate FR prose in `briefs/{S3,S5,S6,M0.1,M0.2,M0.2.1,M0.3,M0.4}-*.md`. → **STOP / review / GO**
- **E5 — CLAUDE.md + bench reports.** Translate `CLAUDE.md` and `bench/reports/*.md`. → **STOP / review / GO**
- **E6 — Final verification.** Run the exit grep + `zig build test` + confirm CI green. Open closing PR.

Rationale for the split: render (E2) is the largest and riskiest paquet (GPU-adjacent comments where precision matters); isolating it keeps each review batch reasonable. ECS/Etch are deliberately absent — they carry negligible FR.

## Acceptance criteria

- Exit grep returns **zero** on the whole repo (code + briefs + CLAUDE.md + bench reports):
  `grep -rnE '//.*\b(le|la|les|une|des|pour|avec|dans|être|cette|où|donc|ainsi|car)\b' src tests` and the equivalent prose grep on `*.md` — manual inspection of any hit to rule out false positives (an English line incidentally containing e.g. "ascii **car**riage").
- `zig build test` green — **no referenced comment or doc-comment broke a test or a reference** (the translation must not have touched anything load-bearing).
- CI green on Linux (+ Windows when available).
- **No tag created.** Branch merged to `main`, then deleted.
- The new language doctrine is exercised by this very chore: this brief is English; the Claude Code prompt dissociates conversation (FR) from repo artefacts (EN, strict).

## Out of scope (explicit)

- FR-detection linter (dropped).
- Any functional change, refactor, or identifier rename.
- The M0.5 housekeeping items (separate milestone).
- Tagging.

## Acted deviations

- **E2 GO (Guy) — scope widened: comments + test-name strings.** The chore now
  also covers French `test "..."` descriptive strings, not just comments. E3
  translates French test names to English and updates every comment that
  references them (both sides kept consistent). Precautions when renaming a
  test: (a) grep the repo for `--test-filter` / CI / hardcoded references to the
  old name and update them too; (b) touch only the `test` descriptive string,
  never a function/decl identifier. The E6 acceptance grep is extended to cover
  French `test "..."` strings, not only comments.
- **E3 GO (Guy) — scope widened again: dev-message string literals.** The chore
  now also covers French developer-facing string literals — specifically the
  `gal/interface.zig` `.purpose = "..."` table (surfaced via `@compileError` +
  `listRequiredMethods`). Translated in E3 *before* test names. Integrity: touch
  only the `.purpose` value, never a key/type/table logic. Mandatory precaution
  (done, clean): grep the FR text in `tests/` + repo for golden/snapshot/test
  matches; none found. `log.*` / `@panic` messages are already English. The E6
  acceptance grep is extended to cover dev-message strings too.
- **Out of scope, confirmed: `etch/lexer.zig:371` `"café"`** — intentional UTF-8
  test input, not a message. Left untouched; flagged as an English/test-data
  false positive for the E6 grep.

## Execution notes

- **Canonical English titles for closed-brief sections** (E1 code references
  already use these verbatim; E4 must title the corresponding brief sections
  identically so the code cross-references stay valid):
  - M0.3 — "std.once verification for Zig 0.16"
  - M0.2.1 — "E3 residual hypotheses"
  - S6 — "Inherited debts"
  - M0.2 / E1 — "Deliverable"
  - M0.3 — "minimal Tier 0 input system" (the input excerpts). NOTE: E1 left the
    `linux_evdev.zig` / `win32_xinput.zig` references reading
    "§ Input system Tier 0 minimal"; E4 aligns both those code references and the
    M0.3 brief section title to "minimal Tier 0 input system".
- **Canonical English brief-SECTION names** (generic section headers cited by code
  cross-references; E2 standardized these, E4 must title the closed-brief sections
  identically):
  - "Critères d'acceptation" → "Acceptance criteria" (e.g. `instancing/batcher.zig`)
  - "Comportement observable" → "Observable behavior" (e.g. `shader_pipeline/compiler.zig`, `hot_reload.zig`)
  - "Suppressions" → "Removals" (e.g. `gal/vulkan/frame.zig`, `swapchain.zig`)
  - "Fichiers" → "Files" (e.g. `gal/vulkan/sampler.zig`)
  - "Notes" / "Scope" / "Out-of-scope" / "CI" — already English-identical, unchanged.
  - "Décomposition en étapes" → "Step decomposition" (M0.2.1; cited by
    `tests/ecs/no_alloc_steady_state_stress.zig`)
  - "Cas N" decision-branch labels → "Case N" (M0.2.1; cited by the stress test +
    `tests/core/plugin_loader/stub_plugin/plugin.zig`)

## Closing notes

*(filled at CLOSED, before opening the PR)*

- **What worked:**
- **What deviated from this brief:**
- **What to flag explicitly in review:** (ambiguous comments encountered; any line where faithful translation was non-obvious)
- **Final measures:** files touched, FR lines removed, `zig build test` result.
- **Residual risk / debt left intentionally:**
