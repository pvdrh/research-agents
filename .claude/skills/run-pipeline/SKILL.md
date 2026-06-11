---
name: run-pipeline
description: Orchestrator end-to-end. Detect SINGLE (1 use case văn xuôi) hoặc BATCH (.xlsx N item) → chạy 6 agent (BA → capability-clusterer chỉ ở BATCH → Researcher → Architect → Reviewer panel → Writer) có feedback loop, sinh báo cáo md/html. Dùng khi user gõ /run-pipeline hoặc yêu cầu chạy toàn bộ.
---

# Run Pipeline — Multi-Agent Orchestrator

## Khi nào dùng
User gõ `/run-pipeline`. Skill TỰ ĐỘNG quét toàn bộ `docs/` làm input — user không cần chỉ định file.

## Quy trình tiền-chạy (BẮT BUỘC trước Step 1)

### Bước 0a — Quét `docs/`
- Dùng `Glob` liệt kê TOÀN BỘ file trong `docs/` (recursive). Lọc bỏ file ẩn (`.DS_Store`, `~$*`, `.tmp`).
- Nếu rỗng → hỏi user "Thư mục `docs/` đang trống. Bạn muốn dán mô tả use case văn xuôi trực tiếp, hay bỏ file vào `docs/` rồi chạy lại?". Dừng nếu user không cung cấp.

### Bước 0b — Hỏi user 2 câu (bắt buộc, dùng AskUserQuestion)

**Câu 1 — Format output:**
```
Bạn muốn báo cáo định dạng nào?
- Markdown (.md) — gọn nhẹ, dễ chia sẻ qua GitHub/Notion
- HTML (.html) — SPA dashboard đẹp, render Mermaid client-side
```

**Câu 2 — Retry mode:**
```
Chế độ chạy?
- Strict — Reviewer cho phép tối đa 3 vòng retry/agent. Chất lượng cao nhất, lâu hơn (5-15 phút).
- Fast — Mỗi agent chạy 1 lần duy nhất, KHÔNG retry. Nhanh (2-5 phút), nhưng có thể bỏ qua issue Reviewer phát hiện.
```

Ghi 2 lựa chọn vào `state.input.format` và `state.input.retry_mode` (`strict` | `fast`).

### Bước 0c — Đọc input đa định dạng
- BA gọi skill `input-reader` cho TỪNG file trong `docs/`. Skill tự bootstrap `.venv` và cài lib cần thiết.
- Gộp kết quả:
  - Có ≥1 file `kind=tabular` → BATCH mode. Tất cả tabular file gộp vào `requirements.cases[]`.
  - Không có tabular, có ≥1 file `text/document` → SINGLE mode. Gộp content làm `use_case_text`.
  - Có thêm `image_description` → đính kèm làm context phụ trợ.

## Detect mode (sau bước 0c)
- ≥1 file `kind=tabular` → BATCH.
- Còn lại → SINGLE.
- User có thể ép qua prompt (vd "chạy SINGLE từ file xlsx này, coi mỗi dòng là 1 yêu cầu phụ").

## Pipeline

### SINGLE (5 bước)
```
Step 1: business-analyst         → state.requirements (v1)
Step 2: technology-researcher    → state.tech_stack (v1)
Step 3: solution-architect       → state.architecture (v1)
Step 4: technical-reviewer       → APPROVED | REVISION_REQUIRED
        ├── REVISION → loop về step 2 hoặc 3 (max 3/agent)
        └── APPROVED → Step 5
Step 5: technical-writer         → file vào results/
```

### BATCH (6 bước)
```
Step 1: business-analyst         → state.requirements (v2 batch, có cases[])
Step 2: capability-clusterer     → state.capabilities + case_capability_map
Step 3: technology-researcher    → state.tech_stack (v2 per-capability)
Step 4: solution-architect       → state.architecture (v2 batch, có overall + per-case fmd/mmd/exc)
Step 5: technical-reviewer       → panel verdict + case_adjustments + capability_verdicts
        ├── REVISION → loop về 2 / 3 / 4 tùy target (max 3/agent)
        └── APPROVED → Step 6
Step 6: technical-writer         → file vào results/
```

## State (shared blackboard)

> **Lưu ý quan trọng về state**: Claude Code KHÔNG có persistent shared memory giữa các subagent — mỗi subagent là 1 conversation độc lập. Orchestrator (main-loop Claude đang chạy skill này) phải tự giữ object `state` dưới đây TRONG CONTEXT của mình, rồi serialize phần liên quan vào prompt khi spawn subagent kế tiếp. KHÔNG ghi state ra file (trừ khi user yêu cầu debug); KHÔNG giả định subagent đọc được state của nhau.


```json
{
  "mode": "single|batch",
  "input": {
    "docs_files": ["docs/...", "docs/..."],
    "use_case_text": "...",
    "format": "md|html",
    "retry_mode": "strict|fast"
  },
  "requirements": null,
  "capabilities": null,
  "case_capability_map": null,
  "tech_stack": null,
  "architecture": null,
  "review_log": [],
  "retry_count": {
    "business-analyst": 0,
    "capability-clusterer": 0,
    "technology-researcher": 0,
    "solution-architect": 0
  },
  "final_verdict": null,
  "saved_path": null
}
```

## Quy tắc orchestration

### Step 1 — BA
Spawn `business-analyst` với prompt:
```
Mode được detect: {SINGLE|BATCH}
Use case (text): {use_case_text}
Xlsx path (nếu BATCH): {xlsx_path}
Đọc thêm tài liệu trong docs/ qua Glob+Read.
Output JSON đúng schema v1 (single) hoặc v2 (batch).
```
Parse JSON → `state.requirements`.

### Step 2 (chỉ BATCH) — Capability Clusterer
```
Requirements:
{state.requirements}

Phân cụm capability theo domain, output JSON đúng schema.
```
Parse → `state.capabilities + state.case_capability_map`.

### Step 3 — Researcher
SINGLE prompt: input `requirements`.
BATCH prompt: input `requirements + capabilities + case_capability_map`.
Parse → `state.tech_stack`.

### Step 4 — Architect
SINGLE prompt: input `requirements + tech_stack`.
BATCH prompt: input đầy đủ. Bắt buộc self-check tất cả Mermaid qua `mermaid-validator`.
Parse → `state.architecture`.

### Step 5 — Reviewer (feedback loop) 🔁
SINGLE: 1 reviewer. BATCH: Expert Panel (3–5 persona động theo domain).

Hành vi phụ thuộc `state.input.retry_mode`:

#### `retry_mode == "fast"` (1 lần, KHÔNG retry)
- Reviewer vẫn chạy + sinh báo cáo issues.
- Bất kể verdict gì → đi thẳng Writer.
- Mọi issue được ghi vào `state.review_log` với flag `accepted_in_fast_mode: true`.
- Writer phải in 1 banner cảnh báo ở đầu báo cáo: "⚠️ Chạy ở chế độ Fast — chưa qua vòng phản biện. Xem Appendix để biết các issue Reviewer đã ghi nhận."

#### `retry_mode == "strict"` (max 3 retry/agent — DEFAULT)
Parse output:
- `verdict == "APPROVED"` → goto Writer.
- `verdict == "REVISION_REQUIRED"`:
  - Group issues theo `target_agent`.
  - Với mỗi target:
    - `state.retry_count[target] >= 3` → mark `ACCEPTED_WITH_RISK`, ghi `state.review_log`, skip.
    - Ngược lại: `retry_count++`, re-spawn agent đó với prompt **chỉ chứa** issues của target + previous output. Yêu cầu "CHỈ sửa các điểm trong issues, KHÔNG regenerate unrelated sections".
    - Cập nhật state từ output mới.
  - Sau khi tất cả target re-run, quay lại Step 5.
- BATCH: nếu có `case_adjustments[]`, áp `new_potential` vào `state.architecture.cases[i].automation_potential_revised`.
- Ghi mọi vòng vào `state.review_log` (round, target_agent, issues_summary, verdict).

### Step 6 — Writer
SINGLE: render md hoặc gọi `html-report-render` cho html.
BATCH: tương tự nhưng skill render SPA dashboard.

File path: `results/{slug}_{YYYYMMDD_HHMM}.{ext}`. Slug = lowercase + gạch dưới + bỏ dấu + max 50.

## Output cuối cho user
```
✅ Pipeline hoàn tất ({mode})

📄 Báo cáo: results/{slug}_{timestamp}.{ext}
🔁 Feedback rounds: <agent>={N} ...
⚠️  Risks accepted: {K} items
📊 Review log: xem Appendix
```

## Edge cases

| Tình huống | Xử lý |
|---|---|
| `docs/` rỗng, không có use case | Ask user clarify |
| User không chỉ định format | Default `md` |
| Agent trả JSON sai schema | Re-spawn 1 lần với prompt "Output JSON đúng schema, không kèm prose" |
| Mermaid fail validator sau 3 vòng | Mark `ACCEPTED_WITH_RISK`, embed raw + warning banner |
| WebSearch không khả dụng | Researcher dùng kiến thức nội tại, ghi rõ "no live search" |
| BATCH: > 30 case | Cho phép Architect chỉ vẽ canonical theo `pattern_group`, các case khác reuse + ghi rõ |
| Excel header không nhận diện | BA log warning vào `assumptions`, vẫn tiếp tục |

## Termination guarantee
- Tổng retry ≤ 4 × 3 = 12 (4 agent × 3 vòng), thường thấp hơn.
- Mỗi agent timeout 10 phút → mark fail, ghi review_log, tiếp tục.
- Pipeline luôn dừng và sinh file output (có thể kèm rủi ro).
