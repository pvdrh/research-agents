#!/usr/bin/env bash
# summarize.sh <run_id>
# Parse logs/{run_id}/run.log → logs/{run_id}/tokens.json (cost report).

set -euo pipefail

RUN_ID="$1"
LOG="logs/$RUN_ID/run.log"
OUT="logs/$RUN_ID/tokens.json"

[ -f "$LOG" ] || { echo "ERROR: log not found: $LOG" >&2; exit 1; }

# Extract STEP_OK lines, parse tokens_in / tokens_out / duration_s / step
# Sum by step (in case có retry → cộng dồn)
awk -F' \\| ' '
  /STEP_OK/ {
    step=""; ti=0; to=0; ds=0
    for (i=4; i<=NF; i++) {
      split($i, kv, "=")
      if (kv[1]=="step") step=kv[2]
      else if (kv[1]=="tokens_in") ti=kv[2]+0
      else if (kv[1]=="tokens_out") to=kv[2]+0
      else if (kv[1]=="duration_s") ds=kv[2]+0
    }
    if (step != "") {
      step_in[step] += ti
      step_out[step] += to
      step_dur[step] += ds
      step_count[step] += 1
    }
  }
  /RETRY/ {
    step=""
    for (i=4; i<=NF; i++) {
      split($i, kv, "=")
      if (kv[1]=="step") step=kv[2]
    }
    if (step != "") retry_count[step] += 1
  }
  /END/ {
    for (i=4; i<=NF; i++) {
      split($i, kv, "=")
      if (kv[1]=="verdict") verdict=kv[2]
      else if (kv[1]=="total_tokens") tt=kv[2]+0
      else if (kv[1]=="total_duration_s") td=kv[2]+0
    }
  }
  END {
    print "{"
    print "  \"run_id\": \"'"$RUN_ID"'\","
    print "  \"verdict\": \"" (verdict ? verdict : "UNKNOWN") "\","
    total_in = 0; total_out = 0; total_dur = 0; retry_total = 0
    for (s in step_in) { total_in += step_in[s]; total_out += step_out[s]; total_dur += step_dur[s] }
    for (s in retry_count) { retry_total += retry_count[s] }
    print "  \"total_tokens_in\": " total_in ","
    print "  \"total_tokens_out\": " total_out ","
    print "  \"total_tokens\": " (total_in + total_out) ","
    print "  \"total_duration_s\": " total_dur ","
    print "  \"retry_total\": " retry_total ","
    print "  \"per_step\": ["
    first = 1
    for (s in step_in) {
      if (!first) print ","
      first = 0
      printf "    {\"step\": \"%s\", \"tokens_in\": %d, \"tokens_out\": %d, \"duration_s\": %d, \"retries\": %d}", s, step_in[s], step_out[s], step_dur[s], (retry_count[s] ? retry_count[s] : 0)
    }
    print ""
    print "  ]"
    print "}"
  }
' "$LOG" > "$OUT"

cat "$OUT"
