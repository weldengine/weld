# etch_synth

Deterministic CLI that generates a synthetic Etch corpus used by the S5
compile-time bench (`zig build bench-etch-compile`). Same seed →
byte-identical output across runs and platforms.

## Usage

```
zig build synth-100 -- --output <dir> --count <N> --seed <S>
```

Default seed: `0x5ec0d e0a55` (hard-coded in `main.zig`). Override via
`--seed`. Output goes to `<dir>/000.etch … <N-1>.etch` (three-digit
zero-padded basenames so lexicographic ordering matches numeric).

## Distribution

Each generated program has:

- 5–10 `component` declarations (`Cmp_<prog>_<n>`), each with 2–3 fields
  picked uniformly across `int` / `float` / `bool`.
- 1 `resource` declaration (`Cfg_<prog>`) with a `bool` `enabled` field.
- 3–5 `rule`s with `when` clauses combining 1–3 `entity has X` checks and
  (roughly half the time) a `resource <Cfg>` gate. Each rule body
  mutates the first numeric field of the first component via `+= <literal>`.

The corpus is intentionally **stress-shaped** for the codegen:

- Distinct archetype signatures per rule (the `when` set varies).
- Both `int` and `float` arithmetic in the body.
- Resource gates so the cooked code exercises the
  `world.resources.contains` early-return path.

## Regenerating the bench fixture

```
zig build synth-100 -- --output bench/fixtures/synth_100/scripts --count 100
```

The 100 committed files are the canonical bench input; do not edit them
by hand.
