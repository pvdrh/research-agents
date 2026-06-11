---
name: input-reader
description: Đọc file đầu vào với nhiều định dạng và chuẩn hóa thành cấu trúc dùng được cho BA. Hỗ trợ .xlsx/.xls (bảng N item), .pdf, .docx, .doc, .txt, .md, .jpg/.jpeg/.png (ảnh chứa text/sơ đồ). Output dạng JSON với schema phù hợp từng loại. Dùng bởi business-analyst ở Step 1 khi input không phải văn xuôi đơn thuần.
---

# Input Reader

## Khi nào dùng
- Bất kỳ file nào trong `docs/` hoặc do user chỉ định không phải plain text trong prompt.
- BA gọi skill này TRƯỚC khi phân tích yêu cầu.

## Input
```json
{
  "path": "docs/<file>.<ext>",
  "options": {
    "sheet_filter": null,
    "min_value_col": null,
    "min_value_threshold": 0,
    "top_k": null,
    "ocr_lang": "vie+eng",
    "page_range": null,
    "merge_continuation": true
  }
}
```

## Yêu cầu môi trường Python

Bất cứ khi nào skill cần gọi Python (xlsx/xls/csv/pdf/docx/html/ocr), **PHẢI chạy trong virtual environment** `.venv` ở root dự án — KHÔNG cài thẳng vào Python hệ thống.

### Bootstrap venv (chạy 1 lần)
Khi skill được gọi lần đầu trong dự án, kiểm tra `.venv/`:

```bash
# macOS / Linux
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install --quiet --upgrade pip

# Windows (PowerShell)
if (-not (Test-Path .venv)) { python -m venv .venv }
.\.venv\Scripts\Activate.ps1
python -m pip install --quiet --upgrade pip

# Windows (cmd / Git Bash)
if [ ! -d ".venv" ]; then python -m venv .venv; fi
source .venv/Scripts/activate
pip install --quiet --upgrade pip
```

### Cài lib theo nhu cầu (lazy)
Chỉ cài thư viện CẦN cho file đang xử lý:

| Ext | Lib | Lệnh trong venv |
|---|---|---|
| `.xlsx`, `.xlsm` | openpyxl | `pip install --quiet openpyxl` |
| `.xls` cũ | xlrd<2.0 | `pip install --quiet "xlrd<2.0"` |
| `.pdf` | pypdf | `pip install --quiet pypdf` |
| `.docx` | python-docx | `pip install --quiet python-docx` |
| `.html` | beautifulsoup4 | `pip install --quiet beautifulsoup4 lxml` |

### Python path trong venv
- macOS/Linux: `.venv/bin/python`
- Windows: `.venv\Scripts\python.exe`

**Mọi lệnh Python trong skill này phải dùng absolute path tới venv python**, không gọi `python` trần. Ví dụ:

```bash
".venv/Scripts/python.exe" -X utf8 -c "import openpyxl; ..."
# hoặc activate venv trước rồi gọi `python`
```

### Lỗi không tạo được venv
Nếu `python -m venv .venv` fail (không có Python hệ thống) → trả `{"error":"PYTHON_UNAVAILABLE","hint":"Cài Python 3.10+ rồi chạy lại"}`. KHÔNG fallback sang Python hệ thống.

---

## Cách làm — chia theo extension

### 1. `.xlsx` / `.xls` (bảng item)
Như mô tả ở phần Excel reader cũ:

```bash
"<python>" -X utf8 -c "
import openpyxl, json, sys
wb = openpyxl.load_workbook(sys.argv[1], data_only=True)
out = {}
for sn in wb.sheetnames:
    ws = wb[sn]
    out[sn] = [[str(c) if c is not None else '' for c in row]
               for row in ws.iter_rows(values_only=True)]
json.dump(out, sys.stdout, ensure_ascii=False)
" "<path>"
```

- `.xls` cũ: dùng `xlrd<2.0` hoặc convert qua LibreOffice headless: `soffice --headless --convert-to xlsx <path>`.
- Nhận diện header generic (mô tả dài nhất → `description`, numeric đầu → `value_primary`, STT → `rank`).
- Lọc + sort theo `min_value_col` / `top_k`.
- Output kind = `tabular`.

### 2. `.pdf`
Lựa chọn theo content:
- Text-based PDF: dùng `pypdf` hoặc `pdfminer.six`:
  ```bash
  "<python>" -X utf8 -c "
  import sys
  try: from pypdf import PdfReader
  except ImportError: from PyPDF2 import PdfReader
  r=PdfReader(sys.argv[1]);
  for i,p in enumerate(r.pages): print(f'\\n=== PAGE {i+1} ===\\n'+p.extract_text())
  " "<path>"
  ```
- Scanned PDF (text rỗng): rasterize qua `pdftoppm` rồi OCR (xem mục 5).
- Chia theo `page_range` nếu chỉ định (`"1-5"`, `"3"`, `"10-20"`).
- Output kind = `text` với metadata `pages[]`.

### 3. `.docx`
```bash
"<python>" -X utf8 -c "
import docx, sys, json
d=docx.Document(sys.argv[1])
paras=[p.text for p in d.paragraphs if p.text.strip()]
tables=[[[c.text for c in row.cells] for row in t.rows] for t in d.tables]
json.dump({'paragraphs':paras,'tables':tables}, sys.stdout, ensure_ascii=False)
" "<path>"
```
- Cần `python-docx`. Lỗi → `pip install python-docx` hint.
- `.doc` (Office 97-2003): convert qua LibreOffice headless trước.
- Output kind = `document` với `paragraphs[]` + `tables[][]`.

### 4. `.txt` / `.md`
Đọc thẳng bằng tool `Read` (built-in). Không cần Python.
- `.md`: parse frontmatter YAML nếu có (giữa `---` đầu file).
- Output kind = `text` với `content` + (optional) `frontmatter`.

### 5. `.jpg` / `.jpeg` / `.png` (ảnh)
Hai trường hợp:

**a. Ảnh có text (screenshot, scan hóa đơn, sơ đồ có chú thích):**
- Dùng built-in Read tool — Claude Code đa-modal có thể "xem" ảnh trực tiếp. Skill HƯỚNG DẪN BA dùng Read trên file ảnh, KHÔNG dùng Python OCR offline trừ khi user yêu cầu offline.
- Fallback offline OCR (khi cần batch lớn):
  ```bash
  tesseract "<path>" - -l <ocr_lang>
  ```
  Cần `tesseract` + traineddata vie/eng cài sẵn. Lỗi → `OCR_UNAVAILABLE` + hint cài đặt.

**b. Ảnh sơ đồ kiến trúc (không có text rõ):**
- Read tool đa-modal mô tả nội dung.
- Output kind = `image_description` với `transcribed_text` (nếu có) và `visual_summary` (1-3 câu mô tả).

## Output schema (tổng quát)

```json
{
  "loaded_from": "docs/<file>.<ext>",
  "kind": "tabular | text | document | image_description",
  "tabular": {
    "sheets": [
      {
        "name": "...",
        "header_map": {"rank":"...","description":"...","value_primary":"..."},
        "extra_columns": [],
        "total_rows": 224,
        "kept_rows": 30,
        "items": [{"src_sheet":"...","src_row":2,"rank":1,"description":"...","value_primary":720.0,"raw":{...}}]
      }
    ],
    "stats": {"total_items": 60, "value_primary_sum": 12345.6}
  },
  "text": {
    "content": "full text...",
    "pages": [{"page":1,"text":"..."}],
    "frontmatter": null
  },
  "document": {
    "paragraphs": ["..."],
    "tables": [[["a","b"],["c","d"]]]
  },
  "image_description": {
    "transcribed_text": "...",
    "visual_summary": "...",
    "ocr_method": "vision-llm | tesseract | none"
  }
}
```

Chỉ field tương ứng với `kind` được populate; các field khác = null.

## Error handling

| Tình huống | Output |
|---|---|
| File không tồn tại | `{"error":"FILE_NOT_FOUND","path":"..."}` |
| Định dạng không hỗ trợ | `{"error":"UNSUPPORTED_FORMAT","ext":".docm","hint":"convert to .docx first"}` |
| Python/lib thiếu | `{"error":"PARSER_UNAVAILABLE","need":"openpyxl|python-docx|pypdf","hint":"pip install ..."}` |
| OCR thiếu | `{"error":"OCR_UNAVAILABLE","hint":"install tesseract or use Read tool (vision)"}` |
| File quá lớn (>50MB) | `{"warning":"LARGE_FILE","action":"truncated_or_sampled","sample":"..."}` |
| PDF scanned không có text layer | Auto fallback sang OCR (mục 5); nếu OCR không có → `error` |

## Quy tắc chọn parser
1. Đọc extension (lowercase).
2. Map:

| Ext | Parser |
|---|---|
| `.xlsx`, `.xls`, `.xlsm` | openpyxl (xls → convert trước) |
| `.csv`, `.tsv` | Python csv module |
| `.pdf` | pypdf → (nếu rỗng) → OCR fallback |
| `.docx`, `.doc` | python-docx (doc → convert trước) |
| `.txt`, `.md`, `.markdown`, `.rst`, `.log` | built-in Read |
| `.jpg`, `.jpeg`, `.png`, `.webp`, `.gif`, `.bmp` | Read (vision) hoặc tesseract |
| `.html`, `.htm` | strip tags qua BeautifulSoup → text |
| Khác | `UNSUPPORTED_FORMAT` |

## Multi-file
Nếu BA gọi skill nhiều lần (mỗi file 1 lần) → caller tự gộp ngoài skill. Skill không gộp.

## Ràng buộc
- **BẮT BUỘC** dùng `.venv` cho mọi lệnh Python. KHÔNG dùng Python hệ thống.
- KHÔNG giả định domain. Không hard-code keyword "OCR", "effort", "VHM" trong logic.
- Output JSON ra stdout, không tạo file tạm trừ khi caller yêu cầu.
- Tôn trọng `page_range`, `sheet_filter`, `top_k` để giảm volume.
- Đối với ảnh / PDF scanned: ưu tiên built-in Read (LLM đa-modal) hơn OCR offline, trừ khi user yêu cầu offline cho privacy.
- Đối với .docx/.pdf có cả text và bảng: trả CẢ paragraphs và tables (đừng bỏ bảng).

## Caller pattern (BA dùng)
```
1. BA Glob docs/ → tìm file.
2. Với mỗi file: gọi input-reader → nhận JSON.
3. Nếu kind=tabular → BA xử lý như BATCH (cases[]).
4. Nếu kind=text/document → BA xử lý như SINGLE (use_case_text = nội dung).
5. Nếu kind=image_description → BA dùng visual_summary làm phụ trợ, KHÔNG làm nguồn chính trừ khi không có nguồn khác.
6. Nhiều file → BA gộp: tabular ưu tiên BATCH; document/text làm context bổ sung.
```
