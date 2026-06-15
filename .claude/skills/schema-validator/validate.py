#!/usr/bin/env python3
"""
validate.py — schema validator engine.
Args:
  validate.py <run_id> <step_name>

Đọc:
  .pipeline_state/{run_id}/manifest.json
  .pipeline_state/{run_id}/step_NN_{step_name}.json  (output cần check)
  .pipeline_state/{run_id}/step_NN_{previous_round}.json (nếu retry, cho ID stability)
  schemas/{step_short}_v{mode_version}.json

In ra stdout JSON {valid, step, checks_run, errors, warnings}.
Exit code: 0 valid, 1 invalid, 2 internal.
"""

import sys, os, json, glob
from pathlib import Path

# Force UTF-8 stdout (Windows console mặc định cp1252)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

SCRIPT_DIR = Path(__file__).parent
SCHEMAS_DIR = SCRIPT_DIR / "schemas"

# Map step_name → schema short
SCHEMA_MAP = {
    "business_analyst":      ("ba",         True),    # SINGLE/BATCH
    "capability_clusterer":  ("clusterer",  False),   # BATCH only
    "technology_researcher": ("researcher", True),
    "solution_architect":    ("architect",  True),
    # technical_reviewer: handled separately (r1, r2, ...)
}

def emit(valid, step, checks_run, errors, warnings):
    out = {
        "valid": valid,
        "step": step,
        "checks_run": checks_run,
        "errors": errors,
        "warnings": warnings,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0 if valid else 1)

def err_internal(msg):
    print(json.dumps({"valid": False, "errors":[{"code":"INTERNAL","msg":msg}]}, ensure_ascii=False))
    sys.exit(2)

def load_json(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        err_internal(f"cannot load {path}: {e}")

def detect_mode(output, manifest):
    m = output.get("mode") or manifest.get("mode")
    if m in ("single", "batch"):
        return m
    return None

def find_step_file(state_dir, step_name):
    """Return path to step_NN_{step_name}.json or step_NN_{step_name}_rN.json (reviewer)."""
    if step_name.startswith("technical_reviewer"):
        files = sorted(glob.glob(str(state_dir / "step_05_technical_reviewer_r*.json")))
        return files[-1] if files else None
    candidates = sorted(glob.glob(str(state_dir / f"step_*_{step_name}.json")))
    return candidates[-1] if candidates else None

def find_prev_step_file(state_dir, step_name, current_path):
    """Return previous round file của cùng agent."""
    if step_name.startswith("technical_reviewer"):
        files = sorted(glob.glob(str(state_dir / "step_05_technical_reviewer_r*.json")))
        if len(files) >= 2:
            return files[-2]
        return None
    # Non-reviewer: chỉ có 1 file (overwrite mỗi lần retry). Phase 1 design này KHÔNG giữ
    # snapshot round trước cho non-reviewer. Bỏ qua ID stability check cho non-reviewer ở Phase 2.
    return None

# ====== Lớp 1: JSON Schema ======

def check_json_schema(output, schema_path):
    """Return (errors, warnings) list."""
    try:
        import jsonschema
    except ImportError:
        # Lazy install
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "jsonschema"])
        import jsonschema

    if not schema_path.exists():
        return [], [{"code":"NO_SCHEMA","msg":f"schema file missing: {schema_path}"}]

    with open(schema_path, 'r', encoding='utf-8') as f:
        schema = json.load(f)

    errors = []
    validator = jsonschema.Draft202012Validator(schema)
    for e in validator.iter_errors(output):
        path = "/" + "/".join(str(p) for p in e.absolute_path) if e.absolute_path else "/"
        errors.append({
            "code": "SCHEMA_VIOLATION",
            "path": path,
            "msg": e.message[:200],
        })
    return errors, []

# ====== Lớp 2: DAG ======

def check_dag(output, step_name):
    """Apply cho clusterer + architect.
    Detect cycle, asymmetry, topo violation."""
    errors = []

    caps = output.get("capabilities") if step_name == "capability_clusterer" else output.get("capabilities", [])
    if not caps:
        return []

    cap_by_id = {c["id"]: c for c in caps if isinstance(c, dict) and "id" in c}

    # Cycle detection (DFS, color marking)
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {cid: WHITE for cid in cap_by_id}
    cycle = []

    def dfs(cid, stack):
        color[cid] = GRAY
        for dep in cap_by_id.get(cid, {}).get("deps", []) or []:
            if dep not in cap_by_id:
                continue
            if color[dep] == GRAY:
                idx = stack.index(dep) if dep in stack else 0
                cycle.extend(stack[idx:] + [dep])
                return True
            if color[dep] == WHITE:
                if dfs(dep, stack + [dep]):
                    return True
        color[cid] = BLACK
        return False

    for cid in list(cap_by_id):
        if color[cid] == WHITE:
            if dfs(cid, [cid]):
                break

    if cycle:
        errors.append({
            "code": "DAG_CYCLE",
            "path": f"capabilities[{cycle[0]}].deps",
            "msg": f"Cycle detected: {' → '.join(cycle)}",
        })

    # Symmetry: enables ↔ deps
    for cid, c in cap_by_id.items():
        enables = c.get("enables", []) or []
        for eid in enables:
            other = cap_by_id.get(eid)
            if not other:
                errors.append({
                    "code": "ASYM_DEP",
                    "path": f"capabilities[{cid}].enables",
                    "msg": f"{cid}.enables chứa {eid} nhưng {eid} không tồn tại trong capabilities[]",
                })
                continue
            if cid not in (other.get("deps", []) or []):
                errors.append({
                    "code": "ASYM_DEP",
                    "path": f"capabilities[{cid}].enables",
                    "msg": f"{cid}.enables=[{eid}] nhưng {eid}.deps không chứa {cid}",
                })

    # Topo order (chỉ architect có build_order)
    if step_name == "solution_architect":
        bp = output.get("build_priority", {})
        oc = bp.get("ordered_capabilities", []) or []
        order_by_id = {x["id"]: x.get("build_order") for x in oc if isinstance(x, dict) and "id" in x}
        for cid, c in cap_by_id.items():
            my_order = order_by_id.get(cid)
            if my_order is None:
                continue
            for dep in (c.get("deps", []) or []):
                dep_order = order_by_id.get(dep)
                if dep_order is None:
                    continue
                if dep_order >= my_order:
                    errors.append({
                        "code": "TOPO_VIOLATION",
                        "path": f"build_priority.ordered_capabilities.{cid}",
                        "msg": f"{cid}.build_order={my_order} nhưng dependency {dep}.build_order={dep_order} (phải nhỏ hơn)",
                    })

    return errors

# ====== Lớp 3: ID stability ======

def check_id_stability(output, prev_output, step_name):
    """So output round hiện tại với round trước. Vi phạm = id biến mất / đổi."""
    if prev_output is None:
        return []
    errors = []

    if step_name == "business_analyst" and output.get("mode") == "batch":
        prev_cases = prev_output.get("cases", []) or []
        cur_cases = output.get("cases", []) or []
        prev_ids = {c.get("id") for c in prev_cases}
        cur_ids = {c.get("id") for c in cur_cases}
        missing = prev_ids - cur_ids
        if missing:
            errors.append({
                "code": "ID_INSTABILITY",
                "path": "cases[]",
                "msg": f"BA round trước có case ID {sorted(missing)} bị xoá ở round này",
            })
        if len(cur_cases) < len(prev_cases):
            errors.append({
                "code": "ID_INSTABILITY",
                "path": "cases[]",
                "msg": f"Số case giảm: {len(prev_cases)} → {len(cur_cases)}",
            })

    if step_name == "capability_clusterer":
        prev_caps = prev_output.get("capabilities", []) or []
        cur_caps = output.get("capabilities", []) or []
        prev_ids = {c.get("id") for c in prev_caps}
        cur_ids = {c.get("id") for c in cur_caps}
        missing = prev_ids - cur_ids
        if missing:
            errors.append({
                "code": "ID_INSTABILITY",
                "path": "capabilities[]",
                "msg": f"Capability ID bị xoá: {sorted(missing)}",
            })

    return errors

# ====== Lớp 4: cross-agent reference ======

def check_xref(output, state_dir, step_name):
    """Architect ↔ BA ↔ Clusterer cross-reference (BATCH only)."""
    if step_name != "solution_architect":
        return []
    if output.get("mode") != "batch":
        return []

    errors = []

    # Load BA + Clusterer
    ba_file = sorted(glob.glob(str(state_dir / "step_01_business_analyst.json")))
    cl_file = sorted(glob.glob(str(state_dir / "step_02_capability_clusterer.json")))
    if not ba_file or not cl_file:
        return [{"code":"XREF_BROKEN","path":"","msg":"BA hoặc Clusterer output không tồn tại để check xref"}]

    ba = load_json(ba_file[0])
    cl = load_json(cl_file[0])

    ba_case_ids = {c.get("id") for c in ba.get("cases", []) or []}
    cl_cap_ids = {c.get("id") for c in cl.get("capabilities", []) or []}

    arch_cases = output.get("cases", []) or []
    arch_caps = output.get("capabilities", []) or []

    # len(architecture.cases) == len(BA.cases)
    if len(arch_cases) != len(ba_case_ids):
        errors.append({
            "code": "XREF_BROKEN",
            "path": "cases[]",
            "msg": f"Architect cases={len(arch_cases)} nhưng BA cases={len(ba_case_ids)}",
        })

    # Mỗi case.capability_ids ⊆ Clusterer's IDs
    for i, case in enumerate(arch_cases):
        cap_refs = case.get("capability_ids", []) or []
        unknown = [c for c in cap_refs if c not in cl_cap_ids]
        if unknown:
            errors.append({
                "code": "XREF_BROKEN",
                "path": f"cases[{i}].capability_ids",
                "msg": f"case {case.get('id')} reference capability không tồn tại: {unknown}",
            })

    # Bi-directional: capability.use_case_ids vs case.capability_ids
    case_by_id = {c.get("id"): c for c in arch_cases}
    for i, cap in enumerate(arch_caps):
        cap_id = cap.get("id")
        for case_id in (cap.get("use_case_ids", []) or []):
            if case_id not in case_by_id:
                errors.append({
                    "code": "XREF_BROKEN",
                    "path": f"capabilities[{i}].use_case_ids",
                    "msg": f"capability {cap_id}.use_case_ids reference case {case_id} không tồn tại",
                })
                continue
            case = case_by_id[case_id]
            if cap_id not in (case.get("capability_ids", []) or []):
                errors.append({
                    "code": "XREF_BROKEN",
                    "path": f"capabilities[{i}].use_case_ids[{case_id}]",
                    "msg": f"capability {cap_id} claim case {case_id} nhưng case {case_id}.capability_ids không chứa {cap_id}",
                })

    return errors

# ====== Main ======

def main():
    if len(sys.argv) < 3:
        print("usage: validate.py <run_id> <step_name>", file=sys.stderr)
        sys.exit(2)

    run_id = sys.argv[1]
    step_name = sys.argv[2]

    state_dir = Path(".pipeline_state") / run_id
    if not state_dir.exists():
        err_internal(f"state dir not found: {state_dir}")

    manifest = load_json(state_dir / "manifest.json")

    step_path = find_step_file(state_dir, step_name)
    if not step_path:
        err_internal(f"step file not found for {step_name}")

    output = load_json(step_path)

    mode = detect_mode(output, manifest)
    if not mode and step_name != "capability_clusterer":
        # No mode → skip với warning
        emit(True, step_name, [], [], [{"code":"NO_MODE","msg":"mode chưa xác định, skip JSON Schema check"}])

    all_errors = []
    all_warnings = []
    checks_run = []

    # Lớp 1
    if step_name in SCHEMA_MAP:
        short, has_mode_variant = SCHEMA_MAP[step_name]
        if has_mode_variant:
            mode_suffix = "v1" if mode == "single" else "v2"
            schema_path = SCHEMAS_DIR / f"{short}_{mode_suffix}.json"
        else:
            schema_path = SCHEMAS_DIR / f"{short}.json"
        errs, warns = check_json_schema(output, schema_path)
        all_errors.extend(errs)
        all_warnings.extend(warns)
        checks_run.append("json_schema")
    elif step_name.startswith("technical_reviewer"):
        mode_suffix = "v1" if mode == "single" else "v2"
        schema_path = SCHEMAS_DIR / f"reviewer_{mode_suffix}.json"
        errs, warns = check_json_schema(output, schema_path)
        all_errors.extend(errs)
        all_warnings.extend(warns)
        checks_run.append("json_schema")

    # Lớp 2: DAG (clusterer + architect)
    if step_name in ("capability_clusterer", "solution_architect"):
        errs = check_dag(output, step_name)
        all_errors.extend(errs)
        checks_run.append("dag")

    # Lớp 3: ID stability (chỉ khi có round trước)
    retry_count = manifest.get("retry_count", {}).get(step_name.replace("_", "-"), 0)
    if retry_count >= 1:
        prev_path = find_prev_step_file(state_dir, step_name, step_path)
        if prev_path:
            prev_output = load_json(prev_path)
            errs = check_id_stability(output, prev_output, step_name)
            all_errors.extend(errs)
            checks_run.append("id_stability")

    # Lớp 4: xref
    if step_name == "solution_architect":
        errs = check_xref(output, state_dir, step_name)
        all_errors.extend(errs)
        checks_run.append("xref")

    valid = len(all_errors) == 0
    emit(valid, step_name, checks_run, all_errors, all_warnings)

if __name__ == "__main__":
    main()
