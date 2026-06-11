---
name: design-token-loader
description: Đọc file DESIGN.md ở project root, parse YAML frontmatter, trả về object các design token (colors, typography, rounded, spacing, components). Dùng bởi html-report-render skill và technical-writer.
---

# Design Token Loader

## Khi nào dùng
- TRƯỚC khi render HTML report.
- Khi cần tra cứu giá trị token cụ thể (vd: `colors.primary` = ?).

## Input
```json
{
  "design_file_path": "DESIGN.md",
  "tokens_needed": ["colors", "typography", "rounded", "spacing", "components"]
}
```
(nếu `tokens_needed` rỗng → load tất cả)

## Cách làm
1. Dùng `Read` đọc file `DESIGN.md`.
2. Trích YAML frontmatter giữa hai dòng `---` đầu tiên.
3. Parse YAML thành object Python-like / JSON.
4. Resolve các tham chiếu `{colors.xxx}` trong components → giá trị thật.
5. Trả về object đã flatten.

## Output schema
```json
{
  "loaded_from": "DESIGN.md",
  "version": "alpha",
  "name": "Notion-design-analysis",
  "tokens": {
    "colors": {
      "primary": "#5645d4",
      "brand-navy": "#0a1530",
      "tint-peach": "#ffe8d4",
      "...": "..."
    },
    "typography": {
      "hero-display": {"fontFamily": "Notion Sans", "fontSize": "80px", "fontWeight": 600, "lineHeight": 1.05, "letterSpacing": "-2px"},
      "...": "..."
    },
    "rounded": {"xs": "4px", "sm": "6px", "md": "8px", "lg": "12px", "...": "..."},
    "spacing": {"xxs": "4px", "...": "...", "hero": "120px"},
    "components": {
      "button-primary": {
        "backgroundColor": "#5645d4",
        "textColor": "#ffffff",
        "rounded": "8px",
        "padding": "10px 18px"
      }
    }
  }
}
```

## Error handling
| Tình huống | Output |
|---|---|
| File `DESIGN.md` không tồn tại | `{"error": "DESIGN_FILE_NOT_FOUND", "fallback": "use built-in default tokens"}` |
| YAML frontmatter sai cú pháp | `{"error": "YAML_PARSE_ERROR", "line": N, "message": "..."}` |
| Reference `{colors.xxx}` không tồn tại | `{"error": "UNKNOWN_TOKEN_REF", "token": "colors.xxx", "used_in": "components.button-primary.backgroundColor"}` |

## Token reference resolver
Quy tắc: bất kỳ string nào dạng `{group.key}` (vd `{colors.primary}`) phải được thay bằng giá trị thật của `tokens[group][key]`.

Ví dụ:
- Input: `"backgroundColor": "{colors.primary}"`
- Output: `"backgroundColor": "#5645d4"`

Nested reference (`{colors.primary}` chứa lại `{...}`) hiếm khi xảy ra trong DESIGN.md; nếu gặp → fail với `CIRCULAR_REF`.

## Cache hint
Trong cùng một pipeline run, token sẽ không đổi — caller có thể cache kết quả lần đầu và tái sử dụng.
