#!/usr/bin/env bash
# run_check.sh <run_id> <step_name>
# Bash wrapper: bootstrap venv + run validate.py. Output JSON stdout.

set -euo pipefail

RUN_ID="$1"
STEP_NAME="$2"

# Activate venv (Windows hoặc POSIX)
if [ -f .venv/Scripts/activate ]; then
  source .venv/Scripts/activate
elif [ -f .venv/bin/activate ]; then
  source .venv/bin/activate
fi

# Choose python
if command -v python >/dev/null 2>&1; then
  PYBIN="python"
elif command -v python3 >/dev/null 2>&1; then
  PYBIN="python3"
else
  echo '{"valid":false,"errors":[{"code":"NO_PYTHON","msg":"cần Python 3.10+"}]}'
  exit 2
fi

# Lazy install jsonschema nếu chưa có
"$PYBIN" -c "import jsonschema" 2>/dev/null || "$PYBIN" -m pip install --quiet jsonschema || {
  echo '{"valid":false,"errors":[{"code":"PIP_INSTALL_FAIL","msg":"không cài được jsonschema"}]}'
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$PYBIN" "$SCRIPT_DIR/validate.py" "$RUN_ID" "$STEP_NAME"
