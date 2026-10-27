#!/bin/bash
# 重启知枝：清掉所有旧实例 → 重新打包 → 启动 → 打印可核对的证据。
# 用法：./scripts/restart-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Sprig"
APP="build/${APP_NAME}.app"
BIN="$APP/Contents/MacOS/${APP_NAME}"

# 注意：必须返回「全部」实例。历史上只用 head -1 取第一个，
# 结果漏掉一个旧代码实例，桌面上同时出现两个版本的设置窗口。
pids_of() { pgrep -f "${BIN}" 2>/dev/null || true; }
running_count() { pids_of | grep -c . || true; }

kill_all() {
    local sig="$1"
    local pids
    pids=$(pids_of)
    [ -z "$pids" ] && return 0
    echo "$pids" | while read -r p; do
        [ -n "$p" ] && kill "-${sig}" "$p" 2>/dev/null || true
    done
}

# 1. 退出所有旧实例
# 先走正常退出（让 UserDefaults 落盘），再 SIGTERM，最后才 SIGKILL。
# 尽量不用 -9：反复强杀容易把系统菜单栏对这个 app 的登记状态弄坏。
BEFORE=$(running_count)
if [ "$BEFORE" -gt 0 ]; then
    osascript -e "tell application id \"com.catking.sprig\" to quit" >/dev/null 2>&1 || true
    sleep 0.8
fi
if [ "$(running_count)" -gt 0 ]; then
    kill_all TERM
    sleep 0.8
fi
if [ "$(running_count)" -gt 0 ]; then
    kill_all KILL
    sleep 0.5
fi
echo "旧实例：清理 ${BEFORE} 个，剩余 $(running_count) 个"

if [ "$(running_count)" -gt 0 ]; then
    echo "!! 仍有实例没退出，先手动处理再重试"
    pids_of
    exit 1
fi

# 2. 重新打包
./scripts/make-app.sh "$CONFIG" >/dev/null
BIN_TIME=$(stat -f "%Sm" -t "%H:%M:%S" "$BIN")
echo "打包完成：${APP}（二进制 ${BIN_TIME}）"

# 3. 启动
open "$APP"
sleep 2.5

# 4. 核对：必须正好一个实例，且进程要能看到
COUNT=$(running_count)
PID=$(pids_of | head -1 || true)
if [ -z "$PID" ]; then
    echo "!! 启动失败：没有找到进程"
    exit 1
fi
if [ "$COUNT" -ne 1 ]; then
    echo "!! 异常：期望 1 个实例，实际 ${COUNT} 个 → $(pids_of | tr '\n' ' ')"
    exit 1
fi
echo "已启动：PID ${PID}（实例数 ${COUNT}）"
