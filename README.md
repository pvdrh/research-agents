# Multi-Agent Research System

> Hệ thống tự động hóa quy trình **Phân tích Use Case → Nghiên cứu công nghệ → Thiết kế kiến trúc → Kiểm duyệt → Viết báo cáo** bằng Claude Code Subagents + Skills.

Không cần code. Không cần Python (trừ khi đọc Excel/PDF). Chỉ cần Claude Code + thư mục này + 1 lệnh.

---

## 1. Hệ thống này làm gì cho bạn?

Bạn có một **ý tưởng / yêu cầu CNTT** (chatbot CSKH, hệ thống đặt phòng, nền tảng e-learning, hệ thống chấm công, đối soát tài chính, hồ sơ bệnh án điện tử, v.v.).

Bạn nói/đưa cho hệ thống:
- 📝 **1 đoạn mô tả văn xuôi**, HOẶC
- 📄 **1 file mô tả** (.pdf, .docx, .txt, .md, .jpg/.png chụp slide), HOẶC
- 📊 **1 file Excel** chứa N nghiệp vụ cần phân tích cùng lúc

Hệ thống tự động:
1. Phân tích yêu cầu (BA).
2. Gom các nghiệp vụ thành "capability" dùng chung (nếu BATCH).
3. Nghiên cứu công nghệ cập nhật ≤ 12 tháng.
4. Thiết kế kiến trúc + vẽ sơ đồ Mermaid.
5. Hội đồng chuyên gia phản biện, có thể điều chỉnh % tự động hóa.
6. Xuất báo cáo `.md` hoặc `.html` (SPA dashboard đẹp như mẫu) vào thư mục `results/`.

---

## 2. Hai chế độ chạy

### 🔹 SINGLE — 1 use case
- Input: 1 đoạn mô tả hoặc 1 file `.pdf/.docx/.txt/.md/.jpg/.png`.
- Output: 1 báo cáo **article** (1 trang dài, có TOC, sơ đồ, bảng so sánh stack, đánh giá rủi ro).
- Ví dụ: *"Tôi cần thiết kế hệ thống chatbot tư vấn bảo hiểm 24/7 cho công ty 200 nhân viên, ngân sách $50k/năm."*

### 🔹 BATCH — N use case từ Excel
- Input: 1 file `.xlsx` với danh sách N item (mỗi dòng = 1 nghiệp vụ).
- Output: 1 báo cáo **SPA dashboard** `.html` với:
  - Sidebar navigation (Tổng quan / Kiến trúc / Hội đồng / C1..Cn capabilities / Cases).
  - Mỗi case có sơ đồ luồng to-be, sequence diagram, bảng exception.
  - Mỗi capability (năng lực dùng chung) có sơ đồ internal, stack đề xuất, KPI.
- Ví dụ: *"Đây là 60 quy trình thủ công trong công ty mình, hãy thiết kế nền tảng tự động hóa."*

---

## 3. Yêu cầu cài đặt

### Bắt buộc
- **[Claude Code](https://claude.ai/code)** đã cài và đăng nhập.
- Hệ điều hành Windows / macOS / Linux.

### Tùy chọn (chỉ khi cần đọc file)
| Định dạng input | Cần có |
|---|---|
| `.txt`, `.md` | (không cần gì) |
| `.jpg`, `.png` | (không cần — Claude đọc ảnh trực tiếp) |
| `.pdf`, `.docx`, `.xlsx`, `.html` | Python 3.10+ trên máy (hệ thống TỰ tạo `.venv` và cài lib khi cần) |
| `.doc` / `.xls` cũ | LibreOffice (`soffice`) để convert |
| OCR offline (PDF scan, ảnh nhiều) | Tesseract + traineddata `vie`+`eng` |

> **Lưu ý quan trọng — Python venv:**
> Khi cần parse file phức tạp, skill `input-reader` TỰ ĐỘNG tạo `.venv/` ở root dự án và cài `openpyxl/pypdf/python-docx/...` vào ĐÓ — KHÔNG đụng vào Python hệ thống của bạn.
> Bạn không cần `pip install` thủ công gì hết. Chỉ cần đảm bảo có Python 3.10+ trên máy.

---

## 4. Cài đặt 3 bước

### Bước 1 — Clone / copy thư mục này
```
research/
├── CLAUDE.md
├── DESIGN.md
├── README.md          ← bạn đang đọc
├── docs/              ← bỏ file input của bạn vào đây
├── results/           ← báo cáo sinh ra ở đây
└── .claude/
    ├── agents/        (6 agent)
    └── skills/        (5 skill)
```

### Bước 2 — Mở Claude Code tại thư mục này
```bash
cd /đường/dẫn/đến/research
claude
```

(Hoặc dùng IDE extension VS Code, mở folder.)

### Bước 3 — Verify
Trong Claude Code, gõ:
```
/help
```
Nếu thấy danh sách lệnh và `/run-pipeline` xuất hiện trong skills → OK.

---

## 5. Chạy lần đầu — hướng dẫn từng bước

### Quy tắc chung
1. Bỏ TẤT CẢ file mô tả vào thư mục `docs/`.
2. Gõ `/run-pipeline`.
3. Trả lời 2 câu hỏi:
   - **Format**: Markdown (`md`) hay HTML (`html`)?
   - **Retry mode**: `Strict` (chất lượng cao, max 3 vòng phản biện/agent, ~5-15 phút) hay `Fast` (1 lần duy nhất, không retry, ~2-5 phút)?
4. Hệ thống tự đọc toàn bộ `docs/`, tự detect SINGLE/BATCH, tự chạy 5-6 bước, lưu kết quả vào `results/`.

---

### 🎯 Tình huống A: Bạn chỉ có 1 ý tưởng văn xuôi (chưa có file)

Tạo file `docs/use_case.md` chứa mô tả:

```markdown
# Đặt lịch khám online

Tôi muốn xây hệ thống đặt lịch khám online cho phòng khám đa khoa 50 bác sĩ,
3 chi nhánh tại Hà Nội. Yêu cầu: bệnh nhân chọn bác sĩ + khung giờ, thanh toán
online, nhắc lịch SMS, tích hợp với hệ thống HIS hiện có (Oracle). Ngân sách
~$80k năm đầu, team 3 dev có kinh nghiệm Node.js + React.
```

Trong Claude Code:
```
/run-pipeline
```

Trả lời: format `html`, retry `Strict`. Đợi ~5-10 phút.

```
✅ Pipeline hoàn tất (single)
📄 Báo cáo: results/dat_lich_kham_online_20260611_1430.html
```

Mở file đó bằng trình duyệt → đọc báo cáo.

---

### 🎯 Tình huống B: Bạn có 1 file `.docx` / `.pdf` mô tả

1. Copy file vào thư mục `docs/`:
   ```
   docs/yeu_cau_he_thong.docx
   ```

2. Gõ `/run-pipeline`.

3. Trả lời 2 câu hỏi (format + retry mode).

4. Đợi → mở file ở `results/`.

---

### 🎯 Tình huống C: Bạn có 1 file Excel N nghiệp vụ (BATCH)

1. Chuẩn bị file Excel theo cấu trúc gợi ý (tối thiểu):

   | Rank | Mô tả nghiệp vụ | Effort (giờ/tháng) |
   |---|---|---|
   | 1 | Đối soát hóa đơn nhà cung cấp với phiếu nhập kho | 720 |
   | 2 | Phê duyệt yêu cầu thanh toán >50tr qua 3 cấp | 480 |
   | ... | ... | ... |

   - Cột text dài nhất → tự nhận diện là **mô tả**.
   - Cột số đầu tiên → tự nhận diện là **giá trị chính** (effort / story points / budget / score — tùy domain bạn).
   - Cột STT → `rank`.
   - Nhiều sheet (vd "Chi nhánh A" / "Chi nhánh B") → tự phân partition.

2. Bỏ file vào `docs/`:
   ```
   docs/danh_sach_60_nghiep_vu.xlsx
   ```

3. Chạy `/run-pipeline`, trả lời format `html` + retry `Strict`.

4. Hệ thống tự detect BATCH mode → chạy 6 bước → sinh **SPA dashboard**. Mở `.html` trong browser.

---

### 🎯 Tình huống D: Bạn có NHIỀU file cùng lúc

Bỏ TẤT CẢ vào `docs/`, ví dụ:
```
docs/
├── 60_nghiep_vu.xlsx       ← tabular → trigger BATCH mode
├── kien_truc_hien_tai.png  ← ảnh sơ đồ → context phụ trợ
├── policy_compliance.pdf   ← document → context bổ sung
└── notes.md                ← ghi chú thêm
```

Chạy `/run-pipeline`. Hệ thống gộp toàn bộ làm input. File `.xlsx` quyết định BATCH mode, các file còn lại bổ sung context cho BA.

---

## 6. Cấu trúc thư mục — bạn cần biết gì?

```
research/
├── CLAUDE.md           ← luật chung cho Claude khi chạy (không sửa)
├── DESIGN.md           ← design tokens Notion (purple #5645d4 + Inter)
├── README.md           ← bạn đang đọc
│
├── docs/               ← 📥 BỎ FILE INPUT CỦA BẠN VÀO ĐÂY
│   └── ...
│
├── results/            ← 📤 BÁO CÁO ĐƯỢC TẠO Ở ĐÂY
│   ├── {slug}_{YYYYMMDD_HHMM}.html
│   └── {slug}_{YYYYMMDD_HHMM}.md
│
└── .claude/            ← bộ não hệ thống (KHÔNG sửa trừ khi biết rõ)
    ├── agents/
    │   ├── business-analyst.md
    │   ├── capability-clusterer.md
    │   ├── technology-researcher.md
    │   ├── solution-architect.md
    │   ├── technical-reviewer.md
    │   └── technical-writer.md
    └── skills/
        ├── run-pipeline/        (orchestrator)
        ├── input-reader/        (đọc đa định dạng)
        ├── mermaid-validator/   (check syntax sơ đồ)
        ├── design-token-loader/ (load tokens từ DESIGN.md)
        └── html-report-render/  (render HTML)
```

**Quy tắc vàng cho người mới:**
- ✅ Bỏ file input vào `docs/`.
- ✅ Đọc báo cáo ở `results/`.
- ❌ KHÔNG sửa `.claude/` và `CLAUDE.md` / `DESIGN.md` trừ khi biết mình đang làm gì.

---

## 7. Quy trình bên trong (để bạn hiểu tại sao mất 3-8 phút)

```
Bạn nhập use case
       │
       ▼
┌──────────────────┐
│ 1. BA            │ → FR/NFR (yêu cầu chức năng/phi chức năng)
│ business-analyst │   (Nếu BATCH: thêm cases[] + pattern_groups)
└────────┬─────────┘
         │
         ▼  (chỉ BATCH)
┌──────────────────────┐
│ 2. Capability        │ → C1..Cn năng lực dùng chung
│ capability-clusterer │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│ 3. Researcher        │ → 2-3 tech stack (SINGLE) hoặc
│ technology-researcher│   stack từng capability (BATCH)
└────────┬─────────────┘  (WebSearch ≤12 tháng)
         │
         ▼
┌──────────────────────┐
│ 4. Architect         │ → kiến trúc + sơ đồ Mermaid
│ solution-architect   │   (self-check syntax)
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│ 5. Reviewer          │ → APPROVED hoặc REVISION
│ technical-reviewer   │   BATCH: panel 3-5 chuyên gia
└────────┬─────────────┘
         │
         ├─ REVISION → quay lại Researcher/Architect (max 3 lần/agent)
         │
         ▼ APPROVED
┌──────────────────────┐
│ 6. Writer            │ → file .md hoặc .html vào results/
│ technical-writer     │
└──────────────────────┘
```

**Tổng thời gian:** SINGLE ~3 phút · BATCH 5-15 phút (tùy N case).

---

## 8. FAQ

### ❓ Báo cáo bằng tiếng Anh được không?
Hiện tại mặc định tiếng Việt. Muốn tiếng Anh phải sửa prompt từng agent trong `.claude/agents/`.

### ❓ Báo cáo theme khác (không Notion purple) được không?
Phải sửa `DESIGN.md` trước (đó là nguồn token màu/font duy nhất). Đừng sửa HTML output trực tiếp.

### ❓ File Excel của tôi có cột tùy chỉnh (vd "% tiết kiệm", "Tần suất"), hệ thống có hiểu không?
Có. BA tự đọc `header_map` từ excel và diễn giải ý nghĩa cột theo domain. Bạn không cần đặt tên cột theo mẫu nào.

### ❓ Hệ thống có "đoán mò" công nghệ không?
Không. Researcher dùng WebSearch + WebFetch để lấy nguồn ≤ 12 tháng. Mỗi đề xuất có URL trích dẫn ở Appendix báo cáo.

### ❓ Nếu sơ đồ Mermaid lỗi syntax?
Có skill `mermaid-validator` tự check trước khi Reviewer duyệt. Nếu sau 3 vòng vẫn lỗi → embed raw + warning banner (không block pipeline).

### ❓ Tôi muốn chạy lại với feedback của mình
Sau khi nhận báo cáo, nói với Claude:
```
Báo cáo results/xxx.html cần sửa: thay PostgreSQL bằng MongoDB,
thêm yêu cầu offline-first cho mobile. Chạy lại từ Researcher.
```
Hệ thống không có "incremental rerun" tự động — đơn giản nhất là chạy `/run-pipeline` mới với prompt rõ hơn.

### ❓ Tôi không có Python, có chạy được không?
Được — nếu input là văn xuôi hoặc `.txt/.md/.jpg/.png`. PDF/DOCX/XLSX cần Python 3.10+ trên máy (chỉ cần có, không cần cài lib gì — hệ thống tự tạo `.venv` và cài lib cần thiết).

### ❓ `.venv/` ở đâu, có ảnh hưởng Python hệ thống không?
`.venv/` nằm ở root dự án (`research/.venv/`). Hoàn toàn ISOLATED — không đụng vào `pip` toàn cục. Muốn xóa sạch chỉ cần `rm -rf .venv` rồi chạy lại.

### ❓ Strict vs Fast mode chọn cái nào?
- **Strict** (mặc định khuyến nghị): cho báo cáo chính thức, đề xuất gửi sếp/khách hàng. Reviewer phản biện thật, hạ % tự động hóa nếu BA quá lạc quan. ~5-15 phút.
- **Fast**: cho prototype nhanh, brainstorm, thử nghiệm prompt. ~2-5 phút. Có banner cảnh báo "chưa qua phản biện" ở đầu báo cáo.

### ❓ Pipeline chạy mãi không xong?
Mỗi agent timeout 10 phút, tổng retry tối đa 12 vòng → pipeline LUÔN dừng. Nếu treo > 20 phút → ngắt và báo lại.

---

## 9. Gọi từng agent riêng lẻ (nâng cao)

Nếu chỉ muốn 1 bước (vd chỉ research công nghệ, không cần BA):

```
/agents
```
hoặc trực tiếp:
```
Dùng agent technology-researcher để research stack cho yêu cầu: ...
```

Tên các agent có sẵn:
- `business-analyst`
- `capability-clusterer` (BATCH only)
- `technology-researcher`
- `solution-architect`
- `technical-reviewer`
- `technical-writer`

---

## 10. Khi gặp lỗi

| Lỗi | Cách xử lý |
|---|---|
| `FILE_NOT_FOUND` | Kiểm tra đường dẫn file trong `docs/` — phải đúng chính tả + extension. |
| `PYTHON_UNAVAILABLE` | Cài Python 3.10+ trên máy. Hệ thống tự lo phần venv + pip. |
| `PARSER_UNAVAILABLE: need openpyxl` | Hiếm khi xảy ra (venv tự cài). Nếu gặp: xóa `.venv/` rồi chạy lại — skill sẽ tạo venv mới. |
| `OCR_UNAVAILABLE` | Cài `tesseract` + traineddata, hoặc gửi ảnh trực tiếp cho Claude (nó tự đọc bằng vision). |
| Pipeline báo `ACCEPTED_WITH_RISK` | Báo cáo vẫn sinh nhưng có rủi ro chưa giải quyết — xem Appendix Review Log để biết. |
| HTML mở ra trắng | Kiểm tra internet (Mermaid CDN cần online), F12 xem console error. |
| Báo cáo thiếu sơ đồ | Có thể Mermaid syntax fail — xem file `.md` (raw code) hoặc Review Log. |

---

## 11. Tài liệu sâu hơn

| Bạn muốn... | Đọc file |
|---|---|
| Hiểu luật chung của hệ thống | `CLAUDE.md` |
| Hiểu design tokens HTML | `DESIGN.md` |
| Tùy biến quy trình review / panel | `.claude/agents/technical-reviewer.md` |
| Tùy biến khung HTML SPA | `.claude/skills/html-report-render/SKILL.md` |
| Tùy biến luồng orchestration | `.claude/skills/run-pipeline/SKILL.md` |
| Hỗ trợ thêm định dạng input mới | `.claude/skills/input-reader/SKILL.md` |
| Tùy biến output schema 1 agent | file agent tương ứng trong `.claude/agents/` |

---

## 12. Triết lý thiết kế

- **Generic-first** — hệ thống không bias domain. Cùng pipeline chạy được cho healthcare, fintech, e-commerce, logistics, edtech, public sector... Capability list + panel persona sinh động theo domain bạn nhập.
- **Stay-in-lane** — mỗi agent làm đúng việc của mình. BA không chọn tech. Researcher không vẽ kiến trúc. Architect không đổi stack. Reviewer chỉ flag, không tự sửa.
- **Always terminate** — max 3 retry/agent, timeout 5 phút/agent. Pipeline luôn dừng và sinh file (kèm rủi ro nếu có).
- **Notion design system** — tất cả HTML output dùng tokens từ `DESIGN.md`. Không hard-code màu trong skill/agent.

---

## 13. License & Credits

Hệ thống chạy thuần trên Claude Code (Anthropic). Không có code production. Không thu thập dữ liệu.

Mọi báo cáo sinh ra thuộc về bạn.

---

**Bắt đầu ngay:**
```bash
cd research/
claude
> /run-pipeline
```

Chúc bạn thiết kế hệ thống vui vẻ. 🚀
