#!/usr/bin/env bash
# append_review.sh <run_id> <round> <target_agent> <issues_summary> <verdict>
# Append 1 dòng JSONL vào review_log.jsonl.

set -euo pipefail

RUN_ID="$1"
ROUND="$2"
TARGET="$3"
ISSUES="$4"
VERDICT="$5"

LOG=".pipeline_state/$RUN_ID/review_log.jsonl"
mkdir -p "$(dirname "$LOG")"
[ -f "$LOG" ] || touch "$LOG"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if command -v jq >/dev/null 2>&1; then
  jq -nc \
    --arg ts "$TS" --argjson round "$ROUND" --arg target "$TARGET" \
    --arg issues "$ISSUES" --arg verdict "$VERDICT" \
    '{ts:$ts, round:$round, target_agent:$target, issues_summary:$issues, verdict:$verdict}' \
    >> "$LOG"
else
  if command -v python >/dev/null 2>&1; then
    PYBIN="python"
  elif command -v python3 >/dev/null 2>&1; then
    PYBIN="python3"
  else
    echo "ERROR: cần python hoặc jq" >&2; exit 127
  fi
  "$PYBIN" -c "
import json,sys
print(json.dumps({
    'ts': '$TS',
    'round': int('$ROUND'),
    'target_agent': '$TARGET',
    'issues_summary': '''$ISSUES'''.replace(chr(39),''),
    'verdict': '$VERDICT'
}, ensure_ascii=False))
" >> "$LOG"
fi

echo "$LOG"
