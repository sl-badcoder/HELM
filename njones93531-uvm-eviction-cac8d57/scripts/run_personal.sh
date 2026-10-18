#!/usr/bin/env bash
set -euo pipefail

# Run exactly one allocation policy with the nvidia_uvm module that is already
# loaded. Override these values through environment variables if needed, e.g.:
# BENCH=sgemm PSIZE=150 POLICY=mmm TIMEOUT=1800 ./scripts/run-personal-policy.sh
BENCH="${BENCH:-bfs-worst}"
PSIZE="${PSIZE:-130}"
TIMEOUT="${TIMEOUT:-1800}"
POLICY="${POLICY:-}"
KERNEL_LABEL="${KERNEL_LABEL:-personal-loaded}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
BENCH_DIR="$ROOT_DIR/benchmarks/scriptsv3"
PERF_PLOT_DIR="$ROOT_DIR/benchmarks/strategied/common/plot"
RESULT_DIR="${RESULT_DIR:-$ROOT_DIR/results/personal}"

case "$BENCH" in
    sgemm)
        PERF_LOGBASE="sgemm"
        EXPECTED_ALLOCS=3
        ;;
    bfs-worst)
        PERF_LOGBASE="bfs-worst"
        EXPECTED_ALLOCS=3
        ;;
    FDTD-2D)
        PERF_LOGBASE="fdtd-2d"
        EXPECTED_ALLOCS=3
        ;;
    GRAMSCHM)
        PERF_LOGBASE="gramschm"
        EXPECTED_ALLOCS=3
        ;;
    stream)
        PERF_LOGBASE="stream"
        EXPECTED_ALLOCS=3
        ;;
    cg)
        PERF_LOGBASE="cg"
        EXPECTED_ALLOCS=9
        ;;
    tealeaf)
        PERF_LOGBASE="tealeaf"
        EXPECTED_ALLOCS=20
        ;;
    *)
        echo "ERROR: Unsupported benchmark: $BENCH" >&2
        exit 1
        ;;
esac

# Migration is the default policy when POLICY is not supplied.
if [[ -z "$POLICY" ]]; then
    printf -v POLICY '%*s' "$EXPECTED_ALLOCS" ''
    POLICY=${POLICY// /m}
fi

if [[ ! "$PSIZE" =~ ^[0-9]+$ ]] || (( PSIZE <= 0 )); then
    echo "ERROR: PSIZE must be a positive integer percentage of VRAM." >&2
    exit 1
fi

if [[ ! "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: TIMEOUT must be a non-negative number of seconds." >&2
    exit 1
fi

if (( ${#POLICY} != EXPECTED_ALLOCS )); then
    echo "ERROR: $BENCH requires a $EXPECTED_ALLOCS-character policy; got '$POLICY'." >&2
    exit 1
fi

if [[ ! -d /sys/module/nvidia_uvm ]]; then
    echo "ERROR: nvidia_uvm is not loaded. Load your personal module first." >&2
    exit 1
fi

export BENCH PSIZE POLICY TIMEOUT KERNEL_LABEL
export SKIP_MODULE_RELOAD=1

PERF_DATA="$ROOT_DIR/benchmarks/strategied/$BENCH/${PERF_LOGBASE}_numa_pref.data"
PERF_CSV="$ROOT_DIR/benchmarks/strategied/$BENCH/${PERF_LOGBASE}_numa_pref.csv"
mkdir -p "$RESULT_DIR"

if [[ -f "$PERF_DATA" ]]; then
    BEFORE_LINES=$(wc -l < "$PERF_DATA")
else
    BEFORE_LINES=0
fi

echo "============================================================"
echo "Running one policy with the currently loaded personal module"
echo "============================================================"
echo "Benchmark:    $BENCH"
echo "Problem size: $PSIZE% of configured VRAM"
echo "Policy:       $POLICY"
echo "Timeout:      $TIMEOUT seconds"
echo "Kernel label: $KERNEL_LABEL"
echo

cd "$BENCH_DIR"

python3 -u <<'PY'
import os

import config
from experiments_nolog import Experiment

bench = os.environ["BENCH"]
benchmark_dir = f"{config.BENCHDIR}/strategied/{bench}"

experiment = Experiment(
    benchmark=bench,
    benchmark_exe="run_numa.sh",
    benchmark_dir=benchmark_dir,
    psizes=[os.environ["PSIZE"]],
    policies=[os.environ["POLICY"]],
    benchmark_arg_desc=benchmark_dir,
    kernel_version=config.KERNEL_VERSION,
    kernel_variant=os.environ["KERNEL_LABEL"],
    kernel_args={},
)

experiment._run(
    clear=True,
    psize=os.environ["PSIZE"],
    policy=os.environ["POLICY"],
    timeout=float(os.environ["TIMEOUT"]),
)
PY

if [[ ! -f "$PERF_DATA" ]]; then
    echo "ERROR: Benchmark did not create $PERF_DATA" >&2
    exit 1
fi

AFTER_LINES=$(wc -l < "$PERF_DATA")
if (( AFTER_LINES <= BEFORE_LINES )); then
    echo "ERROR: Benchmark did not append output to $PERF_DATA" >&2
    exit 1
fi

python3 "$PERF_PLOT_DIR/perf_data2csv.py" "$PERF_DATA"

if [[ ! -s "$PERF_CSV" ]] || (( $(wc -l < "$PERF_CSV") < 2 )); then
    echo "ERROR: No benchmark result was parsed into $PERF_CSV" >&2
    exit 1
fi

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESULT_FILE="$RESULT_DIR/${TIMESTAMP}_PSIZE-${PSIZE}_BENCH-${BENCH}_POLICY-${POLICY}.csv"

{
    head -n 1 "$PERF_CSV"
    tail -n 1 "$PERF_CSV"
} > "$RESULT_FILE"

echo
echo "============================================================"
echo "Result"
echo "============================================================"
cat "$RESULT_FILE"
echo
echo "Full CSV:  $PERF_CSV"
echo "Saved run: $RESULT_FILE"
