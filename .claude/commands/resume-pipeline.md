---
description: Resume một pipeline run đã chạy dở (sau crash, Ctrl+C, hoặc session reset). Đọc `.pipeline_state/{run_id}/manifest.json` để biết step cuối hoàn thành rồi tiếp tục từ step kế tiếp.
---

Bạn được yêu cầu resume pipeline đã chạy dở.

**Tham số**: `$ARGUMENTS` — phải là `run_id` (vd `run_chatbot_csk_20260615_1430_a3f7`). Nếu rỗng → liệt kê các run gần nhất trong `.pipeline_state/` và hỏi user chọn.

Quy trình:

1. **Validate run_id**:
   - Nếu `$ARGUMENTS` rỗng:
     - Chạy `Bash`: `ls -1t .pipeline_state/ | head -10`.
     - Đọc manifest của mỗi run, hiển thị bảng (run_id, current_step, status, created_at).
     - Dùng `AskUserQuestion` cho user chọn 1 run.
   - Nếu `$ARGUMENTS` có giá trị: kiểm `.pipeline_state/$ARGUMENTS/manifest.json` tồn tại; nếu không → báo lỗi.

2. **Đọc manifest**:
   ```bash
   bash .claude/skills/state-store/load.sh $RUN_ID  # liệt kê file đã có
   cat .pipeline_state/$RUN_ID/manifest.json
   ```
   Lấy: `mode`, `current_step`, `completed_steps[]`, `retry_count`, `status`.

3. **Quyết định step kế tiếp**:
   - Map `current_step` → step kế tiếp theo pipeline (xem `.claude/skills/run-pipeline/SKILL.md`).
   - Nếu `status == "COMPLETED"` hoặc `current_step == "technical_writer"` → báo "Pipeline đã xong, file ở `.pipeline_state/$RUN_ID/step_06_technical_writer.json`". Dừng.
   - Nếu `status == "FAILED"` → báo lỗi, hỏi user có muốn restart từ step fail hay không.

4. **Log resume event**:
   ```bash
   bash .claude/skills/observability/log_event.sh $RUN_ID RESUME "from_step=$CURRENT_STEP"
   ```

5. **Load skill `run-pipeline`** và **skip tới step kế tiếp**:
   - Truyền `RUN_ID` + `RESUME_FROM_STEP` vào skill.
   - Skill `run-pipeline` phải hỗ trợ resume mode: đọc input.json + các step đã có từ disk, không hỏi lại format/retry_mode (đã có trong input.json), tiếp tục spawn agent kế tiếp.

6. **Cuối cùng**: trả về đường dẫn báo cáo (giống `/run-pipeline`).

**Edge case**:
- Manifest corrupted JSON → báo lỗi rõ, gợi ý user xóa file đó hoặc chạy `/run-pipeline` mới.
- `step_NN_xxx.json` cuối cùng corrupted → revert về step trước, set `current_step` về step trước đó, spawn lại step bị corrupted.
