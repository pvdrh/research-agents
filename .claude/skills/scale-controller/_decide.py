#!/usr/bin/env python3
"""_decide.py <run_id> <ba_file>: quyết định strategy + chunks."""
import sys, json, math, subprocess
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

CHUNK_SIZE = 15

def main():
    run_id, ba_file = sys.argv[1], sys.argv[2]
    with open(ba_file, 'r', encoding='utf-8') as f:
        ba = json.load(f)

    cases = ba.get("cases", []) or []
    n = len(cases)

    if n <= 15:
        strategy = "full"
        chunks_count = 1
        chunks = [{"index": 0, "case_ids": [c.get("id") for c in cases]}]
    elif n <= 49:
        strategy = "canonical_reuse"
        chunks_count = 1
        chunks = [{"index": 0, "case_ids": [c.get("id") for c in cases]}]
    else:
        strategy = "map_reduce"
        chunks_count = math.ceil(n / CHUNK_SIZE)
        chunks = []
        for i in range(chunks_count):
            chunk_cases = cases[i*CHUNK_SIZE:(i+1)*CHUNK_SIZE]
            chunks.append({
                "index": i,
                "case_ids": [c.get("id") for c in chunk_cases],
            })

    out = {
        "strategy": strategy,
        "n_cases": n,
        "chunks_count": chunks_count,
        "chunks": chunks,
    }

    # Update manifest
    state_dir = Path(".pipeline_state") / run_id
    manifest_path = state_dir / "manifest.json"
    if manifest_path.exists():
        with open(manifest_path, 'r', encoding='utf-8') as f:
            m = json.load(f)
        m["strategy"] = strategy
        m["n_cases"] = n
        m["chunks_count"] = chunks_count
        with open(manifest_path, 'w', encoding='utf-8') as f:
            json.dump(m, f, ensure_ascii=False, indent=2)

    # Log event qua observability
    try:
        subprocess.run(
            ["bash", ".claude/skills/observability/log_event.sh", run_id, "STRATEGY",
             f"n_cases={n}", f"strategy={strategy}", f"chunks_count={chunks_count}"],
            check=False,
        )
    except Exception:
        pass

    print(json.dumps(out, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
