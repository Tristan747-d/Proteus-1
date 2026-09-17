#!/usr/bin/env bash
# Proteus Studio —— 一键安装
#
# 作用：
#   1. 检查依赖（Python 3.11+、mlx-lm）
#   2. 从模板生成 models.json（把占位符替换成本机路径）
#   3. 可选：构建 SwiftUI 应用
#
# 幂等：重复运行安全，已存在的 models.json 不会被覆盖（除非 --force）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 依赖检查
say "检查依赖"

PY=""
for cand in python3.13 python3.12 python3.11 python3; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver=$("$cand" -c 'import sys;print("%d%d"%sys.version_info[:2])' 2>/dev/null || echo 0)
    if [ "$ver" -ge 311 ] 2>/dev/null; then PY="$cand"; break; fi
  fi
done
[ -n "$PY" ] || die "需要 Python 3.11 或更高版本"
ok "Python: $($PY -V) ($(command -v $PY))"

if ! "$PY" -c "import mlx_lm" 2>/dev/null; then
  warn "未安装 mlx-lm"
  echo "    请运行： $PY -m pip install mlx-lm"
  echo "    或使用虚拟环境（推荐）"
  MLX_OK=0
else
  ok "mlx-lm 已安装"
  MLX_OK=1
fi

if ! uname -m | grep -q arm64; then
  die "本项目依赖 Apple Silicon（MLX 与 ANE 均需 arm64）"
fi
ok "架构: $(uname -m)"

# ---------------------------------------------------------------- 模型路径
say "配置模型路径"

MODEL_DIR="${PROTEUS_MODEL_DIR:-}"
if [ -z "$MODEL_DIR" ]; then
  # 尝试常见位置
  for cand in "$HOME/Models/Llama-3.1-8B-Instruct-4bit" \
              "$HOME/.cache/huggingface/hub/models--mlx-community--Meta-Llama-3.1-8B-Instruct-4bit/snapshots"/*; do
    if [ -f "$cand/config.json" ]; then MODEL_DIR="$cand"; break; fi
  done
fi

if [ -z "$MODEL_DIR" ] || [ ! -f "$MODEL_DIR/config.json" ]; then
  warn "未自动找到目标模型"
  echo "    请指定 Llama-3.1-8B-Instruct-4bit 的本地目录："
  printf "    MODEL_DIR="; read -r MODEL_DIR
  [ -f "$MODEL_DIR/config.json" ] || die "该目录下没有 config.json"
fi
ok "目标模型: $MODEL_DIR"

DRAFT="${PROTEUS_DRAFT:-mlx-community/Llama-3.2-1B-Instruct-4bit}"
ok "草稿模型: $DRAFT"

# ---------------------------------------------------------------- 生成配置
say "生成 models.json"

if [ -f models.json ] && [ "$FORCE" -eq 0 ]; then
  warn "models.json 已存在，跳过（用 --force 覆盖）"
else
  sed -e "s|@MODEL_DIR@|$MODEL_DIR|g" \
      -e "s|@DRAFT_MODEL@|$DRAFT|g" \
      models.json.template > models.json
  ok "已生成 models.json"
fi

chmod +x gm-probe 2>/dev/null || true

# ---------------------------------------------------------------- 可选构建
if command -v xcodegen >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
  say "构建 Proteus Studio.app（可选）"
  if [ -d ProteusStudio ]; then
    ( cd ProteusStudio && xcodegen generate >/dev/null 2>&1 \
      && xcodebuild -project ProteusStudio.xcodeproj -scheme ProteusStudio \
           -configuration Release -derivedDataPath /tmp/proteus-build build \
           >/tmp/proteus-build.log 2>&1 )
    APP="/tmp/proteus-build/Build/Products/Release/Proteus Studio.app"
    if [ -d "$APP" ]; then
      mkdir -p "$HOME/Applications"
      rm -rf "$HOME/Applications/Proteus Studio.app"
      cp -R "$APP" "$HOME/Applications/"
      ok "已安装到 ~/Applications/Proteus Studio.app"
    else
      warn "构建失败，详见 /tmp/proteus-build.log"
    fi
  fi
else
  warn "未安装 xcodegen / Xcode，跳过 GUI 构建（网关仍可用）"
fi

# ---------------------------------------------------------------- 完成
cat <<EOF

────────────────────────────────────────────────
 安装完成

 启动网关：
   $PY -m gm --config models.json

 探测新模型：
   ./gm-probe /path/to/model

 打开界面：
   open ~/Applications/"Proteus Studio.app"

 更多说明见 README.md
────────────────────────────────────────────────
EOF

if [ "$MLX_OK" -eq 0 ]; then
  warn "别忘了先安装 mlx-lm 再启动网关"
fi
