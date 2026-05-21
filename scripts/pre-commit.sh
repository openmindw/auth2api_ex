#!/usr/bin/env bash
# scripts/pre-commit.sh — auth2api_ex 提交前门禁
#
# 用法:
#   bash scripts/pre-commit.sh           # 完整检查
#   bash scripts/pre-commit.sh --compile # 仅编译
#   bash scripts/pre-commit.sh --test    # 仅测试
#
# 作为 git hook 使用:
#   ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJ_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
ERR_FILES=()

# ── helpers ──

extract_files() {
  # Extract file paths from Elixir compiler/test error output
  # Matches patterns like:
  #   lib/auth2api_ex/foo.ex:42
  #   test/auth2api_ex/bar.exs:15
  sed -n 's/^[[:space:]]*\(lib\/.*\.ex\|test\/.*\.exs\):[0-9]\+.*/\1/p' | sort -u
}

run_step() {
  local label="$1"
  local cmd="$2"

  echo -e "${YELLOW}▶ ${label}...${NC}"
  echo ""

  local tmp
  tmp="$(mktemp)"

  if eval "$cmd" >"$tmp" 2>&1; then
    echo -e "${GREEN}✓ ${label} 通过${NC}"
    PASS=$((PASS + 1))
  else
    echo -e "${RED}✗ ${label} 失败${NC}"
    FAIL=$((FAIL + 1))

    # Extract error files
    local files
    files="$(extract_files < "$tmp")"
    if [ -n "$files" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && ERR_FILES+=("$f")
      done <<< "$files"
    fi

    # Print output
    cat "$tmp"
  fi

  rm -f "$tmp"
  echo ""
}

# ── main ──

MODE="${1:-all}"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  auth2api_ex pre-commit gate"
echo "═══════════════════════════════════════════════════"
echo ""

case "$MODE" in
  all|--compile|--test) ;;
  *)
    echo "用法: bash scripts/pre-commit.sh [--compile|--test]"
    exit 1
    ;;
esac

# ── compile ──

if [ "$MODE" = "all" ] || [ "$MODE" = "--compile" ]; then
  run_step "mix compile" "mix compile"
fi

# ── test ──

if [ "$MODE" = "all" ] || [ "$MODE" = "--test" ]; then
  run_step "mix test" "mix test"
fi

# ── result ──

echo "═══════════════════════════════════════════════════"

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}  全部通过 (${PASS} 项)${NC}"
  echo "═══════════════════════════════════════════════════"
  exit 0
else
  echo -e "${RED}  ${FAIL} 项失败, ${PASS} 项通过${NC}"
  if [ ${#ERR_FILES[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}  报错文件:${NC}"
    for f in "${ERR_FILES[@]}"; do
      echo "    $f"
    done
  fi
  echo "═══════════════════════════════════════════════════"
  exit 1
fi
