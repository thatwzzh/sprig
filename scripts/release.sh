#!/bin/bash
# 出发布包。只做「检查 -> 构建 -> 校验 -> 压缩」，不替你上传。
#
# 用法：
#   ./scripts/release.sh            # 按当前 tag 出包
#   ./scripts/release.sh --check    # 只做检查，不构建
#
# 版本号只有一个来源：git tag（v0.2.1 -> 0.2.1）。
# 脚本会拒绝三种情况：工作区脏、不在 main、HEAD 不在 tag 上。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Sprig"
APP="build/${APP_NAME}.app"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

fail() { echo "!! $*" >&2; exit 1; }

# ── 1. 代码状态 ──
[ -z "$(git status --porcelain)" ] || fail "工作区有未提交改动，先提交（否则出包内容和 tag 不一致）"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || fail "当前在 ${BRANCH}，发版请在 main 上"

# ── 2. 版本 ──
TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
[ -n "$TAG" ] || fail "没有任何 tag。先 git tag v0.2.1 再打包"
VERSION="${TAG#v}"
[ "$(git rev-list -n1 "$TAG")" = "$(git rev-parse HEAD)" ] \
  || fail "HEAD 不在 ${TAG} 上（tag 之后又提交了）。给当前提交打新 tag，或者把 tag 移过来"
echo "版本：${VERSION}（tag ${TAG}）"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "检查通过（未构建）"
  exit 0
fi

# ── 3. 构建 ──
./scripts/make-app.sh release

# ── 4. 校验产物 ──
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

[ "$PLIST_VERSION" = "$VERSION" ] || fail "包内版本 ${PLIST_VERSION} 和 tag ${VERSION} 不一致"
[ "$BUNDLE_ID" = "com.catking.sprig.app" ] || fail "bundle id 是 ${BUNDLE_ID}，发布必须是 com.catking.sprig.app"
[ "$BUILD_NUMBER" = "$(git rev-list --count HEAD)" ] || fail "build 号 ${BUILD_NUMBER} 和提交数不一致"
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "签名校验失败"

# ── 5. 冒烟：无界面自检必须跑得通 ──
"$APP/Contents/MacOS/${APP_NAME}" --selftest >/dev/null 2>&1 || fail "--selftest 没通过"
echo "自检通过"

# ── 6. 压缩 ──
ZIP="build/${APP_NAME}-v${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo
echo "产物：${ZIP}"
shasum -a 256 "$ZIP"
echo
echo "上传（需要确认）："
echo "  gh release create v${VERSION} ${ZIP} --title \"知枝 v${VERSION}\" --notes-file <(echo \"…\")"
