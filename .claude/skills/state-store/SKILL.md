---
name: state-store
description: Persistent blackboard cho pipeline. Lưu/đọc state qua file `.pipeline_state/{run_id}/`. Orchestrator (run-pipeline) và mọi agent dùng skill này để pass artifact qua file path thay vì nhồi vào prompt — giảm token, cho phép resume sau crash. Cung cấp `new_run`, `save`, `load`, `manifest`, `rename_run`, `append_review`. Bash + jq, không cần Python.
---

# State Store

## Mục đích
Blackboard pattern. Mỗi pipeline run = 1 thư mục `.pipeline_state/{run_id}/`. Mọi artifact của các agent được lưu thành file JSON. Orchestrator pass file path qua prompt thay vì nội dung — agent dùng `Read` đọc.

Lợi ích:
- Token prompt ngắn hơn 5-10× ở BATCH lớn.
- Crash main-loop → `/resume-pipeline {run_id}` tiếp tục từ checkpoint cuối.
- Mọi state thay đổi tracked rõ ràng qua file diff.

## File layout

```
.pipeline_state/{run_id}/
├── manifest.json                          # current state, retry counters, mode
├── input.json                             # ban đầu: docs_files, format, retry_mode
├── step_01_business_analyst.json
├── step_02_capability_clusterer.json      # BATCH only
├── step_03_technology_researcher.json
├── step_04_solution_architect.json
├── step_05_technical_reviewer_r1.json     # round 1
├── step_05_technical_reviewer_r2.json     # round 2 nếu retry
├── step_06_technical_writer.json
└── review_log.jsonl                       # append-only, mỗi dòng 1 event
```

## API

Skill này KHÔNG implement bằng code chạy server-side. Skill cung cấp **chuẩn lệnh bash** mà orchestrator (main-loop) hoặc agent gọi qua tool `Bash`. Mọi lệnh chạy được trên PowerShell (Git Bash mode) hoặc bash POSIX.

### `new_run(slug_seed?: string) → run_id`

Tạo `run_id` mới + thư mục + manifest rỗng.

Format: `run_{slug}_{YYYYMMDD_HHMM}_{4char}`. Khi chưa có slug (trước BA step) → `slug = "pending"`.

```bash
RUN_ID="run_pending_$(date +%Y%m%d_%H%M)_$(openssl rand -hex 2 2>/dev/null || echo $RANDOM | md5sum | head -c4)"
mkdir -p ".pipeline_state/$RUN_ID"
cat > ".pipeline_state/$RUN_ID/manifest.json" <<EOF
{
  "run_id": "$RUN_ID",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": null,
  "current_step": null,
  "completed_steps": [],
  "retry_count": {
    "business-analyst": 0,
    "capability-clusterer": 0,
    "technology-researcher": 0,
    "solution-architect": 0
  },
  "status": "INITIALIZED",
  "final_verdict": null,
  "saved_path": null
}
EOF
echo "$RUN_ID"
```

### `rename_run(old_run_id, new_slug) → new_run_id`

Sau Step 1 (BA), orchestrator có domain/title → đổi slug. Move thư mục + cập nhật manifest.

```bash
NEW_SLUG="<slugified>"   # vd "chatbot_csk"
OLD="$1"
NEW="run_${NEW_SLUG}_$(echo $OLD | grep -oP '\d{8}_\d{4}_[a-f0-9]{4}$')"
mv ".pipeline_state/$OLD" ".pipeline_state/$NEW"
# Cập nhật run_id trong manifest
jq --arg id "$NEW" '.run_id=$id' ".pipeline_state/$NEW/manifest.json" > /tmp/m.json && mv /tmp/m.json ".pipeline_state/$NEW/manifest.json"
echo "$NEW"
```

### `save(run_id, step_name, payload_path)`

`step_name` ∈ {`input`, `business_analyst`, `capability_clusterer`, `technology_researcher`, `solution_architect`, `technical_reviewer_rN`, `technical_writer`}.

```bash
# Convention: file step_XX_yyy.json. XX là số thứ tự cố định.
declare -A STEP_NUM=(
  [input]=00
  [business_analyst]=01
  [capability_clusterer]=02
  [technology_researcher]=03
  [solution_architect]=04
  [technical_writer]=06
)
# technical_reviewer dùng prefix 05 + round suffix: 05_technical_reviewer_r1.json

PREFIX="${STEP_NUM[$STEP_NAME]:-05}"
DEST=".pipeline_state/$RUN_ID/step_${PREFIX}_${STEP_NAME}.json"
cp "$PAYLOAD_PATH" "$DEST"

# Cập nhật manifest
jq --arg s "$STEP_NAME" '.current_step=$s | .completed_steps += [$s]' \
   ".pipeline_state/$RUN_ID/manifest.json" > /tmp/m.json && mv /tmp/m.json ".pipeline_state/$RUN_ID/manifest.json"

echo "$DEST"
```

Caller pattern (orchestrator nhận output từ agent → ghi xuống file → save):
```bash
echo "$AGENT_OUTPUT_JSON" > /tmp/agent_out.json
bash .claude/skills/state-store/save.sh "$RUN_ID" "business_analyst" /tmp/agent_out.json
```

### `load(run_id, step_name?) → file_path`

Trả về **đường dẫn file**, KHÔNG đọc nội dung (giảm token orchestrator). Agent tự `Read` file path.

```bash
RUN_ID="$1"
STEP="$2"
if [ -z "$STEP" ]; then
  ls -1 ".pipeline_state/$RUN_ID/"*.json
else
  ls -1 ".pipeline_state/$RUN_ID/step_"*"_${STEP}"*.json | tail -n1
fi
```

### `manifest(run_id) → JSON`

```bash
cat ".pipeline_state/$1/manifest.json"
```

### `update_manifest(run_id, jq_expression)`

Generic update — vd tăng retry counter, set mode, set final_verdict.

```bash
RUN_ID="$1"
JQ_EXPR="$2"  # vd '.retry_count["solution-architect"] += 1'
jq "$JQ_EXPR" ".pipeline_state/$RUN_ID/manifest.json" > /tmp/m.json && mv /tmp/m.json ".pipeline_state/$RUN_ID/manifest.json"
```

### `append_review(run_id, round, target_agent, issues_summary, verdict)`

```bash
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"round\":$ROUND,\"target_agent\":\"$TARGET\",\"issues_summary\":\"$ISSUES\",\"verdict\":\"$VERDICT\"}" \
  >> ".pipeline_state/$RUN_ID/review_log.jsonl"
```

## Helper scripts (đặt cùng SKILL.md)

Để gọn, skill có 4 file shell helper trong cùng thư mục:
- `new_run.sh` — args: `[slug_seed]` → prints `run_id`.
- `save.sh` — args: `run_id step_name payload_path` → prints saved file path.
- `load.sh` — args: `run_id [step_name]` → prints file path(s).
- `update.sh` — args: `run_id jq_expression`.

## Convention manifest.json

```json
{
  "run_id": "run_chatbot_csk_20260615_1430_a3f7",
  "created_at": "2026-06-15T07:30:00Z",
  "mode": "single | batch | null",
  "current_step": "solution_architect",
  "completed_steps": ["input","business_analyst","technology_researcher"],
  "retry_count": {
    "business-analyst": 0,
    "capability-clusterer": 0,
    "technology-researcher": 1,
    "solution-architect": 2
  },
  "status": "INITIALIZED | RUNNING | APPROVED | ACCEPTED_WITH_RISK | FAILED | COMPLETED",
  "final_verdict": null,
  "saved_path": null,
  "domain": "fintech",
  "title": "Hệ thống chatbot CSKH"
}
```

## Orchestrator pattern (run-pipeline gọi)

```
1. RUN_ID=$(bash .claude/skills/state-store/new_run.sh)
2. echo "$INPUT_JSON" > /tmp/input.json
   bash .claude/skills/state-store/save.sh "$RUN_ID" input /tmp/input.json
3. # Spawn BA
   prompt = "Đọc input tại: .pipeline_state/$RUN_ID/step_00_input.json. Output JSON v1/v2."
   ba_output = Agent(business-analyst, prompt)
   echo "$ba_output" > /tmp/ba.json
   bash .claude/skills/state-store/save.sh "$RUN_ID" business_analyst /tmp/ba.json
4. # Rename run sau khi có slug
   SLUG=$(jq -r '.use_case_summary // .project_summary.title' ".pipeline_state/$RUN_ID/step_01_business_analyst.json" | <slugify>)
   RUN_ID=$(bash .claude/skills/state-store/rename_run.sh "$RUN_ID" "$SLUG")
5. # Spawn Researcher với file path
   prompt = "Đọc requirements tại: .pipeline_state/$RUN_ID/step_01_business_analyst.json. ..."
   ...
```

## Ràng buộc
- KHÔNG bao giờ nhồi full state vào prompt agent. Chỉ pass `run_id` + file path.
- Mọi file lưu là JSON hợp lệ; corrupted JSON → orchestrator must fail fast.
- Manifest là source of truth cho `current_step` + `retry_count`.
- Skill này KHÔNG đọc/sửa nội dung agent — chỉ I/O.
- **Backend JSON**: ưu tiên `jq` (nhanh). Nếu không có `jq` → tự fallback sang Python (`_json_op.py`) — chỉ cần `python` hoặc `python3` trên PATH. Nếu thiếu cả 2 → fail với hint cài đặt.

## Lỗi thường gặp
| Lỗi | Xử lý |
|---|---|
| Cả jq + python đều thiếu | Fail với hint `winget install jqlang.jq` hoặc cài Python 3.10+ |
| `.pipeline_state/` không tồn tại | `mkdir -p` tự động |
| Agent return non-JSON | Orchestrator re-spawn 1 lần với prompt "Chỉ trả JSON đúng schema, không kèm prose" |
| File JSON corrupted | Fail; user xóa file đó và resume |
