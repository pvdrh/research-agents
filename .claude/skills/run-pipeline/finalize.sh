#!/usr/bin/env bash
# finalize.sh <run_id>
# Cleanup + summary cuối run:
#   - Gọi observability/summarize.sh để gen tokens.json
#   - In summary table ra stderr (tokens, duration, retries, gates pass/fail)
#   - Optional: gzip .pipeline_state/{run_id}/ → .pipeline_state/_archive/{run_id}.tar.gz
#                (chỉ khi env FINALIZE_ARCHIVE=1)
#   - Trả JSON tóm tắt ra stdout
# Exit: 0 luôn (finalize không nên fail pipeline).

set -uo pipefail

RUN_ID="${1:-}"
[ -z "$RUN_ID" ] && { echo '{"error":"missing run_id"}'; exit 0; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$PROJECT_ROOT"

STATE_DIR=".pipeline_state/$RUN_ID"
LOG_DIR="logs/$RUN_ID"
MASTER_LOG="logs/runs.log"

[ -d "$STATE_DIR" ] || { echo "{\"error\":\"state dir not found: $STATE_DIR\"}"; exit 0; }

# 1. Gọi observability/summarize nếu có
if [ -x ".claude/skills/observability/summarize.sh" ]; then
  bash .claude/skills/observability/summarize.sh "$RUN_ID" >/dev/null 2>&1 || true
fi

# 2. Đọc manifest
MANIFEST="$STATE_DIR/manifest.json"
TOKENS_JSON="$LOG_DIR/tokens.json"

# Helper: jq hoặc python fallback
read_json() {
  local FILE="$1" KEY="$2"
  if [ ! -f "$FILE" ]; then echo ""; return; fi
  if command -v jq >/dev/null 2>&1; then
    jq -r "$KEY // \"\"" "$FILE" 2>/dev/null
  elif command -v python >/dev/null 2>&1; then
    python -c "
import json,sys
try:
  d=json.load(open('$FILE'))
  k='$KEY'.lstrip('.')
  for p in k.split('.'):
    if isinstance(d,dict): d=d.get(p,'')
    else: d=''
  print(d if d is not None else '')
except: pass
" 2>/dev/null
  fi
}

VERDICT=$(read_json "$MANIFEST" ".final_verdict")
STATUS=$(read_json "$MANIFEST" ".status")
MODE=$(read_json "$MANIFEST" ".mode")
SAVED_PATH=$(read_json "$MANIFEST" ".saved_path")
DOMAIN=$(read_json "$MANIFEST" ".domain")
TITLE=$(read_json "$MANIFEST" ".title")

TOTAL_TOKENS=$(read_json "$TOKENS_JSON" ".total_tokens")
TOTAL_DURATION=$(read_json "$TOKENS_JSON" ".total_duration_s")
RETRY_TOTAL=$(read_json "$TOKENS_JSON" ".retry_total")

# Count gate events từ master log
GATE_OK=0
GATE_FAIL=0
RISK_ACCEPTED=0
if [ -f "$MASTER_LOG" ]; then
  GATE_OK=$(grep -c "| $RUN_ID | GATE_OK" "$MASTER_LOG" 2>/dev/null || echo 0)
  GATE_FAIL=$(grep -c "| $RUN_ID | GATE_FAIL" "$MASTER_LOG" 2>/dev/null || echo 0)
  RISK_ACCEPTED=$(grep -c "| $RUN_ID | RISK_ACCEPTED" "$MASTER_LOG" 2>/dev/null || echo 0)
fi

# 3. Archive (optional)
ARCHIVE_PATH=""
if [ "${FINALIZE_ARCHIVE:-0}" = "1" ]; then
  mkdir -p .pipeline_state/_archive
  ARCHIVE_PATH=".pipeline_state/_archive/${RUN_ID}.tar.gz"
  if command -v tar >/dev/null 2>&1; then
    tar -czf "$ARCHIVE_PATH" -C .pipeline_state "$RUN_ID" 2>/dev/null && \
      echo "  Archived: $ARCHIVE_PATH" >&2 || ARCHIVE_PATH=""
  fi
fi

# 4. Stderr summary
{
  echo ""
  echo "═══ Pipeline Finalize ═══"
  printf "  %-18s %s\n" "Run ID:"        "$RUN_ID"
  [ -n "$TITLE" ]   && printf "  %-18s %s\n" "Title:"     "$TITLE"
  [ -n "$DOMAIN" ]  && printf "  %-18s %s\n" "Domain:"    "$DOMAIN"
  printf "  %-18s %s\n" "Mode:"          "${MODE:-?}"
  printf "  %-18s %s\n" "Status:"        "${STATUS:-?}"
  printf "  %-18s %s\n" "Verdict:"       "${VERDICT:-?}"
  echo ""
  printf "  %-18s %s\n" "Total tokens:"  "${TOTAL_TOKENS:-?}"
  printf "  %-18s %s s\n" "Wall-clock:"  "${TOTAL_DURATION:-?}"
  printf "  %-18s %s\n" "Retry rounds:"  "${RETRY_TOTAL:-0}"
  printf "  %-18s %s pass / %s fail\n" "Hard gates:" "$GATE_OK" "$GATE_FAIL"
  printf "  %-18s %s\n" "Risks accepted:" "$RISK_ACCEPTED"
  echo ""
  [ -n "$SAVED_PATH" ] && printf "  %-18s %s\n" "Output:" "$SAVED_PATH"
  printf "  %-18s %s\n" "State dir:"     "$STATE_DIR"
  printf "  %-18s %s\n" "Log dir:"       "$LOG_DIR"
  [ -n "$ARCHIVE_PATH" ] && printf "  %-18s %s\n" "Archive:" "$ARCHIVE_PATH"
  echo ""
} >&2

# 5. JSON stdout
cat <<EOF
{
  "run_id": "$RUN_ID",
  "verdict": "${VERDICT:-null}",
  "status": "${STATUS:-null}",
  "total_tokens": ${TOTAL_TOKENS:-null},
  "total_duration_s": ${TOTAL_DURATION:-null},
  "retry_total": ${RETRY_TOTAL:-0},
  "gates": {"ok": $GATE_OK, "fail": $GATE_FAIL},
  "risks_accepted": $RISK_ACCEPTED,
  "saved_path": "${SAVED_PATH:-}",
  "archive_path": "${ARCHIVE_PATH:-}"
}
EOF

exit 0
