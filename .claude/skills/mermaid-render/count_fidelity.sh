#!/usr/bin/env bash
# count_fidelity.sh <html_path> <expected_count>
# Count `class="mermaid"` occurrences in HTML file vs expected.
# Pass when actual >= 85% of expected.

set -euo pipefail

HTML_PATH="$1"
EXPECTED="$2"

[ -f "$HTML_PATH" ] || { echo "{\"ok\":false,\"error\":\"FILE_NOT_FOUND\",\"path\":\"$HTML_PATH\"}"; exit 2; }

# -o = print each match on its own line; -c trên dòng → đếm match thực
ACTUAL=$(grep -o 'class="mermaid"' "$HTML_PATH" | wc -l | tr -d ' ')
ACTUAL=${ACTUAL:-0}
THRESHOLD=$(( EXPECTED * 85 / 100 ))

if [ "$ACTUAL" -ge "$THRESHOLD" ]; then
  echo "{\"ok\":true,\"actual\":$ACTUAL,\"expected\":$EXPECTED,\"threshold\":$THRESHOLD}"
  exit 0
else
  echo "{\"ok\":false,\"actual\":$ACTUAL,\"expected\":$EXPECTED,\"threshold\":$THRESHOLD,\"missing\":$((THRESHOLD - ACTUAL))}"
  exit 1
fi
