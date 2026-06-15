#!/usr/bin/env python3
"""
merge_chunks.py <run_id>

Đọc các file step_04_solution_architect_chunk_{i}.json đã save bởi orchestrator
→ merge thành step_04_solution_architect.json.

Quy tắc:
- cases[]: concat từ mọi chunk, validate không trùng id, tổng = manifest.n_cases.
- capabilities, overall, nfr_matrix, data_architecture, security_compliance, operational_view,
  risk_register, cost_breakdown, key_design_decisions, architecture_style, build_priority, precheck:
    lấy từ chunk 0.
- _meta: tokens_in/tokens_out/duration_s cộng dồn; model = chunk 0.
"""
import sys, os, json, glob
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

CHUNK_0_KEYS = [
    "mode", "precheck", "architecture_style", "build_priority", "capabilities",
    "overall", "nfr_matrix", "data_architecture", "security_compliance",
    "operational_view", "risk_register", "cost_breakdown", "key_design_decisions",
]

def main():
    if len(sys.argv) < 2:
        print('{"error":"USAGE: merge_chunks.py <run_id>"}'); sys.exit(2)
    run_id = sys.argv[1]
    state_dir = Path(".pipeline_state") / run_id

    chunk_files = sorted(glob.glob(str(state_dir / "step_04_solution_architect_chunk_*.json")))
    if not chunk_files:
        print('{"error":"NO_CHUNKS","msg":"không tìm thấy chunk file"}'); sys.exit(2)

    with open(state_dir / "manifest.json", 'r', encoding='utf-8') as f:
        manifest = json.load(f)
    expected_n = manifest.get("n_cases", 0)

    chunks = []
    for cf in chunk_files:
        with open(cf, 'r', encoding='utf-8') as f:
            chunks.append(json.load(f))

    # Base = chunk 0 (full context)
    merged = {k: chunks[0].get(k) for k in CHUNK_0_KEYS if k in chunks[0]}

    # Concat cases
    all_cases = []
    seen_ids = set()
    for ci, ch in enumerate(chunks):
        for case in (ch.get("cases", []) or []):
            cid = case.get("id")
            if cid in seen_ids:
                print(json.dumps({
                    "error": "DUPLICATE_CASE_ID",
                    "case_id": cid,
                    "in_chunk": ci,
                }, ensure_ascii=False)); sys.exit(2)
            seen_ids.add(cid)
            all_cases.append(case)
    merged["cases"] = all_cases

    if expected_n and len(all_cases) != expected_n:
        print(json.dumps({
            "error": "CASE_COUNT_MISMATCH",
            "expected": expected_n,
            "got": len(all_cases),
        }, ensure_ascii=False)); sys.exit(2)

    # Merge _meta: sum tokens
    tin = tout = dur = 0
    model = chunks[0].get("_meta", {}).get("model", "sonnet")
    for ch in chunks:
        meta = ch.get("_meta", {}) or {}
        tin += meta.get("tokens_in") or 0
        tout += meta.get("tokens_out") or 0
        dur += meta.get("duration_s") or 0
    merged["_meta"] = {
        "tokens_in": tin,
        "tokens_out": tout,
        "duration_s": dur,
        "model": model,
        "merged_from_chunks": len(chunks),
    }

    # Write merged file vào path chuẩn
    out_path = state_dir / "step_04_solution_architect.json"
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)

    result = {
        "ok": True,
        "merged_path": str(out_path),
        "total_cases": len(all_cases),
        "chunks_merged": len(chunks),
        "total_tokens_in": tin,
        "total_tokens_out": tout,
        "total_duration_s": dur,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
