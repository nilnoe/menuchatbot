#!/usr/bin/env bash
#
# 构建 Rust 核心静态库（Tier 2：RustCore crate → universal staticlib）。
#
# 用法：
#   ./scripts/build-rust-core.sh             # release：双架构，lipo 合成 universal
#   MODE=debug ./scripts/build-rust-core.sh  # debug：仅本机架构，保留符号
#
# 无 cargo 时自动降级：用 Xcode CLT 自带的 cc/ar 编译同 ABI 的 stub 库
# （RustCore/stub/rustcore_stub.c）并写入 .stub 标记，保证
# swift build / swift test 可链接运行（验收 T2-1d）。
#
# 产物：RustCore/dist/librustcore.a；脚本结束时做导出符号 ABI 校验。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${MODE:-release}"
CRATE="$ROOT/RustCore"
DIST="$CRATE/dist"
STUB_MARKER="$DIST/.stub"
case "$(uname -m)" in
  arm64) NATIVE_TARGET="aarch64-apple-darwin" ;;
  x86_64) NATIVE_TARGET="x86_64-apple-darwin" ;;
  *) NATIVE_TARGET="$(uname -m)-apple-darwin" ;;
esac

mkdir -p "$DIST"

EXPECTED_SYMBOLS=(
  dc_index_open dc_index_close dc_index_upsert dc_index_delete
  dc_index_search dc_index_rebuild dc_index_status dc_index_cancel
  dc_index_last_error dc_eval_expr dc_free dc_audit_init dc_audit_snapshot
)

log() { printf '[rustcore] %s\n' "$*"; }

# 系统 nm 可能读不了新版 Rust（LLVM 22）的对象文件属性（Xcode 26 实测
# "Unknown attribute kind"）；优先 llvm-nm，其次系统 nm。
find_nm() {
  # 优先 Rust 工具链自带的 llvm-nm（llvm-tools-preview 组件）：与编译器
  # 同版本 LLVM，能读 LTO+strip 的 release 对象；Apple 系统 nm 对
  # LLVM 22 对象会报 "Unknown attribute kind" 而读不到符号。
  local rust_nm
  if command -v rustc >/dev/null 2>&1; then
    rust_nm="$(rustc --print sysroot 2>/dev/null)/lib/rustlib/$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')/bin/llvm-nm"
    if [ -x "$rust_nm" ]; then
      echo "$rust_nm"
      return
    fi
  fi
  if command -v llvm-nm >/dev/null 2>&1; then
    echo "llvm-nm"
  elif [ -x /opt/homebrew/opt/llvm/bin/llvm-nm ]; then
    echo "/opt/homebrew/opt/llvm/bin/llvm-nm"
  elif [ -x /usr/local/opt/llvm/bin/llvm-nm ]; then
    echo "/usr/local/opt/llvm/bin/llvm-nm"
  else
    echo "nm"
  fi
}
NM_TOOL="$(find_nm)"

# ---- 导出符号校验（防头文件与实现漂移）----
check_symbols() {
  local lib="$1"
  local missing=0
  local symbols
  # 先整体捕获符号表，避免 pipefail + grep -q 提前退出引发的 SIGPIPE 误判。
  symbols="$("$NM_TOOL" -gU "$lib" 2>/dev/null || true)"
  for sym in "${EXPECTED_SYMBOLS[@]}"; do
    if ! grep -qE " _${sym}\$" <<<"$symbols"; then
      log "FAIL 缺少导出符号：${sym}"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    log "ABI 校验失败：${lib}"
    return 1
  fi
  log "ABI 校验通过（${#EXPECTED_SYMBOLS[@]} 个导出符号全部存在）"
}

# ---- 无 cargo 降级：stub 库 ----
build_stub() {
  log "未检测到 cargo，降级构建 stub 库（FFI 测试将 XCTSkip）"
  local obj="$DIST/rustcore_stub.o"
  cc -c -O2 -Wall -I"$ROOT/Sources/CRustCore/include" \
    "$CRATE/stub/rustcore_stub.c" -o "$obj"
  rm -f "$DIST/librustcore.a"
  ar rcs "$DIST/librustcore.a" "$obj"
  rm -f "$obj"
  touch "$STUB_MARKER"
  check_symbols "$DIST/librustcore.a"
  log "stub 库构建完成：$DIST/librustcore.a"
  exit 0
}

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
  build_stub
fi

cd "$CRATE"

if [ "$MODE" = "debug" ]; then
  PROFILE_FLAG=""
  BUILD_DIR="debug"
  log "debug 模式：仅本机架构 ${NATIVE_TARGET}"
else
  PROFILE_FLAG="--release"
  BUILD_DIR="release"
  log "release 模式：构建 universal（aarch64 + x86_64）"
fi

# 确保需要的 rustup target 已安装（release 需要双架构）
ensure_target() {
  local target="$1"
  if ! rustup target list --installed | grep -qx "$target"; then
    log "安装 rustup target：${target}"
    rustup target add "$target"
  fi
}

if [ "$MODE" = "release" ]; then
  ensure_target "aarch64-apple-darwin"
  ensure_target "x86_64-apple-darwin"
fi

if [ "$MODE" = "debug" ]; then
  cargo build $PROFILE_FLAG --target "$NATIVE_TARGET" --locked
  cp "target/$NATIVE_TARGET/$BUILD_DIR/librustcore.a" "$DIST/librustcore.a"
else
  cargo build $PROFILE_FLAG --target aarch64-apple-darwin --locked
  cargo build $PROFILE_FLAG --target x86_64-apple-darwin --locked
  lipo -create \
    "target/aarch64-apple-darwin/$BUILD_DIR/librustcore.a" \
    "target/x86_64-apple-darwin/$BUILD_DIR/librustcore.a" \
    -output "$DIST/librustcore.a"
fi

rm -f "$STUB_MARKER"
check_symbols "$DIST/librustcore.a"

if [ "$MODE" = "debug" ]; then
  log "debug 库构建完成：$DIST/librustcore.a（保留符号，lldb 可下 Rust 断点）"
else
  log "universal release 库构建完成：$DIST/librustcore.a（已 strip）"
fi
