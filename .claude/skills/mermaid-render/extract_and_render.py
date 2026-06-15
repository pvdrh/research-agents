#!/usr/bin/env python3
"""
extract_and_render.py <run_id> <step_name> <step_file_path>
Extract mọi Mermaid diagram trong step file, render qua npx mermaid-cli.
In JSON stdout, exit 0 valid / 1 invalid.
"""

import sys, os, json, re, subprocess, tempfile, time
from pathlib import Path

# UTF-8 stdout (Windows console)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

MERMAID_FIELD_PATTERNS = [
    r".*_mmd$",
    r"^internal_mermaid$",
    r"^fmd$",
    r"^mmd$",
]
MERMAID_FIELD_RE = re.compile("|".join(MERMAID_FIELD_PATTERNS))

REUSE_PATTERN = re.compile(r"^reuse:", re.IGNORECASE)

def is_mermaid_field(key):
    if not isinstance(key, str):
        return False
    return bool(MERMAID_FIELD_RE.match(key))

def walk(obj, path, results):
    """Đệ quy, thu thập (path, code) cho field mermaid."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            new_path = f"{path}.{k}" if path else k
            if is_mermaid_field(k) and isinstance(v, str):
                results.append((new_path, v))
            elif k == "mermaid_diagrams" and isinstance(v, list):
                # [{"type","title","code"}]
                for i, d in enumerate(v):
                    if isinstance(d, dict) and isinstance(d.get("code"), str):
                        results.append((f"{new_path}[{i}].code", d["code"]))
            else:
                walk(v, new_path, results)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            walk(item, f"{path}[{i}]", results)

def render_one(code, idx, run_id):
    """Run npx mermaid-cli. Return (ok: bool, err: str)."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.mmd', delete=False, encoding='utf-8') as f:
        f.write(code)
        mmd_path = f.name
    svg_path = mmd_path.replace('.mmd', '.svg')

    try:
        proc = subprocess.run(
            ["npx", "-y", "@mermaid-js/mermaid-cli", "-i", mmd_path, "-o", svg_path, "-q"],
            capture_output=True, text=True, timeout=60, shell=False,
        )
        if proc.returncode == 0 and os.path.exists(svg_path):
            return True, ""
        else:
            err = (proc.stderr or proc.stdout or "render failed").strip()
            # Trim to 300 chars
            return False, err[:300]
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT after 60s"
    except FileNotFoundError:
        return False, "npx not found"
    except Exception as e:
        return False, f"exception: {e}"
    finally:
        try:
            os.remove(mmd_path)
            if os.path.exists(svg_path):
                os.remove(svg_path)
        except OSError:
            pass

def main():
    if len(sys.argv) < 4:
        print('{"valid":false,"error":"USAGE","msg":"<run_id> <step_name> <step_file>"}')
        sys.exit(2)

    run_id, step_name, step_file = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(step_file, 'r', encoding='utf-8') as f:
        data = json.load(f)

    diagrams = []
    walk(data, "", diagrams)

    skipped_reuse = 0
    to_render = []
    for path, code in diagrams:
        if not code or not code.strip():
            continue
        if REUSE_PATTERN.match(code.strip()):
            skipped_reuse += 1
            continue
        to_render.append((path, code))

    start = time.time()
    failed = []
    rendered = 0
    for path, code in to_render:
        ok, err = render_one(code, len(failed) + rendered, run_id)
        if ok:
            rendered += 1
        else:
            snippet = code.strip().splitlines()[0:3]
            failed.append({
                "path": path,
                "code_snippet": "\n".join(snippet)[:200],
                "error": err,
            })

    duration = int(time.time() - start)
    valid = len(failed) == 0
    out = {
        "valid": valid,
        "step": step_name,
        "total": len(to_render) + skipped_reuse,
        "rendered": rendered,
        "skipped_reuse": skipped_reuse,
        "failed": failed,
        "duration_s": duration,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0 if valid else 1)

if __name__ == "__main__":
    main()
