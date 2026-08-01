#!/usr/bin/env bash
#
# 规模检查（防膨胀早期信号）
#
# 统计源码与测试的总行数、单文件最大行数，超出阈值即失败。
# CI（.github/workflows/ci.yml 的 scale job）与本地共用本脚本。
# 阈值写在下方，可按需调整；也可用环境变量覆盖：
#   SOURCE_LINE_LIMIT=7000 ./scripts/check-scale.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- 阈值（行数）----
# 校准记录（ADR-0009 D8，2026-08-01）：审计模块 Tier A P1 落地前基线
# 已为 6126 / 6319（超出旧上限 6000），按 ACCEPTANCE §9「先测基线再定值」
# 上调至 7500；P2（FFI 审计 + CI 加固）后基线 7629，再次校准至 8000。
# 两次校准原因均登记于此。后续再超限须重新校准并登记。
SOURCE_LINE_LIMIT="${SOURCE_LINE_LIMIT:-8000}"         # Sources 总行数
TEST_LINE_LIMIT="${TEST_LINE_LIMIT:-7500}"             # Tests 总行数
MAX_SOURCE_FILE_LIMIT="${MAX_SOURCE_FILE_LIMIT:-800}"  # Sources 单文件上限
MAX_TEST_FILE_LIMIT="${MAX_TEST_FILE_LIMIT:-600}"      # Tests 单文件上限

FAILED=0

# 注意：所有变量一律用 ${VAR} 花括号形式。macOS 自带 bash 3.2 在
# set -u 下，变量后紧跟全角括号「（」会被误判为未绑定（实测复现），
# 裸 $VAR 形式会偶发 "unbound variable"。
check() { # check <名称> <当前值> <上限>
  if [ "$2" -gt "$3" ]; then
    echo "[scale] FAIL  ${1}：${2} 行（上限 ${3}）"
    FAILED=1
  else
    echo "[scale] OK    ${1}：${2} 行（上限 ${3}）"
  fi
}

stats() { # stats <目录> -> "总行数 最大文件行数 最大文件名"
  find "$1" -name '*.swift' -print0 \
    | xargs -0 wc -l \
    | awk '$2 != "total" { sum += $1; if ($1 > max) { max = $1; name = $2 } }
           END { printf "%d %d %s\n", sum + 0, max + 0, name }'
}

read -r SRC_SUM SRC_MAX SRC_MAX_NAME <<< "$(stats "$ROOT/Sources")"
read -r TEST_SUM TEST_MAX TEST_MAX_NAME <<< "$(stats "$ROOT/Tests")"
SRC_FILES="$(find "$ROOT/Sources" -name '*.swift' | wc -l | tr -d ' ')"
TEST_FILES="$(find "$ROOT/Tests" -name '*.swift' | wc -l | tr -d ' ')"

echo "[scale] 源码：${SRC_FILES} 个文件"
check "Sources 总行数" "$SRC_SUM" "$SOURCE_LINE_LIMIT"
echo "[scale] 最大源码文件：${SRC_MAX_NAME}（${SRC_MAX} 行）"
check "Sources 单文件上限" "$SRC_MAX" "$MAX_SOURCE_FILE_LIMIT"

echo "[scale] 测试：${TEST_FILES} 个文件"
check "Tests 总行数" "$TEST_SUM" "$TEST_LINE_LIMIT"
echo "[scale] 最大测试文件：${TEST_MAX_NAME}（${TEST_MAX} 行）"
check "Tests 单文件上限" "$TEST_MAX" "$MAX_TEST_FILE_LIMIT"

if [ "$FAILED" -eq 1 ]; then
  echo "[scale] 有阈值超标，详见上方 FAIL 项。"
  exit 1
fi
echo "[scale] 全部通过。"
