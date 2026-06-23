#!/usr/bin/env bash
# init.sh — Pre-flight check trước khi tiêu token.
# Exit code:
#   0 = OK, pipeline được phép chạy.
#   1 = soft fail (thiếu optional dep, có warning).
#   2 = hard fail (thiếu hard dep, MUST abort).
# Output: JSON summary ra stdout; chi tiết ra stderr.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$PROJECT_ROOT"

ERRORS=()
WARNINGS=()
CHECKS=()

check_ok()   { CHECKS+=("{\"name\":\"$1\",\"status\":\"ok\",\"detail\":\"$2\"}"); }
check_warn() { CHECKS+=("{\"name\":\"$1\",\"status\":\"warn\",\"detail\":\"$2\"}"); WARNINGS+=("$1: $2"); }
check_fail() { CHECKS+=("{\"name\":\"$1\",\"status\":\"fail\",\"detail\":\"$2\"}"); ERRORS+=("$1: $2"); }

# 1. Node.js + npx (hard dep cho mermaid-render)
if command -v node >/dev/null 2>&1; then
  NODE_VER=$(node --version 2>/dev/null || echo "?")
  check_ok "node" "$NODE_VER"
else
  check_fail "node" "node not found on PATH — mermaid-render sẽ fail. Cài Node.js 18+."
fi

if command -v npx >/dev/null 2>&1; then
  check_ok "npx" "available"
else
  check_fail "npx" "npx not found — mermaid-render gate không chạy được."
fi

# 2. Python (hard dep cho input-reader + schema-validator)
PYBIN=""
if command -v python >/dev/null 2>&1; then
  PYBIN="python"
elif command -v python3 >/dev/null 2>&1; then
  PYBIN="python3"
fi

if [ -n "$PYBIN" ]; then
  PY_VER=$("$PYBIN" --version 2>&1 | head -1)
  check_ok "python" "$PY_VER ($PYBIN)"
else
  check_fail "python" "python/python3 not found — input-reader + schema-validator fail."
fi

# 3. .venv — soft check (input-reader tự bootstrap nếu thiếu)
if [ -d ".venv" ]; then
  check_ok "venv" ".venv/ tồn tại"
else
  check_warn "venv" ".venv/ chưa có — input-reader sẽ tự tạo lần đầu chạy"
fi

# 4. jq (soft — state-store có fallback Python)
if command -v jq >/dev/null 2>&1; then
  check_ok "jq" "$(jq --version 2>/dev/null)"
else
  check_warn "jq" "jq not found — state-store fallback sang Python (chậm hơn)"
fi

# 5. docs/ không rỗng
if [ -d "docs" ]; then
  DOC_COUNT=$(find docs -type f \( ! -name '.*' ! -name '~$*' ! -name '*.tmp' ! -name '.gitkeep' \) 2>/dev/null | wc -l)
  if [ "$DOC_COUNT" -gt 0 ]; then
    check_ok "docs" "$DOC_COUNT file(s)"
  else
    check_fail "docs" "docs/ rỗng — không có input để chạy"
  fi
else
  check_fail "docs" "docs/ không tồn tại"
fi

# 6. DESIGN.md (cho HTML output)
if [ -f "DESIGN.md" ]; then
  # Check YAML frontmatter
  if head -1 DESIGN.md | grep -q '^---$'; then
    check_ok "design_md" "DESIGN.md có frontmatter"
  else
    check_warn "design_md" "DESIGN.md không có YAML frontmatter — html-report-render có thể fail"
  fi
else
  check_warn "design_md" "DESIGN.md không tồn tại — chỉ chạy được output md"
fi

# 7. .pipeline_state/ writable
mkdir -p .pipeline_state 2>/dev/null
if [ -w ".pipeline_state" ]; then
  check_ok "state_dir" ".pipeline_state/ writable"
else
  check_fail "state_dir" ".pipeline_state/ không writable"
fi

# 8. logs/ writable
mkdir -p logs 2>/dev/null
if [ -w "logs" ]; then
  check_ok "logs_dir" "logs/ writable"
else
  check_fail "logs_dir" "logs/ không writable"
fi

# 9. Disk space (>500MB free trên thư mục project)
if command -v df >/dev/null 2>&1; then
  FREE_MB=$(df -m . 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  if [ "${FREE_MB:-0}" -gt 500 ]; then
    check_ok "disk" "${FREE_MB}MB free"
  else
    check_warn "disk" "Chỉ còn ${FREE_MB}MB — pipeline có thể fail nếu BATCH lớn"
  fi
fi

# 10. agents + skills tồn tại
REQUIRED_AGENTS=(business-analyst capability-clusterer technology-researcher solution-architect technical-reviewer technical-writer)
MISSING_AGENTS=()
for a in "${REQUIRED_AGENTS[@]}"; do
  [ -f ".claude/agents/$a.md" ] || MISSING_AGENTS+=("$a")
done
if [ ${#MISSING_AGENTS[@]} -eq 0 ]; then
  check_ok "agents" "6/6 agent file"
else
  check_fail "agents" "Thiếu: ${MISSING_AGENTS[*]}"
fi

REQUIRED_SKILLS=(input-reader state-store schema-validator observability mermaid-render scale-controller html-report-render)
MISSING_SKILLS=()
for s in "${REQUIRED_SKILLS[@]}"; do
  [ -f ".claude/skills/$s/SKILL.md" ] || MISSING_SKILLS+=("$s")
done
if [ ${#MISSING_SKILLS[@]} -eq 0 ]; then
  check_ok "skills" "${#REQUIRED_SKILLS[@]}/${#REQUIRED_SKILLS[@]} skill"
else
  check_fail "skills" "Thiếu: ${MISSING_SKILLS[*]}"
fi

# Verdict
if [ ${#ERRORS[@]} -gt 0 ]; then
  VERDICT="abort"
  EXIT_CODE=2
elif [ ${#WARNINGS[@]} -gt 0 ]; then
  VERDICT="ok_with_warnings"
  EXIT_CODE=1
else
  VERDICT="ok"
  EXIT_CODE=0
fi

# Pretty stderr summary
{
  echo ""
  echo "═══ Pipeline Pre-flight ═══"
  for c in "${CHECKS[@]}"; do
    NAME=$(echo "$c" | sed 's/.*"name":"\([^"]*\)".*/\1/')
    STATUS=$(echo "$c" | sed 's/.*"status":"\([^"]*\)".*/\1/')
    DETAIL=$(echo "$c" | sed 's/.*"detail":"\([^"]*\)".*/\1/')
    case "$STATUS" in
      ok)   ICON="[OK] " ;;
      warn) ICON="[WARN]" ;;
      fail) ICON="[FAIL]" ;;
    esac
    printf "  %s %-12s %s\n" "$ICON" "$NAME" "$DETAIL"
  done
  echo ""
  case "$VERDICT" in
    ok)                echo "==> READY (pipeline được phép chạy)" ;;
    ok_with_warnings)  echo "==> OK with warnings (pipeline chạy nhưng có cảnh báo)" ;;
    abort)             echo "==> ABORT (fix lỗi trên trước khi chạy)" ;;
  esac
  echo ""
} >&2

# JSON stdout
printf '{"verdict":"%s","errors":%d,"warnings":%d,"checks":[%s]}\n' \
  "$VERDICT" "${#ERRORS[@]}" "${#WARNINGS[@]}" \
  "$(IFS=,; echo "${CHECKS[*]}")"

exit "$EXIT_CODE"
