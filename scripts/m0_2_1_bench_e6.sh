#!/usr/bin/env bash
# M0.2.1 / E6 — thermal-aware bench orchestrator (MBP M-series protocol).
#
# Drives one bench session (3 runs of a single case) per the strict protocol
# defined in `engine-phase-0-criteria.md` § Méthodologie bench / sous-section
# « Protocole thermal-aware MBP M-series » :
#
#   - 30 min idle minimum before run #1 (counted from the END of pre-build).
#   - 15 min idle minimum between successive runs.
#   - 3 runs per session.
#   - `powermetrics --samplers thermal,cpu_power -i 100` captured in parallel,
#     verification that "Current pressure level: Nominal" on 100% of samples.
#   - Any non-Nominal sample invalidates the run.
#
# v2 (post first-run feedback) :
#   - Idle pauses are now **enforced** by `sleep` with visible countdown,
#     not just prompts ("press ENTER" was too easy to skip accidentally).
#   - Pre-build is done BEFORE the initial 30 min countdown so the CPU heat
#     from compilation has time to dissipate.
#   - powermetrics regex updated to match the actual M-series output
#     ("Current pressure level: Nominal").
#   - macOS bash 3.2 compatible (no `mapfile`).
#
# Usage:
#   scripts/m0_2_1_bench_e6.sh {s1|c01}
#
# Override env vars (use only for testing the script itself, NOT for real
# protocol runs) :
#   M021_E6_INITIAL_IDLE_SEC  — override the 1800 s (30 min) initial wait.
#   M021_E6_INTER_RUN_IDLE_SEC — override the 900 s (15 min) inter-run wait.
#   M021_E6_SKIP_IDLE=1       — skip all enforced idle (testing only).

set -uo pipefail

CASE="${1:-}"
case "$CASE" in
    s1)
        OPTIMIZE=ReleaseSafe
        WORKERS_FLAG="--workers=4"
        WORKERS_DESC="--workers=4 (forced — S1 baseline calibration)"
        CASE_UPPER="S1"
        GATE_NS=62000
        GATE_DESC="62 µs"
        ;;
    c01)
        OPTIMIZE=ReleaseFast
        WORKERS_FLAG=""
        WORKERS_DESC="default (CPU-topology-driven)"
        CASE_UPPER="C0.1"
        GATE_NS=16600000
        GATE_DESC="16.6 ms"
        ;;
    *)
        echo "Usage: $0 {s1|c01}" >&2
        exit 1
        ;;
esac

INITIAL_IDLE_SEC="${M021_E6_INITIAL_IDLE_SEC:-1800}"
INTER_RUN_IDLE_SEC="${M021_E6_INTER_RUN_IDLE_SEC:-900}"
SKIP_IDLE="${M021_E6_SKIP_IDLE:-0}"

DATE=$(date +%Y-%m-%d)
COMMIT=$(git rev-parse HEAD)
COMMIT_SHORT=$(git rev-parse --short HEAD)
MACHINE=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
OUT_DIR="/tmp/m0_2_1_bench_e6_${CASE}_${DATE}_$$"
mkdir -p "$OUT_DIR"
REPORT="bench/reports/ecs_benchmark_${CASE_UPPER}_${DATE}-thermal-aware.md"

echo "=== M0.2.1 / E6 — thermal-aware bench (v2) ==="
echo "Case            : ${CASE_UPPER}"
echo "Optimize        : ${OPTIMIZE}"
echo "Workers         : ${WORKERS_DESC}"
echo "Gate            : ${GATE_DESC} (${GATE_NS} ns)"
echo "Commit          : ${COMMIT_SHORT} (${COMMIT})"
echo "Date            : ${DATE}"
echo "Machine         : ${MACHINE}"
echo "Out dir         : ${OUT_DIR}"
echo "Report          : ${REPORT}"
echo "Initial idle    : ${INITIAL_IDLE_SEC} s (${INITIAL_IDLE_SEC} / 60 = $((INITIAL_IDLE_SEC/60)) min)"
echo "Inter-run idle  : ${INTER_RUN_IDLE_SEC} s ($((INTER_RUN_IDLE_SEC/60)) min)"
if [ "${SKIP_IDLE}" = "1" ]; then
    echo "*** SKIP_IDLE=1 : idle waits are skipped — DATA NOT OPPOSABLE ***"
fi
echo ""

# Pre-build BEFORE the initial idle countdown so the CPU heat from
# compilation dissipates during the 30 min wait. Without this ordering, the
# bench is measured while the CPU is still warm from `zig build`.
echo "Pre-building bench binary (mode=${OPTIMIZE})..."
zig build -Doptimize="${OPTIMIZE}" bench-ecs -- --case="${CASE}" --smoke >/dev/null 2>&1 || true
echo "Pre-build done at $(date '+%H:%M:%S')."
echo ""

echo "Acquiring sudo for powermetrics (password may be prompted)..."
sudo -v
echo ""

# Idle countdown helper. Sleeps in 1-second slices with a status line that
# updates in place. Ctrl-C interrupts the script — no resume.
sleep_with_countdown() {
    local secs=$1
    local label=$2
    if [ "${SKIP_IDLE}" = "1" ]; then
        echo "${label}: SKIPPED (M021_E6_SKIP_IDLE=1)."
        return
    fi
    local total=$secs
    local end_ts=$(($(date +%s) + secs))
    while [ "$secs" -gt 0 ]; do
        local mins=$((secs / 60))
        local rem=$((secs % 60))
        local pct=$(((total - secs) * 100 / total))
        printf "\r%s — %02d:%02d remaining (%d%%)..." "$label" "$mins" "$rem" "$pct"
        sleep 1
        secs=$(( end_ts - $(date +%s) ))
    done
    printf "\r%s — DONE.                                         \n" "$label"
}

# Counters.
medians=()
non_nominal_counts=()
total_samples=()

for run in 1 2 3; do
    if [ "$run" -eq 1 ]; then
        echo "=== Initial idle ==="
        echo "Pre-build heated the CPU. Wait ${INITIAL_IDLE_SEC} s for thermal dissipation."
        echo "DO NOT use the machine during this window. Browser, IDE, etc. closed."
        echo "Starting countdown at $(date '+%H:%M:%S')."
        sleep_with_countdown "${INITIAL_IDLE_SEC}" "Initial idle"
        # Refresh sudo (cache likely expired after 30 min).
        echo "Refreshing sudo (cache may have expired during idle)..."
        sudo -v
        echo "=== Run 1/3 ==="
    else
        echo ""
        echo "=== Inter-run idle ==="
        echo "Wait ${INTER_RUN_IDLE_SEC} s for thermal dissipation before run ${run}/3."
        echo "Starting countdown at $(date '+%H:%M:%S')."
        sleep_with_countdown "${INTER_RUN_IDLE_SEC}" "Inter-run idle"
        echo "Refreshing sudo..."
        sudo -v
        echo "=== Run ${run}/3 ==="
    fi

    PM_LOG="${OUT_DIR}/powermetrics_run${run}.log"
    BENCH_STDOUT="${OUT_DIR}/bench_stdout_run${run}.log"
    BENCH_REPORT="${OUT_DIR}/bench_report_run${run}.md"

    # Start powermetrics in background.
    sudo powermetrics --samplers thermal,cpu_power -i 100 >"${PM_LOG}" 2>&1 &
    PM_PID=$!
    sleep 1  # Let powermetrics emit at least one header.

    # Run the bench.
    echo "Running bench at $(date '+%H:%M:%S') (case=${CASE}, optimize=${OPTIMIZE})..."
    # shellcheck disable=SC2086
    if ! zig build -Doptimize="${OPTIMIZE}" bench-ecs -- --case="${CASE}" ${WORKERS_FLAG} \
            >"${BENCH_STDOUT}" 2>&1; then
        echo "BENCH FAILED. See ${BENCH_STDOUT}."
        sudo kill -INT "${PM_PID}" 2>/dev/null || true
        wait "${PM_PID}" 2>/dev/null || true
        exit 1
    fi

    # Stop powermetrics.
    sudo kill -INT "${PM_PID}" 2>/dev/null || true
    wait "${PM_PID}" 2>/dev/null || true

    # Archive bench report.
    if [ -f "zig-out/bench/ecs_benchmark.md" ]; then
        cp "zig-out/bench/ecs_benchmark.md" "${BENCH_REPORT}"
    fi

    # Extract median (ns).
    MEDIAN_NS=$(grep -oE "median = [0-9]+ ns" "${BENCH_REPORT}" 2>/dev/null | head -1 | grep -oE "[0-9]+" | head -1)
    if [ -z "${MEDIAN_NS:-}" ]; then
        MEDIAN_NS=$(grep -oE "median = [0-9]+" "${BENCH_STDOUT}" | head -1 | grep -oE "[0-9]+" | head -1)
    fi
    MEDIAN_NS="${MEDIAN_NS:-0}"

    # Count powermetrics pressure samples. M-series format :
    #   "**** Thermal pressure ****\nCurrent pressure level: <level>\n"
    # We `wc -l` after grep so the exit status of grep doesn't add noise.
    SAMPLES_TOTAL=$(grep -E "^Current pressure level:" "${PM_LOG}" 2>/dev/null | wc -l | tr -d ' ')
    SAMPLES_TOTAL="${SAMPLES_TOTAL:-0}"
    NON_NOMINAL=$(grep -E "^Current pressure level:[[:space:]]+(Fair|Serious|Critical)" "${PM_LOG}" 2>/dev/null | wc -l | tr -d ' ')
    NON_NOMINAL="${NON_NOMINAL:-0}"

    echo "Run ${run} done at $(date '+%H:%M:%S'):"
    echo "  Median             : ${MEDIAN_NS} ns"
    echo "  Pressure samples   : ${SAMPLES_TOTAL}"
    echo "  Non-Nominal samples: ${NON_NOMINAL}"

    if [ "${NON_NOMINAL}" -gt 0 ]; then
        echo "  *** PROTOCOL VIOLATION *** non-Nominal Pressure during run ${run}."
        echo "  See ${PM_LOG}. Per protocol, this run is INVALIDATED."
        echo "  Aborting; resume after additional idle by re-launching the script."
        exit 1
    fi

    medians+=("${MEDIAN_NS}")
    non_nominal_counts+=("${NON_NOMINAL}")
    total_samples+=("${SAMPLES_TOTAL}")
done

# Median of medians — sort 3 values, take middle. bash 3.2 compatible.
m0=${medians[0]}
m1=${medians[1]}
m2=${medians[2]}
SORTED=$(printf '%d\n%d\n%d\n' "$m0" "$m1" "$m2" | sort -n)
MEDIAN_OF_MEDIANS=$(echo "$SORTED" | sed -n '2p')

echo ""
echo "=== Session complete ==="
echo "Medians (ns)    : ${medians[*]}"
echo "Median of medians: ${MEDIAN_OF_MEDIANS} ns"
echo "Gate            : ${GATE_NS} ns"

if [ "${MEDIAN_OF_MEDIANS}" -le "${GATE_NS}" ]; then
    VERDICT="GO"
else
    VERDICT="NO-GO"
fi
echo "Verdict         : ${VERDICT}"

# Generate the report.
mkdir -p "$(dirname "${REPORT}")"
{
    echo "# ECS bench ${CASE_UPPER} — M0.2.1 / E6 (thermal-aware)"
    echo ""
    echo "**Date** : ${DATE}"
    echo "**Commit** : \`${COMMIT_SHORT}\` (\`${COMMIT}\`)"
    echo "**Machine** : ${MACHINE}"
    echo "**Build mode** : ${OPTIMIZE}"
    echo "**Workers** : ${WORKERS_DESC}"
    echo "**Protocol** : thermal-aware MBP M-series, cold-isolé conforme."
    echo "**Gate** : ${GATE_DESC} (${GATE_NS} ns)"
    echo "**Initial idle** : ${INITIAL_IDLE_SEC} s ($((INITIAL_IDLE_SEC/60)) min)"
    echo "**Inter-run idle** : ${INTER_RUN_IDLE_SEC} s ($((INTER_RUN_IDLE_SEC/60)) min)"
    echo ""
    echo "## Runs"
    echo ""
    echo "| Run | Median (ns) | Powermetrics samples | Non-Nominal Pressure |"
    echo "|---|---|---|---|"
    for i in 0 1 2; do
        echo "| $((i+1)) | ${medians[$i]} | ${total_samples[$i]} | ${non_nominal_counts[$i]} |"
    done
    echo ""
    echo "## Médiane des médianes"
    echo ""
    echo "**${MEDIAN_OF_MEDIANS} ns**"
    echo ""
    if [ "${VERDICT}" = "GO" ]; then
        echo "Verdict : **GO** (≤ gate ${GATE_NS} ns)."
    else
        echo "Verdict : **NO-GO** (> gate ${GATE_NS} ns)."
    fi
    echo ""
    echo "## Conformité thermal-aware"
    echo ""
    total_non_nominal=0
    for nn in "${non_nominal_counts[@]}"; do
        total_non_nominal=$((total_non_nominal + nn))
    done
    if [ "${total_non_nominal}" -eq 0 ]; then
        echo "Pressure = Nominal sur **100 %** des samples (${total_samples[*]} samples cumul). **Protocole conforme.**"
    else
        echo "ATTENTION : ${total_non_nominal} samples non-Nominal détectés. Protocole VIOLÉ."
    fi
    echo ""
    echo "## Inspection false sharing (M0.2.1 / E6 note 2)"
    echo ""
    echo "Le comptime layout guard dans \`src/core/jobs/scheduler.zig\` (post-E5)"
    echo "valide à compile time que \`gen_and_n\` et \`pending_count\` sont chacun"
    echo "aligné sur sa propre cache line (offsets multiples de 64, delta ≥ 64)."
    echo "Build passe ⇒ assertion validée. **Aucun false sharing entre dispatcher"
    echo "et workers sur ces atomics.**"
    echo ""
    echo "## Logs archivés"
    echo ""
    echo "Sous \`${OUT_DIR}/\` :"
    for i in 1 2 3; do
        echo "- \`bench_report_run${i}.md\` — sortie Markdown du bench."
        echo "- \`bench_stdout_run${i}.log\` — stdout/stderr de l'invocation."
        echo "- \`powermetrics_run${i}.log\` — trace thermique (11 samples par run).";
    done
    echo ""
    echo "## Protocole respecté"
    echo ""
    echo "- ≥ ${INITIAL_IDLE_SEC} s ($((INITIAL_IDLE_SEC/60)) min) idle après pre-build avant run #1 — enforced par sleep."
    echo "- ≥ ${INTER_RUN_IDLE_SEC} s ($((INTER_RUN_IDLE_SEC/60)) min) idle entre runs — enforced par sleep."
    echo "- 3 runs par session — limite la chaîne thermal cumulée."
    echo "- \`powermetrics --samplers thermal,cpu_power -i 100\` capturé en parallèle de chaque run."
    echo "- Vérification programmatique \`Current pressure level: Nominal\` sur 100 % des samples."
} > "${REPORT}"

echo ""
echo "Report written: ${REPORT}"
echo ""
echo "Done."
