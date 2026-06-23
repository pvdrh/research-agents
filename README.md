# Multi-Agent Research System

> Hệ thống tự động hóa quy trình **Phân tích Use Case → Nghiên cứu công nghệ → Thiết kế kiến trúc → Kiểm duyệt → Viết báo cáo** bằng Claude Code Subagents + Skills.

Không cần code production. Chỉ cần Claude Code + thư mục này + 1 lệnh.

---

## 1. Hệ thống làm gì?

Bạn có một **ý tưởng / yêu cầu CNTT** (chatbot CSKH, hệ thống đặt phòng, e-learning, chấm công, đối soát tài chính, EMR, v.v.).

Bạn cung cấp:
- 📝 **1 đoạn mô tả văn xuôi**, HOẶC
- 📄 **1 file mô tả** (`.pdf`, `.docx`, `.txt`, `.md`, `.jpg/.png` chụp slide), HOẶC
- 📊 **1 file Excel** chứa N nghiệp vụ cần phân tích cùng lúc.

Tuỳ **scope** bạn chọn, hệ thống tự động:
1. Phân tích yêu cầu (Business Analyst).
2. Gom nghiệp vụ thành "capability" dùng chung (BATCH).
3. Nghiên cứu công nghệ ≤ 12 tháng (có nguồn trích dẫn) — **có thể bỏ**.
4. Thiết kế kiến trúc + vẽ sơ đồ Mermaid — **có thể bỏ**.
5. Hội đồng chuyên gia phản biện (3-5 persona động theo domain) — **có thể bỏ**.
6. Xuất báo cáo `.md` hoặc `.html` (SPA dashboard) vào `results/`.

---

## 2. Hai chế độ vận hành × Ba scope

### Chế độ
| Mode | Input | Output |
|---|---|---|
| **SINGLE** | 1 đoạn văn HOẶC 1 file `.pdf/.docx/.txt/.md/.jpg/.png` | Báo cáo **article** 1 trang (TOC, sơ đồ, bảng so sánh stack, rủi ro) |
| **BATCH** | 1 file `.xlsx/.csv` với N dòng nghiệp vụ | Báo cáo **SPA dashboard** `.html` (sidebar: Tổng quan / Kiến trúc / Hội đồng / Capabilities / Cases) |

Tự detect: ≥1 file tabular trong `docs/` → BATCH; còn lại → SINGLE.

### Scope (chọn lúc chạy `/run-pipeline`)

| Scope | Pipeline | Thời gian | Khi nào dùng |
|---|---|---|---|
| **`full`** | BA → (Clusterer) → Researcher → Architect → Reviewer → Writer | SINGLE 3-5' · BATCH 5-20' | Báo cáo chính thức end-to-end gửi sếp/khách hàng |
| **`no_research`** | BA → (Clusterer) → Architect (**tech-agnostic**) → Reviewer → Writer | −30-40% | Đã có sẵn tech stack công ty, chỉ cần kiến trúc + sơ đồ. Brainstorm sớm khi chưa muốn lock công nghệ |
| **`analysis_only`** | BA → (Clusterer) → Writer | −70-80% | Chỉ cần tài liệu phân tích nghiệp vụ (FR/NFR + capability map + cases). Không cần kiến trúc, không cần Reviewer |

**Tech-agnostic mode** (`no_research`): Architect dùng pattern name (`Relational DB`, `Message Queue`, `API Gateway`, `Auth Service`) thay tech cụ thể (PostgreSQL/Kafka/Kong/Keycloak). Tech stack section trong báo cáo bị bỏ; banner cảnh báo ở đầu.

**Analysis-only mode**: báo cáo CHỈ có Tổng quan + FR/NFR + Capabilities (BATCH) + Cases (BATCH). Bỏ hoàn toàn kiến trúc + hội đồng review.

---

## 3. Kiến trúc kỹ thuật (Phase 1 + 2 + 3 + 4)

### Blackboard pattern
Toàn bộ state của 1 lần chạy được lưu vào thư mục `.pipeline_state/{run_id}/`, KHÔNG giữ trong context main-loop. Mỗi agent đọc input qua **file path** (`Read` tool), không nhồi data vào prompt → token tiết kiệm 5-10× ở BATCH lớn, và pipeline **resume được sau crash**.

```
.pipeline_state/{run_id}/
├── manifest.json                       # mode, current_step, retry_count, strategy, scope
├── step_00_input.json                  # input gốc (format + retry_mode + scope + docs)
├── step_01_business_analyst.json
├── step_02_capability_clusterer.json   # BATCH only
├── step_03_technology_researcher.json  # SKIP nếu scope ≠ full
├── step_04_solution_architect.json     # SKIP nếu scope = analysis_only
├── step_05_technical_reviewer_r1.json  # SKIP nếu scope = analysis_only
├── step_05_technical_reviewer_r2.json  # round 2 nếu retry
├── step_06_technical_writer.json
└── review_log.jsonl                    # append-only mọi quyết định REVISION/ACCEPT_RISK
```

Agent sau detect file thiếu → tự branch sang mode tương ứng (vd Architect không thấy `step_03` → chạy agnostic mode).

### Hard gates (Phase 2 + 4)
Sau mỗi `state-store.save`, orchestrator chạy gate; fail → re-spawn agent với prompt fix **chỉ chứa lỗi**:

| Gate | Khi nào | Skill | Hành vi khi fail |
|---|---|---|---|
| **Pre-flight** | Trước Step 1 | `run-pipeline/init.sh` | Check node/npx/python/.venv/docs/DESIGN/agents/skills/disk. Hard fail → abort trước khi tiêu token |
| **Schema** | mọi agent JSON | `schema-validator` | check JSON Schema + DAG acyclic + ID stability + cross-agent ref. Sai → re-spawn (max 3) |
| **Mermaid render** | Clusterer + Architect | `mermaid-render` | render thật qua `npx @mermaid-js/mermaid-cli`. Fail render → re-spawn (max 3) |
| **Convergence** | sau mỗi round Reviewer | `run-pipeline` | track `total_regression`. >2 → terminate `ACCEPTED_WITH_RISK_LOOP_DETECTED` |
| **Panel veto** | Reviewer BATCH | `aggregate_panel.sh` | 1 blocker từ bất kỳ persona → auto `REVISION_REQUIRED` |
| **Budget circuit breaker** | sau mỗi step | `run-pipeline/check_budget.sh` | Vượt `BUDGET_MAX_TOKENS` / `BUDGET_MAX_WALL_S` → terminate `ACCEPTED_WITH_RISK_BUDGET_EXCEEDED`, đi thẳng Writer |

### Split Panel Reviewer (Phase 4)
BATCH mode Reviewer chạy theo **Split Panel** thay vì 1 LLM role-play N persona (collusion risk):

1. **Composer pass** — spawn 1 reviewer `panel_mode: composer` sinh 3–5 persona theo domain + 1 **Red Team** (`code:"RED"`) BẮT BUỘC. Schema enforce `contains:{code:"RED"}` — không thể quên red-team.
2. **Persona spawn (song song)** — N+1 reviewer instance độc lập qua Workflow `parallel`, mỗi instance review CHỈ qua lens persona đã gán, KHÔNG thấy output các persona khác → triệt tiêu mode collapse.
3. **Aggregate** — `aggregate_panel.sh` gom N+1 file → reviewer_v2 schema. Logic: panel build, veto trigger nếu ≥1 blocker, `case_adjustments` giữ `new_potential` **thấp nhất** khi conflict (rule "panel chỉ được hạ"), issues dedupe.

Legacy panel (1 LLM N voice) giữ làm fallback khi env `PANEL_MODE=legacy`.

### Scale controller (Phase 3)
Sau BA, orchestrator gọi `scale-controller/decide_strategy.sh` set `manifest.strategy`:

| N cases | Strategy | Cách Architect chạy |
|---|---|---|
| ≤ 15 | `full` | 1 Architect render đầy đủ fmd/mmd/exc mỗi case |
| 16-49 | `canonical_reuse` | 1 Architect vẽ canonical 1 case/pattern_group, các case khác `REUSE:Pxxx + delta_notes` |
| ≥ 50 | `map_reduce` | chia chunks 15, spawn N/15 Architect song song qua `Workflow` tool, merge sau qua `merge_chunks.py` (cap 8 chunks/wave) |

Model override: Architect BATCH spawn với `model: "opus"`, SINGLE giữ mặc định. Scale controller chỉ chạy khi scope có Architect (`full` / `no_research`).

### Observability
Mọi event log vào `logs/`:
```
logs/
├── runs.log                  # master append-only (mọi run)
└── {run_id}/
    ├── run.log               # detail per-run (START, STEP_OK, RETRY, GATE_FAIL, REGRESSION, END...)
    └── tokens.json           # tokens per step + total
```

Mỗi agent return JSON kèm `_meta.tokens_in/tokens_out/duration_s` để orchestrator capture.

---

## 4. Yêu cầu cài đặt

### Bắt buộc
- **[Claude Code](https://claude.ai/code)** đã cài và đăng nhập.
- **Bash + jq** — Windows dùng Git Bash; macOS/Linux có sẵn.
- **Node.js ≥ 16 + npx** — bắt buộc cho `mermaid-render` hard gate khi scope có Architect (`full` / `no_research`). Pipeline FAIL nếu thiếu.
  - Windows: `winget install OpenJS.NodeJS`
  - macOS: `brew install node`
  - Lần đầu chạy: `npx -y @mermaid-js/mermaid-cli --help` để cache puppeteer + Chrome (~150MB).
  - Scope `analysis_only` KHÔNG cần Node.js.

### Tùy chọn (chỉ khi cần đọc file phức tạp)
| Định dạng input | Cần có |
|---|---|
| `.txt`, `.md` | (không cần gì) |
| `.jpg`, `.png` | (không cần — Claude đọc ảnh trực tiếp) |
| `.pdf`, `.docx`, `.xlsx`, `.html` | Python 3.10+ (skill `input-reader` tự tạo `.venv` + `pip install`) |
| `.doc` / `.xls` cũ | LibreOffice (`soffice`) để convert |
| OCR offline (PDF scan) | Tesseract + traineddata `vie`+`eng` |

> **Python venv tự động:** Khi cần parse file phức tạp, skill `input-reader` tạo `.venv/` ở root dự án và cài lib vào đó — KHÔNG đụng Python hệ thống. Xóa sạch: `rm -rf .venv`.

---

## 5. Cài đặt 3 bước

### Bước 1 — Clone / copy thư mục
```
research-agents/
├── CLAUDE.md
├── DESIGN.md
├── README.md          ← bạn đang đọc
├── docs/              ← bỏ file input của bạn vào đây
├── results/           ← báo cáo sinh ra ở đây
├── .pipeline_state/   ← state mỗi run (auto-tạo)
├── logs/              ← observability logs (auto-tạo)
└── .claude/
    ├── commands/      (run-pipeline, resume-pipeline)
    ├── agents/        (6 agent)
    └── skills/        (10 skill)
```

### Bước 2 — Mở Claude Code tại thư mục
```bash
cd /đường/dẫn/đến/research-agents
claude
```

### Bước 3 — Verify dependencies
Cách 1 — chạy pre-flight check tự động:
```bash
bash .claude/skills/run-pipeline/init.sh
```
Script in bảng ASCII với 10+ check (node/npx/python/.venv/jq/docs/DESIGN/agents/skills/disk). Exit 0 = ready; exit 2 = hard fail (fix lỗi trước khi chạy pipeline).

Cách 2 — check thủ công:
```bash
node --version            # ≥ 16  (bỏ qua nếu chỉ dùng analysis_only)
npx --version             # đi kèm npm
jq --version              # bash JSON tool
python --version          # 3.10+ (chỉ khi input có pdf/docx/xlsx)
```

Trong Claude Code, gõ `/help` — nếu thấy `/run-pipeline` và `/resume-pipeline` → OK.

---

## 6. Chạy lần đầu

### Quy tắc chung
1. Bỏ TẤT CẢ file mô tả vào `docs/`.
2. Gõ `/run-pipeline`.
3. Trả lời **3 câu hỏi**:
   - **Format**: `md` hay `html`?
   - **Retry mode**: `strict` (max 3 retry/agent, chất lượng cao) hay `fast` (1 lượt, không phản biện)?
   - **Scope**: `full` / `no_research` / `analysis_only` — xem bảng ở Mục 2.
4. Hệ thống tự đọc `docs/`, tự detect SINGLE/BATCH, tự chạy pipeline theo scope, lưu kết quả vào `results/`.

### 🎯 Tình huống A — văn xuôi
Tạo `docs/use_case.md`:
```markdown
# Đặt lịch khám online
Tôi muốn xây hệ thống đặt lịch khám online cho phòng khám đa khoa 50 bác sĩ,
3 chi nhánh tại Hà Nội. Bệnh nhân chọn bác sĩ + khung giờ, thanh toán online,
nhắc SMS, tích hợp HIS Oracle. Ngân sách ~$80k năm đầu, team 3 dev Node.js + React.
```
Chạy `/run-pipeline` → `html` + `strict` + `full` → đợi ~5-10 phút → mở `results/dat_lich_kham_*.html`.

### 🎯 Tình huống B — file `.docx` / `.pdf`
Copy file vào `docs/` → `/run-pipeline` → trả lời 3 câu → đợi → mở `results/`.

### 🎯 Tình huống C — Excel N nghiệp vụ (BATCH)
Excel tối thiểu:

| Rank | Mô tả nghiệp vụ | Effort (giờ/tháng) |
|---|---|---|
| 1 | Đối soát hóa đơn NCC với phiếu nhập kho | 720 |
| 2 | Phê duyệt thanh toán >50tr qua 3 cấp | 480 |

- Cột text dài nhất → tự nhận `mô tả`.
- Cột số đầu tiên → `giá trị chính` (effort/score/budget tuỳ domain).
- Nhiều sheet → tự phân partition.
- Header tuỳ ý — BA tự đọc `header_map`, không cần đúng template.

Bỏ vào `docs/danh_sach_60_nghiep_vu.xlsx` → `/run-pipeline` → `html` + `strict` + `full` → SPA dashboard.

### 🎯 Tình huống D — chỉ cần phân tích nghiệp vụ
Bạn có file Excel 30 nghiệp vụ, đang chuẩn bị tài liệu trình stakeholder, **chưa cần kiến trúc**:
- Chạy `/run-pipeline` → `html` + `fast` + **`analysis_only`** → ~2 phút → báo cáo có Tổng quan domain + Capabilities + cases với FR/NFR + automation_potential.

### 🎯 Tình huống E — đã có stack công ty, chỉ cần kiến trúc
Công ty của bạn bắt buộc dùng AWS + Java Spring + Oracle. Không cần Researcher đề xuất tech:
- Chạy `/run-pipeline` → `html` + `strict` + **`no_research`** → Architect render kiến trúc agnostic (pattern name), bạn map sang AWS/Java/Oracle sau.

### 🎯 Tình huống F — nhiều file
```
docs/
├── 60_nghiep_vu.xlsx       ← tabular → trigger BATCH
├── kien_truc_hien_tai.png  ← ảnh → context phụ
├── policy_compliance.pdf   ← document → context bổ sung
└── notes.md
```
Hệ thống gộp tất cả làm input. `.xlsx` quyết định BATCH mode.

---

## 7. Resume sau crash

Pipeline crash giữa chừng (Ctrl+C, mất mạng, session reset)? Mọi artifact đã save vào `.pipeline_state/{run_id}/` → resume được:

```
/resume-pipeline run_chatbot_csk_20260615_1430_a3f7
```

Hoặc gọi rỗng để hệ thống liệt kê 10 run gần nhất:
```
/resume-pipeline
```

Logic:
1. Đọc `manifest.json` → biết `current_step` + `completed_steps[]` + **`scope`**.
2. Skip mọi bước đã xong, tiếp tục từ step kế tiếp (theo đúng scope ban đầu).
3. Không hỏi lại format/retry_mode/scope (đã có trong `step_00_input.json`).
4. Log `RESUME` event vào `logs/{run_id}/run.log`.

---

## 8. Cấu trúc thư mục

```
research-agents/
├── CLAUDE.md                  ← luật chung (không sửa)
├── DESIGN.md                  ← design tokens Notion (purple #5645d4 + Inter)
├── README.md
│
├── docs/                      ← 📥 INPUT
├── results/                   ← 📤 OUTPUT (.md/.html)
├── .pipeline_state/           ← state mỗi run (blackboard)
├── logs/                      ← observability logs
├── .venv/                     ← Python venv (auto-tạo khi parse file phức tạp)
│
└── .claude/
    ├── commands/
    │   ├── run-pipeline.md        (/run-pipeline)
    │   └── resume-pipeline.md     (/resume-pipeline)
    │
    ├── agents/                    (6 subagent)
    │   ├── business-analyst.md
    │   ├── capability-clusterer.md   ← BATCH only
    │   ├── technology-researcher.md  ← skip nếu scope ≠ full
    │   ├── solution-architect.md     ← skip nếu scope = analysis_only; agnostic mode nếu no_research
    │   ├── technical-reviewer.md     ← skip nếu scope = analysis_only; bỏ check tech nếu no_research
    │   └── technical-writer.md       ← scope-aware rendering
    │
    └── skills/                    (10 skill)
        ├── run-pipeline/          ← orchestrator end-to-end (branch theo scope)
        ├── input-reader/          ← đọc đa định dạng (xlsx/pdf/docx/img/...)
        ├── state-store/           ← blackboard CRUD
        ├── observability/         ← log_event + summarize
        ├── schema-validator/      ← hard gate JSON Schema + DAG + ID stability
        ├── mermaid-validator/     ← rule-based check syntax (LLM tự đọc)
        ├── mermaid-render/        ← HARD gate render thật qua npx mermaid-cli
        ├── scale-controller/      ← decide_strategy + merge_chunks (BATCH lớn)
        ├── design-token-loader/   ← parse DESIGN.md YAML frontmatter
        └── html-report-render/    ← render HTML (SINGLE article hoặc BATCH SPA)
```

**Quy tắc vàng:**
- ✅ Bỏ file input vào `docs/`. Đọc báo cáo ở `results/`.
- ✅ Crash → `/resume-pipeline {run_id}` thay vì chạy lại từ đầu.
- ✅ Debug pipeline → mở `logs/{run_id}/run.log`.
- ❌ KHÔNG sửa `.claude/`, `CLAUDE.md`, `DESIGN.md` nếu chưa hiểu rõ.

---

## 9. Quy trình bên trong

```
Bạn nhập use case → docs/
       │
       ▼
[0a] Pre-flight check (init.sh) — fail-fast nếu thiếu dep / docs rỗng
       │
       ▼
[0b] Quét docs/ + AskUserQuestion (format, retry_mode, SCOPE) + new_run → run_pending_*
       │
       ▼  input-reader cho từng file → gộp /tmp/input.json → state-store.save
       │
       ▼
┌──────────────────┐
│ 1. BA            │ → FR/NFR (v1 SINGLE / v2 BATCH cases[])
│ business-analyst │   → rename run với slug từ domain → schema gate
└────────┬─────────┘
         │
         ▼  (BATCH) scale-controller.decide_strategy → manifest.strategy
         │
         ▼  (BATCH only)
┌──────────────────────┐
│ 2. Capability        │ → C1..Cn + dependency_graph_mmd
│ capability-clusterer │   → schema gate + mermaid render gate
└────────┬─────────────┘
         │
         ├─────────────────────────────────► scope = analysis_only → Step 6 (Writer)
         │
         ▼  scope ∈ {full, no_research}
         │
         ├─────────────────────────────────► scope = no_research → SKIP Step 3
         │
         ▼  scope = full
┌──────────────────────┐
│ 3. Researcher        │ → SINGLE: 2-3 stack candidate
│ technology-researcher│   BATCH: stack từng capability (WebSearch ≤12 tháng)
└────────┬─────────────┘   → schema gate
         │
         ▼
┌──────────────────────┐
│ 4. Architect         │ → kiến trúc + Mermaid (agnostic mode nếu scope=no_research)
│ solution-architect   │   strategy=full/canonical_reuse/map_reduce
└────────┬─────────────┘   → schema gate + mermaid render gate
         │
         ▼
┌──────────────────────┐
│ 5. Reviewer          │ → SINGLE: 1 reviewer
│ technical-reviewer   │   BATCH (Phase 4): Split Panel — composer → N+1 persona độc lập SONG SONG → aggregate
└────────┬─────────────┘   convergence guard: total_regression > 2 → terminate
         │
         ├─ REVISION_REQUIRED → re-spawn target agent (max 3/agent) → round mới
         ├─ panel veto (1 blocker REJECT) → REVISION
         │
         ▼ APPROVED hoặc ACCEPTED_WITH_RISK
┌──────────────────────┐
│ 6. Writer            │ → md hoặc html → results/{slug}_{timestamp}.{ext}
│ technical-writer     │   scope-aware: ẩn/hiện section theo scope
└──────────────────────┘   → count_fidelity.sh verify mọi diagram embed
         │
         ▼
[7] finalize.sh — gen tokens.json, in summary table (tokens/wall/gates/risks), optional gzip state
         │
         ▼
   logs/{run_id}/tokens.json + summary stdout
```

> Sau MỖI step (giữa các box), orchestrator gọi `check_budget.sh`: tổng tokens hoặc wall-clock vượt trần (default 2M tokens / 30 phút) → terminate `ACCEPTED_WITH_RISK_BUDGET_EXCEEDED`, đi thẳng Writer. Override: `BUDGET_MAX_TOKENS=500000 BUDGET_MAX_WALL_S=600 /run-pipeline`.

**Tổng thời gian** (scope = `full`): SINGLE ~3-5 phút · BATCH 5-20 phút.
- `no_research`: −30-40% (bỏ Researcher + bớt issue Reviewer raise).
- `analysis_only`: −70-80% (chỉ 1-2 agent đầu).

---

## 10. FAQ

### ❓ Khi nào dùng scope nào?
- **`full`** — báo cáo chính thức end-to-end gửi sếp/khách hàng. Researcher đề xuất tech cập nhật, Architect lock công nghệ cụ thể, Reviewer check feasibility.
- **`no_research`** — đã có tech stack công ty (vd "phải dùng AWS + Java Spring") và chỉ cần kiến trúc + sơ đồ pattern-level. Architect dùng pattern name, bạn map sang tech của mình sau. Cũng dùng cho brainstorm sớm khi chưa muốn lock công nghệ.
- **`analysis_only`** — chỉ cần tài liệu BA (FR/NFR + capability map + cases) để trình stakeholder hoặc làm input cho team kiến trúc nội bộ. Không cần Mermaid kiến trúc, không cần Reviewer. Nhanh nhất.

### ❓ Vì sao bắt buộc Node.js?
Phase 2 thêm hard gate render Mermaid thật qua `mermaid-cli` (puppeteer + Chrome). Validator rule-based cũ không bắt được mọi lỗi parser → diagram pass validator nhưng vẫn vỡ trên browser. Hard gate này đảm bảo 100% diagram trong báo cáo render được. Scope `analysis_only` không có diagram → không cần Node.js.

### ❓ Báo cáo bằng tiếng Anh?
Mặc định tiếng Việt. Muốn tiếng Anh → sửa prompt từng agent trong `.claude/agents/`.

### ❓ Đổi theme HTML?
Sửa `DESIGN.md` (frontmatter YAML) — nguồn token duy nhất. Đừng sửa HTML output trực tiếp.

### ❓ Excel của tôi cột tuỳ chỉnh, có hiểu không?
Có. BA tự đọc `header_map` và diễn giải theo domain. Không cần đặt tên cột theo mẫu.

### ❓ Researcher có "đoán mò" công nghệ?
Không. `WebSearch + WebFetch` lấy nguồn ≤ 12 tháng. Mỗi đề xuất có URL ở Appendix. (Hoặc dùng `no_research` để bỏ qua hoàn toàn bước này.)

### ❓ Sơ đồ Mermaid lỗi syntax?
3 lớp bảo vệ: (1) Architect self-check qua `mermaid-validator`. (2) Hard gate `mermaid-render` re-spawn nếu fail. (3) Sau 3 vòng vẫn fail → `ACCEPTED_WITH_RISK`, banner cảnh báo, không block pipeline.

### ❓ BATCH 100 case có chạy nổi không?
Có — strategy `map_reduce` chia chunks 15, spawn 7 Architect song song qua Workflow tool, merge sau. Architect dùng `model: "opus"` cho BATCH.

### ❓ Pipeline oscillation (Reviewer cứ route đi route lại)?
Convergence guard track `total_regression`. Vượt 2 → terminate `ACCEPTED_WITH_RISK_LOOP_DETECTED`, Writer in banner đặc biệt.

### ❓ Strict vs Fast?
- **Strict** (mặc định): cho báo cáo chính thức. Reviewer phản biện thật, hạ % tự động hoá nếu BA quá lạc quan. ~5-15 phút.
- **Fast**: prototype nhanh. ~2-5 phút. Banner "chưa qua phản biện" ở đầu báo cáo. (Áp dụng cho scope `full` và `no_research`; `analysis_only` không có Reviewer nên strict/fast tương đương.)

### ❓ Pipeline luôn dừng?
Mỗi agent timeout 10 phút. Max retry 3/agent × 4 agent = 12 vòng. Pipeline LUÔN sinh file (kèm rủi ro nếu có).

### ❓ Tôi không có Python?
Được nếu input là văn xuôi hoặc `.txt/.md/.jpg/.png`. PDF/DOCX/XLSX cần Python 3.10+ (chỉ cần có executable, lib tự cài vào `.venv`).

### ❓ Crash giữa chừng, tôi mất hết?
Không. State đã save vào `.pipeline_state/{run_id}/`. Chạy `/resume-pipeline {run_id}` để tiếp tục từ step cuối hoàn thành — đúng scope ban đầu.

### ❓ Chạy `analysis_only` xong, muốn chạy tiếp Architect thì làm sao?
Cách đơn giản nhất: chạy `/run-pipeline` mới với scope `no_research` hoặc `full`, đưa cùng file input. Hiện chưa có cơ chế "upgrade scope" trên run cũ.

---

## 11. Gọi từng agent riêng (nâng cao)

```
/agents
```
Hoặc trực tiếp:
```
Dùng agent technology-researcher để research stack cho yêu cầu: ...
```

Agent có sẵn: `business-analyst`, `capability-clusterer` (BATCH only), `technology-researcher`, `solution-architect`, `technical-reviewer`, `technical-writer`.

---

## 12. Debug & troubleshooting

| Vấn đề | Cách xử lý |
|---|---|
| `PIPELINE_ABORT reason=no_node_npx` | Cài Node.js + chạy `npx -y @mermaid-js/mermaid-cli --help` 1 lần. (Hoặc dùng scope `analysis_only` để bỏ qua.) |
| `FILE_NOT_FOUND` | Kiểm path trong `docs/` — đúng chính tả + extension |
| `PYTHON_UNAVAILABLE` | Cài Python 3.10+ |
| `PARSER_UNAVAILABLE: need openpyxl` | Xoá `.venv/` rồi chạy lại — skill sẽ tạo venv mới |
| `OCR_UNAVAILABLE` | Cài `tesseract` hoặc gửi ảnh trực tiếp (Claude vision) |
| `ACCEPTED_WITH_RISK_LOOP_DETECTED` | Reviewer oscillation. Xem `review_log.jsonl` để biết lý do |
| `ACCEPTED_WITH_RISK_GATE_FAIL` | Schema/Mermaid gate fail >3 lần. Xem `logs/{run_id}/run.log` |
| `ACCEPTED_WITH_RISK_BUDGET_EXCEEDED` | Vượt `BUDGET_MAX_TOKENS` hoặc `BUDGET_MAX_WALL_S`. Tăng trần qua env var hoặc giảm scope. |
| `init.sh` báo `==> ABORT` | Thiếu hard dep (node/python/agents/skills) hoặc docs/ rỗng. Sửa theo từng dòng `[FAIL]` rồi chạy lại |
| HTML mở ra trắng | Mermaid CDN cần online. F12 xem console |
| Báo cáo thiếu diagram | `count_fidelity.sh` log mismatch. Xem `logs/{run_id}/run.log` |
| Manifest corrupt khi resume | Xoá `.pipeline_state/{run_id}/` rồi chạy `/run-pipeline` mới |

**Inspect state 1 run cụ thể:**
```bash
ls .pipeline_state/{run_id}/                   # các artifact
cat .pipeline_state/{run_id}/manifest.json     # current_step + retry_count + strategy + scope
cat .pipeline_state/{run_id}/review_log.jsonl  # mọi quyết định Reviewer
cat logs/{run_id}/run.log                      # event log chi tiết
cat logs/{run_id}/tokens.json                  # cost report
```

**Master log mọi run:**
```bash
tail -f logs/runs.log
```

---

## 13. Tài liệu sâu hơn

| Bạn muốn... | Đọc file |
|---|---|
| Luật chung hệ thống | `CLAUDE.md` |
| Design tokens HTML | `DESIGN.md` |
| Logic orchestration chi tiết (bao gồm scope branching) | `.claude/skills/run-pipeline/SKILL.md` |
| Blackboard API | `.claude/skills/state-store/SKILL.md` |
| Log format + event types | `.claude/skills/observability/SKILL.md` |
| Strategy mode + chunk merge | `.claude/skills/scale-controller/SKILL.md` |
| Schema gate logic | `.claude/skills/schema-validator/SKILL.md` |
| Mermaid render gate | `.claude/skills/mermaid-render/SKILL.md` |
| Rule check Mermaid | `.claude/skills/mermaid-validator/SKILL.md` |
| Tuỳ biến khung HTML SPA | `.claude/skills/html-report-render/SKILL.md` |
| Hỗ trợ format input mới | `.claude/skills/input-reader/SKILL.md` |
| Pre-flight check + lifecycle | `.claude/skills/run-pipeline/init.sh`, `finalize.sh` |
| Budget circuit breaker | `.claude/skills/run-pipeline/check_budget.sh` |
| Split Panel Reviewer + aggregator | `.claude/skills/run-pipeline/aggregate_panel.sh` + section "B. BATCH mode — Split Panel" trong `.claude/agents/technical-reviewer.md` |
| Agnostic mode chi tiết | `.claude/agents/solution-architect.md` (section "Agnostic mode") |
| Scope-aware review | `.claude/agents/technical-reviewer.md` (section "Scope-aware review") |
| Scope-aware rendering | `.claude/agents/technical-writer.md` (section "Scope-aware rendering") |
| Output schema 1 agent | file agent tương ứng |

---

## 14. Triết lý thiết kế

- **Generic-first** — không bias domain. Cùng pipeline chạy được cho healthcare, fintech, e-commerce, logistics, edtech, public sector... Capability list + panel persona sinh động theo domain user nhập.
- **Stay-in-lane** — mỗi agent làm đúng việc. BA không chọn tech. Researcher không vẽ kiến trúc. Architect không đổi stack. Reviewer chỉ flag, không tự sửa. Writer chỉ format.
- **Scope-as-feature** — user chọn độ sâu pipeline (`full` / `no_research` / `analysis_only`) thay vì chạy cứng nhắc end-to-end. Tiết kiệm thời gian + token cho use case không cần tech selection.
- **Blackboard, not prompt-stuffing** — state qua file path, không nhồi vào prompt. Skip step = không tạo file → agent sau tự branch.
- **Fail fast, hard gates** — schema + Mermaid render check ngay sau save. Sai → re-spawn với prompt fix cụ thể, không đẩy lỗi xuống Reviewer.
- **Always terminate** — max 3 retry/agent, timeout 10 phút/agent, convergence guard, panel veto, budget circuit breaker. Pipeline LUÔN dừng và sinh file.
- **Independent review (Phase 4)** — BATCH Reviewer là N+1 instance song song độc lập (mỗi persona 1 context riêng) thay vì 1 LLM role-play, triệt tiêu collusion / mode collapse. Red Team luôn bắt buộc.
- **Bounded resources (Phase 4)** — pre-flight check fail-fast trước khi tiêu token; budget breaker terminate sớm khi vượt trần token/wall-clock thay vì silent overshoot.
- **Resume-able** — crash → `/resume-pipeline {run_id}` không mất artifact.
- **Observable** — mỗi event log vào `logs/`, mỗi agent return `_meta.tokens/duration`.
- **Notion design system** — HTML output dùng tokens từ `DESIGN.md`, không hard-code.

---

## 15. Không có trong scope

- Code Python/Node chạy production — hệ thống chạy thuần qua Claude Code agents/skills (trừ helper bash/python cho state-store, observability, scale-controller).
- Render Mermaid offline thành PNG/SVG embed báo cáo — HTML dùng mermaid.js CDN client-side. (`mermaid-render` chỉ dùng để **validate**, không xuất ảnh.)
- Đa ngôn ngữ output — hiện chỉ tiếng Việt.
- Theme tự chọn — chỉ Notion (purple + Inter).
- Upgrade scope giữa chừng (vd đang `analysis_only` muốn chạy tiếp Architect trên cùng run) — phải chạy `/run-pipeline` mới.

---

## 16. License & Credits

Hệ thống chạy thuần trên Claude Code (Anthropic). Không có code production. Không thu thập dữ liệu. Báo cáo sinh ra thuộc về bạn.

---

**Bắt đầu ngay:**
```bash
cd research-agents/
claude
> /run-pipeline
```

Chúc bạn thiết kế hệ thống vui vẻ. 🚀
