#!/bin/bash
# 把 SPM 产物包成一个可双击的 .app（菜单栏 App，无 Dock 图标）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Sprig"
APP="build/${APP_NAME}.app"

swift build -c "$CONFIG" --disable-sandbox
BIN=".build/${CONFIG}/${APP_NAME}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"

# 应用图标：菜单栏图标由 BrandMark.swift 矢量绘制，这里只需要 .icns
if [ ! -f assets/logo/Sprig.icns ]; then
  ./assets/logo/export.sh >/dev/null
fi
cp assets/logo/Sprig.icns "$APP/Contents/Resources/AppIcon.icns"

# mermaid 运行时：```mermaid 图在本地渲染，不走网络
if [ -f assets/vendor/mermaid.min.js ]; then
  cp assets/vendor/mermaid.min.js "$APP/Contents/Resources/mermaid.min.js"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>Sprig</string>
    <key>CFBundleIdentifier</key>
    <string>com.catking.sprig.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Sprig</string>
    <key>CFBundleDisplayName</key>
    <string>知枝</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
