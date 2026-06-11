---
description: Chạy full multi-agent pipeline (BA → Capability → Researcher → Architect → Reviewer → Writer). Tự quét docs/, hỏi format + retry mode, sinh báo cáo md/html vào results/.
---

Bạn được yêu cầu chạy full pipeline multi-agent.

**Bắt buộc** sử dụng skill `run-pipeline` để thực thi. Skill này nằm ở `.claude/skills/run-pipeline/SKILL.md` và chứa toàn bộ logic orchestration.

Quy trình:
1. Load skill `run-pipeline` (đọc file SKILL.md).
2. Thực hiện đúng các bước trong skill — KHÔNG bỏ qua Bước 0a (Glob docs/), Bước 0b (AskUserQuestion 2 câu: format + retry_mode), Bước 0c (gọi input-reader cho từng file).
3. Spawn các subagent theo đúng thứ tự pipeline (SINGLE 5 bước hoặc BATCH 6 bước).
4. Giữ state trong context của bạn (main loop) và pass-by-prompt cho từng subagent.
5. Cuối cùng spawn `technical-writer` để sinh file vào `results/`, trả đường dẫn cho user.

Tham số bổ sung từ user (nếu có): $ARGUMENTS
