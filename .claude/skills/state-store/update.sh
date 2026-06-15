#!/usr/bin/env bash
# update.sh <run_id> <op> [args...]
# Cập nhật manifest.json. 3 ops:
#   set <jsonpath> <value_json>        — set giá trị
#   inc <jsonpath>                     — tăng số nguyên +1
#   jq <full_jq_expression>            — chỉ dùng khi có jq, full power
# In manifest sau khi update.

set -euo pipefail

RUN_ID="$1"
OP="$2"
shift 2

MANIFEST=".pipeline_state/$RUN_ID/manifest.json"
[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v jq >/dev/null 2>&1; then
  JSON_BACKEND="jq"
else
  if command -v python >/dev/null 2>&1; then
    PYBIN="python"
  elif command -v python3 >/dev/null 2>&1; then
    PYBIN="python3"
  else
    echo "ERROR: cần jq hoặc python" >&2; exit 127
  fi
  JSON_BACKEND="python"
fi

case "$OP" in
  set)
    JSONPATH="$1"; VALUE="$2"
    if [ "$JSON_BACKEND" = "jq" ]; then
      TMP=$(mktemp)
      jq --argjson v "$VALUE" "$JSONPATH = \$v" "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
    else
      "$PYBIN" "$SCRIPT_DIR/_json_op.py" set "$MANIFEST" "$JSONPATH" "$VALUE"
    fi
    ;;
  inc)
    JSONPATH="$1"
    if [ "$JSON_BACKEND" = "jq" ]; then
      TMP=$(mktemp)
      jq "$JSONPATH += 1" "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
    else
      "$PYBIN" "$SCRIPT_DIR/_json_op.py" inc "$MANIFEST" "$JSONPATH"
    fi
    ;;
  jq)
    [ "$JSON_BACKEND" = "jq" ] || { echo "ERROR: jq backend not available" >&2; exit 1; }
    EXPR="$1"
    TMP=$(mktemp)
    jq "$EXPR" "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
    ;;
  *)
    echo "ERROR: unknown op: $OP (use set/inc/jq)" >&2; exit 2 ;;
esac

cat "$MANIFEST"
