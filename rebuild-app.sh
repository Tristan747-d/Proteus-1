#!/usr/bin/env bash
# 重新构建并安装 Proteus Studio.app。
#
# 为什么需要它：install.sh 只在检测到 xcodegen 时顺手构建一次，而开发中
# 每次改 Swift 源码都要重建。手敲那串 xcodebuild 参数容易漏 derivedDataPath
# 而污染源码树。
#
# 也修掉了历史上两个坑：
#   · 复用 /tmp/proteus-build 曾留下 root 所有的中间产物，导致后续 rm 失败；
#     现在每次用全新的临时目录构建。
#   · 安装目录里的旧 .app 可能是 root 所有（早期用 sudo 装过），此时会明确
#     提示你该跑什么，而不是抛一堆 Permission denied。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/ProteusStudio"
DEST="$HOME/Applications/Proteus Studio.app"

[ -d "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }
command -v xcodegen  >/dev/null || { echo "需要 xcodegen: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "需要 Xcode" >&2; exit 1; }

BD="$(mktemp -d "${TMPDIR:-/tmp}/proteus-build.XXXXXX")"
trap 'rm -rf "$BD"' EXIT

echo "==> 构建"
( cd "$SRC" && xcodegen generate >/dev/null )
xcodebuild -project "$SRC/ProteusStudio.xcodeproj" -scheme ProteusStudio \
  -configuration Release -derivedDataPath "$BD" build \
  >"$BD/build.log" 2>&1 || { echo "构建失败，日志：$BD/build.log" >&2; tail -30 "$BD/build.log" >&2; exit 1; }

APP="$BD/Build/Products/Release/Proteus Studio.app"
[ -d "$APP" ] || { echo "构建产物缺失: $APP" >&2; exit 1; }

echo "==> 退出正在运行的实例"
osascript -e 'quit app "Proteus Studio"' >/dev/null 2>&1 || true
sleep 1
pkill -f "Proteus Studio.app" 2>/dev/null || true

if [ -d "$DEST" ] && [ ! -w "$DEST" ]; then
  echo "✗ $DEST 不属于当前用户，无法覆盖（多半是早期用 sudo 装的）。"
  echo "  执行一次即可修复归属："
  echo "      sudo rm -rf \"$DEST\""
  echo "  然后再跑本脚本。"
  exit 1
fi

echo "==> 安装到 $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "✓ 完成。启动： open \"$DEST\""
