#!/bin/bash
# 重启知枝：退出旧实例 → 重新打包 → 启动 → 打印可核对的证据。
# 用法：./scripts/restart-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Sprig"
APP="build/${APP_NAME}.app"
BIN="$APP/Contents/MacOS/${APP_NAME}"

pid_of() { pgrep -f "${BIN}" 2>/dev/null | head -1 || true; }

# 1. 退出旧实例
# 先走正常退出（让 UserDefaults 落盘），再 SIGTERM，最后才 SIGKILL。
# 尽量不用 -9：反复强杀容易把系统菜单栏对这个 app 的登记状态弄坏。
if [ -n "$(pid_of)" ]; then
    osascript -e "tell application id \"com.catking.sprig\" to quit" >/dev/null 2>&1 || true
    sleep 0.6
fi
if [ -n "$(pid_of)" ]; then
    pkill -TERM -f "${BIN}" 2>/dev/null || true
    sleep 0.6
fi
if [ -n "$(pid_of)" ]; then
    pkill -KILL -f "${BIN}" 2>/dev/null || true
    sleep 0.3
fi
echo "旧实例：已退出"

# 2. 重新打包
./scripts/make-app.sh "$CONFIG" >/dev/null
BIN_TIME=$(stat -f "%Sm" -t "%H:%M:%S" "$BIN")
echo "打包完成：${APP}（二进制 ${BIN_TIME}）"

# 3. 启动
open "$APP"
sleep 2

PID=$(pid_of)
if [ -z "$PID" ]; then
    echo "启动失败：没有找到进程"
    exit 1
fi
echo "已启动：PID $PID"
