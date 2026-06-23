#!/usr/bin/env bash
# aggregate_panel.sh <run_id> <round>
# Gom các file step_05_technical_reviewer_persona_{CODE}_r{ROUND}.json (N+1 file)
# → 1 file step_05_technical_reviewer_r{ROUND}.json đúng schema reviewer_v2.json.
#
# Logic aggregate:
# - panel[]            : từ status mỗi persona
# - panel_veto         : triggered nếu ≥1 persona có issue blocker (Phase 3 rule)
# - verdict            : REVISION_REQUIRED nếu có blocker; ngược lại APPROVED
# - case_adjustments[] : dedupe theo case_id; nhiều persona đặt cho cùng case → giữ new_potential THẤP NHẤT
# - capability_verdicts: dedupe theo id; conflict → ADJ ưu tiên hơn OK
# - issues[]           : dedupe theo (target_agent, category, prefix 60 ký tự description)
# - regression_check   : so với r{ROUND-1} (đã aggregated) nếu có
#
# Output: stdout = path file aggregated.

set -uo pipefail

RUN_ID="${1:-}"
ROUND="${2:-1}"

[ -z "$RUN_ID" ] && { echo "usage: $0 <run_id> <round>" >&2; exit 1; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.pipeline_state/$RUN_ID"
[ -d "$STATE_DIR" ] || { echo "state dir not found: $STATE_DIR" >&2; exit 1; }

# Tìm persona files của round này
PERSONA_FILES=("$STATE_DIR"/step_05_technical_reviewer_persona_*_r${ROUND}.json)
if [ ! -f "${PERSONA_FILES[0]}" ]; then
  echo "no persona files for round $ROUND" >&2
  exit 1
fi

# Python aggregator
PYBIN=""
command -v python  >/dev/null 2>&1 && PYBIN="python"
[ -z "$PYBIN" ] && command -v python3 >/dev/null 2>&1 && PYBIN="python3"
[ -z "$PYBIN" ] && { echo "need python" >&2; exit 2; }

PRIOR_FILE=""
if [ "$ROUND" -gt 1 ]; then
  PRIOR_FILE="$STATE_DIR/step_05_technical_reviewer_r$((ROUND-1)).json"
  [ -f "$PRIOR_FILE" ] || PRIOR_FILE=""
fi

OUT_FILE="$STATE_DIR/step_05_technical_reviewer_r${ROUND}.json"
MANIFEST="$STATE_DIR/manifest.json"

"$PYBIN" - "$RUN_ID" "$ROUND" "$OUT_FILE" "$MANIFEST" "$PRIOR_FILE" "${PERSONA_FILES[@]}" <<'PYEOF'
import json, sys, os, glob, datetime

run_id   = sys.argv[1]
round_n  = int(sys.argv[2])
out_file = sys.argv[3]
manifest = sys.argv[4]
prior    = sys.argv[5]
files    = sys.argv[6:]

personas       = []
case_adj_map   = {}   # case_id -> dict (giữ new_potential thấp nhất)
cap_verdict_map= {}   # id -> dict
issues_seen    = set()
issues         = []
total_tok_in   = 0
total_tok_out  = 0
total_dur      = 0
has_blocker    = False
veto_by        = None
veto_reason    = None

for f in files:
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception as e:
        print(f"skip {f}: {e}", file=sys.stderr); continue

    p = d.get("persona") or {}
    code = p.get("code","?")
    status = d.get("status","OK")
    personas.append({
        "code": code,
        "name": p.get("name", code),
        "focus": p.get("focus",""),
        "status": status,
        "comment": d.get("comment",""),
        "mandatory": p.get("mandatory", code == "RED")
    })

    # case adjustments
    for ca in d.get("case_adjustments", []) or []:
        cid = ca.get("case_id")
        if not cid: continue
        ca = dict(ca); ca["by"] = code
        if cid in case_adj_map:
            prev = case_adj_map[cid]
            # Giữ new_potential thấp hơn
            if (ca.get("new_potential") or 1.0) < (prev.get("new_potential") or 1.0):
                case_adj_map[cid] = ca
            # excl=true có ưu tiên
            if ca.get("excl"):
                case_adj_map[cid]["excl"] = True
                case_adj_map[cid]["reason"] = ca.get("reason") or prev.get("reason","")
        else:
            case_adj_map[cid] = ca

    # capability verdicts — ADJ thắng OK
    for cv in d.get("capability_verdicts", []) or []:
        cid = cv.get("id")
        if not cid: continue
        if cid in cap_verdict_map:
            if cv.get("status") == "ADJ" and cap_verdict_map[cid].get("status") == "OK":
                cap_verdict_map[cid] = cv
        else:
            cap_verdict_map[cid] = cv

    # issues — dedupe key = (target, category, desc[:60])
    for iss in d.get("issues", []) or []:
        sev = iss.get("severity","")
        if sev == "blocker":
            has_blocker = True
            if veto_by is None:
                veto_by = code
                veto_reason = iss.get("description","")
        key = (
            iss.get("target_agent",""),
            iss.get("category",""),
            (iss.get("description","") or "")[:60].strip().lower()
        )
        if key not in issues_seen:
            issues_seen.add(key)
            iss = dict(iss); iss["raised_by"] = code
            issues.append(iss)

    # meta
    m = d.get("_meta", {}) or {}
    total_tok_in  += int(m.get("tokens_in")  or 0)
    total_tok_out += int(m.get("tokens_out") or 0)
    total_dur     += int(m.get("duration_s") or 0)

# Verdict
verdict = "REVISION_REQUIRED" if has_blocker else ("REVISION_REQUIRED" if issues else "APPROVED")
# Nếu có major và còn retry quota → REVISION_REQUIRED (orchestrator quyết quota; ở đây mặc định REVISION nếu issues)
# Nếu chỉ minor và 0 blocker → APPROVED. Đơn giản hóa:
if not issues:
    verdict = "APPROVED"
else:
    sevs = {i.get("severity") for i in issues}
    if "blocker" in sevs or "major" in sevs:
        verdict = "REVISION_REQUIRED"
    else:
        verdict = "APPROVED"

panel_veto = {
    "triggered": has_blocker,
    "by_persona": veto_by,
    "severity": "blocker" if has_blocker else None,
    "reason": veto_reason
}

# retry_count from manifest
retry_count_after = {}
try:
    mf = json.load(open(manifest, encoding="utf-8"))
    rc = mf.get("retry_count", {})
    for k in ("business-analyst","capability-clusterer","technology-researcher","solution-architect"):
        retry_count_after[k] = rc.get(k, 0)
except Exception:
    pass

# Regression check vs prior aggregated
regression_check = {
    "compared_to_round": (round_n - 1) if round_n > 1 and prior else None,
    "new_issues_from_prior_fix": [],
    "regression_count": 0
}
if prior and os.path.exists(prior):
    try:
        prev = json.load(open(prior, encoding="utf-8"))
        prev_issues = prev.get("issues", []) or []
        prev_keys = {(i.get("target_agent",""), i.get("category",""), (i.get("description","") or "")[:60].lower())
                     for i in prev_issues}
        # Issues mới xuất hiện round này
        for iss in issues:
            key = (iss.get("target_agent",""), iss.get("category",""),
                   (iss.get("description","") or "")[:60].lower())
            if key not in prev_keys:
                # Heuristic: previously_ok=true nếu round trước có target_agent này nhưng category khác
                prev_targets = {i.get("target_agent") for i in prev_issues}
                regression_check["new_issues_from_prior_fix"].append({
                    "category": iss.get("category",""),
                    "description": iss.get("description",""),
                    "previously_ok": iss.get("target_agent") not in prev_targets,
                    "caused_by_target": iss.get("target_agent","")
                })
        regression_check["regression_count"] = len(regression_check["new_issues_from_prior_fix"])
    except Exception as e:
        print(f"prior compare failed: {e}", file=sys.stderr)

aggregated = {
    "mode": "batch",
    "verdict": verdict,
    "panel": personas,
    "panel_veto": panel_veto,
    "case_adjustments": list(case_adj_map.values()),
    "capability_verdicts": list(cap_verdict_map.values()),
    "issues": issues,
    "regression_check": regression_check,
    "retry_count_after_this_round": retry_count_after,
    "_meta": {
        "tokens_in": total_tok_in,
        "tokens_out": total_tok_out,
        "duration_s": total_dur,
        "model": "sonnet",
        "aggregated_from": [os.path.basename(f) for f in files],
        "aggregated_at": datetime.datetime.utcnow().isoformat() + "Z"
    }
}

# Atomic write
tmp = out_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(aggregated, fh, ensure_ascii=False, indent=2)
os.replace(tmp, out_file)

print(out_file)
PYEOF
