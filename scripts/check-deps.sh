#!/usr/bin/env bash
#
# 依赖方向检查（T2-1e）：Streaming / Views 等业务层不得 import CRustCore，
# Rust C ABI 桥接只能存在于 DeepSeekChatIndexing。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

# macos-14 runner 可能未装 ripgrep；优先 rg，缺失时回退 grep。
if command -v rg >/dev/null 2>&1; then
  find_import() { rg -l "$1" "$2" >/dev/null 2>&1; }
  has_import() { rg -q "$1" "$2" >/dev/null 2>&1; }
else
  find_import() { grep -rl "$1" "$2" >/dev/null 2>&1; }
  has_import() { grep -rq "$1" "$2" >/dev/null 2>&1; }
fi

if find_import "import CRustCore" "$ROOT/Sources/DeepSeekChat"; then
  echo "[deps] FAIL 业务层 import CRustCore："
  grep -rl "import CRustCore" "$ROOT/Sources/DeepSeekChat" | sed 's/^/  /'
  FAILED=1
else
  echo "[deps] OK 业务层不 import CRustCore"
fi

if ! has_import "import CRustCore" "$ROOT/Sources/DeepSeekChatIndexing"; then
  echo "[deps] FAIL DeepSeekChatIndexing 应承载 Rust 桥接（import CRustCore）"
  FAILED=1
else
  echo "[deps] OK Rust 桥接位于 DeepSeekChatIndexing"
fi

exit "$FAILED"
