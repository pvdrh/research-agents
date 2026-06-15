---
name: mermaid-render
description: Hard gate render mọi Mermaid diagram trong output Architect/Clusterer qua `npx -y @mermaid-js/mermaid-cli`. Catch 100% syntax error thật (vượt rule-based mermaid-validator). Pipeline HARD-FAIL nếu npx/Node.js không có. Cung cấp `render_all.sh` (validate batch) + `count_fidelity.sh` (Writer count `class="mermaid"` trong HTML).
---

# Mermaid Render — Hard Gate

## Mục đích
Mermaid-validator (rule-based, LLM tự đọc) không bắt được mọi lỗi parser thật. Phase 2 thêm gate này: render diagram bằng **mermaid-cli thật** (Node.js puppeteer Chrome) — nếu render thành công file SVG → diagram chắc chắn parse được trên client browser.

## Khi nào gọi

### `render_all.sh <run_id> <step_name>`
Gọi sau khi `state-store.save` cho:
- `capability_clusterer` (có `dependency_graph_mmd`).
- `solution_architect` (có nhiều diagram: capabilities[].internal_mermaid, cases[].fmd/mmd, overall.*_mmd, build_priority.roadmap_mmd).

### `count_fidelity.sh <html_path> <expected_count>`
Gọi bởi Writer sau khi Write file HTML để verify mọi diagram được embed.

## Hard dependency

- Node.js (`node --version` >= 16).
- `npx` (đi kèm npm).
- Lần đầu chạy mermaid-cli tự pull puppeteer + Chrome (~150MB). Build subsequent ~3s/diagram.

Thiếu → script exit code 2 với message:
```
ERROR: mermaid-cli requires Node.js + npx.
Cài đặt:
  Windows: winget install OpenJS.NodeJS
  Sau đó chạy 1 lần để cache puppeteer:
    npx -y @mermaid-js/mermaid-cli --help
```

KHÔNG fallback. Pipeline fail.

## `render_all.sh <run_id> <step_name>`

Đọc file step, extract mọi field tên kết thúc `_mmd` hoặc `mermaid` (cụ thể: `dependency_graph_mmd`, `internal_mermaid`, `fmd`, `mmd`, `c4_context_mmd`, `c4_container_mmd`, `lifecycle_mmd`, `pipeline_mmd`, `roadmap_mmd`, `erd_mmd`, `code` trong `mermaid_diagrams[]`).

Loop:
1. Ghi diagram code vào `/tmp/mr_{run_id}_{i}.mmd`.
2. Chạy `npx -y @mermaid-js/mermaid-cli -i /tmp/mr_{run_id}_{i}.mmd -o /tmp/mr_{run_id}_{i}.svg -q`.
3. Exit 0 = pass; non-zero = fail (capture stderr).

Skip rỗng, skip placeholder `"REUSE:Pxxx"` (lowercase, áp dụng cho cases reuse pattern).

### Output (JSON stdout)
```json
{
  "valid": true | false,
  "step": "solution_architect",
  "total": 38,
  "rendered": 36,
  "skipped_reuse": 2,
  "failed": [
    {
      "path": "cases[3].mmd",
      "code_snippet": "sequenceDiagram\n  Client --> Server: GET",
      "error": "Parse error on line 2: '-->' invalid for sequenceDiagram"
    }
  ],
  "duration_s": 47
}
```

Exit: 0 = valid (rendered ≥ total - skipped), 1 = invalid (any failed), 2 = environment missing.

## `count_fidelity.sh <html_path> <expected_count>`

```bash
ACTUAL=$(grep -c 'class="mermaid"' "$1")
THRESHOLD=$(( $2 * 85 / 100 ))
if [ "$ACTUAL" -ge "$THRESHOLD" ]; then
  echo "{\"ok\":true,\"actual\":$ACTUAL,\"expected\":$2,\"threshold\":$THRESHOLD}"
  exit 0
else
  echo "{\"ok\":false,\"actual\":$ACTUAL,\"expected\":$2,\"threshold\":$THRESHOLD,\"missing\":$((THRESHOLD - ACTUAL))}"
  exit 1
fi
```

Threshold 85% (theo CLAUDE.md fidelity rule).

## Caller pattern (orchestrator)

```bash
case "$STEP_NAME" in
  capability_clusterer|solution_architect)
    MR_OUT=$(bash .claude/skills/mermaid-render/render_all.sh "$RUN_ID" "$STEP_NAME")
    MR_EXIT=$?
    bash .claude/skills/observability/log_event.sh "$RUN_ID" \
      "$([ $MR_EXIT -eq 0 ] && echo GATE_OK || echo GATE_FAIL)" \
      "step=$STEP_NAME" "gate=mermaid"
    if [ "$MR_EXIT" -eq 2 ]; then
      echo "ERROR: pipeline fail — Node.js/npx missing" >&2
      exit 2  # HARD FAIL pipeline
    fi
    if [ "$MR_EXIT" -ne 0 ]; then
      # Re-spawn với prompt chứa failed diagrams + error messages
      ...
    fi
    ;;
esac
```

## Performance & cache
- First run: pull Chrome ~150MB → 30-60s.
- Subsequent: 2-3s/diagram. BATCH 60 case × ~3 diagram/case = ~3-5 phút.
- Optimization Phase 3: hash diagram code → cache; chỉ render mới/đổi.

## Ràng buộc
- KHÔNG sửa diagram. Chỉ check pass/fail.
- KHÔNG silent — phải log GATE_FAIL nếu có diagram fail.
- KHÔNG fallback rule-based khi npx có nhưng render fail — phải báo lỗi thật.
- Output `code_snippet` ngắn (≤200 char) để orchestrator put vào prompt fix.
