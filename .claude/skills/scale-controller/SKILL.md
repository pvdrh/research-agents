---
name: scale-controller
description: Quyết định strategy Architect dựa trên N cases BA detect được. 3 mức — FULL (≤15 case, vẽ đủ chi tiết mỗi case), CANONICAL_REUSE (16-49 case, vẽ 1 canonical/pattern_group, cases khác reuse), MAP_REDUCE (≥50 case, chia chunks 15 chạy parallel qua Workflow tool rồi merge). Cung cấp `decide_strategy.sh` + `merge_chunks.py`.
---

# Scale Controller

## Mục đích
Pipeline BATCH với N case lớn dễ tràn token. Architect output chứa Mermaid + ADR + risk register cho từng case → 60 cases có thể vượt 200k token output, vượt giới hạn API.

Skill này chạy SAU BA Step 1, TRƯỚC Capability Clusterer (Step 2), set strategy vào manifest. Architect đọc strategy để biết detail level.

## Strategy table

| N cases | Strategy | Architect behavior |
|---|---|---|
| ≤ 15 | `full` | Vẽ đầy đủ fmd/mmd/exc cho mỗi case riêng biệt. |
| 16-49 | `canonical_reuse` | Vẽ canonical (1 case đại diện cho mỗi pattern_group). Cases còn lại: `fmd/mmd = "REUSE:Pxxx"`, `delta_notes = [...]`. Exception table inherit. |
| ≥ 50 | `map_reduce` | Orchestrator chia BA.cases[] thành chunks 15, spawn N/15 Architect song song qua Workflow tool. Mỗi chunk nhận full context (BA + Clusterer + Researcher) + danh sách case_ids của chunk. Chunk 0 sinh phần overall + capabilities; chunks khác chỉ sinh cases[]. Merge sau qua `merge_chunks.py`. |

## API

### `decide_strategy.sh <run_id>`

Output JSON stdout:
```json
{
  "strategy": "full | canonical_reuse | map_reduce",
  "n_cases": 60,
  "chunks_count": 4,
  "chunks": [
    {"index": 0, "case_ids": ["C1","C2","...","C15"]},
    {"index": 1, "case_ids": ["C16","...","C30"]},
    ...
  ]
}
```

Tự ghi vào `manifest.strategy`, `manifest.n_cases`, `manifest.chunks_count`. Log event `STRATEGY`.

Áp dụng: mode = batch. SINGLE → trả `{"strategy": "n/a", "n_cases": 1}` và skip.

### `merge_chunks.py <run_id>`

Chỉ chạy khi `strategy = map_reduce`. Args: `run_id`.

Đọc các file `step_04_solution_architect_chunk_{i}.json` đã save bởi orchestrator → merge thành `step_04_solution_architect.json` chuẩn.

Quy tắc merge:
1. **Cases[]**: concat từ mọi chunk. Validate không trùng `id`. Tổng = `manifest.n_cases`.
2. **Capabilities, overall, nfr_matrix, data_architecture, security_compliance, operational_view, risk_register, cost_breakdown, key_design_decisions, architecture_style, build_priority, precheck**: lấy từ **chunk 0** (chunk đầu, được giao "full context").
3. **_meta**: cộng dồn `tokens_in/tokens_out/duration_s` mọi chunk. `model` = chunk 0.

Output: file merged path. Log: `MERGE_DONE chunks=N total_cases=M tokens_in=X tokens_out=Y`.

## Caller pattern (orchestrator)

```bash
# Sau Step 1 BA
SAVED=$(bash state-store/save.sh $RUN_ID business_analyst /tmp/ba.json)
bash schema-validator/run_check.sh $RUN_ID business_analyst

# Detect mode
MODE=$(python -c "import json; print(json.load(open('$SAVED')).get('mode','single'))")

# Decide strategy (BATCH only)
if [ "$MODE" = "batch" ]; then
  STRATEGY_OUT=$(bash scale-controller/decide_strategy.sh $RUN_ID)
  STRATEGY=$(python -c "import json; print(json.loads('''$STRATEGY_OUT''')['strategy'])")
fi

# Step 4 Architect — branching theo strategy
if [ "$STRATEGY" = "map_reduce" ]; then
  # Spawn N chunks song song qua Workflow tool
  # Mỗi chunk Agent với prompt riêng + chunk_index + case_ids
  ...
  # Sau khi all chunks save xong:
  bash scale-controller/merge_chunks.py $RUN_ID
else
  # FULL hoặc CANONICAL_REUSE — spawn 1 Architect duy nhất với prompt chứa strategy hint
  ...
fi
```

## Ràng buộc
- KHÔNG đụng BA / Clusterer / Researcher — chỉ quyết định và merge cho Architect.
- Threshold cố định (15 / 49 / 50+). Tương lai có thể cho user override.
- `chunks_count = ceil(N / 15)`. Chunk cuối có thể ít hơn 15 cases.
- Map-reduce concurrent cap: tối đa **8 chunks song song** (tránh rate limit API). N > 120 sẽ chia làm 2 wave.
- Schema-validator phải cho phép `cases[].fmd = "REUSE:Pxxx"` khi strategy = canonical_reuse.
