#!/bin/bash
# 把 GitHub 最新 release 的 zip 同步到官网目录，作为国内下载镜像。
#
# 为什么需要：GitHub Releases 在国内容易断，官网走的是国内可达的托管域名。
# 把 zip 放进 docs/downloads/ 后重新发布官网，用户就能直连下载。
#
# 用法：
#   ./scripts/sync-release.sh            # 同步最新 release，更新版本号和下载计数
#   ./scripts/sync-release.sh --dry-run  # 只看会拉哪个版本，不下载
#
# 同步完记得重新发布官网，否则线上还是旧包。

set -uo pipefail
cd "$(dirname "$0")/.."

REPO="thatwzzh/sprig"
DEST="docs/downloads"
OUT="$DEST/Sprig-latest.zip"
PAGE="docs/index.html"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# GitHub API 在国内常被拦：先走代理，失败再直连
api_get() {
    local out
    out=$(curl -s --max-time 25 "$1" 2>/dev/null)
    if [ -z "$out" ]; then
        out=$(curl -s --max-time 25 --noproxy '*' "$1" 2>/dev/null)
    fi
    printf '%s' "$out"
}

echo "查询 $REPO 的最新 release…"
JSON=$(api_get "https://api.github.com/repos/$REPO/releases/latest")

if [ -z "$JSON" ]; then
    echo "✗ 拿不到 GitHub API 响应。检查网络，或配好代理。"
    exit 1
fi

TAG=$(printf '%s' "$JSON" | jq -r '.tag_name // empty')
URL=$(printf '%s' "$JSON" | jq -r '[.assets[]? | select(.name | endswith(".zip"))][0].browser_download_url // empty')

if [ -z "$TAG" ]; then
    echo "✗ 仓库还没有 release，或 API 返回异常。"
    exit 1
fi
if [ -z "$URL" ]; then
    echo "✗ 最新 release（${TAG}）里没有 .zip 附件。"
    exit 1
fi

echo "最新版本: ${TAG}"
echo "下载地址: $URL"

if [ "$DRY_RUN" = "1" ]; then
    echo "（--dry-run，不下载）"
    exit 0
fi

mkdir -p "$DEST"
echo "下载中…"
if ! curl -fsL --max-time 300 -o "$OUT.tmp" "$URL"; then
    rm -f "$OUT.tmp"
    echo "✗ 下载失败。GitHub Releases 在国内不稳，可开代理后重试。"
    exit 1
fi

# 校验：必须是能解开的 zip，且含 Sprig.app —— 否则可能把错误页当包发了
if ! unzip -t "$OUT.tmp" >/dev/null 2>&1; then
    rm -f "$OUT.tmp"
    echo "✗ 下载到的不是合法 zip（可能拿到了 HTML 错误页）。"
    exit 1
fi
if ! unzip -l "$OUT.tmp" 2>/dev/null | grep -q "Sprig.app/Contents/MacOS/Sprig"; then
    rm -f "$OUT.tmp"
    echo "✗ 压缩包里没有 Sprig.app/Contents/MacOS/Sprig。"
    exit 1
fi

mv "$OUT.tmp" "$OUT"
echo "✓ 已更新 $OUT ($(du -h "$OUT" | cut -f1))"

# 版本号 + 下载计数一起写回页面
COUNT=$(api_get "https://api.github.com/repos/$REPO/releases?per_page=100" \
        | jq -r 'if type == "array" then ([.[].assets[]?.download_count] | add // 0) else empty end')

if [ -f "$PAGE" ]; then
    if [ -n "${COUNT:-}" ]; then
        /usr/bin/sed -i '' \
            -e "s|<span class=\"dl-version\">[^<]*</span>|<span class=\"dl-version\">$TAG</span>|" \
            -e "s|<strong data-downloads>[^<]*</strong>|<strong data-downloads>$COUNT</strong>|" \
            "$PAGE"
        echo "✓ 页面已更新：版本 ${TAG}，下载 ${COUNT} 次"
    else
        /usr/bin/sed -i '' \
            -e "s|<span class=\"dl-version\">[^<]*</span>|<span class=\"dl-version\">$TAG</span>|" \
            "$PAGE"
        echo "✓ 页面版本号已更新为 ${TAG}（下载计数没拿到，保持原值）"
    fi
fi

echo
echo "下一步：重新发布官网，让线上镜像换成 ${TAG}"
