#!/usr/bin/env bash
# rename_run.sh <old_run_id> <new_slug>
# Đổi slug phần đầu run_id (sau Step 1 BA có title). Giữ timestamp + random.
# Prints new_run_id.

set -euo pipefail

OLD="$1"
NEW_SLUG="$2"

OLD_DIR=".pipeline_state/$OLD"
[ -d "$OLD_DIR" ] || { echo "ERROR: run_id not found: $OLD" >&2; exit 1; }

# slugify
SLUG=$(echo "$NEW_SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g' | cut -c1-30)
[ -z "$SLUG" ] && SLUG="pending"

# Extract suffix YYYYMMDD_HHMM_xxxx từ old run_id
SUFFIX=$(echo "$OLD" | grep -oE '[0-9]{8}_[0-9]{4}_[a-f0-9]{4}$' || true)
[ -z "$SUFFIX" ] && { echo "ERROR: cannot extract suffix from: $OLD" >&2; exit 1; }

NEW="run_${SLUG}_${SUFFIX}"
NEW_DIR=".pipeline_state/$NEW"

if [ "$OLD" = "$NEW" ]; then
  echo "$OLD"
  exit 0
fi

mv "$OLD_DIR" "$NEW_DIR"

# Update run_id field trong manifest
MANIFEST="$NEW_DIR/manifest.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v jq >/dev/null 2>&1; then
  TMP=$(mktemp)
  jq --arg id "$NEW" '.run_id=$id' "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
else
  if command -v python >/dev/null 2>&1; then PYBIN="python"
  elif command -v python3 >/dev/null 2>&1; then PYBIN="python3"
  else echo "ERROR: cần python hoặc jq" >&2; exit 127; fi
  "$PYBIN" "$SCRIPT_DIR/_json_op.py" set "$MANIFEST" ".run_id" "\"$NEW\""
fi

echo "$NEW"
