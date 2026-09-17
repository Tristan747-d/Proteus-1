#!/usr/bin/env bash
# 从 AppIcon-source.png 生成 AppIcon.icns（macOS 应用图标）。
#
# 为什么需要脚本：.icns 是二进制产物，不该手工维护。原始图（1254×1254
# RGBA PNG）是唯一真源，改图后重跑本脚本即可。
#
# 用法：
#   ./make-icon.sh [源图路径]
#
# 不传参数时使用 ProteusStudio/AppIcon-source.png。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$HERE/ProteusStudio/AppIcon-source.png}"
OUT="$HERE/ProteusStudio/AppIcon.icns"

[ -f "$SRC" ] || { echo "找不到源图: $SRC" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "需要 macOS 的 iconutil" >&2; exit 1; }

# 源图应当是正方形；非正方形时明确拒绝，而不是悄悄拉伸变形。
read -r W H < <(sips -g pixelWidth -g pixelHeight "$SRC" 2>/dev/null \
  | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w, h}')
if [ -z "${W:-}" ] || [ "$W" != "$H" ]; then
  echo "✗ 源图必须是正方形（当前 ${W:-?}×${H:-?}）：$SRC" >&2
  exit 1
fi
echo "==> 源图 ${W}×${H}"

ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/AppIcon.iconset.XXXXXX")/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# macOS 要求的标准尺寸与命名（@1x = N，@2x = 2N）。
# 全部由源图重新采样，保证各尺寸风格一致。
gen() { sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

echo "==> 生成 iconset（10 个尺寸）"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ 已写入 $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "提示：重跑 ./rebuild-app.sh 让新图标进入 .app。"
echo "     macOS 会缓存图标；若 Dock/Finder 仍显示旧的，执行："
echo "         killall Dock"
