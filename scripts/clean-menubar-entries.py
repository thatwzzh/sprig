#!/usr/bin/env python3
"""清理 macOS 26「允许在菜单栏中显示」里的残留条目。

macOS Tahoe 把第三方菜单栏图标的授权记在 Control Center 的 group container 里：

    ~/Library/Group Containers/group.com.apple.controlcenter/
        Library/Preferences/group.com.apple.controlcenter.plist
            ↳ trackedApplications   （嵌套的二进制 plist：key/value 交替的数组）

这个文件只会追加、不会自动回收，卸载或改过 bundle id 的 app 会一直留在列表里。
脚本默认只做预演（列出会删哪些），加 --apply 才真删，删前自动备份。

用法：
    python3 scripts/clean-menubar-entries.py --filter sprig
    python3 scripts/clean-menubar-entries.py --filter sprig --apply

需要给运行它的进程「完整磁盘访问」（系统设置 → 隐私与安全性 → 完整磁盘访问）。
"""

import argparse
import datetime
import os
import plistlib
import subprocess
import sys

REGISTRY = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.controlcenter"
    "/Library/Preferences/group.com.apple.controlcenter.plist"
)
KEY = "trackedApplications"


def load():
    try:
        with open(REGISTRY, "rb") as handle:
            outer = plistlib.load(handle)
    except PermissionError:
        sys.exit(
            "没有权限读这个文件。需要给运行它的进程「完整磁盘访问」：\n"
            "系统设置 → 隐私与安全性 → 完整磁盘访问（授权后要重启该进程）"
        )
    blob = outer.get(KEY)
    if not isinstance(blob, bytes):
        sys.exit(f"{KEY} 不是二进制块，结构可能变了，停止。")
    inner = plistlib.loads(blob)
    if not isinstance(inner, list):
        sys.exit(f"{KEY} 的内层不是数组（{type(inner).__name__}），结构可能变了，停止。")
    return outer, inner


def describe(key) -> str:
    """key 可能是字符串，也可能是序列化过的对象，尽量还原成可读文本。"""
    if isinstance(key, str):
        return key
    if isinstance(key, bytes):
        for encoding in ("utf-8", "utf-16-le"):
            try:
                return key.decode(encoding)
            except UnicodeDecodeError:
                continue
    return repr(key)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--filter", required=True,
                        help="匹配 bundle id 的片段，比如 sprig")
    parser.add_argument("--apply", action="store_true",
                        help="真的写入；不加只预演")
    args = parser.parse_args()

    if not os.path.exists(REGISTRY):
        sys.exit(f"找不到 {REGISTRY}")

    outer, inner = load()
    if len(inner) % 2 != 0:
        sys.exit("内层数组长度是奇数，不是 key/value 交替，停止。")

    needle = args.filter.lower()
    drop_at = []
    for index in range(0, len(inner), 2):
        name = describe(inner[index])
        if needle in name.lower():
            drop_at.append(index)
            print(f"命中 {index // 2}: {name}")

    if not drop_at:
        print("没有匹配条目，什么都没做。")
        return

    print(f"共 {len(inner) // 2} 条，命中 {len(drop_at)} 条。")
    if not args.apply:
        print("预演结束。加 --apply 才会写入。")
        return

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{REGISTRY}.bak-{stamp}"
    with open(REGISTRY, "rb") as source, open(backup, "wb") as target:
        target.write(source.read())
    print("已备份到", backup)

    kept = []
    for index in range(0, len(inner), 2):
        if index not in drop_at:
            kept.extend([inner[index], inner[index + 1]])
    outer[KEY] = plistlib.dumps(kept, fmt=plistlib.FMT_BINARY)
    with open(REGISTRY, "wb") as handle:
        plistlib.dump(outer, handle, fmt=plistlib.FMT_BINARY)
    print(f"写入完成，剩 {len(kept) // 2} 条。")

    for name in ("cfprefsd", "ControlCenter", "SystemUIServer"):
        subprocess.run(["killall", name], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("已重启 cfprefsd / ControlCenter / SystemUIServer。")
    print("重新打开知枝，Control Center 会按新 bundle id 重新登记一次。")


if __name__ == "__main__":
    main()
