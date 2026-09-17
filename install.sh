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

  # 附件功能：pypdf 只在处理 PDF 时才需要，缺失不影响其它类型
  # （docx/rtf/html 走 macOS 自带的 textutil）。因此这里只提示，不报错。
  if "$PY" -c "import pypdf" 2>/dev/null; then
    ok "pypdf 已安装（支持 PDF 附件）"
  else
    warn "未安装 pypdf —— PDF 附件将无法解析（其它类型不受影响）"
    echo "    需要时运行： $PY -m pip install pypdf"
  fi
fi

if ! uname -m | grep -q arm64; then
  die "本项目依赖 Apple Silicon（MLX 与 ANE 均需 arm64）"
fi
ok "架构: $(uname -m)"

# 工作目录必须在本地盘。launchd 进程读 iCloud 里的 .py 会触发 fileprovider
# 死锁（Errno 11 Resource deadlock avoided），而终端里跑同一份代码正常 ——
# 所以这个坑只在「装成服务之后」才暴露，必须在这里拦下。
case "$HERE" in
  *"Mobile Documents"*|*"com~apple~CloudDocs"*)
    warn "本目录在 iCloud 内："
    warn "  $HERE"
    warn "launchd 服务不能用 iCloud 路径作 WorkingDirectory（会 EDEADLK 死锁）。"
    warn "建议移到本地盘后再装服务，例如："
    echo "      mv \"$HERE\" ~/Proteus-Release && cd ~/Proteus-Release && ./install.sh"
    warn "（安装会继续，但 proteus startup 将拒绝在 iCloud 路径下装服务）"
    ;;
  *) ok "工作目录在本地盘: $HERE" ;;
esac

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

# ---------------------------------------------------------------- 端口
PORT="${PROTEUS_PORT:-8320}"
case "$PORT" in
  ''|*[!0-9]*) die "PROTEUS_PORT 必须是数字: $PORT" ;;
esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  die "PROTEUS_PORT 需在 1024–65535 之间（<1024 需要 root）"
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "端口 $PORT 已被占用："
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sed -n '2,3p' | sed 's/^/      /'
  warn "继续安装，但网关可能起不来；之后可用 proteus port <N> 换端口"
else
  ok "网关端口: $PORT"
fi

# ---------------------------------------------------------------- 生成配置
say "生成 models.json"

if [ -f models.json ] && [ "$FORCE" -eq 0 ]; then
  warn "models.json 已存在，跳过（用 --force 覆盖）"
else
  sed -e "s|@MODEL_DIR@|$MODEL_DIR|g" \
      -e "s|@DRAFT_MODEL@|$DRAFT|g" \
      -e "s|@PORT@|$PORT|g" \
      models.json.template > models.json
  ok "已生成 models.json"
fi

chmod +x gm-probe 2>/dev/null || true
chmod +x proteus 2>/dev/null || true

# ---------------------------------------------------------------- CLI 安装
say "安装 proteus 命令行工具"

# 优先装到已在 PATH 里的**用户可写** bin 目录。
# ⚠️ 必须同时检查可写性：/usr/local/bin 常在 PATH 里但普通用户不可写，
# 早期版本因此直接 Permission denied 并中断整个安装（实测踩到）。
BIN_DIR=""
for cand in "$HOME/.local/bin" "$HOME/bin" "/usr/local/bin"; do
  case ":$PATH:" in
    *":$cand:"*) ;;
    *) continue ;;
  esac
  if [ -d "$cand" ] && [ -w "$cand" ]; then BIN_DIR="$cand"; break; fi
  if [ ! -e "$cand" ] && [ -w "$(dirname "$cand")" ]; then BIN_DIR="$cand"; break; fi
done

if [ -z "$BIN_DIR" ]; then
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi

# 用符号链接而不是拷贝：改 Proteus-Release 后 CLI 立即生效，不会分叉两份。
if ln -sf "$HERE/proteus" "$BIN_DIR/proteus" 2>/dev/null; then
  ok "已链接: $BIN_DIR/proteus -> $HERE/proteus"
else
  warn "无法写入 $BIN_DIR/proteus，改装到 ~/.local/bin"
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
  ln -sf "$HERE/proteus" "$BIN_DIR/proteus"
  ok "已链接: $BIN_DIR/proteus"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *)
    warn "$BIN_DIR 不在 PATH 里，请加一行到 shell 配置（~/.zshrc）："
    echo "      export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

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

 启动（网关 + 界面一起）：
   proteus startup

 其它命令：
   proteus status            查看服务与模型状态
   proteus stop              停止
   proteus restart           重启
   proteus logs -f           跟踪日志
   proteus doctor            环境自检
   proteus --help            全部命令

 注意：proteus startup 首次运行会自动安装 launchd 服务
       （KeepAlive 生效，网关崩溃会自动重启，开机自启）。

 更多说明见 README.md
────────────────────────────────────────────────
EOF

if [ "$MLX_OK" -eq 0 ]; then
  warn "别忘了先安装 mlx-lm 再启动网关"
fi
