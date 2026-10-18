#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIG
# ============================================================

BENCH="tealeaf"
PSIZE="130"
TIMEOUT="1800"

BENCH_DIR="/uvm-eviction/benchmarks/scriptsv3"
PLOT_DIR="/uvm-eviction/tools/fault_plotsv3"
PERF_PLOT_DIR="/uvm-eviction/benchmarks/strategied/common/plot"
RESULT_DIR="/uvm-eviction/results/mim"

export BENCH PSIZE TIMEOUT

mkdir -p "$RESULT_DIR"


# ============================================================
# BENCHMARK CONFIG
# ============================================================

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
        echo "ERROR: Unsupported benchmark: $BENCH"
        exit 1
        ;;
esac


# ============================================================
# TIMING HELPERS
# ============================================================

now_ns() {
    date +%s%N
}

elapsed() {
    awk -v start="$1" -v end="$2" \
        'BEGIN { printf "%.3f", (end - start) / 1000000000 }'
}

TOTAL_START=$(now_ns)

echo "============================================================"
echo "BENCH:   $BENCH"
echo "PSIZE:   $PSIZE"
echo "TIMEOUT: $TIMEOUT"
echo "============================================================"


# ============================================================
# 1. PROFILING
# ============================================================

cd "$BENCH_DIR"

PROFILE_DIR="/uvm-eviction/benchmarks/default/${BENCH}/log_x86_64-595.71.05_faults-new_${PSIZE}_${BENCH}"
LOG="${PROFILE_DIR}/${BENCH}_klog"

rm -rf "$PROFILE_DIR"

echo
echo "=== Profiling ==="

START=$(now_ns)

python3 - <<'PY'
import os
from faults import get_experiment

exp = next(
    e for e in get_experiment(False, False)
    if e.benchmark == os.environ["BENCH"]
)

exp.benchmark_args = [os.environ["PSIZE"]]
exp.run(clear=True)
PY

END=$(now_ns)
PROFILE_TIME=$(elapsed "$START" "$END")

echo "Profiling time: ${PROFILE_TIME}s"


# Basic sanity check: reject tiny/header-only logs.
if [ ! -f "$LOG" ]; then
    echo "ERROR: profiling log was not created"
    exit 1
fi

LOG_SIZE=$(stat -c%s "$LOG")

if [ "$LOG_SIZE" -lt 1024 ]; then
    echo "ERROR: profiling log is only ${LOG_SIZE} bytes"
    echo "Benchmark probably failed before producing fault data."
    exit 1
fi


# ============================================================
# 2. HELM METRICS
# ============================================================

cd "$PLOT_DIR"

echo
echo "=== HELM metrics ==="

START=$(now_ns)

python3 metric_plot.py "$LOG" -o metrics_stats_relative

METRICS=$(
    python3 fault_parsing.py \
        "$LOG" \
        metrics_stats_relative |
    tail -n 1
)

END=$(now_ns)
METRICS_TIME=$(elapsed "$START" "$END")

if [ -z "$METRICS" ] || [ ! -f "$METRICS" ]; then
    echo "ERROR: metrics file was not generated"
    exit 1
fi

echo "Metrics time: ${METRICS_TIME}s"
echo "Metrics file: $METRICS"


# ============================================================
# 3. MIM POLICY
# ============================================================

echo
echo "=== MIM policy ==="

POLICY_FILE=$(mktemp)

START=$(now_ns)

python3 - "$METRICS" "$POLICY_FILE" <<'PY'
import sys
import pandas as pd
from itertools import combinations

df = pd.read_csv(sys.argv[1]).sort_values("label").reset_index(drop=True)
df["cost"] = df["size"] / 100.0

streaming = (
    df["dr_intra_mean_1000"].between(1, 1000, inclusive="both").all()
    and df["tr_mean_1"].between(0, 0.005, inclusive="both").all()
)

if streaming:
    df["device_score"] = -df["dc_intra_rel_mean_1000"]
    migrate = df["d_mean_1000"] >= 0.13
else:
    df["device_score"] = df[
        ["tr_median_1000", "ts_rel_median_1000"]
    ].max(axis=1)

    migrate = (
        (df["d_mean_1000"] > 0.02)
        & (df["dr_intra_mean_1000"] > 1)
    )

minimum = df["device_score"].min()

if minimum < 0:
    df["device_score"] += 1.001 * abs(float(minimum))

if minimum <= 0:
    df["device_score"] += 0.001

best_score = float("-inf")
device = set()

for count in range(len(df) + 1):
    for choice in combinations(range(len(df)), count):
        indices = list(choice)

        cost = df.loc[indices, "cost"].sum()
        score = df.loc[indices, "device_score"].sum()

        if cost <= 0.99 and score > best_score:
            best_score = score
            device = set(choice)

policy = "".join(
    "d" if i in device
    else ("m" if migrate.iloc[i] else "h")
    for i in range(len(df))
)

print("Streaming:", streaming)
print("Policy:", policy)

with open(sys.argv[2], "w") as f:
    f.write(policy)
PY

POLICY=$(cat "$POLICY_FILE")
rm -f "$POLICY_FILE"

END=$(now_ns)
POLICY_TIME=$(elapsed "$START" "$END")

export POLICY

if [ "${#POLICY}" -ne "$EXPECTED_ALLOCS" ]; then
    echo "ERROR: policy '$POLICY' has length ${#POLICY}"
    echo "Expected $EXPECTED_ALLOCS for $BENCH"
    exit 1
fi

echo "Policy: $POLICY"
echo "Policy calculation time: ${POLICY_TIME}s"


# ============================================================
# 4. RUN SELECTED POLICY
# ============================================================

cd "$BENCH_DIR"

echo
echo "=== Selected policy run ==="

START=$(now_ns)

python3 - <<'PY'
import os
from perf import get_experiments

experiment = next(
    exp for exp in get_experiments(False, False)
    if exp.benchmark == os.environ["BENCH"]
)

experiment._run(
    clear=True,
    psize=os.environ["PSIZE"],
    policy=os.environ["POLICY"],
    timeout=float(os.environ["TIMEOUT"]),
)
PY

END=$(now_ns)
RUN_TIME=$(elapsed "$START" "$END")

echo "Selected-run wall time: ${RUN_TIME}s"


# ============================================================
# 5. CONVERT NATIVE RESULT
# ============================================================

PERF_DATA="/uvm-eviction/benchmarks/strategied/${BENCH}/${PERF_LOGBASE}_numa_pref.data"
PERF_CSV="/uvm-eviction/benchmarks/strategied/${BENCH}/${PERF_LOGBASE}_numa_pref.csv"

cd "$PERF_PLOT_DIR"

if [ ! -f "$PERF_DATA" ]; then
    echo "ERROR: performance data not found:"
    echo "$PERF_DATA"
    exit 1
fi

python3 perf_data2csv.py \
    "../../${BENCH}/${PERF_LOGBASE}_numa_pref.data"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

RESULT_FILE="${RESULT_DIR}/${TIMESTAMP}_PSIZE-${PSIZE}_BENCH-${BENCH}_POLICY-${POLICY}.csv"

{
    head -n 1 "$PERF_CSV"
    tail -n 1 "$PERF_CSV"
} > "$RESULT_FILE"


# Get actual benchmark kernel time and reject ERROR rows.
KERNEL_TIME=$(
python3 - "$RESULT_FILE" <<'PY'
import csv
import sys

with open(sys.argv[1], newline="") as f:
    row = list(csv.DictReader(f))[-1]

if str(row.get("Iteration", "")).upper() == "ERROR":
    print("ERROR")
else:
    print(row.get("Kernel Time", ""))
PY
)


# ============================================================
# 6. SAVE TIMINGS
# ============================================================

TOTAL_END=$(now_ns)
TOTAL_TIME=$(elapsed "$TOTAL_START" "$TOTAL_END")

TIMING_FILE="${RESULT_DIR}/${TIMESTAMP}_PSIZE-${PSIZE}_BENCH-${BENCH}_timings.csv"

cat > "$TIMING_FILE" <<EOF
benchmark,psize,policy,profiling_seconds,metrics_seconds,policy_seconds,selected_run_wall_seconds,kernel_time,total_seconds
${BENCH},${PSIZE},${POLICY},${PROFILE_TIME},${METRICS_TIME},${POLICY_TIME},${RUN_TIME},${KERNEL_TIME},${TOTAL_TIME}
EOF


# ============================================================
# SUMMARY
# ============================================================

echo
echo "============================================================"
echo "TIMING SUMMARY"
echo "============================================================"
printf "%-28s %s s\n" "Profiling" "$PROFILE_TIME"
printf "%-28s %s s\n" "HELM metrics" "$METRICS_TIME"
printf "%-28s %s s\n" "MIM policy calculation" "$POLICY_TIME"
printf "%-28s %s s\n" "Selected run wall time" "$RUN_TIME"
printf "%-28s %s\n"   "Kernel time" "$KERNEL_TIME"
printf "%-28s %s s\n" "Total script time" "$TOTAL_TIME"

echo
echo "Policy:        $POLICY"
echo "Result:        $RESULT_FILE"
echo "Timing report: $TIMING_FILE"