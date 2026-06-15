#!/usr/bin/env bash
# decide_strategy.sh <run_id>
# Đọc BA output, đếm cases, quyết định strategy. Update manifest. Log event.
# Output JSON stdout.

set -euo pipefail

RUN_ID="$1"

if command -v python >/dev/null 2>&1; then PYBIN="python"
elif command -v python3 >/dev/null 2>&1; then PYBIN="python3"
else echo '{"error":"NO_PYTHON"}'; exit 2; fi

BA_FILE=$(bash .claude/skills/state-store/load.sh "$RUN_ID" business_analyst)
if [ -z "$BA_FILE" ] || [ ! -f "$BA_FILE" ]; then
  echo '{"error":"BA_FILE_NOT_FOUND"}'; exit 2
fi

# Detect mode + count cases
MODE=$("$PYBIN" -c "import json; d=json.load(open('$BA_FILE')); print(d.get('mode','single'))")

if [ "$MODE" != "batch" ]; then
  cat <<EOF
{
  "strategy": "n/a",
  "n_cases": 1,
  "chunks_count": 1,
  "chunks": [{"index": 0, "case_ids": []}]
}
EOF
  bash .claude/skills/state-store/update.sh "$RUN_ID" set ".strategy" '"n/a"' > /dev/null
  bash .claude/skills/state-store/update.sh "$RUN_ID" set ".n_cases" '1' > /dev/null
  exit 0
fi

# BATCH: count + decide
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$PYBIN" "$SCRIPT_DIR/_decide.py" "$RUN_ID" "$BA_FILE"
