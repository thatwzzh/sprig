#!/bin/bash
# 把 SVG 标识导出成 PNG 与 .icns。只用 macOS 自带工具：qlmanage / sips / iconutil。
# 用法：./assets/logo/export.sh
set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p png Sprig.iconset

# —— 应用图标 ——
qlmanage -t -s 1024 -o "$TMP" sprig-icon.svg >/dev/null 2>&1
SRC="$TMP/sprig-icon.svg.png"
for s in 1024 512 256 128 64 32 16; do
  sips -z "$s" "$s" "$SRC" --out "png/icon-$s.png" >/dev/null
done

# —— .icns：iconutil 要求的命名 ——
cp png/icon-16.png    Sprig.iconset/icon_16x16.png
cp png/icon-32.png    Sprig.iconset/icon_16x16@2x.png
cp png/icon-32.png    Sprig.iconset/icon_32x32.png
cp png/icon-64.png    Sprig.iconset/icon_32x32@2x.png
cp png/icon-128.png   Sprig.iconset/icon_128x128.png
cp png/icon-256.png   Sprig.iconset/icon_128x128@2x.png
cp png/icon-256.png   Sprig.iconset/icon_256x256.png
cp png/icon-512.png   Sprig.iconset/icon_256x256@2x.png
cp png/icon-512.png   Sprig.iconset/icon_512x512.png
cp png/icon-1024.png  Sprig.iconset/icon_512x512@2x.png

iconutil -c icns Sprig.iconset -o Sprig.icns
rm -rf Sprig.iconset

echo "png/ 与 Sprig.icns 已生成"
