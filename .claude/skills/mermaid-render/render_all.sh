#!/usr/bin/env bash
# render_all.sh <run_id> <step_name>
# Render mọi Mermaid diagram trong step file qua npx mermaid-cli.
# HARD FAIL nếu npx/Node.js không có.

set -uo pipefail

RUN_ID="$1"
STEP_NAME="$2"

# 1. Check Node.js + npx
if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
  cat <<EOF
{
  "valid": false,
  "step": "$STEP_NAME",
  "error": "MISSING_NODE_NPX",
  "msg": "Cài Node.js: winget install OpenJS.NodeJS, sau đó: npx -y @mermaid-js/mermaid-cli --help"
}
EOF
  exit 2
fi

# 2. Locate step file
STEP_FILE=$(bash .claude/skills/state-store/load.sh "$RUN_ID" "$STEP_NAME")
if [ -z "$STEP_FILE" ] || [ ! -f "$STEP_FILE" ]; then
  echo "{\"valid\":false,\"error\":\"STEP_FILE_NOT_FOUND\",\"step\":\"$STEP_NAME\"}"
  exit 2
fi

# 3. Python extract + render (đặt logic Python ở file riêng cho gọn)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v python >/dev/null 2>&1; then
  PYBIN="python"
elif command -v python3 >/dev/null 2>&1; then
  PYBIN="python3"
else
  echo '{"valid":false,"error":"NO_PYTHON"}'; exit 2
fi

"$PYBIN" "$SCRIPT_DIR/extract_and_render.py" "$RUN_ID" "$STEP_NAME" "$STEP_FILE"
