#!/usr/bin/env bash
# save.sh <run_id> <step_name> <payload_path>
# Copy payload vào .pipeline_state/{run_id}/step_NN_{step_name}.json
# Cập nhật manifest.current_step + completed_steps.
# Prints saved file path.

set -euo pipefail

RUN_ID="$1"
STEP_NAME="$2"
PAYLOAD_PATH="$3"

DIR=".pipeline_state/$RUN_ID"
[ -d "$DIR" ] || { echo "ERROR: run_id not found: $RUN_ID" >&2; exit 1; }
[ -f "$PAYLOAD_PATH" ] || { echo "ERROR: payload not found: $PAYLOAD_PATH" >&2; exit 1; }

case "$STEP_NAME" in
  input)                    PREFIX="00" ;;
  business_analyst)         PREFIX="01" ;;
  capability_clusterer)     PREFIX="02" ;;
  technology_researcher)    PREFIX="03" ;;
  solution_architect)       PREFIX="04" ;;
  technical_reviewer_r*)    PREFIX="05" ;;
  technical_writer)         PREFIX="06" ;;
  *) echo "ERROR: unknown step_name: $STEP_NAME" >&2; exit 1 ;;
esac

DEST="$DIR/step_${PREFIX}_${STEP_NAME}.json"

# Detect JSON backend
if command -v jq >/dev/null 2>&1; then
  JSON_BACKEND="jq"
else
  # Ưu tiên 'python' (Windows + Linux), fallback 'python3'
  if command -v python >/dev/null 2>&1; then
    PYBIN="python"
  elif command -v python3 >/dev/null 2>&1; then
    PYBIN="python3"
  else
    echo "ERROR: cần jq hoặc python" >&2; exit 127
  fi
  JSON_BACKEND="python"
fi

# Validate JSON
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$JSON_BACKEND" = "jq" ]; then
  jq empty "$PAYLOAD_PATH" 2>/dev/null || { echo "ERROR: payload is not valid JSON: $PAYLOAD_PATH" >&2; exit 2; }
else
  "$PYBIN" "$SCRIPT_DIR/_json_op.py" validate "$PAYLOAD_PATH" || { echo "ERROR: payload is not valid JSON" >&2; exit 2; }
fi

cp "$PAYLOAD_PATH" "$DEST"

# Update manifest: add to completed_steps, set current_step
MANIFEST="$DIR/manifest.json"
if [ "$JSON_BACKEND" = "jq" ]; then
  TMP=$(mktemp)
  jq --arg s "$STEP_NAME" '
    .current_step = $s
    | .completed_steps = ((.completed_steps // []) + [$s] | unique_by(.))
    | .status = "RUNNING"
  ' "$MANIFEST" > "$TMP" && mv "$TMP" "$MANIFEST"
else
  "$PYBIN" "$SCRIPT_DIR/_json_op.py" add_step "$MANIFEST" "$STEP_NAME"
fi

echo "$DEST"
