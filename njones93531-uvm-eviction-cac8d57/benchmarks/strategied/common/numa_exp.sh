#!/bin/bash
logbase=$1
cmd=$2
out=$3
data=${logbase}_numa_pref.data

preferred_node=${NUMA_NODE:-1}
if [ ! -d "/sys/devices/system/node/node${preferred_node}" ]; then
  preferred_node=0
fi

use_timeout=1
if [ $use_timeout -eq 1 ]; then
  echo $out >> $data
  timeout "$TIMEOUT" numactl --cpunodebind=0 --preferred="$preferred_node" bash -c "$cmd" >> "$data"
  if [ $? -eq 0 ]; then
    echo "Command did not time out within $TIMEOUT seconds\n" >> $data
  else
    echo "Command timed out after $TIMEOUT seconds\n" >> $data
  fi
else
  echo $out >> $data
  numactl --cpunodebind=0 --preferred="$preferred_node" bash -c "$cmd" >> "$data"
fi
