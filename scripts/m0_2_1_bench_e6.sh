#!/usr/bin/env bash
# M0.2.1 / E6 — thermal-aware bench orchestrator (MBP M-series protocol).
#
# Drives one bench session (3 runs of a single case) per the strict protocol
# defined in `engine-phase-0-criteria.md` § Méthodologie bench / sous-section
# « Protocole thermal-aware MBP M-series » :
#
#   - 30 min idle minimum before run #1.
#   - 15 min idle minimum between successive runs.
#   - 3 runs per session (no more, no less — limits thermal chain).
#   - `powermetrics --samplers thermal,cpu_power -i 100` captured in parallel,
#     verification that Pressure = Nominal on 100% of samples.
#   - Any non-Nominal sample invalidates the run.
#
# Usage:
#   sudo -v   # prime sudo creds first
#   scripts/m0_2_1_bench_e6.sh {s1|c01}
#
# The script pauses between runs so the operator can confirm idle time has
# elapsed. After all 3 runs complete, it generates the Markdown report at
# `bench/reports/ecs_benchmark_{S1,C0.1}_<DATE>-thermal-aware.md`.

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

DATE=$(date +%Y-%m-%d)
COMMIT=$(git rev-parse HEAD)
COMMIT_SHORT=$(git rev-parse --short HEAD)
MACHINE=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
OUT_DIR="/tmp/m0_2_1_bench_e6_${CASE}_${DATE}_$$"
mkdir -p "$OUT_DIR"
REPORT="bench/reports/ecs_benchmark_${CASE_UPPER}_${DATE}-thermal-aware.md"

echo "=== M0.2.1 / E6 — thermal-aware bench ==="
echo "Case      : ${CASE_UPPER}"
echo "Optimize  : ${OPTIMIZE}"
echo "Workers   : ${WORKERS_DESC}"
echo "Gate      : ${GATE_DESC} (${GATE_NS} ns)"
echo "Commit    : ${COMMIT_SHORT} (${COMMIT})"
echo "Date      : ${DATE}"
echo "Machine   : ${MACHINE}"
echo "Out dir   : ${OUT_DIR}"
echo "Report    : ${REPORT}"
echo ""

# Pre-build via a smoke run to warm the cache before the timed runs.
# Smoke is a single-dispatch sanity run on a tiny entity set — does not
# stress the thermals, just compiles the bench binary into `.zig-cache/`.
echo "Pre-building bench binary via smoke (mode=${OPTIMIZE})..."
zig build -Doptimize="${OPTIMIZE}" bench-ecs -- --case="${CASE}" --smoke >/dev/null 2>&1 || true
echo "Pre-build done."
echo ""

echo "Acquiring sudo for powermetrics (password may be prompted)..."
sudo -v
echo ""

medians=()
non_nominal_counts=()
total_samples=()

for run in 1 2 3; do
    if [ "$run" -eq 1 ]; then
        echo "=== Run 1/3 ==="
        echo "Confirm machine has been idle ≥ 30 min."
        echo "Press ENTER to start run 1..."
        read -r
    else
        echo ""
        echo "=== Inter-run pause ==="
        echo "Wait ≥ 15 min idle before run $run/3."
        echo "Press ENTER when ready..."
        read -r
        echo "Refreshing sudo..."
        sudo -v
        echo "=== Run $run/3 ==="
    fi

    PM_LOG="${OUT_DIR}/powermetrics_run${run}.log"
    BENCH_STDOUT="${OUT_DIR}/bench_stdout_run${run}.log"
    BENCH_REPORT="${OUT_DIR}/bench_report_run${run}.md"

    # Start powermetrics in background.
    sudo powermetrics --samplers thermal,cpu_power -i 100 >"${PM_LOG}" 2>&1 &
    PM_PID=$!
    sleep 1  # Let powermetrics emit at least one header.

    # Run the bench.
    echo "Running bench (case=${CASE}, optimize=${OPTIMIZE})..."
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
    else
        echo "WARNING: zig-out/bench/ecs_benchmark.md not found."
    fi

    # Extract median (ns).
    MEDIAN_NS=$(grep -oE "median = [0-9]+ ns" "${BENCH_REPORT}" 2>/dev/null | head -1 | grep -oE "[0-9]+" || true)
    if [ -z "${MEDIAN_NS:-}" ]; then
        MEDIAN_NS=$(grep -oE "median = [0-9]+" "${BENCH_STDOUT}" | head -1 | grep -oE "[0-9]+" || echo "0")
    fi

    # Count Pressure samples.
    NON_NOMINAL=$(grep -cE "Pressure[[:space:]]*[:=][[:space:]]*(Fair|Serious|Critical)" "${PM_LOG}" 2>/dev/null || echo "0")
    SAMPLES_TOTAL=$(grep -cE "Pressure[[:space:]]*[:=]" "${PM_LOG}" 2>/dev/null || echo "0")

    echo "Run ${run} done:"
    echo "  Median             : ${MEDIAN_NS} ns"
    echo "  Pressure samples   : ${SAMPLES_TOTAL} total"
    echo "  Non-Nominal samples: ${NON_NOMINAL}"

    if [ "${NON_NOMINAL}" -gt 0 ]; then
        echo "  *** PROTOCOL VIOLATION *** non-Nominal Pressure during run ${run}."
        echo "  See ${PM_LOG}. Per protocol, this run is INVALIDATED."
        echo "  Press ENTER to retry run ${run} (after additional idle), or Ctrl-C to abort."
        read -r
        sudo -v
        ((run--))  # Decrement: this iteration didn't count.
        continue
    fi

    medians+=("${MEDIAN_NS}")
    non_nominal_counts+=("${NON_NOMINAL}")
    total_samples+=("${SAMPLES_TOTAL}")
done

# Median of medians (3 values → middle one when sorted).
sorted_medians=$(printf "%s\n" "${medians[@]}" | sort -n)
mapfile -t sorted_arr <<< "${sorted_medians}"
MEDIAN_OF_MEDIANS="${sorted_arr[1]}"

echo ""
echo "=== Session complete ==="
echo "Medians         : ${medians[*]}"
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
        echo "- \`powermetrics_run${i}.log\` — trace thermique."
    done
    echo ""
    echo "## Protocole respecté"
    echo ""
    echo "- ≥ 30 min idle avant run #1 — confirmé par l'opérateur via prompt ENTER."
    echo "- ≥ 15 min idle entre runs — confirmé par l'opérateur via prompt ENTER."
    echo "- 3 runs par session (pas 7) — limite la chaîne thermal cumulée."
    echo "- \`powermetrics --samplers thermal,cpu_power -i 100\` capturé en parallèle de chaque run."
    echo "- Vérification programmatique Pressure = Nominal sur 100 % des samples."
} > "${REPORT}"

echo ""
echo "Report written: ${REPORT}"
echo ""
echo "Done."
