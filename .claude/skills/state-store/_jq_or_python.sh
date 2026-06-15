#!/usr/bin/env bash
# _jq_or_python.sh — helper: dùng jq nếu có, fallback Python (đã có sẵn .venv hoặc system).
# Usage:
#   source _jq_or_python.sh
#   jq_filter '<filter>' < input.json > output.json
#   jq_merge '<filter>' '--arg key value' < input.json
#
# Phục vụ các script state-store/observability để chạy được kể cả khi máy không có jq.

set -euo pipefail

# Detect once
if command -v jq >/dev/null 2>&1; then
  _JSON_BACKEND="jq"
elif command -v python >/dev/null 2>&1; then
  _JSON_BACKEND="python"
elif command -v python3 >/dev/null 2>&1; then
  _JSON_BACKEND="python3"
else
  echo "ERROR: cần jq HOẶC python. Cài: winget install jqlang.jq  (Windows) hoặc apt install jq (Linux)" >&2
  exit 127
fi

# Run filter qua stdin, in ra stdout
jq_filter() {
  local filter="$1"; shift
  if [ "$_JSON_BACKEND" = "jq" ]; then
    jq "$@" "$filter"
  else
    # Python fallback dùng jsonpath đơn giản qua eval của filter dạng "."<path>
    # Đối với các filter phức tạp orchestrator phải dùng python script riêng.
    # Ở đây hỗ trợ subset: .field, .field.sub, .[i], assignments .field = "value".
    local pybin
    pybin=$(command -v python || command -v python3)
    "$pybin" -c "
import sys, json, re
data = json.load(sys.stdin)
filt = '''$filter'''
# Trường hợp đơn giản: chỉ là 1 path '.foo.bar'
m = re.match(r'^\.([\w\.\[\]\"]+)\s*$', filt)
if m:
    path = m.group(1)
    cur = data
    for part in re.findall(r'(\w+)|\[(\d+)\]', path):
        key, idx = part
        if key: cur = cur.get(key) if isinstance(cur, dict) else None
        else: cur = cur[int(idx)] if isinstance(cur, list) else None
    print(json.dumps(cur, ensure_ascii=False))
else:
    # Trường hợp filter phức tạp — orchestrator dùng python_inline.sh thay vì hàm này
    print('UNSUPPORTED_FILTER_FOR_PYTHON_FALLBACK', file=sys.stderr)
    sys.exit(99)
"
  fi
}

# Empty/validate JSON
jq_empty() {
  if [ "$_JSON_BACKEND" = "jq" ]; then
    jq empty "$@"
  else
    local pybin
    pybin=$(command -v python || command -v python3)
    "$pybin" -c "import sys,json; json.load(open(sys.argv[1])) if len(sys.argv)>1 else json.load(sys.stdin)" "$@"
  fi
}
