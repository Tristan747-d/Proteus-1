#!/usr/bin/env bash
# 重新构建并安装 Proteus Studio.app。
#
# 为什么需要它：install.sh 只在检测到 xcodegen 时顺手构建一次，而开发中
# 每次改 Swift 源码都要重建。手敲那串 xcodebuild 参数容易漏 derivedDataPath
# 而污染源码树。
#
# 也修掉了历史上三个坑：
#   · 复用 /tmp/proteus-build 曾留下 root 所有的中间产物，导致后续 rm 失败；
#     现在每次用全新的临时目录构建。
#   · 安装目录里的旧 .app 可能是 root 所有（早期用 sudo 装过），此时会明确
#     提示你该跑什么，而不是抛一堆 Permission denied。
#   · ProteusStudio.xcodeproj 同理可能是 root 所有，会让 xcodegen 以一句
#     晦涩的 NSCocoaErrorDomain 513 失败；它是生成物，自动删除重建。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/ProteusStudio"
DEST="$HOME/Applications/Proteus Studio.app"

[ -d "$SRC" ] || { echo "找不到 $SRC" >&2; exit 1; }
command -v xcodegen  >/dev/null || { echo "需要 xcodegen: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "需要 Xcode" >&2; exit 1; }

BD="$(mktemp -d "${TMPDIR:-/tmp}/proteus-build.XXXXXX")"
trap 'rm -rf "$BD"' EXIT

# ⚠️ XcodeGen 需要**重写** ProteusStudio.xcodeproj。若该目录曾由 sudo 生成，
# 它就归 root 所有，xcodegen 会以一句很晦涩的 NSCocoaErrorDomain 513
# ("couldn't be copied because you don't have permission") 失败。
# .xcodeproj 是 project.yml 的生成物（且已被 .gitignore），删掉重建即可。
if [ -d "$SRC/ProteusStudio.xcodeproj" ] && [ ! -w "$SRC/ProteusStudio.xcodeproj" ]; then
  echo "==> ProteusStudio.xcodeproj 不属于当前用户（早期用 sudo 生成的）"
  if rm -rf "$SRC/ProteusStudio.xcodeproj" 2>/dev/null; then
    echo "    已删除，将由 xcodegen 重新生成"
  else
    echo "✗ 无法删除。执行一次即可修复归属："
    echo "      sudo rm -rf \"$SRC/ProteusStudio.xcodeproj\""
    echo "  然后重跑本脚本（它是 project.yml 的生成物，删掉不会丢东西）。"
    exit 1
  fi
fi

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
