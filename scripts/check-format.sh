#!/bin/bash
# check-format.sh — Hugo blog post formatting checker
# Usage: bash scripts/check-format.sh <markdown-file>

set -euo pipefail

FILE="$1"

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: bash scripts/check-format.sh <markdown-file>"
  exit 1
fi

FAILED=0
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

check() {
  local label="$1"
  local pattern="$2"
  local desc="$3"
  local exclude="${4:-}"

  if [ -n "$exclude" ]; then
    grep -nP "$pattern" "$FILE" | grep -vP "$exclude" > "$TMP" 2>/dev/null || true
  else
    grep -nP "$pattern" "$FILE" > "$TMP" 2>/dev/null || true
  fi

  if [ -s "$TMP" ]; then
    echo "=== FAIL: $label ==="
    echo "  rule: $desc"
    while IFS= read -r line; do
      echo "  line $line"
    done < "$TMP"
    FAILED=1
  else
    echo "  OK : $label"
  fi
}

echo "Checking: $FILE"
echo ""

# 1. ~ spacing: 数字 ~ 数字 (with spaces around ~)
check "~ spacing" \
      '[0-9]~[0-9]' \
      "数字与 ~ 之间须有空格，写成 10 ~ 20 而非 10~20"

# 2. whitespace inside <strong> tags
check "<strong> inner whitespace" \
      '<strong>\s|\s</strong>' \
      "<strong> 标签内部首尾不能有空格，写成 <strong>foo</strong> 而非 <strong> foo </strong>"

# 3. <strong> glued to CJK characters (not markdown brackets)
check "<strong> glued to CJK" \
      '\p{Han}<strong>|</strong>\p{Han}' \
      "<strong> 标签与相邻中文字符之间须有空格"

# 4. inline code glued to adjacent characters (exclude code block markers)
check "inline code glued" \
      '\w`[^\s]|[^\s]`\w' \
      "行内代码 `code` 与相邻文字之间须有空格" \
      '^[0-9]+:```'

# 5. forbidden title prefix
check "forbidden title prefix" \
      '^title:\s*".*?(深入理解|详解|深入浅出|一网打尽|手把手|一文读懂)' \
      "标题禁止使用 深入理解/详解/深入浅出/一网打尽/手把手/一文读懂 等套路前缀"

# 6. tags count must be exactly 3
tag_count=$(grep -P '^tags:' "$FILE" | grep -oP '"[^"]*"' | wc -l)
if [ "$tag_count" -ne 3 ]; then
  echo "=== FAIL: tags count ==="
  echo "  rule: tags 必须是 3 个，当前 ${tag_count} 个"
  FAILED=1
else
  echo "  OK : tags count (3)"
fi

echo ""
if [ "$FAILED" = "1" ]; then
  echo "Some checks failed — fix the lines listed above."
  exit 1
else
  echo "All checks passed."
fi
