---
name: mermaid-validator
description: Kiểm tra cú pháp Mermaid.js (flowchart, sequenceDiagram, classDiagram, erDiagram, C4) trước khi đưa vào báo cáo. Trả về danh sách lỗi kèm gợi ý sửa. Dùng bởi solution-architect (self-check) và technical-reviewer (gate-keeping).
---

# Mermaid Validator Skill

## Khi nào dùng
- Solution Architect: TRƯỚC khi nộp diagrams cho Reviewer.
- Technical Reviewer: TRƯỚC khi approve giải pháp.
- Technical Writer: TRƯỚC khi embed vào HTML/MD cuối.

## Input
```json
{
  "mermaid_code": "string (raw code, KHÔNG bao gồm ```mermaid fence)",
  "diagram_type": "sequence | flowchart | class | er | c4 | auto"
}
```

## Cách validate (theo thứ tự)

### Bước 1: Detect diagram type
Nhìn dòng đầu non-empty:
- `flowchart` / `graph` → flowchart
- `sequenceDiagram` → sequence
- `classDiagram` → class
- `erDiagram` → er
- `C4Context` / `C4Container` / `C4Component` → c4

Nếu không match → lỗi `UNKNOWN_DIAGRAM_TYPE`.

### Bước 2: Syntax check theo type

**Flowchart**
- Direction phải là `TB|TD|BT|RL|LR` (mặc định LR nếu thiếu).
- Mũi tên hợp lệ: `-->`, `---`, `-.->`, `==>`, `--text-->`, `-->|text|`.
- Node ID không chứa khoảng trắng; nếu có → phải escape `["..."]` hoặc `("...")`.
- Bracket cân bằng (mỗi `[` có `]`, mỗi `(` có `)`, mỗi `{` có `}`).
- Nếu sử dụng `:::className` để gán class, BẮT BUỘC khai báo `classDef className fill:#xxx,stroke:#xxx,...` ở đâu đó trong cùng block (warning nếu thiếu, error nếu validator strict).
- Nested subgraph hợp lệ; mỗi `subgraph` phải có `end`.

**❌ FLOWCHART INLINE-CLASS PITFALLS (Mermaid v10+ strict — gây "Syntax error in text"):**

Mermaid v10/v11 KHÔNG chấp nhận các pattern sau, dù v8 cũ có thể tha:

1. **`:::class` trên target node trong cùng dòng edge** — `A --> B[Label]:::ext` ❌
   → Tách: khai báo `B[Label]:::ext` riêng 1 dòng, rồi viết edge `A --> B` riêng.

2. **`:::class` trên source node trong cùng dòng edge** — `A([Label]):::ext --> B` ❌
   → Tách: khai báo `A([Label]):::ext` riêng, rồi `A --> B`.

3. **`:::class` trên diamond decision** — `CHK{Decision}:::dec` ❌ (parser nhầm với edge label).
   → Tách: `CHK{Decision}` 1 dòng, rồi `class CHK dec` HOẶC dùng classDef + `CHK{Decision}:::dec` ở dòng riêng (không kèm edge).

4. **Chain shorthand `A --> B --> C[Label]:::cls`** ❌ — class chỉ apply C nhưng parser fail.
   → Viết 3 dòng riêng: declare nodes + 2 edge.

**Quy tắc vàng — "DECLARE-THEN-CONNECT":**
```
✅ ĐÚNG:
flowchart LR
  classDef svc fill:#f0eaff,stroke:#5645d4
  classDef ext fill:#f5f5f5,stroke:#bbb
  A([Source]):::ext
  B[Process]:::svc
  C{Decision}
  D[Sink]:::svc
  class C svc
  A --> B
  B --> C
  C -->|Yes| D

❌ SAI (gây "Syntax error in text" Mermaid v10):
flowchart LR
  classDef svc fill:#f0eaff,stroke:#5645d4
  A([Source])-->B[Process]:::svc
  B-->C{Decision}:::svc-->|Yes|D[Sink]:::svc
```

Validator BẮT BUỘC raise error `INLINE_CLASS_ON_EDGE` khi gặp regex pattern:
- `\-\->\s*\w+[\[\(\{][^]]*[\]\)\}]:::` (inline class trên target)
- `^\s*\w+[\[\(\{][^]]*[\]\)\}]:::\w+\s*\-\->` (inline class trên source dùng edge)

**SequenceDiagram**
- Mũi tên hợp lệ: `->`, `->>`, `-->`, `-->>`, `-x`, `--x`, `-)`, `--)`.
- ❌ Sai phổ biến: dùng `-->` của flowchart trong sequence (phải `-->>`).
- `participant` / `actor` khai báo trước khi dùng (warning nếu thiếu).
- `loop`, `alt`, `opt`, `par`, `critical`, `box` phải có `end` tương ứng. Đặc biệt `box rgb(R,G,B) <Lane>` (cho subgrouping participant theo lane màu) BẮT BUỘC có `end` đóng. Nested box KHÔNG hợp lệ.
- `autonumber` (nếu dùng) phải ở dòng đầu sau `sequenceDiagram`.
- `Note over X,Y: ...` hợp lệ; nhiều participant phân tách bằng dấu phẩy không có khoảng trắng (`Note over A,B:`).

**ClassDiagram**
- Relation hợp lệ: `<|--`, `*--`, `o--`, `-->`, `<--`, `..>`, `..|>`.
- Method/field trong `{}` phải có visibility (`+`, `-`, `#`, `~`) nếu khai báo.

**ErDiagram**
- Cardinality: `||--o{`, `}o--||`, `||--||`, `}o--o{`, `|o--o|`.
- Entity name viết HOA.

**C4**
- Khai báo `Person()`, `System()`, `Container()`, `Component()` đúng signature.

### Bước 3: Common rules (mọi diagram)
- File phải có ít nhất 1 node/participant/entity.
- Không có dòng trống ở giữa block diagram (sẽ break parser cũ).
- Comment dùng `%%`, KHÔNG dùng `//` hay `#`.
- Label chứa ký tự đặc biệt (`(`, `)`, `:`, `,`) phải bọc `"..."`.

## Output schema

**Khi pass:**
```json
{
  "valid": true,
  "diagram_type_detected": "sequence",
  "warnings": [
    {"line": 5, "message": "Participant 'X' used but not declared explicitly"}
  ]
}
```

**Khi fail:**
```json
{
  "valid": false,
  "diagram_type_detected": "sequence",
  "errors": [
    {
      "line": 12,
      "col": 4,
      "code": "WRONG_ARROW",
      "message": "Sequence diagrams use '->>' not '-->'",
      "snippet": "  Client --> Server: Request"
    }
  ],
  "suggested_fix": "Đổi `Client --> Server` thành `Client ->> Server` (synchronous) hoặc `Client -->> Server` (response)."
}
```

## Implementation note
Skill này là **rule-based check** chạy thuần bằng phân tích text — không cần Node.js. Khi gọi skill, agent đọc input, chạy các bước 1-3 trong đầu (LLM reasoning), và trả về output JSON đúng schema.

Nếu cần độ chính xác cao hơn (test render thật), có thể chạy `npx -y @mermaid-js/mermaid-cli -i input.mmd -o /tmp/out.svg` qua Bash — nhưng đó là tùy chọn, không bắt buộc.

## Ví dụ

**Input lỗi:**
```
sequenceDiagram
  Client --> Server: GET /orders
  Server --> DB: SELECT *
```

**Output:**
```json
{
  "valid": false,
  "diagram_type_detected": "sequence",
  "errors": [
    {"line": 2, "code": "WRONG_ARROW", "message": "Use '->>' for sync call in sequenceDiagram", "snippet": "Client --> Server"},
    {"line": 3, "code": "WRONG_ARROW", "message": "Use '->>' for sync call in sequenceDiagram", "snippet": "Server --> DB"}
  ],
  "suggested_fix": "Thay tất cả '-->' bằng '->>' (request) hoặc '-->>' (response)."
}
```
