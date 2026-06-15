#!/usr/bin/env bash
# load.sh <run_id> [step_name]
# Print file path(s). Không đọc nội dung — caller dùng Read.

set -euo pipefail

RUN_ID="$1"
STEP_NAME="${2:-}"

DIR=".pipeline_state/$RUN_ID"
[ -d "$DIR" ] || { echo "ERROR: run_id not found: $RUN_ID" >&2; exit 1; }

if [ -z "$STEP_NAME" ]; then
  ls -1 "$DIR"/*.json 2>/dev/null | sort
else
  # match step_NN_{step_name}.json hoặc step_NN_{step_name}_*.json (reviewer rN)
  ls -1 "$DIR"/step_*_"${STEP_NAME}"*.json 2>/dev/null | sort | tail -n1
fi
