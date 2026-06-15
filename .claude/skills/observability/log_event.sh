#!/usr/bin/env bash
# log_event.sh <run_id> <event_type> [key=value]...
# Ghi vào logs/runs.log (master) + logs/{run_id}/run.log (detail).

set -euo pipefail

RUN_ID="$1"
EVENT="$2"
shift 2

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "logs/$RUN_ID"

# Build fields string: "key=value | key=value"
FIELDS=""
for kv in "$@"; do
  if [ -z "$FIELDS" ]; then
    FIELDS="$kv"
  else
    FIELDS="$FIELDS | $kv"
  fi
done

LINE="$TS | $RUN_ID | $EVENT"
[ -n "$FIELDS" ] && LINE="$LINE | $FIELDS"

# Master log
mkdir -p logs
echo "$LINE" >> logs/runs.log

# Per-run log
echo "$LINE" >> "logs/$RUN_ID/run.log"
