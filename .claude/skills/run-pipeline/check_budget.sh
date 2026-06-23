#!/usr/bin/env bash
# check_budget.sh <run_id>
# Circuit breaker: check tổng token + wall-clock của run so với budget config.
# Đọc từ logs/runs.log (tích lũy STEP_OK events) và pipeline_start_ts trong manifest.
#
# Budget từ env vars (default rộng rãi):
#   BUDGET_MAX_TOKENS    — mặc định 2000000 (~2M tokens cả in+out)
#   BUDGET_MAX_WALL_S    — mặc định 1800    (30 phút wall-clock)
#   BUDGET_WARN_PCT      — mặc định 80      (cảnh báo khi vượt %)
#
# Output JSON stdout:
#   {"status":"ok|warn|exceeded","tokens":N,"wall_s":N,"limits":{...},"reason":"..."}
# Exit:
#   0 = ok
#   1 = warn (vượt WARN_PCT nhưng chưa kịch trần)
#   2 = exceeded (kịch trần — orchestrator PHẢI terminate)

set -uo pipefail

RUN_ID="${1:-}"
[ -z "$RUN_ID" ] && { echo '{"error":"missing run_id"}'; exit 0; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$PROJECT_ROOT"

MAX_TOKENS="${BUDGET_MAX_TOKENS:-2000000}"
MAX_WALL_S="${BUDGET_MAX_WALL_S:-1800}"
WARN_PCT="${BUDGET_WARN_PCT:-80}"

RUN_LOG="logs/$RUN_ID/run.log"
MANIFEST=".pipeline_state/$RUN_ID/manifest.json"

# Sum tokens từ STEP_OK events
TOKENS=0
if [ -f "$RUN_LOG" ]; then
  TOKENS=$(awk -F' \\| ' '
    /STEP_OK/ {
      for (i=4; i<=NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "tokens_in"  && kv[2] ~ /^[0-9]+$/) ti += kv[2]
        if (kv[1] == "tokens_out" && kv[2] ~ /^[0-9]+$/) to += kv[2]
      }
    }
    END { print (ti + to) + 0 }
  ' "$RUN_LOG")
fi

# Wall-clock từ created_at trong manifest
WALL_S=0
if [ -f "$MANIFEST" ]; then
  CREATED=""
  if command -v jq >/dev/null 2>&1; then
    CREATED=$(jq -r '.created_at // empty' "$MANIFEST" 2>/dev/null)
  elif command -v python >/dev/null 2>&1; then
    CREATED=$(python -c "import json; print(json.load(open('$MANIFEST')).get('created_at','') or '')" 2>/dev/null)
  fi
  if [ -n "$CREATED" ]; then
    # Convert ISO8601 → epoch (best effort, POSIX date may not handle T/Z)
    CLEAN=$(echo "$CREATED" | sed 's/T/ /;s/Z$//')
    START_EPOCH=$(date -d "$CLEAN UTC" +%s 2>/dev/null || echo 0)
    if [ "$START_EPOCH" -gt 0 ]; then
      NOW=$(date -u +%s)
      WALL_S=$((NOW - START_EPOCH))
    fi
  fi
fi

# Percent
TOK_PCT=$(( TOKENS * 100 / (MAX_TOKENS > 0 ? MAX_TOKENS : 1) ))
WALL_PCT=$(( WALL_S * 100 / (MAX_WALL_S > 0 ? MAX_WALL_S : 1) ))

STATUS="ok"
REASON=""
EXIT=0

if [ "$TOKENS" -ge "$MAX_TOKENS" ]; then
  STATUS="exceeded"; EXIT=2
  REASON="tokens $TOKENS >= max $MAX_TOKENS"
elif [ "$WALL_S" -ge "$MAX_WALL_S" ]; then
  STATUS="exceeded"; EXIT=2
  REASON="wall_clock ${WALL_S}s >= max ${MAX_WALL_S}s"
elif [ "$TOK_PCT" -ge "$WARN_PCT" ] || [ "$WALL_PCT" -ge "$WARN_PCT" ]; then
  STATUS="warn"; EXIT=1
  REASON="approaching limits (tok ${TOK_PCT}%, wall ${WALL_PCT}%)"
fi

cat <<EOF
{
  "status": "$STATUS",
  "tokens": $TOKENS,
  "wall_s": $WALL_S,
  "tok_pct": $TOK_PCT,
  "wall_pct": $WALL_PCT,
  "limits": {"max_tokens": $MAX_TOKENS, "max_wall_s": $MAX_WALL_S, "warn_pct": $WARN_PCT},
  "reason": "$REASON"
}
EOF

exit "$EXIT"
