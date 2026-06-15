#!/usr/bin/env bash
# new_run.sh [slug_seed]
# Tạo run_id mới + thư mục .pipeline_state/{run_id}/ + manifest rỗng.
# Prints run_id ra stdout.

set -euo pipefail

SLUG="${1:-pending}"
# slugify: lowercase, gạch dưới, bỏ dấu, max 30 char
SLUG=$(echo "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g' | cut -c1-30)
[ -z "$SLUG" ] && SLUG="pending"

TS=$(date +%Y%m%d_%H%M)
RAND=$(openssl rand -hex 2 2>/dev/null || printf "%04x" $((RANDOM * RANDOM % 65536)))
RUN_ID="run_${SLUG}_${TS}_${RAND}"

DIR=".pipeline_state/$RUN_ID"
mkdir -p "$DIR"

cat > "$DIR/manifest.json" <<EOF
{
  "run_id": "$RUN_ID",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": null,
  "current_step": null,
  "completed_steps": [],
  "retry_count": {
    "business-analyst": 0,
    "capability-clusterer": 0,
    "technology-researcher": 0,
    "solution-architect": 0
  },
  "status": "INITIALIZED",
  "final_verdict": null,
  "saved_path": null,
  "domain": null,
  "title": null
}
EOF

touch "$DIR/review_log.jsonl"

echo "$RUN_ID"
