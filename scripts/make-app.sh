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
    <string>__BUNDLE_ID__</string>
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
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key>
        <string>com.catking.sprig.demo</string>
        <key>CFBundleURLSchemes</key>
        <array><string>sprig</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

# bundle id 可覆盖：本地开发时换一个，避开 macOS 对旧 id 的菜单栏授权记录
BUNDLE_ID="${SPRIG_BUNDLE_ID:-com.catking.sprig.app}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP/Contents/Info.plist"

# 版本号从 git tag 读：v0.2.0 → 0.2.0；CFBundleVersion 用提交数，保证单调递增
VERSION="${SPRIG_VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
fi
if [ -z "$VERSION" ]; then
  VERSION="0.0.0"
  echo "!! 没有 git tag，版本号回落为 ${VERSION}（打一个 tag 就好）"
fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$APP/Contents/Info.plist"
echo "版本 ${VERSION}（build ${BUILD_NUMBER}）"

# 把 acp-host 打进包：用户下载后开箱可用，不必再去 brew/pip 装一次。
# 找的顺序：SPRIG_ACPHOST 环境变量 → Homebrew → /usr/local/bin → 仓库构建产物
ACPHOST=""
for candidate in "${SPRIG_ACPHOST:-}" "$HOME/code/acp-host/target/release/acp-host" \
                 /opt/homebrew/bin/acp-host /usr/local/bin/acp-host; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && ACPHOST="$candidate" && break
done
if [ -n "$ACPHOST" ]; then
  rm -f "$APP/Contents/Resources/acp-host"
  cp "$ACPHOST" "$APP/Contents/Resources/acp-host"
  chmod +x "$APP/Contents/Resources/acp-host"
  echo "已打入 acp-host：$ACPHOST"
else
  echo "!! 没找到 acp-host，包内不带（功能要用户自己装）"
fi

# 签名：默认 adhoc。adhoc 每次构建 CDHash 都会变，系统记不住授权（辅助功能/屏幕录制会重弹）。
# 有稳定的签名证书时用 SPRIG_SIGN_IDENTITY 指定，授权就跟着证书走，不再每次重问。
# 注意顺序：包里嵌套的可执行文件必须**先**签，外层后签——外层签名会记录里面的哈希。
SIGN_ARGS=(--force)
if [ -n "${SPRIG_SIGN_IDENTITY:-}" ]; then
  SIGN_ARGS+=(--options runtime --sign "$SPRIG_SIGN_IDENTITY")
else
  SIGN_ARGS+=(--sign -)
fi

if [ -f "$APP/Contents/Resources/acp-host" ]; then
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Resources/acp-host" >/dev/null 2>&1 \
    || echo "!! 内层 acp-host 签名失败"
fi
codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null 2>&1 \
  && echo "已签名：${SPRIG_SIGN_IDENTITY:-adhoc}" \
  || echo "!! 外层签名失败（证书名对吗？security find-identity -v -p codesigncing）"

codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  && echo "签名校验通过" \
  || echo "!! 签名校验失败：codesign --verify --deep --strict \"$APP\""
echo "$APP"
