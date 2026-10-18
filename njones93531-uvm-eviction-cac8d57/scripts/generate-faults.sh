#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}/../benchmarks/scriptsv3/"

TIMEOUT=12000
SUBSET=""
SMOKE=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TIMEOUT="$2"; shift 2 ;;
    -s|--subset) SUBSET=1; shift ;;
    --smoke) SMOKE=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -n "$TIMEOUT" ]] && export TIMEOUT="$TIMEOUT"
if [[ -n "$SUBSET" && -n "$SMOKE" ]]; then
  echo "--subset and --smoke are mutually exclusive"
  exit 1
fi
[[ -n "$SUBSET" ]] && ARGS+=("-s")
[[ -n "$SMOKE" ]] && ARGS+=("--smoke")

python3 -u faults.py "${ARGS[@]}"
