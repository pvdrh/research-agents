---
name: run-pipeline
description: Orchestrator end-to-end. Blackboard pattern — mọi artifact agent lưu vào `.pipeline_state/{run_id}/`, agent nhận input qua file path (không nhồi vào prompt). Detect SINGLE/BATCH → chạy 6 agent (BA → capability-clusterer chỉ ở BATCH → Researcher → Architect → Reviewer panel → Writer) có feedback loop, sinh báo cáo md/html. Dùng khi user gõ /run-pipeline hoặc yêu cầu chạy toàn bộ.
---

# Run Pipeline — Multi-Agent Orchestrator (Blackboard Pattern)

## Khi nào dùng
- User gõ `/run-pipeline`. Skill TỰ ĐỘNG quét toàn bộ `docs/` làm input.
- `/resume-pipeline {run_id}` cũng load skill này nhưng có cờ resume.

## Thay đổi lớn so với phiên trước (Phase 1)
1. **Mọi state lưu vào `.pipeline_state/{run_id}/`** qua skill `state-store`, KHÔNG giữ trong context main-loop.
2. **Agent nhận input qua file path** (`read_from: ".pipeline_state/{run_id}/step_NN_xxx.json"`), KHÔNG nhồi data vào prompt.
3. **Mỗi step ghi log** vào `logs/{run_id}/run.log` qua skill `observability`.
4. **Mỗi agent return JSON có `_meta.tokens_in/_meta.tokens_out/_meta.duration_s`** để orchestrator capture.
5. **Crash → resume được** qua `/resume-pipeline {run_id}`.

## Thay đổi Phase 2 — Hard gates
6. **Schema gate** (`schema-validator`) chạy SAU mỗi state-store.save. Sai → re-spawn agent.
7. **Mermaid render gate** (`mermaid-render`) chạy sau Clusterer + Architect. Diagram fail thật trên `mermaid-cli` → re-spawn.
8. **Convergence guard**: track `total_regression` qua các round Reviewer. >2 → terminate `ACCEPTED_WITH_RISK_LOOP_DETECTED`.
9. **Gate fail counts vào `retry_count[agent]`** chung (cùng counter với Reviewer route). Vượt 3 → mark `ACCEPTED_WITH_RISK_GATE_FAIL`.
10. **Hard dependency Node.js + npx** cho mermaid-render. Pipeline fail nếu thiếu (xem CLAUDE.md).

## Thay đổi Phase 3 — Scale + Polish
11. **Scale controller**: sau BA, gọi `scale-controller/decide_strategy.sh` set `manifest.strategy` ∈ {full, canonical_reuse, map_reduce}.
12. **Architect branching**: prompt khác nhau theo strategy. `map_reduce` → spawn N/15 chunks song song qua Workflow tool, merge sau qua `merge_chunks.py`.
13. **Model override**: Architect BATCH spawn với `model: "opus"` (SINGLE giữ `sonnet`).
14. **Panel veto**: Reviewer BATCH 1 blocker REJECT = veto, verdict tổng auto `REVISION_REQUIRED`.

## Quy trình tiền-chạy (BẮT BUỘC trước Step 1)

### Bước 0 — Pre-flight check (lifecycle init)

CHẠY ĐẦU TIÊN, trước khi hỏi user bất cứ gì:

```bash
bash .claude/skills/run-pipeline/init.sh
INIT_EXIT=$?
```

- Exit `0` → ready, đi tiếp.
- Exit `1` → có WARN nhưng được phép chạy (hiện cho user, không hỏi).
- Exit `2` → HARD FAIL. In stderr cho user, **KHÔNG hỏi gì thêm, KHÔNG tạo run_id, dừng**. User phải fix lỗi (thiếu Node/python, docs rỗng, agent/skill missing, ...) rồi gọi lại `/run-pipeline`.

Stderr của init.sh có sẵn format ASCII đẹp — hiển thị nguyên.

### Bước 0a — Quét `docs/`
- `Glob docs/**/*` lọc bỏ ẩn (`.DS_Store`, `~$*`, `.tmp`, `.gitkeep`).
- Rỗng → hỏi user dán mô tả văn xuôi hoặc bỏ file vào docs.

### Bước 0b — Hỏi user 3 câu (`AskUserQuestion`)

**Câu 1 — Format output**: Markdown (.md) | HTML (.html).

**Câu 2 — Retry mode**: Strict (max 3 retry/agent, 5-15 phút) | Fast (1 lượt, 2-5 phút).

**Câu 3 — Scope**: `full` (đầy đủ: BA → Researcher → Architect → Reviewer → Writer) | `no_research` (bỏ Researcher; Architect thiết kế **tech-agnostic** dùng pattern/component name thay tech cụ thể) | `analysis_only` (CHỈ BA + Clusterer nếu BATCH → Writer; bỏ Researcher + Architect + Reviewer).

Save cả 3 vào `input.json`: `format`, `retry_mode`, `scope`.

### Bước 0c — Tạo run_id + khởi tạo state

```bash
RUN_ID=$(bash .claude/skills/state-store/new_run.sh)
# RUN_ID format: run_pending_YYYYMMDD_HHMM_xxxx

bash .claude/skills/observability/log_event.sh "$RUN_ID" START \
  "format=$FORMAT" "retry_mode=$RETRY_MODE" "docs_count=$DOCS_COUNT"
```

### Bước 0d — Đọc input đa định dạng + ghi input.json

Với mỗi file trong docs:
- Gọi skill `input-reader` → nhận JSON output.
- Gộp kết quả:
  - ≥1 file `kind=tabular` → mode=batch, gộp `requirements.cases[]`.
  - Không có tabular, có ≥1 file `text/document` → mode=single, gộp `use_case_text`.
  - `image_description` → context phụ trợ.

Ghi gộp vào `/tmp/input.json`:
```json
{
  "docs_files": ["docs/file1.xlsx", "docs/file2.md"],
  "format": "md|html",
  "retry_mode": "strict|fast",
  "mode_hint": "single|batch",
  "use_case_text": "...",
  "tabular_payloads": [{...input-reader output...}],
  "auxiliary_image_descriptions": [...]
}
```

```bash
bash .claude/skills/state-store/save.sh "$RUN_ID" input /tmp/input.json
bash .claude/skills/state-store/update.sh "$RUN_ID" ".mode = \"$MODE_HINT\""
```

## Detect mode
- ≥1 file `kind=tabular` → BATCH.
- Còn lại → SINGLE.
- User có thể ép qua prompt.

## Pipeline

### Scope branching
`input.json.scope` quyết định step nào chạy:

| scope | SINGLE chạy | BATCH chạy |
|---|---|---|
| `full` (default) | BA → Researcher → Architect → Reviewer → Writer | BA → Clusterer → Researcher → Architect → Reviewer → Writer |
| `no_research` | BA → Architect (agnostic) → Reviewer → Writer | BA → Clusterer → Architect (agnostic) → Reviewer → Writer |
| `analysis_only` | BA → Writer | BA → Clusterer → Writer |

Khi skip step, orchestrator vẫn pass file path đầy đủ cho agent sau — agent tự handle file thiếu (Researcher → `step_03` không tồn tại → Architect chạy agnostic mode).

### SINGLE — `full` (5 bước)
```
Step 1: business-analyst         → step_01_business_analyst.json
Step 2: technology-researcher    → step_03_technology_researcher.json
Step 3: solution-architect       → step_04_solution_architect.json
Step 4: technical-reviewer       → step_05_technical_reviewer_r{N}.json
        ├── REVISION → loop về step 2/3 (max 3/agent)
        └── APPROVED → Step 5
Step 5: technical-writer         → step_06_technical_writer.json + results/file
```

### SINGLE — `no_research` (4 bước)
```
Step 1: business-analyst         → step_01_business_analyst.json
Step 3: solution-architect       → step_04_solution_architect.json   (agnostic mode)
Step 4: technical-reviewer       → step_05_technical_reviewer_r{N}.json
Step 5: technical-writer         → step_06_technical_writer.json
```

### SINGLE — `analysis_only` (2 bước)
```
Step 1: business-analyst         → step_01_business_analyst.json
Step 5: technical-writer         → step_06_technical_writer.json
```

### BATCH — `full` (6 bước)
```
Step 1: business-analyst         → step_01_business_analyst.json
Step 2: capability-clusterer     → step_02_capability_clusterer.json
Step 3: technology-researcher    → step_03_technology_researcher.json
Step 4: solution-architect       → step_04_solution_architect.json
Step 5: technical-reviewer       → step_05_technical_reviewer_r{N}.json
        ├── REVISION → loop về 2/3/4 (max 3/agent)
        └── APPROVED → Step 6
Step 6: technical-writer         → step_06_technical_writer.json + results/file
```

### BATCH — `no_research` (5 bước)
```
Step 1: business-analyst → Step 2: clusterer → Step 4: architect (agnostic)
      → Step 5: reviewer (no tech check) → Step 6: writer
```

### BATCH — `analysis_only` (3 bước)
```
Step 1: business-analyst → Step 2: capability-clusterer → Step 6: writer
```

## Budget circuit breaker (Phase 4)

Sau MỖI step (sau khi save + gate xong, trước khi spawn agent kế tiếp), gọi:

```bash
BUDGET_OUT=$(bash .claude/skills/run-pipeline/check_budget.sh "$RUN_ID")
BUDGET_EXIT=$?
case $BUDGET_EXIT in
  0) ;;  # ok, continue
  1) bash .claude/skills/observability/log_event.sh "$RUN_ID" BUDGET_WARN "$(echo $BUDGET_OUT | python -c 'import json,sys;d=json.load(sys.stdin);print(f"reason={d[\"reason\"]}")')";;
  2) bash .claude/skills/observability/log_event.sh "$RUN_ID" BUDGET_EXCEEDED "reason=$(echo $BUDGET_OUT | python -c 'import json,sys;print(json.load(sys.stdin)[\"reason\"])')"
     bash .claude/skills/state-store/update.sh "$RUN_ID" '.status="ACCEPTED_WITH_RISK" | .final_verdict="ACCEPTED_WITH_RISK_BUDGET_EXCEEDED"'
     # Skip mọi step còn lại trừ Writer (in best-effort report với banner)
     goto Step Writer ;;
esac
```

Cấu hình qua env vars (default rộng tay):
- `BUDGET_MAX_TOKENS=2000000` (~2M tokens cả vào+ra)
- `BUDGET_MAX_WALL_S=1800` (30 phút wall-clock)
- `BUDGET_WARN_PCT=80`

User override:
```bash
BUDGET_MAX_TOKENS=500000 BUDGET_MAX_WALL_S=600 /run-pipeline
```

Khi `final_verdict == "ACCEPTED_WITH_RISK_BUDGET_EXCEEDED"`, Writer in banner:
> ⚠️ **Pipeline cắt sớm do vượt budget** — báo cáo là best-effort với state tại thời điểm cắt. Các step chưa chạy: {danh sách}.

## Quy tắc orchestration

### Pattern chung cho mỗi step (Phase 2 — có gate)

```
1. START_TIME=$(date +%s)
2. Spawn agent → return JSON
3. Save: bash state-store/save.sh $RUN_ID $STEP_NAME /tmp/step_out.json
4. Log: bash observability/log_event.sh $RUN_ID STEP_OK step=... tokens_in=... tokens_out=... duration_s=...

5. # ── HARD GATE: SCHEMA ──
   GATE1=$(bash .claude/skills/schema-validator/run_check.sh $RUN_ID $STEP_NAME)
   GATE1_EXIT=$?
   bash observability/log_event.sh $RUN_ID \
     "$([ $GATE1_EXIT -eq 0 ] && echo GATE_OK || echo GATE_FAIL)" \
     "step=$STEP_NAME" "gate=schema"
   if [ "$GATE1_EXIT" -ne 0 ]; then
     RETRY=$(bash state-store/update.sh $RUN_ID inc ".retry_count[\"$AGENT_NAME\"]" | tail -1)
     if [ "$RETRY" -gt 3 ]; then
       bash observability/log_event.sh $RUN_ID RISK_ACCEPTED "step=$STEP_NAME" "reason=schema_invalid"
       # đi tiếp với output cũ (best-effort)
     else
       # Re-spawn với prompt fix: pass GATE1 errors[]
       goto step 2  # với prompt = "Schema fail: <errors>. Đọc step_NN.json, CHỈ sửa các field nêu."
     fi
   fi

6. # ── HARD GATE: MERMAID (chỉ clusterer + architect) ──
   case "$STEP_NAME" in capability_clusterer|solution_architect)
     GATE2=$(bash .claude/skills/mermaid-render/render_all.sh $RUN_ID $STEP_NAME)
     GATE2_EXIT=$?
     if [ "$GATE2_EXIT" -eq 2 ]; then
       # HARD FAIL — Node/npx missing
       bash observability/log_event.sh $RUN_ID PIPELINE_ABORT "reason=no_node_npx"
       exit 2
     fi
     bash observability/log_event.sh $RUN_ID \
       "$([ $GATE2_EXIT -eq 0 ] && echo GATE_OK || echo GATE_FAIL)" \
       "step=$STEP_NAME" "gate=mermaid"
     if [ "$GATE2_EXIT" -ne 0 ]; then
       RETRY=$(bash state-store/update.sh $RUN_ID inc ".retry_count[\"$AGENT_NAME\"]" | tail -1)
       if [ "$RETRY" -gt 3 ]; then
         bash observability/log_event.sh $RUN_ID RISK_ACCEPTED "step=$STEP_NAME" "reason=mermaid_invalid"
       else
         # Re-spawn với prompt fix: pass failed[].path + error
         goto step 2
       fi
     fi
   ;; esac

7. # OK, qua step sau
```

> Lưu ý: pseudocode trên dùng `goto` cho dễ đọc. Thực thi: orchestrator (main-loop) tracking variable round, lặp spawn cho đến khi gate pass hoặc retry > 3.

> `AGENT_NAME` = `STEP_NAME` với underscore → dash (`business_analyst` → `business-analyst`) để khớp `retry_count` key.

### Step 1.5 — Decide Strategy (BATCH only, Phase 3)

Sau khi BA save + schema gate pass, BATCH chạy:
```bash
STRATEGY_OUT=$(bash .claude/skills/scale-controller/decide_strategy.sh "$RUN_ID")
STRATEGY=$(python -c "import json; print(json.loads('''$STRATEGY_OUT''')['strategy'])")
N_CASES=$(python -c "import json; print(json.loads('''$STRATEGY_OUT''')['n_cases'])")
CHUNKS_COUNT=$(python -c "import json; print(json.loads('''$STRATEGY_OUT''')['chunks_count'])")
```

`STRATEGY` decide cách spawn Architect ở Step 4.

### Step 1 — BA

Prompt:
```
Mode được detect: {SINGLE|BATCH}
Run ID: {RUN_ID}
Đọc input tại: .pipeline_state/{RUN_ID}/step_00_input.json (dùng tool Read)
- field `use_case_text` là văn xuôi cho SINGLE
- field `tabular_payloads` là output từ input-reader cho BATCH
- field `auxiliary_image_descriptions` là phụ trợ
Output JSON đúng schema v1 (single) hoặc v2 (batch), kèm _meta.
```

Sau khi save:
- Extract title/domain → rename run:
```bash
SLUG=$(jq -r '.use_case_summary // .project_summary.title // "untitled"' /tmp/step_out.json | head -c50)
NEW_RUN_ID=$(bash .claude/skills/state-store/rename_run.sh "$RUN_ID" "$SLUG")
bash .claude/skills/observability/log_event.sh "$NEW_RUN_ID" RENAME "old=$RUN_ID" "new=$NEW_RUN_ID"
DOMAIN=$(jq -r '.domain' /tmp/step_out.json)
bash .claude/skills/state-store/update.sh "$NEW_RUN_ID" ".domain=\"$DOMAIN\" | .title=\"$SLUG\""
RUN_ID="$NEW_RUN_ID"
```

### Step 2 (chỉ BATCH) — Capability Clusterer
Prompt:
```
Run ID: {RUN_ID}
Đọc requirements tại: .pipeline_state/{RUN_ID}/step_01_business_analyst.json (Read tool)
Phân cụm capability theo domain, output JSON đúng schema + _meta.
```

### Step 3 — Researcher
SINGLE:
```
Read: step_01_business_analyst.json
```
BATCH:
```
Read: step_01_business_analyst.json, step_02_capability_clusterer.json
```

### Step 4 — Architect (branching theo strategy, Phase 3)

**SINGLE** (`strategy = n/a`):
- Spawn 1 Architect với `model: "sonnet"`.
- Prompt: `Read step_01_business_analyst.json, step_03_technology_researcher.json. Render đầy đủ.`

**BATCH — `strategy = full`** (≤15 cases):
- Spawn 1 Architect với `model: "opus"`.
- Prompt: `Read step_01, step_02, step_03. Strategy=full. Render fmd/mmd/exc đầy đủ cho mỗi case.`

**BATCH — `strategy = canonical_reuse`** (16-49 cases):
- Spawn 1 Architect với `model: "opus"`.
- Prompt: `Read step_01, step_02, step_03. Strategy=canonical_reuse. Vẽ canonical 1 case đại diện cho mỗi pattern_group. Các case khác cùng group: fmd/mmd="REUSE:Pxxx", delta_notes=[...].`

**BATCH — `strategy = map_reduce`** (≥50 cases):
- Spawn N chunks song song qua **Workflow tool** (parallel pattern Anthropic):
  ```javascript
  const chunks = manifest.chunks  // từ decide_strategy
  const partials = await parallel(chunks.map((chunk, i) => () =>
    agent("solution-architect", {
      model: "opus",
      prompt: `Run ID: ${RUN_ID}
        Chunk index: ${i} / ${chunks.length}
        Case IDs cho chunk này: ${chunk.case_ids.join(",")}
        Read full state: step_01, step_02, step_03 + manifest.json.
        CHỈ thiết kế chi tiết cho case_ids trên.
        ${i === 0 ? "Sinh ĐẦY ĐỦ capabilities + overall + nfr_matrix + ... + key_design_decisions (full context)" : "CHỈ trả cases[] + _meta, các field khác null/missing"}.
        Output schema architect_v2.json + _meta.`,
    })
  ))
  // Save từng chunk
  for (i, partial of partials) {
    save partial to step_04_solution_architect_chunk_${i}.json
  }
  // Merge
  bash scale-controller/merge_chunks.py $RUN_ID
  ```
- Concurrent cap: tối đa 8 chunks song song (rate limit safety). N>120 → 2 wave.

Sau khi step_04 merged (hoặc trực tiếp save với strategy khác), chạy schema gate + mermaid render gate như Phase 2.

### Step 5 — Reviewer (feedback loop) 🔁

**SINGLE pipeline**: spawn 1 reviewer như cũ (`panel_mode: single`).

**BATCH pipeline — Split Panel** (KHUYẾN NGHỊ, default từ Phase 4):

1. **Composer pass** — spawn 1 reviewer với `panel_mode: composer` để sinh danh sách 3-5 persona + 1 red-team (`code:"RED"`). Save → `step_05_composer.json`. Gọi schema-validator với `reviewer_composer.json`. Cache panel danh sách trong manifest `.panel` để các round retry tái dùng (KHÔNG re-compose).

2. **Persona spawn (song song)** — đọc panel[], spawn N+1 reviewer instance qua Workflow tool (parallel pattern):
   ```javascript
   const panel = composer.panel  // N+1 persona, đã có RED
   const persona_outs = await parallel(panel.map((p) => () =>
     agent("technical-reviewer", {
       model: "sonnet",
       prompt: `panel_mode: persona
Run ID: ${RUN_ID}
Round: ${ROUND}
Assigned persona: ${JSON.stringify(p)}
Read state files (step_01..step_04 + step_05_technical_reviewer_r${ROUND-1}.json nếu có).
Review CHỈ qua lens persona này. Output reviewer_persona.json.`
     })
   ))
   ```
   Mỗi instance ghi vào `step_05_technical_reviewer_persona_{CODE}_r{ROUND}.json`.

3. **Aggregate** — orchestrator gọi:
   ```bash
   bash .claude/skills/run-pipeline/aggregate_panel.sh "$RUN_ID" "$ROUND"
   ```
   Sinh `step_05_technical_reviewer_r{ROUND}.json` đúng schema reviewer_v2.json. Sau đó chạy schema-validator như step thường.

4. **Routing & retry**: như cũ. Convergence guard (TOTAL_REGRESSION>2) áp trên file aggregated.

**BATCH pipeline — Legacy panel** (chỉ khi env `PANEL_MODE=legacy`): spawn 1 reviewer `panel_mode: legacy_panel`, behavior như Phase 3. Giữ làm fallback nếu Workflow tool không khả dụng.

Round 1: file `step_05_technical_reviewer_r1.json`. Round N: `_rN.json`.

#### Convergence guard (Phase 2)

Track biến `TOTAL_REGRESSION=0`. Sau mỗi round Reviewer:

```bash
REG_COUNT=$(python -c "
import json,sys
d=json.load(open('.pipeline_state/$RUN_ID/step_05_technical_reviewer_r${ROUND}.json'))
print(d.get('regression_check',{}).get('regression_count',0))
")
TOTAL_REGRESSION=$((TOTAL_REGRESSION + REG_COUNT))
bash observability/log_event.sh $RUN_ID REGRESSION "round=$ROUND" "count=$REG_COUNT" "total=$TOTAL_REGRESSION"

if [ "$TOTAL_REGRESSION" -gt 2 ]; then
  bash observability/log_event.sh $RUN_ID LOOP_DETECTED "total_regression=$TOTAL_REGRESSION"
  bash state-store/update.sh $RUN_ID set ".status" '"ACCEPTED_WITH_RISK"'
  bash state-store/update.sh $RUN_ID set ".final_verdict" '"ACCEPTED_WITH_RISK_LOOP_DETECTED"'
  # Skip mọi retry, đi thẳng Writer
  goto Step 6
fi
```

Writer phải in banner đặc biệt khi `final_verdict == "ACCEPTED_WITH_RISK_LOOP_DETECTED"`:
> ⚠️ **Pipeline phát hiện oscillation** — Reviewer điều hướng lặp giữa các agent gây regression (>2). Báo cáo được chấp nhận với rủi ro chưa giải quyết.

#### Hành vi theo `retry_mode`:

#### `retry_mode == "fast"` (1 lượt)
- Reviewer chạy, sinh issues, save vào `r1`.
- Đi thẳng Writer; ghi mọi issue với `accepted_in_fast_mode: true` vào review_log.jsonl.
- Writer in banner cảnh báo.

#### `retry_mode == "strict"` (max 3/agent — DEFAULT)
Parse output reviewer:
- `verdict == "APPROVED"` → goto Writer.
- `verdict == "REVISION_REQUIRED"`:
  - Group issues theo `target_agent`.
  - Mỗi target:
    - `manifest.retry_count[target] >= 3` → mark `ACCEPTED_WITH_RISK`, append vào review_log, skip.
    - Ngược lại:
      ```bash
      bash .claude/skills/state-store/update.sh "$RUN_ID" ".retry_count[\"$TARGET\"] += 1"
      bash .claude/skills/observability/log_event.sh "$RUN_ID" RETRY \
        "step=$TARGET" "round=$NEW_RETRY_COUNT" "reason=$REASON"
      bash .claude/skills/state-store/append_review.sh "$RUN_ID" "$ROUND" "$TARGET" "$ISSUES_SUMMARY" "REVISION"
      ```
      Re-spawn agent với prompt **CHỈ chứa issues của target** + path file output cũ:
      ```
      Bạn đang ở vòng retry {NEW_COUNT}/3 cho {TARGET}.
      Đọc output cũ tại: .pipeline_state/{RUN_ID}/step_NN_{TARGET}.json
      Đọc issues từ Reviewer tại: .pipeline_state/{RUN_ID}/step_05_technical_reviewer_r{N}.json (lọc target_agent={TARGET})
      CHỈ sửa các điểm trong issues; KHÔNG regenerate unrelated sections.
      Output JSON đầy đủ schema + _meta.
      ```
  - Sau khi tất cả target re-run xong, save reviewer round mới (`r{N+1}`).

### Step 6 — Writer
Prompt:
```
Run ID: {RUN_ID}
Đọc state đầy đủ:
- step_01_business_analyst.json
- step_02_capability_clusterer.json (nếu BATCH)
- step_03_technology_researcher.json
- step_04_solution_architect.json
- step_05_technical_reviewer_r{N}.json (round cuối — lấy file r{N} có số lớn nhất)
- review_log.jsonl
- step_00_input.json (cho format + retry_mode)
Render báo cáo md/html. Lưu vào results/{slug}_{YYYYMMDD_HHMM}.{ext}.
Output JSON: {"saved_path": "results/...", "_meta": {...}}
```

Save output writer + update manifest:
```bash
bash .claude/skills/state-store/save.sh "$RUN_ID" technical_writer /tmp/writer_out.json
SAVED_PATH=$(jq -r '.saved_path' /tmp/writer_out.json)
bash .claude/skills/state-store/update.sh "$RUN_ID" \
  ".saved_path=\"$SAVED_PATH\" | .status=\"COMPLETED\" | .final_verdict=\"$VERDICT\""
```

## Kết thúc pipeline (lifecycle finalize)

```bash
TOTAL_DURATION=$(( $(date +%s) - PIPELINE_START ))
TOTAL_TOKENS=$(awk -F' \\| ' '/STEP_OK/ {for(i=4;i<=NF;i++){split($i,kv,"="); if(kv[1]=="tokens_in") ti+=kv[2]; else if(kv[1]=="tokens_out") to+=kv[2]}} END {print ti+to}' logs/$RUN_ID/run.log)

bash .claude/skills/observability/log_event.sh "$RUN_ID" END \
  "verdict=$VERDICT" "total_tokens=$TOTAL_TOKENS" "total_duration_s=$TOTAL_DURATION"

# Lifecycle finalize: gen tokens.json, in summary table, optional archive
bash .claude/skills/run-pipeline/finalize.sh "$RUN_ID"
```

Đặt `FINALIZE_ARCHIVE=1` trước khi gọi finalize.sh nếu muốn gzip `.pipeline_state/{run_id}/` thành `.pipeline_state/_archive/{run_id}.tar.gz` (mặc định OFF — giữ state dạng raw để debug).

## Output cuối cho user
```
✅ Pipeline hoàn tất ({mode})

📄 Báo cáo: results/{slug}_{timestamp}.{ext}
🆔 Run ID: {run_id}
🔁 Feedback rounds: <agent>={N} ...
⚠️  Risks accepted: {K} items
📊 Review log: .pipeline_state/{run_id}/review_log.jsonl
📈 Cost report: logs/{run_id}/tokens.json
```

## Resume mode

Nếu được gọi từ `/resume-pipeline` với `RESUME_FROM_STEP`:
1. Skip Bước 0a/0b/0c (đã có).
2. Đọc `.pipeline_state/{RUN_ID}/step_00_input.json` để lấy mode + format + retry_mode.
3. Đọc `manifest.json` để biết step kế tiếp.
4. Log event RESUME.
5. Tiếp tục pipeline từ step kế tiếp.

## Edge cases

| Tình huống | Xử lý |
|---|---|
| `docs/` rỗng | Hỏi user clarify, không tạo run_id |
| Agent return non-JSON | Re-spawn 1 lần với prompt "Output đúng JSON, không kèm prose" |
| Agent return JSON thiếu `_meta` | Log WARN; tokens_in/out=null trong runs.log |
| Mermaid fail sau 3 vòng | Mark `ACCEPTED_WITH_RISK`, log review_log, banner trong report |
| WebSearch không khả dụng | Researcher dùng kiến thức nội tại, ghi "no live search" |
| BATCH N>30 | Architect được phép canonical theo `pattern_group` (Phase 3 sẽ tự enforce) |
| Excel header khó nhận | BA log warning vào `assumptions`, tiếp tục |
| Save fail (jq lỗi, disk full) | Pipeline fail, log STEP_FAIL, dừng — user fix disk + resume |

## Termination guarantee
- Tổng retry ≤ 4 × 3 = 12.
- Mỗi agent timeout 10 phút → mark fail, log STEP_FAIL, tiếp tục.
- Pipeline luôn dừng và sinh file output.

## Ràng buộc Phase 1
- **KHÔNG nhồi state vào prompt agent** — luôn pass file path.
- **Mỗi step phải gọi `state-store.save`** trước khi qua step sau.
- **Mỗi step phải gọi `observability.log_event`** với tokens + duration.
- **`_meta` field bắt buộc** trong output mọi agent. Thiếu → WARN, không crash.
- **Crash giữa pipeline** → user phải resume được qua `/resume-pipeline {run_id}` mà không mất artifact đã save.
