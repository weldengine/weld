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

```etch
rule closure_block_return(entity: Entity)
  when entity has Counter
{
  let pick = |x: int| {
    if x > 3 {
      return 40
    }
    x
  }
  entity.get_mut(Counter).value = pick(7) + 2
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
    throw Error { message: "boom", code: ErrorCode.io_fail }
  } catch err {
    x = err.message.len()
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

## Optionals — T? / none / some / if let / while let (E2 block 5)

```etch
fn first_positive(a: int, b: int) -> int? {
  if a > 0 { some(a) } else if b > 0 { some(b) } else { none }
}

rule pick(entity: Entity)
  when entity has Counter
{
  let chosen: int? = first_positive(0, 9)
  let mut total = 0
  if let x = chosen {
    total += x
  } else {
    total = -1
  }
  while let y = (if total < 3 { some(total) } else { none }) {
    total += 1
  }
  entity.get_mut(Counter).value = total
}
```

## Events — event declaration / emit (E3 ECS layer)

```etch
event DamageDealt { amount: int = 0, crit: bool = false }

rule deal_damage(entity: Entity)
  when entity has Health
{
  emit DamageDealt { amount: 25, crit: true }
}
```

## Tags — declaration / query operators / deferred mutation (E3 ECS layer)

```etch
tags {
  unit {
    status { alive, dead, stunned }
    team { red, blue }
  }
}

rule tag_ops(entity: Entity)
  when entity has Counter
  and entity has_tag .unit.status.alive
  and entity has_no_tag .unit.status.dead
  and entity has_any_tag [.unit.team.red, .unit.team.blue]
  and entity has_all_tags [.unit.status.alive, .unit.status.stunned]
{
  entity.add_tag(.unit.status.stunned)
  entity.remove_tag(.unit.status.alive)
}
```

## Observer — @on_event rule with the implicit `event` binding (E3 ECS layer)

```etch
event DamageDealt { amount: int = 0 }
resource DamageTally { total: int = 0 }

@on_event(DamageDealt)
rule absorb_damage()
  when resource DamageTally
{
  let t = get_mut(DamageTally)
  t.total += event.amount
}
```

## Change detection — `entity has T changed` filter (E3 ECS layer)

```etch
component Health { current: i32 = 100 }
component Counter { value: i32 = 0 }

rule react(entity: Entity)
  when entity has Counter and entity has Health changed
{
  entity.get_mut(Counter).value += 1
}
```

## Async — `async rule` + `await` (E3 sub-slice B)

```etch
event QuestStarted { }
resource Quest { stage: int = 0 }

async rule intro_sequence()
  when resource Quest
{
  let q = get_mut(Quest)
  q.stage = 1
  await wait(2)
  await global_event(QuestStarted)
  let done = get_mut(Quest)
  done.stage = 2
}
```

## String interpolation — `"a {expr} b"` (E3 sub-slice C tranche 1c)

```etch
component Acc { out: int = 0 }

rule announce(entity: Entity)
  when entity has Acc
{
  let who = "weld"
  let msg = "hi {who}, n={1 + 2}, literal brace: \{x}"
  entity.get_mut(Acc).out = msg.len()
}
```

## Optional ops — `?.` / `??` / `!` + `some`/`none` patterns (E3 sub-slice C tranche 4)

```etch
component OptAcc { out: int = 0 }

rule optional_ops(entity: Entity)
  when entity has OptAcc
{
  let mut xs: int[] = [10, 20]
  let a = xs.pop() ?? -1
  let b = xs.pop()!
  let mut m = [1: 100, 2: 200]
  let c = m[1] ?? 0
  let s: string? = some("hello")
  let d = s?.len() ?? 0
  let e = match m[2] {
    some(x) => x + 1,
    none => 0,
  }
  entity.get_mut(OptAcc).out = a + b + c + d + e
}
```

## Sets — `Set.new()` / `Set.from([...])` builtin associated calls (E3 sub-slice C tranche 3bis)

```etch
component SetAcc { out: int = 0 }

rule set_ops(entity: Entity)
  when entity has SetAcc
{
  let empty: Set<int> = Set.new()
  let mut s = Set.from([1, 2, 2, 3])
  s.insert(4)
  if s.contains(2) {
    entity.get_mut(SetAcc).out = s.len() + empty.len()
  }
}
```

## Methods — `mut self` receiver mutated in place (E3 sub-slice C tranche 5)

```etch
component MutAcc { out: int = 0 }

struct Cnt { v: int }

impl Cnt {
  fn bump(mut self, by: int) {
    self.v += by
  }

  fn peek(self) -> int {
    self.v
  }
}

rule mutate_through_method(entity: Entity)
  when entity has MutAcc
{
  let mut c = Cnt { v: 1 }
  c.bump(41)
  entity.get_mut(MutAcc).out = c.peek()
}
```

## Anonymous struct literal — `.{ field: value }` against the expected type (E3 sub-slice C tranche 8)

```etch
component AnonAcc { out: int = 0 }

struct Pt { x: int y: int }

struct Box { p: Pt k: int }

rule anon_struct_literals(entity: Entity)
  when entity has AnonAcc
{
  let q: Pt = .{ x: 40, y: 2 }
  let b = Box { p: .{ x: 7, y: 5 }, k: 30 }
  entity.get_mut(AnonAcc).out = q.x + q.y + b.p.x + b.k
}
```
