#!/bin/bash
#
# 从主图标源重新生成 Resources/AppIcon.icns。
#
# 主图标是 `assets/generated/grabi-appicon.png`（1024×1024，透明背景）。
# 本脚本只做确定性的缩放和 .icns 打包，不重新设计图形 —— 设计改动走图像生成/编辑流程，
# 生成结果落盘后从这里重新导出，所有尺寸共用同一张源图。
#
#   ./tools/make-icon.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE="$ROOT/assets/generated/grabi-appicon.png"
[[ -f "$SOURCE" ]] || { echo "找不到主图标源: $SOURCE" >&2; exit 1; }
sips -Z 1024 "$SOURCE" --out "$WORK/icon-1024.png" >/dev/null

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
    sips -Z "$size" "$WORK/icon-1024.png" --out "$WORK/icon-$size.png" >/dev/null
done
cp "$WORK/icon-16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK/icon-32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK/icon-32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK/icon-64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK/icon-128.png"  "$ICONSET/icon_128x128.png"
cp "$WORK/icon-256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$WORK/icon-256.png"  "$ICONSET/icon_256x256.png"
cp "$WORK/icon-512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$WORK/icon-512.png"  "$ICONSET/icon_512x512.png"
cp "$WORK/icon-1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "已生成 $ROOT/Resources/AppIcon.icns"
