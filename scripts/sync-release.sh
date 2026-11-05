#!/bin/bash
# 把 GitHub 最新 release 的 zip 同步到官网目录，作为国内下载镜像。
#
# 为什么需要：GitHub Releases 在国内容易断，官网走的是国内可达的托管域名。
# 把 zip 放进 docs/downloads/ 后重新发布官网，用户就能直连下载。
#
# 用法：
#   ./scripts/sync-release.sh            # 同步最新 release 并更新页面版本号
#   ./scripts/sync-release.sh --dry-run  # 只看会拉哪个版本，不下载
#
# 同步完记得重新发布官网，否则线上还是旧包。

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="thatwzzh/sprig"
DEST="docs/downloads"
OUT="$DEST/Sprig-latest.zip"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

api_get() {
    # GitHub API 在国内常被拦，先走代理试一次，再直连
    curl -s --max-time 20 "$1" 2>/dev/null && return 0
    curl -s --max-time 20 --noproxy '*' "$1" 2>/dev/null
}

echo "查询 $REPO 的最新 release…"
JSON=$(api_get "https://api.github.com/repos/$REPO/releases/latest")

if [ -z "$JSON" ]; then
    echo "✗ 拿不到 GitHub API 响应。检查网络，或在设置里配好代理。"
    exit 1
fi

read -r TAG URL <<< "$(printf '%s' "$JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('')
    raise SystemExit
if not d.get('tag_name'):
    print('')
    raise SystemExit
zips = [a for a in d.get('assets', []) if a['name'].endswith('.zip')]
print(d['tag_name'], zips[0]['browser_download_url'] if zips else '')
")"

if [ -z "${TAG:-}" ]; then
    echo "✗ 仓库还没有 release，或最新 release 没有 .zip 附件。"
    exit 1
fi

echo "最新版本: $TAG"
echo "下载地址: $URL"

if [ "$DRY_RUN" = "1" ]; then
    echo "（--dry-run，不下载）"
    exit 0
fi

mkdir -p "$DEST"
echo "下载中…"
if ! curl -fL --max-time 300 -o "$OUT.tmp" "$URL"; then
    rm -f "$OUT.tmp"
    echo "✗ 下载失败。GitHub Releases 在国内不稳，可先开代理再试。"
    exit 1
fi

# 校验：必须是能解开、且含 Sprig.app 的 zip，避免把错误页当包发出去
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
SIZE=$(du -h "$OUT" | cut -f1)
echo "✓ 已更新 $OUT ($SIZE)"

# 页面上的版本号跟着走，别让用户下到 v0.2.3 却看到 v0.2.0
if [ -f docs/index.html ]; then
    python3 - "$TAG" <<'PY'
import re, sys, pathlib
tag = sys.argv[1]
p = pathlib.Path("docs/index.html")
s = p.read_text()
new, n = re.subn(r'(<span class="dl-version">)[^<]*(</span>)', rf'\g<1>{tag}\g<2>', s)
if n:
    p.write_text(new)
    print(f"✓ 页面版本号已更新为 {tag}")
else:
    print("（页面里没有 dl-version 占位，跳过版本号更新）")
PY
fi

echo
echo "下一步：重新发布官网，让线上镜像换成 $TAG"
