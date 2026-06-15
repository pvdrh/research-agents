---
name: schema-validator
description: Hard gate kiểm schema output của agent SAU khi state-store đã save. 4 lớp check fail-fast — (1) JSON Schema, (2) DAG acyclic + đối xứng deps↔enables + topo order, (3) ID stability giữa các round retry, (4) cross-agent reference (architect.cases ↔ clusterer.capabilities). Dùng Python `jsonschema` lib (lazy install vào .venv). Caller: run-pipeline orchestrator gọi sau mỗi state-store.save.
---

# Schema Validator

## Mục đích
Hard-gate ngay sau khi agent return + state-store.save. Vi phạm → orchestrator re-spawn agent với prompt fix CỤ THỂ thay vì để Reviewer phát hiện ở Step 5 (tốn 1 round).

## Khi nào gọi
Orchestrator (skill `run-pipeline`) gọi SAU `state-store.save` cho mọi step có schema:
- `business_analyst`
- `capability_clusterer`
- `technology_researcher`
- `solution_architect`
- `technical_reviewer_rN`

Bỏ qua: `input`, `technical_writer` (Writer có gate riêng = `mermaid-render/count_fidelity.sh`).

## Input (CLI)
```
bash .claude/skills/schema-validator/run_check.sh <run_id> <step_name>
```

Mặc định đọc file mới nhất tại `.pipeline_state/{run_id}/step_NN_{step_name}.json`. Cho retry mode, validator tự load file round trước (`step_05_technical_reviewer_r{N-1}.json` hoặc `step_NN_{agent}.json` lưu trước đó) để check ID stability.

## Output
JSON stdout:
```json
{
  "valid": true | false,
  "step": "solution_architect",
  "checks_run": ["json_schema", "dag", "id_stability", "xref"],
  "errors": [
    {
      "code": "DAG_CYCLE",
      "path": "capabilities[3].deps",
      "msg": "Cycle detected: C1→C3→C5→C1"
    },
    {
      "code": "ASYM_DEP",
      "path": "capabilities[2].enables",
      "msg": "C2.enables=[C5] nhưng C5.deps không chứa C2"
    }
  ],
  "warnings": [
    {"code": "OPTIONAL_MISSING", "path": "key_design_decisions[3].alternatives_considered", "msg": "empty array, không phải warning blocker"}
  ]
}
```

Exit code:
- `0` = valid.
- `1` = invalid (`errors[]` non-empty).
- `2` = internal error (Python crash, file missing, lib install fail).

## 4 lớp check

### Lớp 1 — JSON Schema (`json_schema`)
Mỗi step có 1 JSON Schema cố định tại `schemas/{step_name}_v{mode_version}.json`:
- `schemas/ba_v1.json` — BA SINGLE.
- `schemas/ba_v2.json` — BA BATCH.
- `schemas/clusterer.json` — Capability Clusterer (BATCH only).
- `schemas/researcher_v1.json` — Researcher SINGLE.
- `schemas/researcher_v2.json` — Researcher BATCH.
- `schemas/architect_v1.json` — Architect SINGLE.
- `schemas/architect_v2.json` — Architect BATCH.
- `schemas/reviewer_v1.json` — Reviewer SINGLE.
- `schemas/reviewer_v2.json` — Reviewer BATCH.

Mode được phát hiện từ field `mode` trong output, hoặc từ `manifest.mode` nếu output không có.

### Lớp 2 — DAG (clusterer + architect)
Áp dụng cho `capabilities[]`:
- **Acyclic**: build dependency graph từ `capabilities[i].deps[]`. Detect cycle (Tarjan SCC hoặc DFS). Vi phạm → `DAG_CYCLE` kèm cycle path.
- **Đối xứng**: với mỗi `Cx.enables = [Cy, Cz]` phải tồn tại `Cy.deps ⊇ {Cx}` và `Cz.deps ⊇ {Cx}`. Vi phạm → `ASYM_DEP`.
- **Topo order**: nếu `Cx.deps = [Cy]` thì `Cx.build_order > Cy.build_order` (chỉ áp dụng cho Architect output có `build_priority.ordered_capabilities`). Vi phạm → `TOPO_VIOLATION`.

### Lớp 3 — ID stability (chỉ khi retry)
Khi `manifest.retry_count[agent] >= 1`, load file step round trước. So sánh:
- **BA**: `cases[i].id` không được đổi với cùng `cases[i].rank + cases[i].partition`. Số cases không được giảm.
- **Clusterer**: `capabilities[i].id` không được đổi. Số capabilities có thể đổi (Reviewer route có thể yêu cầu merge/split).
- **Architect**: `cases[i].id` phải khớp BA. `capability_ids[]` ⊆ Clusterer's IDs.

Vi phạm → `ID_INSTABILITY`.

### Lớp 4 — Cross-agent reference (BATCH only, architect)
- Mỗi `architecture.cases[i].capability_ids[j]` phải tồn tại trong `clusterer.capabilities[].id`.
- `len(architecture.cases) == len(BA.cases)`.
- `architecture.capabilities[].id` ⊇ `clusterer.capabilities[].id` (cho phép thêm sub-cap nhưng không bỏ).
- Bi-directional: với mỗi `architecture.capabilities[i].use_case_ids[k]`, file BA phải có case `id == k`, VÀ `architecture.cases[k].capability_ids` chứa `i`.

Vi phạm → `XREF_BROKEN`.

## Caller pattern (orchestrator)

```bash
SAVED=$(bash .claude/skills/state-store/save.sh "$RUN_ID" "$STEP_NAME" /tmp/agent_out.json)
GATE_OUT=$(bash .claude/skills/schema-validator/run_check.sh "$RUN_ID" "$STEP_NAME")
GATE_EXIT=$?

bash .claude/skills/observability/log_event.sh "$RUN_ID" \
  "$([ $GATE_EXIT -eq 0 ] && echo GATE_OK || echo GATE_FAIL)" \
  "step=$STEP_NAME" "gate=schema"

if [ "$GATE_EXIT" -ne 0 ]; then
  # Tăng retry counter (cùng counter với Reviewer route)
  NEW_RETRY=$(bash .claude/skills/state-store/update.sh "$RUN_ID" inc ".retry_count.$STEP_NAME" | tail -1)
  if [ "$NEW_RETRY" -gt 3 ]; then
    # Mark ACCEPTED_WITH_RISK_SCHEMA_INVALID, đi tiếp
    bash .claude/skills/observability/log_event.sh "$RUN_ID" RISK_ACCEPTED "step=$STEP_NAME" "reason=schema_invalid"
  else
    # Re-spawn agent với prompt fix CỤ THỂ (errors[] từ GATE_OUT)
    ...
  fi
fi
```

## Yêu cầu môi trường
- Python (đã có qua `.venv` từ input-reader skill).
- `jsonschema` lib (lazy install lần đầu).

```bash
source .venv/Scripts/activate 2>/dev/null || source .venv/bin/activate 2>/dev/null || true
python -c "import jsonschema" 2>/dev/null || python -m pip install --quiet jsonschema
```

## Ràng buộc
- KHÔNG sửa output agent. Chỉ check + báo lỗi.
- Errors phải có `path` JSON Pointer style để agent fix đúng chỗ.
- Mỗi error có `code` enum-style để orchestrator có thể group + xử lý khác nhau.
- Performance: <2s/step (validate JSON Schema + DAG cho 14 capability + 60 case).
- KHÔNG block pipeline khi `mode` không xác định được → return `valid: true` + warning.
