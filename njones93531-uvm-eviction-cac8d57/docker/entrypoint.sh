#!/bin/bash
set -euo pipefail

echo "Setting up the environment"
root=/uvm-eviction

VRAM_MB=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits)
VRAM_GB=$(( (VRAM_MB + 512) / 1024 ))

#Set config file
cd "$root/benchmarks/scriptsv3/"
python3 set_config.py --root "$root" --vram-size "$VRAM_GB"

cd "$root"

echo "Environment complete" 

umask 000
exec "$@"
