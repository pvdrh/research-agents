---
name: observability
description: Log mọi pipeline run vào `logs/runs.log` (master append-only) + `logs/{run_id}/run.log` (detail) + `logs/{run_id}/tokens.json` (summary). Cung cấp `log_event` + `summarize`. Mỗi agent trả `_meta.tokens_in/_meta.tokens_out` để orchestrator capture. Bash thuần, không Python.
---

# Observability

## Mục đích
- Mọi pipeline run có dấu vết: tokens, duration, retry, lỗi.
- Debug khi report sai → mở `logs/{run_id}/run.log` xem rõ step nào tốn nhất, retry vì lý do gì.
- Cost report: tổng token / run → so sánh strict vs fast mode.

## File layout

```
logs/
├── runs.log                          # master append-only, mỗi dòng 1 event
└── {run_id}/
    ├── run.log                       # detail log per-run
    └── tokens.json                   # summary: tokens per step + total
```

## Master log format `logs/runs.log`

Plain text, pipe-separated, dễ grep + dễ tail:

```
2026-06-15T07:30:01Z | run_pending_20260615_1430_a3f7 | START   | mode=null  | docs=docs/usecase.md
2026-06-15T07:30:43Z | run_chatbot_csk_20260615_1430_a3f7 | RENAME  | new_slug=chatbot_csk
2026-06-15T07:30:43Z | run_chatbot_csk_20260615_1430_a3f7 | STEP_OK | step=business_analyst | tokens_in=8200 | tokens_out=4100 | duration_s=42
2026-06-15T07:31:01Z | run_chatbot_csk_20260615_1430_a3f7 | STEP_OK | step=technology_researcher | tokens_in=4500 | tokens_out=2800 | duration_s=18
2026-06-15T07:35:22Z | run_chatbot_csk_20260615_1430_a3f7 | RETRY   | step=solution_architect | round=2 | reason=mermaid_syntax
2026-06-15T07:40:00Z | run_chatbot_csk_20260615_1430_a3f7 | END     | verdict=APPROVED | total_tokens=87500 | total_duration_s=599
```

Event types:
- `START` — pipeline khởi tạo.
- `RENAME` — run_id đổi slug sau BA.
- `STEP_OK` — 1 agent step hoàn thành (kèm tokens + duration).
- `STEP_FAIL` — agent fail/timeout.
- `RETRY` — Reviewer route lại 1 agent (kèm round + reason).
- `WARN` — schema sai, mermaid warning, ... (không fail).
- `END` — pipeline kết thúc (verdict + total).

## API

### `log_event <run_id> <event_type> [key=value]...`

```bash
bash .claude/skills/observability/log_event.sh "$RUN_ID" STEP_OK \
  "step=business_analyst" "tokens_in=8200" "tokens_out=4100" "duration_s=42"
```

Đẩy vào `logs/runs.log` + `logs/{run_id}/run.log`.

### `summarize <run_id>`

Đọc `logs/{run_id}/run.log` → tính tổng tokens, duration, retry count, ghi vào `logs/{run_id}/tokens.json`:

```json
{
  "run_id": "run_chatbot_csk_20260615_1430_a3f7",
  "verdict": "APPROVED",
  "total_tokens_in": 52300,
  "total_tokens_out": 35200,
  "total_tokens": 87500,
  "total_duration_s": 599,
  "per_step": [
    {"step": "business_analyst", "tokens_in": 8200, "tokens_out": 4100, "duration_s": 42, "retries": 0},
    {"step": "technology_researcher", "tokens_in": 4500, "tokens_out": 2800, "duration_s": 18, "retries": 0},
    {"step": "solution_architect", "tokens_in": 18500, "tokens_out": 15300, "duration_s": 240, "retries": 1},
    {"step": "technical_reviewer", "tokens_in": 12000, "tokens_out": 4500, "duration_s": 90, "retries": 0},
    {"step": "technical_writer", "tokens_in": 9100, "tokens_out": 8500, "duration_s": 209, "retries": 0}
  ],
  "retry_total": 1
}
```

## Token capture pattern

Mỗi agent BẮT BUỘC trả `_meta` ở root output JSON:

```json
{
  "mode": "single",
  "use_case_summary": "...",
  ...
  "_meta": {
    "tokens_in": 8200,
    "tokens_out": 4100,
    "duration_s": 42,
    "model": "sonnet"
  }
}
```

Orchestrator đọc field này bằng jq + đẩy vào `log_event`. Nếu agent quên `_meta` → log với `tokens_in=null tokens_out=null` + WARN event.

> **Note**: hiện tại Claude Code expose token counts qua API metadata mà subagent có thể đọc — agent dùng `_meta` để self-report. Nếu tương lai có cách orchestrator query trực tiếp, refactor sau.

## Ràng buộc
- `logs/` ở root project (gitignored).
- Master log append-only — KHÔNG bao giờ rewrite.
- Mỗi dòng 1 event — dễ grep/awk/tail.
- Không leak PII vào log (vd content use_case_text → KHÔNG log). Chỉ log metric.
- Nếu `logs/{run_id}/` không tồn tại → `log_event` tự `mkdir -p`.
