# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Mục đích dự án

Hệ thống Multi-Agent tự động hóa quy trình:
**Phân tích Use Case CNTT → Nghiên cứu công nghệ → Thiết kế kiến trúc → Kiểm duyệt → Viết báo cáo**

Hỗ trợ 2 chế độ vận hành:
- **SINGLE** — 1 use case văn xuôi (hoặc 1 file .pdf/.docx/.txt/.md/.jpg/.png mô tả) → 1 báo cáo article.
- **BATCH** — file .xlsx/.csv chứa N nghiệp vụ → báo cáo SPA dashboard với capability mapping + panel review.

Output: `.md` hoặc `.html` (Notion-style design system) lưu trong `results/`.

Hệ thống **generic theo domain**: không bias kế toán/OCR/RPA/SAP. Mỗi pipeline run sinh capability list, persona panel, content theo domain user cung cấp.

## Cấu trúc

```
research/
├── CLAUDE.md                  ← file này (project memory, auto-load)
├── DESIGN.md                  ← design system Notion (token nguồn cho HTML output)
├── README.md                  ← hướng dẫn người dùng
├── .gitignore
├── docs/                      ← input: tài liệu user
├── results/                   ← output: báo cáo .md/.html
├── .venv/                     ← Python venv (auto-tạo bởi input-reader skill)
└── .claude/
    ├── commands/              ← slash command (user gõ /xxx)
    │   └── run-pipeline.md        ← wrapper trigger skill run-pipeline
    ├── agents/                ← 6 subagent (.claude/agents/{name}.md)
    │   ├── business-analyst.md
    │   ├── capability-clusterer.md       ← chỉ chạy ở BATCH mode
    │   ├── technology-researcher.md
    │   ├── solution-architect.md
    │   ├── technical-reviewer.md
    │   └── technical-writer.md
    └── skills/                ← 5 skill (.claude/skills/{name}/SKILL.md)
        ├── run-pipeline/          ← orchestrator end-to-end
        ├── input-reader/          ← đọc đa định dạng: xlsx/pdf/docx/txt/md/jpg/png/html
        ├── mermaid-validator/     ← check cú pháp Mermaid
        ├── design-token-loader/   ← load DESIGN.md tokens
        └── html-report-render/    ← render HTML (SINGLE article hoặc BATCH SPA)
```

**Cơ chế trigger**:
- **Slash command** `/run-pipeline` → user gõ trong chat → Claude load `.claude/commands/run-pipeline.md` → command yêu cầu Claude load skill `run-pipeline` để chạy.
- **Skill** auto-load khi description match yêu cầu user, hoặc được command/agent gọi đến tên.
- **Subagent** spawn qua `Agent` tool với `subagent_type={name}`. Không có shared memory giữa các subagent — orchestrator phải pass state qua prompt.

## Cách dùng

### Chạy full pipeline
```
/run-pipeline
```
Skill TỰ ĐỘNG quét TOÀN BỘ file trong `docs/`. Trước khi chạy sẽ hỏi 2 câu (AskUserQuestion):
1. Format output: `md` hoặc `html`.
2. Retry mode: `strict` (max 3 retry/agent, chất lượng cao) hoặc `fast` (1 lần, không retry, nhanh).

Sau đó tự detect mode (SINGLE/BATCH dựa trên file có/không có tabular), chạy lần lượt agent, lưu kết quả vào `results/`.

**Python venv**: bất cứ khi nào cần parse `.xlsx/.pdf/.docx/.html` qua Python, skill `input-reader` tự bootstrap `.venv` ở root dự án rồi `pip install` lib cần thiết. KHÔNG cài thẳng vào Python hệ thống.

### Gọi từng agent
Dùng `Agent` tool với `subagent_type`:
- `business-analyst` — phân tích yêu cầu (input qua input-reader skill).
- `capability-clusterer` — gom case thành shared capability (BATCH only).
- `technology-researcher` — research stack.
- `solution-architect` — thiết kế kiến trúc + Mermaid.
- `technical-reviewer` — review (SINGLE: 1 reviewer; BATCH: expert panel động theo domain).
- `technical-writer` — render báo cáo.

## Pipeline

### SINGLE (5 bước)
1. **BA** → FR/NFR (v1).
2. **Researcher** → 2-3 tech stack candidate.
3. **Architect** → component + sequence diagram (self-check Mermaid).
4. **Reviewer** → APPROVED hoặc REVISION (route lại Researcher/Architect, max 3/agent).
5. **Writer** → md hoặc html article.

### BATCH (6 bước)
1. **BA** → cases[] + FR/NFR chung (v2). Đọc file qua input-reader.
2. **Capability Clusterer** → C1..Cn + case_capability_map.
3. **Researcher** → stack TỪNG capability.
4. **Architect** → internal mỗi capability + fmd/mmd/exc TỪNG case + overall data flow.
5. **Reviewer (Expert Panel)** → persona động theo domain (3-5 người), điều chỉnh `automation_potential` từng case (was→now, KHÔNG được tăng).
6. **Writer** → md tóm tắt hoặc html SPA dashboard.

## Quy ước

- **Slug**: lowercase, gạch dưới, bỏ dấu tiếng Việt, max 50 ký tự.
- **Mermaid**:
  - Label node ≤ 40 ký tự.
  - Sequence dùng `->>` (call) / `-->>` (response), KHÔNG `-->`.
  - Flowchart: classDef cho mọi `:::className`.
  - Sequence to-be: dùng `autonumber` + `box rgb(R,G,B) Lane ... end` chia lane.
  - `Note over X,Y: 💾 ...` cho điểm lưu data.
- **HTML output**: BẮT BUỘC qua `html-report-render` skill, KHÔNG hard-code màu/font/spacing ngoài tokens `DESIGN.md`.
- **Theme**: chỉ Notion (purple `#5645d4` + Inter). Không dùng theme khác.
- **JSON contract giữa agent**: schema cố định trong từng file agent — không tự ý thêm field; muốn field mới, sửa file agent trước.
- **Generic**: KHÔNG hard-code domain (kế toán, OCR, SAP, healthcare, e-commerce...) vào logic skill/agent. Agent tự nhận domain qua `state.requirements.domain`.

## File quan trọng cần đọc trước khi sửa

| Khi muốn... | Đọc file... |
|---|---|
| Thay đổi quy trình review / panel persona | `.claude/agents/technical-reviewer.md` |
| Thay đổi khung HTML / SPA dashboard | `.claude/skills/html-report-render/SKILL.md` |
| Thay đổi token màu/font | `DESIGN.md` (frontmatter YAML) |
| Thay đổi luồng orchestration | `.claude/skills/run-pipeline/SKILL.md` |
| Thay đổi cách đọc file đầu vào | `.claude/skills/input-reader/SKILL.md` |
| Thay đổi schema output agent | file agent tương ứng |
| Thay đổi rule Mermaid | `.claude/skills/mermaid-validator/SKILL.md` |

## Ràng buộc nguyên tắc

- **Stay-in-lane**:
  - BA không đề xuất công nghệ / vẽ kiến trúc / đặt tên capability.
  - Capability Clusterer không research tech, không vẽ internal architecture.
  - Researcher không thiết kế kiến trúc.
  - Architect không đổi tech stack, không đổi danh sách capability.
  - Reviewer không tự sửa — chỉ flag + route.
  - Writer không sửa nội dung kỹ thuật — chỉ format.
- **Pipeline luôn terminate**: max 3 retry/agent × 4 agent = ≤12 retry; timeout 10 phút/agent.
- **Generic-first**: mọi quyết định domain-specific phải do agent sinh trong context, không nằm cứng trong skill/CLAUDE.md.

## Không có trong scope

- Code thực thi (Python/Node) chạy production — hệ thống này chạy thuần qua Claude Code agents/skills.
- Render Mermaid offline thành PNG/SVG — báo cáo HTML dùng mermaid.js CDN render client-side.
- Đa ngôn ngữ output — hiện chỉ tiếng Việt; muốn tiếng Anh phải sửa prompt từng agent.
- Theme tự chọn — chỉ Notion (purple + Inter); muốn theme khác phải mở rộng `DESIGN.md` trước.
