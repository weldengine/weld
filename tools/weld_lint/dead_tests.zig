//! Dead-test analysis — every in-tree file holding a `test` block must belong to
//! the analysis closure of some test target, or be a DECLARED exclusion.
//!
//! WHY A STATIC CLOSURE AND NOT A COUNT. M1.1.14 hunted dead tests three times
//! with three methods; two failed. A per-binary enumeration blew a ten-minute
//! budget, and pairing the ordered spec list against the summary tree produced
//! 79 mismatches because that tree does not follow declaration order. What the
//! class needs is a check that builds nothing and runs nothing.
//!
//! WHY IT MATTERS MORE THAN SLEEPING ASSERTIONS. An uncollected `test` block is
//! never ANALYSED, so the code it instantiates gets no elaboration and no
//! type-checking. That one mechanism explains both areas the sweep found:
//! `zig_codegen/cache.zig` stopped compiling when `std.fs.cwd()` was removed at
//! Zig 0.16 and nobody learned it, and a use-after-return in the render graph
//! survived ten milestones. A dead test switches off COMPILATION coverage.
//!
//! THE EDGE CRITERION, and it is a criterion rather than a heuristic — it was
//! derived from measurements that discriminate all four observed cases:
//!
//!   - `_ = @import("f.zig");` inside a `comptime` block → EDGE.
//!     The explicit reference guard. In CODE: a commented-out one is not an edge,
//!     and that mattered (see below).
//!   - `const n = @import("f.zig");` (or `pub const`) where `n` is referenced
//!     elsewhere in this root's closure → EDGE. This is why `src/etch/lexer.zig`'s
//!     17 tests are collected although nothing pins the file: `parser.zig` binds
//!     it and uses it.
//!   - `const n = @import("f.zig");` never referenced → NO EDGE. This is why
//!     `zig_codegen/root.zig` was dead: `src/etch/root.zig` binds it as
//!     `pub const codegen_zig` and never touches the name.
//!   - `@import("f.zig").decl` used inline → decided by the REFERENCE like every
//!     other form, never by the syntax. `pub const Graph = @import("graph.zig").Graph`
//!     pulls that file's tests once `Graph` is referenced; `triangleIsFlat` pulled
//!     nothing because nothing referenced it. Same syntax, opposite outcomes.
//!
//! It approximates Zig's lazy analysis, and the direction of its error matters: a
//! missed edge yields a false DEAD, noisy and visible; an invented edge yields a
//! false ALIVE, which says green. The hostile fixtures exist to refuse the second.
//!
//! THE CLOSURE IS PER ROOT, AND THAT IS THE CORRECTION THAT MADE IT BELIEVABLE.
//! A single closure over all roots at once let a reference made from ANOTHER
//! module license an edge inside this one: `tests/etch/keyword_ident_test.zig`
//! names `codegen_zig`, but it reaches it through the `weld_etch` MODULE, and
//! Zig collects no tests across a module boundary. Thirty-seven blocks that no
//! binary runs were counted live. Per root, growth is monotone — files only
//! enter, a reference counts only from a file already admitted HERE, and no two
//! files vouch for each other into the closure.
//!
//! `live_tests` is therefore the sum over roots, a MULTISET count: a file two
//! targets reach is counted twice, because the suite compiles and runs it twice.
//! That is what makes it comparable to the suite's own collected total. The dead
//! verdict is taken against the UNION — a file is dead only if NO root reaches it.
//!
//! TWO FALSE-ALIVE DEFECTS, both found by measurement and neither by the
//! fixtures, recorded because each is a class rather than an instance:
//!
//!   1. A BINDING COUNTED AS A REFERENCE TO ITSELF. The cross-file search
//!      re-reads every live file including the one under analysis, passing
//!      `osrc.len` as the binding-line start — a sentinel meaning "nothing to
//!      skip". With the binding file as its own candidate the exclusion window
//!      was empty, so `pub const codegen_zig = @import(…)` was its own
//!      justification. The same-file test was POINTER IDENTITY, which never
//!      fired: the production reader allocates a fresh buffer per call. It is now
//!      by PATH. The fixture harness returned the map's own stable pointer, so
//!      the bug was unreachable there — a harness differing from production in
//!      the exact property under test agrees with the code instead of judging it.
//!      It now allocates per call too.
//!   2. A COMMENTED-OUT IMPORT READ AS AN IMPORT. `src/etch/root.zig` shows the
//!      guard that WOULD wire the subtree, `//   _ = @import("zig_codegen/root.zig");`,
//!      and the head of that line ends in `_ =`. The reference search had been
//!      taught to skip comments earlier in this milestone, for the same file and
//!      nearly the same sentence; the IMPORT site had not. A correction applied
//!      at one site and not at its twin is the motif this repository sweeps.
//!
//! ROOT DISCOVERY IS ANCHORED ON THE WIRING, not on path syntax: a table is read
//! only when a `for` loop over it calls `addTest`, and a module's
//! `root_source_file` is read only inside that declaration's own initializer.
//! The previous forms invented roots out of `zig fmt` arguments and out of the
//! next declaration's literal. See `loopRoots` and `modulePath`.
//!
//! THE BILATERAL CONTROL IS WHAT AUTHORISES THIS GUARD, and it is not the fixture
//! count. Two independent computations must land on one number: this closure, and
//! `zig build test --summary all`. Too permissive overshoots, too strict
//! undershoots, and only equality excludes both — a property twenty-odd passing
//! fixtures did not have, and which caught a real defect on its first
//! application. Every term of the difference is declared IN ADVANCE in
//! `uncollected`: a predicted gap is a result, the same gap unannounced reads as
//! a broken guard. Measured on all three platforms of the matrix at the state
//! that activated it, closure 1857 in every case:
//!
//!   macOS   1857 − 5 = 1852, suite reports 1852
//!   Linux   1857 − 5 = 1852, suite reports 1852
//!   Windows 1857 − 7 = 1850, suite reports 1850
//!
//! The three reconcile exactly, and getting there refuted the hypothesis the gap
//! was first written on: `conv.zig` is collected on NO platform, not just macOS.
//!
//! Only relative `.zig` imports are followed. A module-name import (`std`,
//! `weld_core`) crosses into a module that owns its own test target and its own
//! closure — and, as the per-root correction above shows, its own references.

const std = @import("std");

/// One file that holds `test` blocks but sits outside every closure.
pub const Dead = struct {
    path: []const u8,
    tests: usize,
};

/// What an analysis pass found, including the size of what it looked at.
///
/// The counts are not decoration: this tool exists because a probe rendered a
/// verdict over an object it had not measured, four times in one milestone. A
/// report that says "0 dead" over 0 files examined is the same defect wearing
/// the tool's own badge.
pub const Report = struct {
    /// Files reached from at least one root.
    in_closure: usize = 0,
    /// Files under the scanned roots holding at least one `test` block.
    with_tests: usize = 0,
    /// Test blocks counted in the closure.
    live_tests: usize = 0,
    /// Files holding tests and outside every closure, excluding declarations.
    dead: std.ArrayList(Dead) = .empty,
    /// Files matched by a declared exclusion, reported and not failed on.
    excluded: usize = 0,
    /// Test blocks inside declared exclusions.
    excluded_tests: usize = 0,
    /// Every closure file with its test count, so a delta can be DECOMPOSED.
    closure: std.ArrayList(Dead) = .empty,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        for (self.dead.items) |d| gpa.free(d.path);
        self.dead.deinit(gpa);
        for (self.closure.items) |c| gpa.free(c.path);
        self.closure.deinit(gpa);
    }
};

/// A deliberate refusal to elaborate a subtree, with the milestone that owns it.
///
/// An exclusion is DECLARED, never silent: that is what separates a known debt
/// from a hidden one, and it is why `zig_codegen` has a legitimate status here
/// rather than an embarrassed absence.
pub const Exclusion = struct {
    prefix: []const u8,
    reason: []const u8,
    owner: []const u8,
};

/// The tree's declared exclusions.
pub const exclusions = [_]Exclusion{
    .{
        .prefix = "src/etch/zig_codegen/",
        .reason = "the subtree IS elaborated — two live test targets reach `codegen_zig` through " ++
            "the `weld_etch` module boundary — but the subset the wire-in ADDS does not compile: " ++
            "`zig_codegen/tests/` and `cache.zig`, where `std.fs.cwd()` was removed at Zig 0.16 " ++
            "and the replacement takes an `io` parameter these functions do not have, so the " ++
            "repair changes the codegen cache's public signatures",
        .owner = "M1.D.5",
    },
};

/// A file INSIDE the closure whose blocks `zig build test` does not collect.
///
/// The closure count and the suite's collected total are two independent
/// computations, and their agreement is what authorises this guard. They are not
/// equal, and every term of the difference is declared HERE, in advance: a
/// predicted gap is a result, while the same gap unannounced reads as a broken
/// guard and nobody activates it. An undeclared gap is exactly what the control
/// exists to surface.
///
/// This is a different list from `exclusions`. An exclusion is a subtree no
/// closure reaches at all; an entry here is reached, counted, and then not
/// collected — for a reason that lives in the compiler or in `build.zig`, never
/// in this analysis.
pub const Uncollected = struct {
    path: []const u8,
    blocks: usize,
    /// `null` means every platform.
    only_on: ?std.Target.Os.Tag = null,
    reason: []const u8,
};

/// The declared terms of the closure-versus-suite gap, one entry per mechanism.
pub const uncollected = [_]Uncollected{
    .{
        .path = "src/modules/render/gal/vulkan/conv.zig",
        .blocks = 4,
        .reason = "reached by this analysis through `gal/root.zig`'s `pub const " ++
            "vulkan_backend`, and elaborated by Zig on NO platform of the matrix: the " ++
            "render step reports 45 collected against a closure of 49 on macOS, on " ++
            "ubuntu-24.04 and on windows-2025 alike. MEASURED, and it REFUTES the standing " ++
            "hypothesis that the macOS Null backend was the cause and that Linux and " ++
            "Windows would collect these four — they do not. What is established is the " ++
            "absence, on all three; the mechanism inside Zig's lazy analysis is not, and " ++
            "is deliberately not guessed at here",
    },
    .{
        .path = "src/core/ipc/shm_posix.zig",
        .blocks = 1,
        .only_on = .windows,
        .reason = "selected by comptime dispatch inside `shm.zig` and not analysed on " ++
            "Windows. This analysis is static and follows the import regardless",
    },
    .{
        .path = "src/core/ipc/transport_posix.zig",
        .blocks = 1,
        .only_on = .windows,
        .reason = "same comptime dispatch as `shm_posix.zig`. The pair is exactly the " ++
            "Linux-minus-Windows gap: the `core` step reports 167 collected on " ++
            "ubuntu-24.04 and 165 on windows-2025, and that ONE step is the only " ++
            "difference between the two cells across all 129",
    },
    .{
        .path = "tests/ecs/no_alloc_steady_state_stress.zig",
        .blocks = 1,
        .reason = "the M0.2.1/E2 scheduler-livelock stress test hangs off `zig build " ++
            "test-stress` and is deliberately kept OUT of `zig build test` — its own " ++
            "`build.zig` comment says so. THE FIFTH BLOCK of the M1.1.14 sweep, which two " ++
            "attempts failed to localise: it was never dead and never missing, it was in a " ++
            "step the suite does not run",
    },
};

/// Blocks the closure counts that `zig build test` does not collect, on `os`.
/// The number of test blocks `zig build test` COLLECTS on each platform.
///
/// **THIS IS THE OTHER SIDE OF THE CONSERVATION, and until M1.1.14's review there
/// was no other side.** `uncollectedOn` gives the declared gap, so
/// `live_tests - gap` yields an EXPECTED collected total — and the tool printed
/// that expectation and then printed `clean`, having compared it to nothing. The
/// confrontation existed only behind an optional `--expect-collected=N` that
/// neither `build.zig` nor the CI ever passed. A control that a path can bypass is
/// not a control, and this one was the guard built AGAINST that very class.
///
/// **WHY A DECLARED NUMBER AND NOT A DERIVED ONE.** The tool cannot run the suite;
/// it reads source. So the unconditional check confronts the closure against a
/// number a human wrote down, which catches CLOSURE drift on every invocation with
/// no flag to forget. What stops that number from being bumped to match a drifted
/// closure is the SECOND layer: CI parses `zig build test`'s own reported total and
/// passes it through `--expect-collected`, so the declared number is itself
/// confronted with what the suite actually ran. Two independently produced numbers,
/// which is the definition the bilateral control has carried since it was written.
///
/// **Windows is two lower** and the two blocks are the `only_on = .windows` entries
/// above — `shm_posix.zig` and `transport_posix.zig`. That is arithmetic on this
/// same table and not a second measurement, which is why the CI layer matters.
pub fn expectedCollectedOn(os: std.Target.Os.Tag) usize {
    // Reconciled against `zig build test --summary all`, which reported **1875
    // collected on macOS** (1856 passed + 19 skipped) at M1.1.15 — NOT bumped to
    // match the closure's own arithmetic, which is the repair the failure message
    // forbids. The two numbers agree here, and they were produced independently:
    // 1875 is what the suite ran, and the closure separately arrives at 1875 from
    // this table. Windows is two lower, the two `only_on = .windows` entries above.
    //
    // This control has now stopped three commits in a row on its first real uses,
    // each time on a genuine test addition, and each time the number was re-derived
    // from the suite rather than from the closure. That is the whole point of it.
    // M1.1.15 bumps this twice, once per gate that adds blocks, and each time the number
    // is re-derived from the SUITE: gate A added six blocks in
    // `forge_3d/tests/world_test.zig` (1869 → 1875, suite reported 1875), gate B added
    // three more to the same file (1875 → 1878, suite reported 1878 — 1859 passed + 19
    // skipped, macOS aarch64). The CI layer confronts both branches on the matrix
    // platforms themselves: measured 1875 on `ubuntu-24.04` and 1873 on `windows-2025`
    // at gate A, through `-Dexpect-collected` fed by each cell's own total.
    // Gate C added six more to `world_test.zig` (1878 → 1884, suite reported 1884 —
    // 1865 passed + 19 skipped, macOS aarch64).
    // `moveKinematic` added one more at the gate C round-trip (1884 → 1885, suite
    // reported 1885 — 1866 passed + 19 skipped, macOS aarch64).
    // Gate D added two to `forge/api/components.zig` with the `Sleeping` marker
    // (1885 → 1887, suite reported 1887 — 1868 passed + 19 skipped, macOS aarch64).
    // Gate D added six in `tests/physics/transform_sync_test.zig` (1887 → 1893, suite
    // reported 1893 — 1874 passed + 19 skipped, macOS aarch64).
    // F-D1 added one signal test to `tests/physics/transform_sync_test.zig` (1893 → 1894,
    // suite reported 1894 — 1875 passed + 19 skipped, macOS aarch64).
    // Gate E added three to `forge/api/precision.zig` (1894 → 1897, suite reported 1897 —
    // 1878 passed + 19 skipped, macOS aarch64) and seven to the new
    // `weld_lint/rules/no_precision_crossing.zig` (1897 → 1904, suite reported 1904 —
    // 1885 passed + 19 skipped, macOS aarch64).
    // Gate E added two to the new `src/interfaces/PhysicsModule.zig` (1904 → 1906, suite
    // reported 1906 — 1887 passed + 19 skipped, macOS aarch64).
    // The F-F1/F-F2 closing pass on `no_precision_crossing` added three (1906 → 1909, suite
    // reported 1909 — 1890 passed + 19 skipped, macOS aarch64).
    // The closing NO-GO pass added eight: three transactionality tests plus a W4 test in
    // `world_test.zig`, a presence test and the registration test in `transform_sync_test.zig`,
    // and two Windows-spelling tests on the lint rule (1909 → 1917, suite reported 1917 —
    // 1898 passed + 19 skipped, macOS aarch64).
    // The NO-GO pass merged the tick and the publication and added the C1.1 gameplay-write
    // guard (1918 -> 1919, suite reported 1919 - 1900 passed + 19 skipped, macOS aarch64).
    // The NO-GO pass merged the tick and the publication, then added the C1.1 gameplay-write
    // guard, the trigger pair, the pre-publication dispatch and the double registration
    // (1918 -> 1922, suite reported 1922 - 1903 passed + 19 skipped, macOS aarch64).
    // The third NO-GO pass added the two lone-trigger cases, the write-conflict guard and the
    // isolated resolver test (1922 -> 1926, suite reported 1926 - 1907 passed + 19 skipped,
    // macOS aarch64).
    // The third NO-GO pass added the two lone-trigger cases, the write-conflict guard, the
    // isolated resolver test and the declared-access guard (1922 -> 1927, suite reported 1927
    // - 1908 passed + 19 skipped, macOS aarch64).
    // The fourth NO-GO pass added the two election tests, the update-issued moveKinematic
    // guard and three on the linter's path coverage, and wired `weld_lint/main.zig` into the
    // closure (1927 -> 1933, suite reported 1933 - 1914 passed + 19 skipped, macOS aarch64).
    // The fifth pass RE-SCOPED `syncIn` out of the milestone: four reception tests removed,
    // two reduced to their publication half, and the linter's path coverage re-tested
    // (1933 -> 1929, suite reported 1929 - 1910 passed + 19 skipped, macOS aarch64).
    // The fifth pass RE-SCOPED `syncIn` out of the milestone: four reception tests removed, two
    // reduced to their publication half, the linter's path coverage re-tested, and one added
    // for the election criterion's second level (1933 -> 1930, suite reported 1930 - 1911
    // passed + 19 skipped, macOS aarch64).
    // The sixth pass replaced the lint completeness machinery with visited declarations: the
    // three path-coverage tests go, one four-combination stale test arrives (1930 -> 1927,
    // suite reported 1927 - 1908 passed + 19 skipped, macOS aarch64).
    // The seventh pass added the `Sleeping` conflict twin and the presence-removal guard
    // (1927 -> 1929, suite reported 1929 - 1910 passed + 19 skipped, macOS aarch64).
    // The eighth pass moved the presence-removal guard into `world_test.zig` with its wake
    // half, and pinned the absent inward direction as one named test (1929 -> 1930, suite
    // reported 1930 - 1911 passed + 19 skipped, macOS aarch64).
    // The ninth pass added the publish/withdraw lifetime guard (1930 -> 1931, suite reported
    // 1931 - 1912 passed + 19 skipped, macOS aarch64).
    // The tenth pass closed the publication lifetime from both sides (1931 -> 1933, suite
    // reported 1933 - 1914 passed + 19 skipped, macOS aarch64).
    // M1.1.15.1 gate A added three blocks for `core.ModuleContext`: one inline field-set pin
    // in `src/core/module_context.zig` and the two named tests of
    // `tests/core/module_context_test.zig` (1933 -> 1936, suite reported 1936 - 1917 passed +
    // 19 skipped, macOS aarch64). The three carry no platform dispatch, so Windows moves by
    // the same three; that step is arithmetic on this table, and the `-Dexpect-collected`
    // layer fed by each cell's own total is what confronts it independently.
    // M1.1.15.1 gate B is a net +3 over gate A, and it is a net of removals and additions
    // rather than a bare addition — declared here because a floor that only ever grows
    // hides what left. REMOVED, three tests whose object the infallible `Broadphase.update`
    // deleted: `update is atomic under allocation failure` (broadphase_test), `a failed pose
    // write leaves the store where the broadphase still says it is` and `a failed
    // moveKinematic leaves a retry able to derive the same velocity` (world_test), plus `P1-1
    // a publication that fails leaves every body velocity untouched` (character_test) —
    // four. ADDED, seven: the four uniqueness-invariant tests in broadphase_test, two
    // allocation-free/no-divergence tests in world_test, and the rewritten P1-1.
    // (1936 -> 1939, suite reported 1939 - 1920 passed + 19 skipped, macOS aarch64.)
    // M1.1.15.1 gate C adds seven: five in the new `tests/physics/forge_module_test.zig`
    // (the surface's allocator/fallibility shape, the void/fallible split, the owned-allocator
    // lifecycle, the `step` failure sweep with its no-failure counter-factual, and the ECS
    // publication guard), and two in `src/interfaces/PhysicsModule.zig` — one extended, one
    // new for the `Step` contract. (1939 -> 1946, suite reported 1946 - 1927 passed + 19
    // skipped, macOS aarch64.)
    // M1.1.15.1 gate D adds three for the dense `BodyId` index (`M1.D.13`): two in
    // `forge_3d/tests/world_test.zig` — the stale-generation resolution and the two-way
    // agreement between the index and the registration list — and one in
    // `tests/physics/transform_sync_test.zig` for the publication order the index must not
    // touch. (1946 -> 1949, suite reported 1949 - 1930 passed + 19 skipped, macOS aarch64.)
    // THE M1.1.15.1 REOPENING (F1/F2/F3) added seven to `tests/physics/forge_module_test.zig`:
    // three that pin the two defects the external review named — deduplication at the
    // projecting tier, retention on the entity set, and the absence of a staging cap — and
    // four that take the rest of the adapter's surface from signature to behaviour, the
    // class sweep having measured 9 behaviour-asserted entries against 19 that were not.
    // (1949 -> 1956, suite reported 1956 - 1937 passed + 19 skipped, macOS aarch64.)
    // THE SECOND REOPENING (G1/G2) added five more to the same file: the allocator-exhaustion
    // pin that separates the one entry which CAN report from the three that cannot, and four
    // that give a DISCRIMINATING oracle to entries whose previous one told them apart from
    // nothing — `moveKinematic` against `setBodyTransform` (read through `ground_velocity`,
    // the frozen surface having no velocity getter), `addForce` against `addImpulse`,
    // `destroyShape` against a no-op, and `pointQuery` against `overlapAabb`.
    // (1956 -> 1961, suite reported 1961 - 1942 passed + 19 skipped, macOS aarch64.)
    // K1 split the premise pin in two: one test drives the PUBLIC path under truncation and
    // asserts what actually holds, the other asserts the refusal AND the windowed LIMIT of
    // that detection. Two tests where there was one.
    // (1963 -> 1964, suite reported 1964 - 1945 passed + 19 skipped, macOS aarch64.)
    // H1 added one: the entity-major premise guarded in EVERY mode rather than by a
    // `std.debug.assert` that ReleaseFast compiles to nothing.
    // (1961 -> 1962, suite reported 1962 - 1943 passed + 19 skipped, macOS aarch64.)
    // I2 added one: a signature walk over the four multi-result query entries, which now all
    // carry an error channel. A starved-allocator probe shows an entry DID report on one
    // call; the walk shows it CANNOT fail to.
    // (1962 -> 1963, suite reported 1963 - 1944 passed + 19 skipped, macOS aarch64.)
    // M1.1.15.2 G1 adds four to `src/etch/parser.zig` for the `.d.etch` parse mode:
    // the longest-match extension detection (with the §21 typed extensions pinned as NOT
    // declaration files), the `service` construct parsing bodyless, the E1900 refusal with
    // its `arena.stmts.len == 0` discriminator and its standard-mode reverse control, and
    // the standard-mode refusal with the stop-set recovery guard.
    // (1964 -> 1968, suite reported 1968 - 1949 passed + 19 skipped, macOS aarch64.)
    // The four carry no platform dispatch, so Windows moves by the same four; that step is
    // arithmetic on this table, and the `-Dexpect-collected` layer fed by each cell's own
    // total is what confronts it independently.
    // G1 adds two to `src/etch/types.zig`: the E1901 allow-list (with its
    // standard-mode counter-factual, its every-occurrence check, and the nine
    // admitted constructs) and the cross-file service resolution driven through
    // `checkProject` (unknown method, arity, local shadowing, and the
    // no-declaration-file counter-factual).
    // (1968 -> 1970, suite reported 1970 - 1951 passed + 19 skipped, macOS aarch64.)
    // The G1 AMENDMENT adds one to `src/etch/types.zig`: `event_decl` joins
    // §20.1's allow-list after a Claude.ai round-trip, and the test pins that it
    // parses, that it registers (observed through the duplicate-symbol path),
    // and that `component` and `resource` in the same position are still E1901 —
    // so the list widened by exactly one and not by a family.
    // (1970 -> 1971, suite reported 1971 - 1952 passed + 19 skipped, macOS aarch64.)
    // M1.1.15.2 G2 adds ten. Four in the new `src/etch/services.zig` (signature
    // derivation, the call-through with its error union, the registration
    // refusals, and the emitter's type names); five in the new
    // `tests/etch_services/service_call_test.zig` (a value returned to a rule, a
    // string crossing both ways, a Zig error union caught by `try`/`catch`,
    // E0902 with its two counter-factuals, and the local shadowing a service);
    // and one in `src/etch/interp.zig` pinning the PRE-EXISTING assignment-RHS
    // throw defect this gate exposed and closed.
    // (1971 -> 1981, suite reported 1981 - 1962 passed + 19 skipped, macOS aarch64.)
    // G3 adds three in the new `tests/etch_bindgen/detch_emitter_test.zig`: the
    // committed artifact matching the emitter (with its non-vacuity checks), the
    // divergence detected from BOTH sides with the line named, and the emitted
    // text parsing and resolving as a `.d.etch`.
    // (1981 -> 1984, suite reported 1984 - 1965 passed + 19 skipped, macOS aarch64.)
    // G4 adds four in the new `tests/etch_events/event_bridge_test.zig`: the
    // `.d.etch`-declared event resolving in a rule (with an undeclared-type and
    // an unknown-field counter-factual), the three-tick observation, the
    // ordering oracle that reddens if the drain moves before the per-tick
    // `clear`, and the counted drop for a type the program never mentions.
    // (1984 -> 1988, suite reported 1988 - 1969 passed + 19 skipped, macOS aarch64.)
    // G5a adds five. Two in `src/modules/forge/forge_3d/query/overlap.zig` — the
    // entity-major order asserted as CONTIGUITY, and the replace-worst retention that
    // a proof written on `finish` alone would miss — and three in
    // `tests/physics/forge_module_test.zig` for the entries this gate adds:
    // `getBodyTransform`'s error channel against a body AT the origin,
    // `getTriggerOverlaps` refusing to truncate a state, and the three joint stubs
    // presentable and failing loud.
    // (1988 -> 1993, suite reported 1993 - 1974 passed + 19 skipped, macOS aarch64.)
    // G5b adds seven to `tests/physics/transform_sync_test.zig`: the gameplay-
    // authoritative dynamic body publishing nothing while still stepping, the
    // load-bearing no-wake guard with both halves of the conjunction and its
    // non-vacuity, the wrapper application not replayed, the two authority
    // transitions, the single elected body, and the trigger following before the
    // sensor pass reads it.
    // (1993 -> 2000, suite reported 2000 - 1980 passed + 19 skipped, macOS aarch64.)
    // Plus one in `forge/api/components.zig` pinning the `.sav` migration's third
    // measurement: `.solver` is the ZERO value, so a zero-padded image loads correctly
    // under the empty migration and nothing has to be written for it.
    // (2000 -> 2001, suite reported 2001 - 1982 passed + 19 skipped, macOS aarch64.)
    // Plus one more: the SCHEDULER path for `syncIn`, which found a real defect on its
    // first run — a write made before the world's first `beginFrame` is stamped tick 0,
    // so a `> 0` baseline filtered it out; the journal's "never consumed" is a sentinel
    // now and not a zero.
    // (2001 -> 2002, suite reported 2002 - 1983 passed + 19 skipped, macOS aarch64.)
    // G6 adds five: three in `tests/etch_bindgen/detch_emitter_test.zig` (the physics
    // artifact matching its spec, all three emitted declarations parsing and resolving,
    // and the `Entity` field carrying no default) and two in the new
    // `tests/physics/physics_service_test.zig` (a rule calling the service and receiving
    // its result, and the two sensor deltas reaching the Tier 0 bus).
    // (2002 -> 2007, suite reported 2007 - 1988 passed + 19 skipped, macOS aarch64.)
    // G6b adds three to `tests/physics/forge_module_test.zig`: the coverage map that
    // confronts the 29 non-lifecycle entries with their discriminating oracle, and the
    // two oracles the audit found MISSING — `setAngularVelocity` about its own axis
    // (the gap M1.1.15.1 named and left) and `overlapShape` on the probe's geometry
    // rather than its box.
    // (2007 -> 2010, suite reported 2010 - 1991 passed + 19 skipped, macOS aarch64.)
    // G7 — THE FREEZE — adds three: the guard instantiated against the real adapter in
    // `tests/physics/forge_module_test.zig`, the shape of the signature comparison in
    // `src/interfaces/PhysicsModule.zig` (whose attestation of ABSENCE became one of
    // PRESENCE rather than being deleted), and the bidirectional slice run end to end in
    // the new `tests/physics/arena_slice_test.zig`.
    // (2010 -> 2013, suite reported 2013 - 1994 passed + 19 skipped, macOS aarch64.)
    // THE REPRISE. G8 adds five, one per external-review finding in the perimeter plus the
    // header: the delegated wrapper with its effect asserted through it, the empty-slice size
    // query on `getTriggerOverlaps`, `point_query_count` signalling its truncation, the change
    // baseline advancing on examination, and the header confronted with its own bytes.
    // (2013 -> 2018, suite reported 2018 - 1999 passed + 19 skipped, macOS aarch64.)
    // G9 adds one: the removal oracle for the journal keyed by `BodyId`. Silent
    // corruption — the counter-factual restoring the positional key reddens THIS test
    // and nothing else in the suite, which is what "no red signalled it" measures.
    // (2018 -> 2019, suite reported 2019 - 2000 passed + 19 skipped, macOS aarch64.)
    // G10 adds three, one per object of the gate: the conservation oracle for a
    // `.gameplay` dynamic body against an infinite mass with the finite-mass control that
    // makes it non-vacuous, the direction of the `solver -> gameplay` transition measured
    // on a body left asleep for many ticks, and the authority mirror reaching every body
    // of the entity rather than the elected one alone.
    // (2019 -> 2022, suite reported 2022 - 2003 passed + 19 skipped, macOS aarch64.)
    // G11 adds seven: six oracles for the five mutation wrappers — `move_kinematic`'s
    // derivation and atomic mirror, the journal mark's production path, `set_authority`,
    // the sweep-versus-teleport contrast that separates the two character movers,
    // `resize_character`'s three outcomes, and the election the wrappers share with the
    // seam — plus the slice commanding a physical state from a rule and observing it
    // from another.
    // (2022 -> 2029, suite reported 2029 - 2010 passed + 19 skipped, macOS aarch64.)
    // G7 replayed adds ONE: the block's declared size, confronted with the block's own
    // text. Deleting an `assertFn` line used to leave the tree green at 2029 of 2029 —
    // the constant declared a size and nothing put it in front of the list it sized.
    // (2029 -> 2030, suite reported 2030 - 2011 passed + 19 skipped, macOS aarch64.)
    // G12 adds three: a static under the DEFAULT authority observed moving BY A QUERY,
    // the forbidden-mutation diagnostic separating a write from a non-write, and the
    // three-body scene where only the `.solver` write is reported.
    // (2030 -> 2033, suite reported 2033 - 2014 passed + 19 skipped, macOS aarch64.)
    // G13 adds three: the gravity differential against a kinematic, the character-push
    // differential against a kinematic, and the sleep path measured rather than reasoned.
    // (2033 -> 2036, suite reported 2036 - 2017 passed + 19 skipped, macOS aarch64.)
    // G14 adds two: `move_kinematic`'s refusal leaving pose, velocity and journal mark
    // untouched, and `set_joint_motor` resolving on the receiver and failing loud.
    // (2036 -> 2038, suite reported 2038 - 2019 passed + 19 skipped, macOS aarch64.)
    // Reprise 2 adds five: the diagnostic observed from the PRODUCTION path, `addImpulse`
    // through the public interface, the three-support differential, the flip on an
    // already-sleeping body, and `applied_tick` distinct from `consumed_tick`.
    // (2038 -> 2043, suite reported 2043 - 2024 passed + 19 skipped, macOS aarch64.)
    // Reprise 3 adds four: the FIRST forbidden mutation of a body's life (G17), and the
    // three sleep-regime properties of G18 — `putToSleep` refusing before writing, the
    // window not ageing while piloted, and the transition reaching every body of the
    // entity.
    // (2043 -> 2047, suite reported 2047 - 2028 passed + 19 skipped, macOS aarch64.)
    // Reprise 4 adds two: a spawn is not a mutation (G19), and the gameplay/sleeping
    // invariant on all three paths (G20).
    // (2047 -> 2049, suite reported 2049 - 2030 passed + 19 skipped, macOS aarch64.)
    // Reprise 5 adds two: `move_kinematic` refusing a subject that is not gameplay-
    // authoritative (G21), and the bound of that guard — the four other wrappers must NOT
    // demand it (G21). G22 is a test-shape correction and a brief reconciliation, which
    // add none.
    // (2049 -> 2051, suite reported 2051 - 2032 passed + 19 skipped, macOS aarch64.)
    //
    // ── M1.B ──
    // G1 adds nine. Four are the `@storage` argument schema, and each asserts the
    // ABSENCE of the other code as well as the presence of its own — E0503 on a value
    // outside the domain, E0504 on a non-constant argument, E0503 on both arity
    // failures, and the widening counter-factual over the four spellings a valid
    // program may use. Five are the mode end to end: the registry records what the
    // declaration said (the test that would have failed for the four months the
    // annotation was a no-op), the mode is a DECLARED no-op so the storage has not
    // moved, an Etch `component X {}` is legal and still records its mode, the codegen
    // refuses a sparse program with its own typed error, and the same program without
    // the annotation lowers.
    // (2051 -> 2060, suite reported 2060 - 2041 passed + 19 skipped, macOS aarch64.)
    // G1 adds a tenth, found by re-reading the doc comment against the code rather than
    // by a failing test: `@storage(kind: sparse)` carries a value the domain HAS and a
    // name the schema does not declare, so it is a step-3 failure — and it was falling
    // through to the const test, answering `E0504 — must be a constant storage mode`,
    // false about the value and silent about the fault. The test asserts E0503 and the
    // ABSENCE of E0504. The valid-corpus `sparse_tag.etch` fixture adds NO block: the
    // corpus driver is one test iterating a table.
    // (2060 -> 2061, suite reported 2061 - 2042 passed + 19 skipped, macOS aarch64.)
    // G1 reversal adds one: the BARE spelling of a domain value is refused, asserted with
    // the ABSENCE of E0504 — an `ident` is not const-evaluable, so without its own branch
    // it answered "must be a constant", false about a value the domain HAS. The widening
    // counter-factual was rewritten rather than added to: it now carries the refused row
    // beside the accepted ones, so it tests the bound in both directions in one block.
    // (2061 -> 2062, suite reported 2062 - 2043 passed + 19 skipped, macOS aarch64.)
    // G2 adds ten. Nine are the sparse backend's invariants, one per invariant plus the
    // two discriminating halves the gate demands — the swap-remove counter-factual on the
    // LAST entry, and the recycled-generation case. The tenth is the EMPTY archetype,
    // legal since this gate: an entity spawns into it, resolves, shares it with a second
    // such entity, and despawns. `chunk.zig`'s "rejects empty component list" test is
    // REPLACED by its opposite rather than added to, so it contributes none.
    //
    // These nine were SILENTLY UNCOLLECTED first: `pub const sparse_storage = @import(…)`
    // at the ECS root is two hops from the module root, and the suite reported the same
    // total with them present as without. What caught it is this guard's own closure
    // analysis, which is static — the pin `_ = ecs.sparse_storage;` in `src/core/root.zig`
    // is what the four M0.8/E3-D pins beside it already record.
    // (2062 -> 2072, suite reported 2072 - 2053 passed + 19 skipped, macOS aarch64.)
    //
    // M1.B / G3 adds TWENTY-THREE in `tests/ecs/sparse_routing_test.zig`, the Tier 0 routing
    // acceptance file: the no-migration property of a sparse add and its table
    // counter-factual, the no-migration property of a sparse remove, `hasComponentDyn`'s
    // totality over the three ways of being absent, the batched add's refusal of an
    // already-present sparse component and its mixed-set migration, four on the prepared
    // remove trio (the hook window, abort, a sparse-only set that must build no new
    // signature, and a refusal accompanied by its acceptance complement), the despawn
    // sweep, the change mark, `componentBytes`'s non-stamping, the tag mutation's set AND
    // clear, the World-level reserve-then-mutate sweep, and the all-negative query's
    // permission over the empty archetype, and the sparse-ONLY entity, which backs the
    // contract written on `dynamicLocation` (never null for a live handle, because the
    // table half of the split is empty and the empty archetype is legal since G2). No test
    // is replaced this gate except the G1 no-op pin in `tests/etch/storage_mode_test.zig`,
    // swapped for its opposite — one for one, so it contributes none.
    // SEVENTEEN of those were the gate's first pass; SIX more came from an adversarial review
    // that REFUSED it — five pinning defects (the sparse-only self-migration on each batched
    // path, `applyTagMutation`'s lost stale-handle return, the typed `spawn`'s missing
    // `ensureSparseStores`, and the duplicate-sparse-id double insert) plus one closing the
    // TYPED arms, which had no coverage at all. Each was written RED first, and each fix has a
    // counter-factual that reddens exactly its own test. The comment that said SIXTEEN was
    // itself one of that review's findings.
    // M1.B / G4 adds SIX more to the same file, taking it to TWENTY-NINE: the three TABLE
    // twins of the G3 review's F4/F5, whose preconditions predate M1.B and were carried by
    // `std.debug.assert` alone — their counter-factual runs in ReleaseFast, where the assert
    // is stripped, so it distinguishes "the active check works" from "the assert works"; the
    // `on_remove` firing order over the UNION at despawn; add-on-present on a sparse
    // component firing the replacement rather than the add; and the THREE-PATH oracle, which
    // drives all six command kinds through each of the three apply switches and reports the
    // count PER PATH on its own line (a counter-factual removing the despawn sweep takes all
    // three to 5/6 and names the uncovered path, so the 6/6 is not vacuous).
    // M1.B / G5 adds EIGHT: four inline in `src/etch/ecs_bridge.zig` — the bimodal
    // `ComponentRef` round-trip on the sparse arm, its TABLE twin as the mode-only
    // counter-factual, the sparse change stamp, and the refusal surviving the widening —
    // two in `tests/ecs/sparse_routing_test.zig` for the new `World.changedTickOf` (both
    // arms as twins, and its totality), and two in `tests/etch/storage_mode_test.zig`: the
    // all-negative rule VISITING a sparse-only entity (the other half of the empty-archetype
    // permission G2 opened, which G3 pinned as MATCHING and not as iterating), and the
    // boundary pin that a rule does not yet SELECT by a sparse component, which is G7's
    // planner and whose arrival flips that assertion.
    // M1.B / G6 adds SEVEN across three scene test files, and NO production change to the
    // loader: three in `load_roundtrip_test.zig` (a sparse component loading into its own
    // store; the SAME cooked bytes giving the same values under either mode, with the
    // archetypes differing; and two on-disk blocks whose TABLE subset coincides landing in
    // ONE archetype), one in `extensions_test.zig` (an ALL-SPARSE extension activating
    // without touching the archetype — the self-migration guard's only production producer),
    // and three in `crossref_test.zig` (a cross-ref resolving INTO a sparse row, plus the two
    // Etch-cook seam tests: `@storage(.sparse)` changes NOTHING in the cooked bytes, and the
    // same bytes load under either host registration).
    // M1.B / G7 adds TWELVE: nine in `tests/ecs/hybrid_query_test.zig` — two sparse members of
    // OPPOSITE cardinality (the driver follows, and the visited SET is identical whichever one
    // is smaller), equal cardinality decided by declaration order and re-elected to show it is
    // stable, a TABLE member winning the election, an all-table query electing `.table`,
    // `not has T` on a sparse T as a per-entity test, the locator reaching either backend, the
    // frozen-surface control, an all-negative query whose exclusion is sparse, and a
    // table-driven query reaching a sparse with-member — plus two in
    // `tests/etch/storage_mode_test.zig` (a disjunctive rule with a sparse term visiting a
    // both-matching entity ONCE, and a change filter on a table member while the driver is
    // sparse) and one replacement that adds none: the G5 boundary pin, flipped to its opposite.
    // M1.B / G8 adds FOUR: three in `hybrid_query_test.zig` — the dense split covering the
    // population exactly once and evenly (checked as an interval COVER, not inferred from the
    // sum: a split double-counting one index and skipping another passes a sum), a target
    // above the population yielding one range per entity and never an empty one, and the
    // report NAMING the two dispatch entries — plus one in `storage_mode_test.zig` for the
    // structural effect under a sparse driver, which carries a DISCRIMINATING half asserted
    // on the elected plan because the correctness half alone does not distinguish the driver
    // (measured: forcing `.table` leaves the correctness assertions green).
    // M1.B / G9 adds TEN in `tests/ecs/requires_test.zig`, written at Tier 0 through
    // `registerComponentRaw`'s `.requires` name list so a front-end regression cannot read as a
    // `@requires` regression: the cycle refusal with its DIAMOND complement (a visited-set
    // implementation reports a cycle on a diamond and would pass the refusals while being
    // wrong), the unknown requisite, the FORWARD reference, the transitive closure in one
    // migration, the closure as a FLOOR rather than a reset, the failing-allocator sweep, the
    // sparse member, the requirer's removal cascading nothing, the skipped-and-signalled
    // refusal with its frame-boundary reset, and the grouped removal with its refusal
    // complement. Two invalid corpus fixtures (E0505, E0506) are data rows in the existing
    // corpus test and add no block.
    // (2132 -> 2142, suite reported 2142 - 2123 passed + 19 skipped, macOS aarch64, in ALL
    // FOUR corners {Debug, ReleaseSafe} x {f32, f64} with identical figures.)
    // G9's re-render added ONE block to `tests/etch/storage_mode_test.zig` — the
    // per-tick semantics of `requires_removals_skipped` proven on an Etch program
    // carrying NO `changed` filter, which is the regime where `stepOnce` skips
    // `beginFrame` entirely (2142 -> 2143, suite closure reports 2143).
    // G10/B1 added TWO to `tests/ecs/hybrid_query_test.zig` — a dense range
    // reaching a WORKER through `JobBuilder.addDenseRangeJobs`, differential
    // against the same body on the calling thread, plus the staging edge cases
    // (2143 -> 2145, suite closure reports 2145).
    return switch (os) {
        .windows => 2143,
        else => 2145,
    };
}

/// Blocks the closure counts that `zig build test` does not collect, on `os`.
pub fn uncollectedOn(os: std.Target.Os.Tag) usize {
    var n: usize = 0;
    for (uncollected) |u| {
        if (u.only_on == null or u.only_on.? == os) n += u.blocks;
    }
    return n;
}

/// Whether `path` falls under a declared exclusion.
pub fn excludedBy(path: []const u8) ?Exclusion {
    for (exclusions) |e| {
        if (std.mem.indexOf(u8, path, e.prefix) != null) return e;
    }
    return null;
}

/// Counts the top-level `test` declarations in `source`.
pub fn countTests(source: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "test")) continue;
        if (t.len == 4) continue;
        const c = t[4];
        if (c != ' ' and c != '\t') continue;
        const rest = std.mem.trimStart(u8, t[4..], " \t");
        if (rest.len == 0) continue;
        if (rest[0] == '"' or rest[0] == '{' or std.ascii.isAlphabetic(rest[0]) or rest[0] == '_') n += 1;
    }
    return n;
}

/// One outgoing edge: the relative import path a file's analysis reaches.
const Edge = struct { rel: []const u8 };

/// Extracts the edges of `source` under the criterion documented at the top.
///
/// Two passes, because the second criterion needs to know whether a bound name
/// is used and a name can be used before its binding is read.
fn edgesOf(gpa: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Edge)) !void {
    // Pass 1 — every `@import("…")` occurrence, with the binding name if any and
    // whether it is consumed inline by a field access.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "@import(\"")) |at| {
        const start = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        const rel = source[start..end];
        i = end + 1;
        if (!std.mem.endsWith(u8, rel, ".zig")) continue;
        // A COMMENTED-OUT import is not an import. See `edgesOfLive`.
        if (inComment(source, at)) continue;

        // Find the statement head to classify the binding.
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |p| p + 1 else 0;
        const head = std.mem.trim(u8, source[line_start..at], " \t");

        // `head` is trimmed on BOTH ends, so the trailing space of `_ = ` is gone.
        // Comparing against `"_ = "` matched nothing and reported the pinned file
        // dead — caught by this file's own fixture, which is what they are for.
        if (std.mem.endsWith(u8, head, "_ =")) {
            try out.append(gpa, .{ .rel = rel }); // explicit reference guard
            continue;
        }
        // The DISCRIMINANT IS THE REFERENCE, never the syntax of the import.
        // An earlier version refused `@import("f.zig").decl` outright, which is
        // wrong: `pub const Graph = @import("graph.zig").Graph;` DOES pull that
        // file's tests once `Graph` is referenced, while `triangleIsFlat` pulled
        // nothing because nothing referenced it. Same syntax, opposite outcomes,
        // one rule. So the syntax test folds INTO the reference test rather than
        // preceding it, and an unbound inline access simply has no name to check.
        const name = bindingName(head) orelse continue;
        if (isReferenced(source, name, line_start)) try out.append(gpa, .{ .rel = rel });
    }
}

/// Edges of `source` where a bound name counts as referenced if it appears in
/// `source` itself OR in any OTHER file of `live` — and in nothing else.
///
/// `path` is the file `source` was read from, and it is what identifies it.
/// THE SAME-FILE TEST USED TO BE POINTER IDENTITY, `osrc.ptr == source.ptr`,
/// AND IT NEVER FIRED IN PRODUCTION: the real reader allocates a fresh buffer on
/// every call, so re-reading the very file under analysis yielded a different
/// pointer. The cross-file loop then scanned the binding file as though it were
/// another file, with `binding_line_start = osrc.len` — a sentinel meaning "no
/// binding line to skip" — so the empty exclusion window let the binding line
/// count as a reference to itself. `pub const codegen_zig = @import(…)` was
/// therefore its own justification, and all of `src/etch/zig_codegen/` entered
/// the closure: a SELF-REFERENTIAL rule, and the false-ALIVE direction.
///
/// The fixtures could not see it. `Fixture.read` returns a stable pointer out of
/// a hash map, so pointer identity worked there and only there — a harness that
/// differed from production in the exact property under test. It now returns a
/// fresh copy per call, like the real reader, and the comparison is by PATH,
/// which is correct whatever the reader does with memory.
fn edgesOfLive(
    gpa: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    live: []const []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
    out: *std.ArrayList(Edge),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "@import(\"")) |at| {
        const start = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        const rel = source[start..end];
        i = end + 1;
        if (!std.mem.endsWith(u8, rel, ".zig")) continue;
        // A COMMENTED-OUT import is not an import, and this is the edge that
        // admitted all of `src/etch/zig_codegen/`. `src/etch/root.zig` carries
        // `//   _ = @import("zig_codegen/root.zig");` — a commented-out EXAMPLE
        // of the reference guard, in the paragraph explaining why the subtree is
        // held — and the head of that line ends in `_ =`, so it was read as the
        // guard itself. Thirty-seven blocks entered the closure on the strength
        // of a comment, which is the false-ALIVE direction: it says green.
        //
        // The reference search was taught to skip comments earlier in this
        // milestone, for the same file and very nearly the same sentence. The
        // IMPORT site was not, and a correction applied at one site and not at
        // its twin is the motif this repository sweeps rather than patches.
        if (inComment(source, at)) continue;

        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |p| p + 1 else 0;
        const head = std.mem.trim(u8, source[line_start..at], " \t");
        if (std.mem.endsWith(u8, head, "_ =")) {
            try out.append(gpa, .{ .rel = rel });
            continue;
        }
        const name = bindingName(head) orelse {
            // A binding the head parser does not recognise — an `@import` inside a
            // `switch` assigned to a referenced `const`, as `ipc/transport.zig`
            // does. Refusing it outright reported a live file dead; admitting it
            // whenever the enclosing statement binds SOMETHING keeps the criterion
            // (a reference exists) without teaching the parser every expression form.
            if (enclosingBindingReferenced(path, source, line_start, live, read)) {
                try out.append(gpa, .{ .rel = rel });
            }
            continue;
        };
        if (isReferenced(source, name, line_start)) {
            try out.append(gpa, .{ .rel = rel });
            continue;
        }
        for (live) |other| {
            if (std.mem.eql(u8, other, path)) continue;
            const osrc = read(other) orelse continue;
            if (isReferenced(osrc, name, osrc.len)) {
                try out.append(gpa, .{ .rel = rel });
                break;
            }
        }
    }
}

/// Whether the `const NAME = ` statement enclosing `line_start` binds a name that
/// is referenced in `source` or in the live set. Walks back to the nearest
/// `const … = ` line, which is where a multi-line `switch` binding starts.
fn enclosingBindingReferenced(
    path: []const u8,
    source: []const u8,
    line_start: usize,
    live: []const []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
) bool {
    var pos = line_start;
    var back: usize = 0;
    while (pos > 0 and back < 8) : (back += 1) {
        const prev_end = pos - 1;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0..prev_end], '\n')) |p| p + 1 else 0;
        const line = std.mem.trim(u8, source[prev_start..prev_end], " \t");
        if (bindingName(line)) |name| {
            if (isReferenced(source, name, prev_start)) return true;
            for (live) |other| {
                if (std.mem.eql(u8, other, path)) continue;
                const osrc = read(other) orelse continue;
                if (isReferenced(osrc, name, osrc.len)) return true;
            }
            return false;
        }
        pos = prev_start;
        if (prev_start == 0) break;
    }
    return false;
}

/// The bound name of `const NAME = ` / `pub const NAME = `, or null.
fn bindingName(head: []const u8) ?[]const u8 {
    var h = head;
    if (std.mem.startsWith(u8, h, "pub ")) h = std.mem.trimStart(u8, h["pub ".len..], " \t");
    if (!std.mem.startsWith(u8, h, "const ")) return null;
    h = std.mem.trimStart(u8, h["const ".len..], " \t");
    const eq = std.mem.indexOfScalar(u8, h, '=') orelse return null;
    const name = std.mem.trim(u8, h[0..eq], " \t");
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return name;
}

/// Whether a byte offset falls inside a `//` comment.
///
/// MEASURED, and by the worst possible route: the guard admitted all of
/// `src/etch/zig_codegen/` because `src/etch/root.zig` carries a COMMENT naming
/// `codegen_zig` — the very paragraph explaining why that subtree is dead. The
/// documentation of a corpse reported it alive. A reference search that reads
/// prose is not a reference search.
fn inComment(source: []const u8, at: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |p| p + 1 else 0;
    var i = line_start;
    while (i + 1 < at) : (i += 1) {
        if (source[i] == '/' and source[i + 1] == '/') return true;
        if (source[i] == '"') return false; // a `//` inside a string is not a comment
    }
    return false;
}

/// Whether `name` appears as an identifier anywhere outside its own binding line,
/// ignoring occurrences inside comments.
fn isReferenced(source: []const u8, name: []const u8, binding_line_start: usize) bool {
    const binding_line_end = std.mem.indexOfScalarPos(u8, source, binding_line_start, '\n') orelse source.len;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, name)) |at| {
        i = at + name.len;
        if (at >= binding_line_start and at < binding_line_end) continue; // its own binding
        const before_ok = at == 0 or !isIdentChar(source[at - 1]);
        const after = at + name.len;
        const after_ok = after >= source.len or !isIdentChar(source[after]);
        if (before_ok and after_ok and !inComment(source, at)) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Resolves `rel` against the directory of `from`, normalising `..` segments.
fn resolveRel(gpa: std.mem.Allocator, from: []const u8, rel: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(from) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ dir, rel });
    defer gpa.free(joined);
    return normalise(gpa, joined);
}

/// Collapses `a/b/../c` to `a/c` and normalises separators to `/`.
fn normalise(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", parts.items);
}

/// One root's closure: the files reached, and their `test` block count.
const RootClosure = struct {
    files: std.ArrayList([]const u8) = .empty,
    tests: usize = 0,

    fn deinit(self: *RootClosure, gpa: std.mem.Allocator) void {
        for (self.files.items) |f| gpa.free(f);
        self.files.deinit(gpa);
    }
};

/// The closure of ONE root, by monotone growth.
///
/// SCOPED TO THIS ROOT, and that scope is the whole correction. The cross-file
/// reference that makes a binding live — `gal/root.zig` binds `pub const
/// barriers`, `render_graph/pass.zig` writes `gal.barriers.Access` — is real, but
/// it is only meaningful WITHIN one module. Run over every root at once, the
/// same rule let `tests/etch/keyword_ident_test.zig` license an edge inside
/// `src/etch/`: that file names `codegen_zig`, but it reaches it through the
/// `weld_etch` MODULE, and Zig collects no tests across a module boundary. So a
/// reference from another root's closure is not evidence about this one, and
/// counting it admitted 37 blocks that no binary ever runs.
///
/// Per root, the growth is monotone: files only ever enter, a reference only
/// counts when it comes from a file already admitted HERE, and there is no rule
/// by which two files vouch for each other into the closure.
fn closureOf(
    gpa: std.mem.Allocator,
    root: []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
) !RootClosure {
    var out: RootClosure = .{};
    errdefer out.deinit(gpa);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    const first = try normalise(gpa, root);
    try seen.put(gpa, first, {});
    try out.files.append(gpa, first);

    while (true) {
        // Admissions are STAGED and appended after the scan. Appending inside the
        // loop reallocates `files.items` and leaves the loop variable dangling
        // into freed memory — which segfaulted on Zig's `0xaa` poison at the
        // first real run.
        var pending: std.ArrayList([]const u8) = .empty;
        defer pending.deinit(gpa);
        for (out.files.items) |path| {
            const src = read(path) orelse continue;
            var edges: std.ArrayList(Edge) = .empty;
            defer edges.deinit(gpa);
            try edgesOfLive(gpa, path, src, out.files.items, read, &edges);
            for (edges.items) |e| {
                const resolved = try resolveRel(gpa, path, e.rel);
                if (seen.contains(resolved)) {
                    gpa.free(resolved);
                    continue;
                }
                try seen.put(gpa, resolved, {});
                try pending.append(gpa, resolved);
            }
        }
        if (pending.items.len == 0) break;
        for (pending.items) |r| try out.files.append(gpa, r);
    }

    for (out.files.items) |path| {
        const src = read(path) orelse continue;
        out.tests += countTests(src);
    }
    return out;
}

/// Walks each root's closure and reports every file with tests outside all of them.
///
/// `read` supplies file contents so the analysis is testable against fixtures
/// without touching the filesystem layout the tool normally walks.
///
/// `live_tests` is the sum over roots and therefore a MULTISET count: a file two
/// targets both reach is counted twice, because the suite compiles it twice and
/// runs its tests twice. That is what makes it comparable to the suite's own
/// collected total. `in_closure` and `closure` are the UNION, which is the right
/// basis for the dead verdict — a file is dead only if no root reaches it.
pub fn analyze(
    gpa: std.mem.Allocator,
    roots: []const []const u8,
    all_files: []const []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
) !Report {
    var report: Report = .{};
    errdefer report.deinit(gpa);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }

    for (roots) |r| {
        var one = try closureOf(gpa, r, read);
        defer one.deinit(gpa);
        report.live_tests += one.tests;
        for (one.files.items) |f| {
            if (seen.contains(f)) continue;
            const owned = try gpa.dupe(u8, f);
            try seen.put(gpa, owned, {});
            report.in_closure += 1;
            const src = read(f) orelse continue;
            try report.closure.append(gpa, .{ .path = try gpa.dupe(u8, f), .tests = countTests(src) });
        }
    }

    for (all_files) |f| {
        const src = read(f) orelse continue;
        const n = countTests(src);
        if (n == 0) continue;
        report.with_tests += 1;
        const norm = try normalise(gpa, f);
        defer gpa.free(norm);
        if (seen.contains(norm)) continue;
        if (excludedBy(norm)) |_| {
            report.excluded += 1;
            report.excluded_tests += n;
            continue;
        }
        try report.dead.append(gpa, .{ .path = try gpa.dupe(u8, norm), .tests = n });
    }
    return report;
}

// ---------------------------------------------------------------------------
// Tests — the hostile fixtures the criterion is only believable with
// ---------------------------------------------------------------------------

const Fixture = struct {
    var files: std.StringHashMapUnmanaged([]const u8) = .empty;
    var copies: std.ArrayList([]u8) = .empty;
    var gpa: std.mem.Allocator = undefined;

    /// Returns a FRESH buffer on every call, exactly as the production reader
    /// does. It used to hand back the map's own stable pointer, and that single
    /// difference is why no fixture could see the self-reference defect: a
    /// same-file test written as pointer identity passed here and never fired in
    /// the tree. A harness that differs from production in the property under
    /// test agrees with the code instead of judging it.
    fn read(path: []const u8) ?[]const u8 {
        const src = files.get(path) orelse return null;
        const copy = gpa.dupe(u8, src) catch return null;
        copies.append(gpa, copy) catch {
            gpa.free(copy);
            return null;
        };
        return copy;
    }

    fn deinit(a: std.mem.Allocator) void {
        for (copies.items) |c| a.free(c);
        copies.deinit(a);
        copies = .empty;
        files.deinit(a);
        files = .empty;
    }
};

fn runFixture(
    gpa: std.mem.Allocator,
    entries: []const [2][]const u8,
    roots: []const []const u8,
) !Report {
    Fixture.files = .empty;
    Fixture.copies = .empty;
    Fixture.gpa = gpa;
    for (entries) |e| try Fixture.files.put(gpa, e[0], e[1]);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (entries) |e| try names.append(gpa, e[0]);
    return analyze(gpa, roots, names.items, &Fixture.read);
}

test "a test three imports deep is ALIVE" {
    // The false-DEAD direction. Each hop binds a name AND references it, which
    // is the ordinary way a module reaches its files; a closure that stops short
    // would condemn most of the tree.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "const a = @import(\"a.zig\");\npub const A = a.T;\n" },
        .{ "m/a.zig", "const b = @import(\"b.zig\");\npub const T = b.U;\n" },
        .{ "m/b.zig", "const c = @import(\"c.zig\");\npub const U = c.V;\n" },
        .{ "m/c.zig", "pub const V = u8;\ntest \"deep\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 4), r.in_closure);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a file bound but never referenced is DEAD" {
    // The false-ALIVE direction, and the one that kills: it says green. This is
    // `zig_codegen` exactly — `pub const codegen_zig = @import(...)`, never used.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const orphan = @import(\"orphan.zig\");\n" },
        .{ "m/orphan.zig", "test \"never analysed\" {}\ntest \"nor this\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/orphan.zig", r.dead.items[0].path);
    try std.testing.expectEqual(@as(usize, 2), r.dead.items[0].tests);
}

test "an inline field access whose name is NEVER referenced is DEAD" {
    // `foundation/math/exact.zig` exactly: bound as
    // `pub const triangleIsFlat = @import("exact.zig").triangleIsFlat;` and
    // referenced by nothing, so its two tests never ran.
    //
    // This fixture ORIGINALLY bound `f` and then wrote `pub const g = f;`, which
    // references it — it therefore encoded the refuted rule (syntax decides) and
    // passed only because the implementation shared the mistake. Corrected here
    // with its sibling below, which is the same syntax with the reference present.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const f = @import(\"leaf.zig\").f;\n" },
        .{ "m/leaf.zig", "pub fn f() void {}\ntest \"leaf\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/leaf.zig", r.dead.items[0].path);
}

test "an explicit comptime reference guard is an edge" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "comptime {\n    _ = @import(\"pinned.zig\");\n}\n" },
        .{ "m/pinned.zig", "test \"pinned\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a declared exclusion is reported, not failed on" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const x = @import(\"src/etch/zig_codegen/cache.zig\");\n" },
        .{ "src/etch/zig_codegen/cache.zig", "test \"excluded\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.excluded);
    try std.testing.expectEqual(@as(usize, 1), r.excluded_tests);
}

test "relative parent segments resolve" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/sub/root.zig", "const up = @import(\"../up.zig\");\npub const U = up.U;\n" },
        .{ "m/up.zig", "pub const U = u8;\ntest \"up\" {}\n" },
    }, &.{"m/sub/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "countTests counts declarations and not prose" {
    try std.testing.expectEqual(@as(usize, 2), countTests("test \"a\" {}\ntest {}\n"));
    try std.testing.expectEqual(@as(usize, 0), countTests("// test \"a\" {}\n/// test {}\n"));
    try std.testing.expectEqual(@as(usize, 0), countTests("const testing = 1;\ntesting_only();\n"));
}

// ---------------------------------------------------------------------------
// Root discovery
// ---------------------------------------------------------------------------

/// Extracts every `addTest` root source path from `build_zig`.
///
/// DERIVED, never duplicated. A hand-kept list beside `build.zig` would drift
/// the first time a target is added, and drift here reads as "no dead tests" —
/// the failure that says green. Two shapes are matched: `b.createModule` and
/// `b.addModule`, both keyed by the variable `addTest` roots at.
pub fn rootsFromBuildZig(gpa: std.mem.Allocator, build_zig: []const u8) !std.ArrayList([]const u8) {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, build_zig, i, ".root_module = ")) |at| {
        const name_start = at + ".root_module = ".len;
        var name_end = name_start;
        while (name_end < build_zig.len and isIdentChar(build_zig[name_end])) name_end += 1;
        i = name_end;
        // Only the ones an `addTest` roots at.
        const line_start = if (std.mem.lastIndexOfScalar(u8, build_zig[0..at], '\n')) |p| p + 1 else 0;
        if (std.mem.indexOf(u8, build_zig[line_start..at], "addTest") == null) continue;
        const mod = build_zig[name_start..name_end];
        if (try modulePath(gpa, build_zig, mod)) |p| try roots.append(gpa, p);
    }
    try loopRoots(gpa, build_zig, &roots);
    return roots;
}

/// Extracts the literal paths of every table a loop turns into test targets.
///
/// A target whose `root_source_file` is a LOOP VARIABLE has no literal to find
/// at its `createModule`, so the first version of this file missed every one of
/// them and reported all of `tests/` dead. The paths are still literals — in the
/// table the loop walks — so they are read from there.
///
/// ANCHORED ON THE WIRING, NOT ON THE PATH SYNTAX, and that is a correction.
/// Two shapes used to be matched independently — `.path = "…"` entries anywhere,
/// and any line that was a quoted `.zig` path followed by a comma — neither of
/// them scoped to a table that feeds `addTest`. The second INVENTED THREE ROOTS:
/// the arguments of a `zig fmt` `addSystemCommand`, which are exactly that shape
/// and are not test roots at all. An invented root is the false-ALIVE direction
/// — it silently admits whatever it reaches and can mask a genuinely dead file —
/// and the fixture that was supposed to catch it only checked that a
/// `b.path("…")` call was NOT matched, a different syntax, so it agreed with the
/// implementation's blind spot instead of testing it.
///
/// The rule is now one rule and it asks the question that actually decides:
/// does a `for` loop over this table build test targets? A table is read only
/// when its name is the subject of a loop whose body calls `addTest`, and then
/// EVERY quoted `.zig` literal inside the table is taken — which covers both
/// shapes without naming either.
pub fn loopRoots(gpa: std.mem.Allocator, build_zig: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, build_zig, i, "for (")) |at| {
        const s = at + "for (".len;
        var e = s;
        while (e < build_zig.len and isIdentChar(build_zig[e])) e += 1;
        i = if (e > s) e else s + 1;
        if (e == s or e >= build_zig.len or build_zig[e] != ')') continue;
        const name = build_zig[s..e];
        const body = loopBody(build_zig, e) orelse continue;
        if (std.mem.indexOf(u8, body, "addTest") == null) continue;
        try tableLiterals(gpa, build_zig, name, out);
    }
}

/// The text of the block opened by the first `{` after `at`, brace-matched.
///
/// Strings and line comments are skipped, so a `"{s}"` in a format call or a
/// brace inside a comment cannot close the body early and truncate the
/// `addTest` search into a false negative.
fn loopBody(src: []const u8, at: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, src, at, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '"' => {
                i += 1;
                while (i < src.len and src[i] != '"') : (i += 1) {
                    if (src[i] == '\\') i += 1;
                }
            },
            '/' => {
                if (i + 1 < src.len and src[i + 1] == '/') {
                    i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse return null;
                }
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return src[open .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Appends every quoted `.zig` literal of the array bound to `name`.
fn tableLiterals(
    gpa: std.mem.Allocator,
    build_zig: []const u8,
    name: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var buf: [128]u8 = undefined;
    const decl = std.fmt.bufPrint(&buf, "const {s} = ", .{name}) catch return;
    const at = std.mem.indexOf(u8, build_zig, decl) orelse return;
    const body = loopBody(build_zig, at + decl.len) orelse return;

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, i, '"')) |q| {
        const end = std.mem.indexOfScalarPos(u8, body, q + 1, '"') orelse return;
        i = end + 1;
        const lit = body[q + 1 .. end];
        if (!std.mem.endsWith(u8, lit, ".zig")) continue;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, lit)) break;
        } else try out.append(gpa, try gpa.dupe(u8, lit));
    }
}

/// The `root_source_file` path of the module bound to `name`, if it is a literal.
///
/// SCOPED TO THE DECLARATION'S OWN INITIALIZER, by brace matching. It used to
/// search forward from the declaration under a 400-character window, which is a
/// window and not a boundary: when a module's `root_source_file` is NOT a literal
/// — `b.path(spec.path)` in the `test_specs` loop, the ordinary shape — the
/// search ran on and took the literal of the NEXT declaration, inventing a root
/// out of whatever came after. That is the direction that says ALIVE, since an
/// invented root admits its whole closure.
///
/// It did not fire on the current `build.zig`, measured: the loop's module is
/// followed by enough `addImport` lines to push the next literal past 400 bytes.
/// One reordering away from firing, and found by a fixture written for a
/// different defect — which is the argument for a boundary rather than a window.
fn modulePath(gpa: std.mem.Allocator, build_zig: []const u8, name: []const u8) !?[]u8 {
    var buf: [128]u8 = undefined;
    const decl = std.fmt.bufPrint(&buf, "const {s} = b.", .{name}) catch return null;
    const at = std.mem.indexOf(u8, build_zig, decl) orelse return null;
    const init_block = loopBody(build_zig, at + decl.len) orelse return null;
    const key = std.mem.indexOf(u8, init_block, "root_source_file = b.path(\"") orelse return null;
    const s = key + "root_source_file = b.path(\"".len;
    const e = std.mem.indexOfScalarPos(u8, init_block, s, '"') orelse return null;
    return try gpa.dupe(u8, init_block[s..e]);
}

test "rootsFromBuildZig picks addTest roots and skips other modules" {
    const gpa = std.testing.allocator;
    const src =
        \\const a_module = b.createModule(.{
        \\    .root_source_file = b.path("src/a/root.zig"),
        \\});
        \\const not_a_test = b.createModule(.{
        \\    .root_source_file = b.path("src/never/root.zig"),
        \\});
        \\const exe = b.addExecutable(.{ .root_module = not_a_test });
        \\const a_tests = b.addTest(.{ .root_module = a_module });
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings("src/a/root.zig", roots.items[0]);
}

test "a non-literal root_source_file does not borrow the next declaration's" {
    // The window-versus-boundary defect, pinned on its own. `t_mod` roots at a
    // loop variable, so it has no literal of its own; the declaration that
    // FOLLOWS it does. Under the old 400-character window that literal was taken
    // and `src/runtime/main.zig` — an executable — became a test root.
    //
    // The counter-factual is the fixture below it: the same shape with a literal
    // in its OWN initializer must still be discovered, or the fix would have
    // closed the defect by discovering nothing.
    const gpa = std.testing.allocator;
    const src =
        \\const t_mod = b.createModule(.{ .root_source_file = b.path(spec.path) });
        \\const t = b.addTest(.{ .root_module = t_mod });
        \\const exe_mod = b.createModule(.{ .root_source_file = b.path("src/runtime/main.zig") });
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 0), roots.items.len);
}

test "a literal root_source_file in the declaration's own initializer IS taken" {
    const gpa = std.testing.allocator;
    const src =
        \\const t_mod = b.createModule(.{ .root_source_file = b.path("src/a/root.zig") });
        \\const t = b.addTest(.{ .root_module = t_mod });
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings("src/a/root.zig", roots.items[0]);
}

test "a root whose path is a loop variable is still discovered" {
    // DEFECT 1, pinned. The first version read only literal `root_source_file`
    // arguments, so every target built by the `test_specs` loop was invisible and
    // all of `tests/` reported dead. The paths ARE literals — in the table the
    // loop walks — and that is where they are read from.
    const gpa = std.testing.allocator;
    const src =
        \\const test_specs = [_]Spec{
        \\    .{ .path = "tests/a/one.zig" },
        \\    .{ .path = "tests/a/two.zig" },
        \\};
        \\for (test_specs) |spec| {
        \\    const t_mod = b.createModule(.{ .root_source_file = b.path(spec.path) });
        \\    const t = b.addTest(.{ .root_module = t_mod });
        \\}
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings("tests/a/one.zig", roots.items[0]);
    try std.testing.expectEqualStrings("tests/a/two.zig", roots.items[1]);
}

test "an inline field access whose name IS referenced is ALIVE" {
    // DEFECT 2, pinned, and it is the counterpart of the third fixture above:
    // same syntax, opposite outcome, decided by the reference alone. This is
    // `render_graph.Graph` — `pub const Graph = @import("graph.zig").Graph;` with
    // a `comptime { _ = render_graph.Graph; }` guard — whose six tests ARE
    // collected, against `exact.zig`, which nothing referenced.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const Graph = @import(\"graph.zig\").Graph;\ncomptime { _ = Graph; }\n" },
        .{ "m/graph.zig", "pub const Graph = struct {};\ntest \"graph\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a bare string-array table of roots is discovered, and only its elements" {
    // The IPC targets, built from a `[_][]const u8` list walked by a loop that
    // calls `addTest`. The executable's `b.path` argument sits in the same file
    // and must not be taken: it builds a binary, not a test target.
    const gpa = std.testing.allocator;
    const src =
        \\const ipc_specs = [_][]const u8{
        \\    "tests/ipc/framing.zig",
        \\    "tests/ipc/shm.zig",
        \\};
        \\for (ipc_specs) |p| {
        \\    const t_mod = b.createModule(.{ .root_source_file = b.path(p) });
        \\    const t = b.addTest(.{ .root_module = t_mod });
        \\}
        \\const exe_mod = b.createModule(.{ .root_source_file = b.path("src/runtime/main.zig") });
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings("tests/ipc/framing.zig", roots.items[0]);
    try std.testing.expectEqualStrings("tests/ipc/shm.zig", roots.items[1]);
}

test "quoted .zig paths that feed no test target are NOT roots" {
    // THE INVENTED ROOT, pinned. These three lines are the arguments of a
    // `zig fmt` system command in `build.zig`, and the previous element-shaped
    // matcher took them for test roots — the false-ALIVE direction, since an
    // invented root admits its closure and can mask a genuinely dead file.
    //
    // The discriminant is the WIRING: no loop walks this list, so nothing here
    // builds a test target. The fixture that preceded this one only checked that
    // a `b.path(...)` call was not matched, which is a different syntax, so it
    // shared the implementation's blind spot instead of testing it.
    const gpa = std.testing.allocator;
    const src =
        \\const fmt_cmd = b.addSystemCommand(&.{
        \\    b.graph.zig_exe,
        \\    "fmt",
        \\    "src/core/platform/window/wayland_protocols/core.zig",
        \\    "src/core/platform/window/wayland_protocols/xdg_shell.zig",
        \\});
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 0), roots.items.len);
}

test "a table walked by a loop that builds no test target is NOT a root list" {
    // The twin of the fixture above, by the pairing rule: the table has the exact
    // shape of a root list and a loop DOES walk it, so only the absence of
    // `addTest` in the body separates the two. Its sibling is the IPC fixture,
    // which is this file with `addTest` present and must yield two roots.
    const gpa = std.testing.allocator;
    const src =
        \\const shader_srcs = [_][]const u8{
        \\    "src/shaders/a.zig",
        \\    "src/shaders/b.zig",
        \\};
        \\for (shader_srcs) |p| {
        \\    const c = b.addSystemCommand(&.{ "glslc", p });
        \\}
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 0), roots.items.len);
}

test "a brace inside a string does not truncate the loop body" {
    // `loopBody` brace-matches, so a `"{s}"` in a format call inside the loop —
    // ordinary in `build.zig` — would close the body early under a naive scan and
    // hide the `addTest` below it, turning a real root list into no roots at all.
    // That is the false-DEAD direction, loud rather than green, but it would have
    // condemned every root under a table that logs.
    const gpa = std.testing.allocator;
    const src =
        \\const specs = [_][]const u8{
        \\    "tests/a.zig",
        \\};
        \\for (specs) |p| {
        \\    std.debug.print("building {s}}}\n", .{p});
        \\    const t = b.addTest(.{ .root_module = m });
        \\}
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings("tests/a.zig", roots.items[0]);
}

test "a file referenced ONLY from outside the closure is DEAD" {
    // FIXTURE 7 — it guards the direction the fixpoint opened, and it is the only
    // one that can say green when it should say red. `outside.zig` binds AND
    // references `victim.zig`, but nothing ever admits `outside.zig`, so that
    // reference must not count. This is `src/etch/zig_codegen/` exactly: 37 dead
    // blocks across files that reference each other.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const nothing = u8;\n" },
        .{ "m/outside.zig", "const victim = @import(\"victim.zig\");\npub const V = victim.V;\n" },
        .{ "m/victim.zig", "pub const V = u8;\ntest \"victim\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    // One dead FILE, not two: only files holding `test` blocks are counted, and
    // `outside.zig` holds none. Expecting two was my own error — the report
    // counts dead TESTS' homes, never every unreached file.
    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/victim.zig", r.dead.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), r.live_tests);
}

test "the same file referenced from INSIDE the closure is ALIVE" {
    // The twin, by the pairing rule: same shape, discriminant inverted, verdict
    // inverted. `helper.zig` is admitted, so ITS reference to `victim` counts —
    // which is `render_graph/pass.zig` writing `gal.barriers.Access` for a name
    // `gal/root.zig` binds and never touches.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "const helper = @import(\"helper.zig\");\ncomptime { _ = helper; }\npub const victim = @import(\"victim.zig\");\n" },
        .{ "m/helper.zig", "pub const use = victim.V;\n" },
        .{ "m/victim.zig", "pub const V = u8;\ntest \"victim\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a name occurring only in a COMMENT is not a reference" {
    // The defect that admitted all of `zig_codegen`: `src/etch/root.zig` names
    // `codegen_zig` in the paragraph explaining why that subtree is DEAD, and the
    // reference search read it as a use. Its twin below is the same name in code.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const orphan = @import(\"orphan.zig\");\n// orphan is held, see M1.D.5\n" },
        .{ "m/orphan.zig", "test \"dead\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
}

test "a binding is not a reference to ITSELF, scanned as another file" {
    // THE SELF-REFERENTIAL RULE, pinned. The cross-file search re-reads every
    // live file including the one under analysis, and it passes `osrc.len` as the
    // binding-line start — a sentinel meaning "no binding line to skip". So when
    // the file scanned is the binding file, the exclusion window is empty and the
    // binding line answers for itself: `pub const held = @import("held.zig");`
    // became its own justification.
    //
    // It is the false-ALIVE direction and it admitted 37 blocks in the tree. The
    // same-file test is now by PATH; it used to be pointer identity, which the
    // production reader defeats by allocating a fresh buffer per call.
    //
    // The root is deliberately the ONLY live file, so the sole candidate the
    // cross-file loop can find the name in is the binding file itself.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const held = @import(\"held.zig\");\n" },
        .{ "m/held.zig", "test \"held\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/held.zig", r.dead.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), r.live_tests);
}

test "a commented-out reference guard is NOT an edge" {
    // `src/etch/root.zig` exactly: the paragraph explaining why `zig_codegen` is
    // held shows the guard that WOULD wire it — `//   _ = @import("…");` — and
    // the head of that line ends in `_ =`, so the extractor took the comment for
    // the code. Thirty-seven blocks were admitted by prose.
    //
    // Its twin is below: the same line without the `//`, which must be an edge.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "// to wire it, write:\n//   _ = @import(\"held.zig\");\npub const held = @import(\"held.zig\");\n" },
        .{ "m/held.zig", "test \"held\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/held.zig", r.dead.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), r.live_tests);
}

test "the SAME guard in code IS an edge" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "comptime {\n    _ = @import(\"held.zig\");\n}\n" },
        .{ "m/held.zig", "test \"held\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "the same name in CODE is a reference" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const orphan = @import(\"orphan.zig\");\npub const O = orphan.V;\n" },
        .{ "m/orphan.zig", "pub const V = u8;\ntest \"live\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}
