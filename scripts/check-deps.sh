#!/usr/bin/env bash
#
# 依赖方向检查（T2-1e）：Streaming / Views 等业务层不得 import CRustCore，
# Rust C ABI 桥接只能存在于 DeepSeekChatIndexing。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

if rg -l "import CRustCore" "$ROOT/Sources/DeepSeekChat" >/dev/null 2>&1; then
  echo "[deps] FAIL 业务层 import CRustCore："
  rg -l "import CRustCore" "$ROOT/Sources/DeepSeekChat" | sed 's/^/  /'
  FAILED=1
else
  echo "[deps] OK 业务层不 import CRustCore"
fi

if ! rg -q "import CRustCore" "$ROOT/Sources/DeepSeekChatIndexing"; then
  echo "[deps] FAIL DeepSeekChatIndexing 应承载 Rust 桥接（import CRustCore）"
  FAILED=1
else
  echo "[deps] OK Rust 桥接位于 DeepSeekChatIndexing"
fi

exit "$FAILED"
