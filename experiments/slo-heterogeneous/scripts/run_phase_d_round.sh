#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 RUN_ROOT REPEAT SEED" >&2
  exit 2
fi

run_root=$1
repeat=$2
seed=$3

for spec in "0 0" "20 1.6" "40 3.2" "60 4.8" "80 6.4" "95 7.6"; do
  set -- $spec
  PHASE_D_BACKGROUND_MODE=gateway-visible \
    bash /opt/aibrix-experiment/tools/run_phase_d_l20_busy_condition.sh \
      "$run_root" "$1" "$2" "$repeat" "$seed"
done

printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$run_root/repeat-${repeat}-complete-utc.txt"
