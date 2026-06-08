<!-- ebnf-example corpus for the M0.8 EBNF harness (ebnf_examples_test.zig).

Each fenced ```etch block below is extracted and fed to the parser; every block
must parse without error. The blocks are E1-valid programs drawn from the
grammar (etch-grammar.md) and the reference (etch-reference-part1.md) — the
constructs landed in E1: component/resource/rule, the when clause, expressions,
cast, type aliases, assert, match, ranges + for-in, collections (arrays / maps,
indexing, slicing), closures, loop/break/continue, and throw/try/catch.

The spec docs are not in the repo (engine-spec decision); this file is the
in-repo example source the harness embeds. When the grammar enters the repo
(re-evaluated in Phase 0), the harness can point @embedFile at it directly. As
later stages land constructs, their example blocks are appended here. -->

# EBNF example blocks (E1)

## Components and resources

```etch
component Health {
  current: float = 100.0
  max: float = 100.0
}
```

```etch
@save
component Position {
  x: float = 0.0
  y: float = 0.0
}
```

```etch
component Counter {
  @range(0, 100)
  value: int = 0
}
```

```etch
resource GameMode {
  max_players: i32 = 4
}
```

```etch
@config
resource GraphicsSettings {
  resolution_scale: f32 = 1.0
}
```

## Type aliases

```etch
type Meters = float
```

```etch
type Score = int
```

## Rules and when clauses

```etch
rule heal(entity: Entity)
  when entity has Health
{
  entity.get_mut(Health).current += 1.0
}
```

```etch
rule tick(entity: Entity, dt: float)
  when entity has Health and entity has Position
{
  let h = entity.get(Health)
}
```

```etch
rule frozen_check(entity: Entity)
  when entity has Health and not entity has Position
{
  let c = entity.get(Health).current
}
```

```etch
rule either(entity: Entity)
  when entity has Health or entity has Position
{
  let x = 0
}
```

```etch
rule filtered(entity: Entity)
  when entity has Counter { value == 0 }
{
  entity.get_mut(Counter).value = 1
}
```

```etch
rule resource_gate()
  when resource GameMode
{
  let m = get(GameMode).max_players
}
```

```etch
rule resource_changed_gate()
  when resource GameMode changed
{
  let mode = get_mut(GameMode)
}
```

## Cast, assert

```etch
rule promote(entity: Entity)
  when entity has Counter
{
  let n = entity.get(Counter).value
  entity.get_mut(Position).x = n as float
}
```

```etch
rule guard(entity: Entity)
  when entity has Health
{
  assert(entity.get(Health).current > 0.0, "must be alive")
}
```

## Match

```etch
rule classify(entity: Entity)
  when entity has Counter
{
  let v = entity.get(Counter).value
  entity.get_mut(Counter).value = match v { 0 => 10, 1 => 20, _ => 0 }
}
```

```etch
rule pick(entity: Entity)
  when entity has Counter
{
  entity.get_mut(Counter).value = match entity.get(Counter).value { n => n + 1 }
}
```

## Ranges and for-in

```etch
rule sum_range(entity: Entity)
  when entity has Counter
{
  let mut s = 0
  for i in 0..10 {
    s += i
  }
  entity.get_mut(Counter).value = s
}
```

```etch
rule sum_inclusive(entity: Entity)
  when entity has Counter
{
  let mut s = 0
  for i in 0..=5 {
    s += i
  }
  entity.get_mut(Counter).value = s
}
```

## Collections: arrays, indexing, slicing

```etch
rule array_index(entity: Entity)
  when entity has Counter
{
  let arr = [10, 20, 30]
  entity.get_mut(Counter).value = arr[1]
}
```

```etch
rule array_slice(entity: Entity)
  when entity has Counter
{
  let arr = [1, 2, 3, 4]
  let s = arr[1..3]
  entity.get_mut(Counter).value = s[0]
}
```

```etch
rule array_fill(entity: Entity)
  when entity has Counter
{
  let buf = [0; 8]
  entity.get_mut(Counter).value = buf[0]
}
```

```etch
rule for_array(entity: Entity)
  when entity has Counter
{
  let xs = [1, 2, 3]
  let mut total = 0
  for x in xs {
    total += x
  }
  entity.get_mut(Counter).value = total
}
```

## Collections: maps

```etch
rule map_sum(entity: Entity)
  when entity has Counter
{
  let m = [1: 10, 2: 20]
  let mut s = 0
  for k, v in m {
    s += v
  }
  entity.get_mut(Counter).value = s
}
```

```etch
rule empty_map(entity: Entity)
  when entity has Counter
{
  let m: [int: int] = [:]
  entity.get_mut(Counter).value = 0
}
```

## Closures

```etch
rule closure_apply(entity: Entity)
  when entity has Counter
{
  let double = |x: int| x * 2
  entity.get_mut(Counter).value = double(21)
}
```

```etch
rule closure_capture(entity: Entity)
  when entity has Counter
{
  let factor = 3
  let scale = |x: int| x * factor
  entity.get_mut(Counter).value = scale(5)
}
```

## Loop, break, continue

```etch
rule loop_break(entity: Entity)
  when entity has Counter
{
  let x = loop {
    break 42
  }
  entity.get_mut(Counter).value = x
}
```

```etch
rule labeled_break(entity: Entity)
  when entity has Counter
{
  let mut found = 0
  outer: loop {
    loop {
      found = 7
      break outer
    }
  }
  entity.get_mut(Counter).value = found
}
```

## Error handling

```etch
rule try_catch(entity: Entity)
  when entity has Counter
{
  let mut x = 0
  try {
    throw 99
  } catch err {
    x = err
  }
  entity.get_mut(Counter).value = x
}
```

## Declarations — struct + inherent impl (E2 block 3)

```etch
struct V2 {
  x: int = 0
  y: int = 0
}

impl V2 {
  fn sum(self) -> int {
    self.x + self.y
  }
  fn make(a: int, b: int) -> V2 {
    V2 { x: a, y: b }
  }
}
```

## Declarations — enum + variant match (E2 block 3 tranche B)

```etch
enum Difficulty {
  easy,
  normal,
  hard,
}

rule pick(entity: Entity)
  when entity has Counter
{
  let d = Difficulty.hard
  entity.get_mut(Counter).value = match d {
    Difficulty.easy => 1,
    .normal => 2,
    Difficulty.hard => 3,
  }
}
```

## Declarations — trait + impl Trait for T (E2 block 3 tranche C)

```etch
trait Doubler {
  fn base(self) -> int
  fn doubled(self) -> int {
    self.base() * 2
  }
}

struct N {
  v: int = 0
}

impl Doubler for N {
  fn base(self) -> int {
    self.v
  }
}

rule pick(entity: Entity)
  when entity has Counter
{
  let n = N { v: 21 }
  entity.get_mut(Counter).value = n.doubled()
}
```

## Generics — params, bounds, where, generic types (E2 block 4)

```etch
trait Comparable {
  fn cmp(self, other: int) -> int
}

fn largest<T: Comparable>(a: T, b: T) -> T
  where T: Comparable
{
  a
}

struct Range<T> {
  min: T
  max: T
}

enum Holder<T> {
  present,
  absent,
}

rule pick(entity: Entity)
  when entity has Counter
{
  let chosen = largest(1, 2)
  entity.get_mut(Counter).value = chosen
}
```

## Generics — inherent impl with a generic target (§891)

```etch
struct Range<T> {
  min: T
  max: T
}

impl<T> Range<T> {
  fn contains(self, v: T) -> bool {
    v >= self.min and v <= self.max
  }
}

rule pick(entity: Entity)
  when entity has Counter
{
  let rng = Range { min: 2, max: 8 }
  entity.get_mut(Counter).value = if rng.contains(5) { 1 } else { 0 }
}
```
