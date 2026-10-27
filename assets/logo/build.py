#!/usr/bin/env python3
"""知枝 Sprig 标识生成器：一根枝条，两片对生叶。

几何是手工调出来的，脚本只负责把同一份路径展开成各交付物：
  sprig-mark.svg       主标记（单色，currentColor，紧裁剪）
  sprig-icon.svg       macOS 图标（纸色底 + 墨绿标记，仅 2 色）
  sprig-icon-dark.svg  反白版（墨绿底 + 纸色标记）
  sprig-menubar.svg    菜单栏模板（18pt，加粗版，纯黑 template）
  preview.html         标识规范预览页（单文件，直接双击打开）

用法：python3 assets/logo/build.py
"""
import math
import os
import re

# —— 品牌色（全局只用这两种）———————————————————————————————
INK = "#1B4332"     # 墨绿：枝条
PAPER = "#F3EDE1"   # 纸色：底

# —— 骨架：一条向右上方生长的枝 ————————————————————————————
SPINE = ((25.2, 58.0), (24.0, 48.0), (26.0, 37.0), (33.0, 28.0))
W0, W1 = 4.0, 2.7                                   # 枝根 / 枝梢半径
STEM_END = 0.74                                     # 枝在这里被顶叶收住
TOP_LEAF = dict(off=30, back=2.8, length=22.5, half_hi=10.2, half_lo=9.2)
LEFT_LEAF = dict(t=0.30, ang=-140, offset=0.95, length=20.5, half_hi=8.8, half_lo=8.8)

# —— 图标规格 ————————————————————————————————————————————
ICON_SIZE = 1024
ICON_PAD = 100          # macOS 图标留白：底板 824
MARK_RATIO = 0.62       # 标记占底板高度的比例

HERE = os.path.dirname(os.path.abspath(__file__))


def cubic(t, spine=SPINE):
    p0, p1, p2, p3 = spine
    mt = 1 - t
    return (mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0],
            mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1])


def tangent(t, spine=SPINE):
    p0, p1, p2, p3 = spine
    mt = 1 - t
    x = 3 * mt**2 * (p1[0] - p0[0]) + 6 * mt * t * (p2[0] - p1[0]) + 3 * t**2 * (p3[0] - p2[0])
    y = 3 * mt**2 * (p1[1] - p0[1]) + 6 * mt * t * (p2[1] - p1[1]) + 3 * t**2 * (p3[1] - p2[1])
    n = math.hypot(x, y)
    return (x / n, y / n)


def stem_half(t, w0, w1):
    return w0 + (w1 - w0) * t ** 0.75


def stem_path(t_end=STEM_END, w0=W0, w1=W1, steps=24):
    """枝身：按锥度取左右两侧点，根部留一条斜切平面。"""
    left, right = [], []
    for i in range(steps + 1):
        t = t_end * i / steps
        c = cubic(t)
        tx, ty = tangent(t)
        w = stem_half(t, w0, w1)
        left.append((c[0] - ty * w, c[1] + tx * w))
        right.append((c[0] + ty * w, c[1] - tx * w))
    return _poly(left + list(reversed(right)))


def leaf(base0, base1, ang, length, half_hi, half_lo, belly=0.40, sharp=0.62):
    """叶片：叶基是一条弦，两侧可不等宽，收到尖。"""
    mx, my = (base0[0] + base1[0]) / 2, (base0[1] + base1[1]) / 2
    a = math.radians(ang)
    ux, uy = math.cos(a), math.sin(a)
    px, py = -uy, ux

    def P(s, o, w):
        return (mx + ux * length * s + px * w * o, my + uy * length * s + py * w * o)

    tip = (mx + ux * length, my + uy * length)
    a1, a2 = P(belly, 1.0, half_hi), P(sharp, 0.52, half_hi)
    c1, c2 = P(sharp, -0.52, half_lo), P(belly, -1.0, half_lo)
    return (f"M{_f(base0[0])} {_f(base0[1])} "
            f"C{_f(a1[0])} {_f(a1[1])} {_f(a2[0])} {_f(a2[1])} {_f(tip[0])} {_f(tip[1])} "
            f"C{_f(c1[0])} {_f(c1[1])} {_f(c2[0])} {_f(c2[1])} {_f(base1[0])} {_f(base1[1])} Z")


def _f(v):
    return f"{v:.2f}"


def _poly(pts):
    d = f"M{_f(pts[0][0])} {_f(pts[0][1])}"
    d += " " + " ".join(f"L{_f(x)} {_f(y)}" for x, y in pts[1:])
    return d + " Z"


def build_mark(w0=W0, w1=W1, leaf_scale=1.0, bold=0.0):
    """bold > 0 时整体加粗（18pt 菜单栏版）。"""
    top, left = TOP_LEAF, LEFT_LEAF
    out = [stem_path(STEM_END, w0, w1)]

    # 顶叶：叶基沿叶轴退进枝内，枝梢被叶片完整包住，接缝不可见
    tip = cubic(STEM_END)
    tx, ty = tangent(STEM_END)
    ang = math.degrees(math.atan2(ty, tx)) + top["off"]
    ux, uy = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    back = top["back"] * (w0 / W0)      # 枝越粗，叶基退得越深，避免接缝露白
    base = (tip[0] - ux * back, tip[1] - uy * back)
    px, py = -uy, ux
    chord = 1.6 + bold * 1.6
    out.append(leaf((base[0] + px * chord, base[1] + py * chord),
                    (base[0] - px * chord, base[1] - py * chord),
                    ang, top["length"] * leaf_scale,
                    top["half_hi"] * leaf_scale + bold, top["half_lo"] * leaf_scale + bold))

    # 侧叶：叶基压进枝的左侧表面
    c = cubic(left["t"])
    ltx, lty = tangent(left["t"])
    lw = stem_half(left["t"], w0, w1) * left["offset"]
    base = (c[0] + lty * lw, c[1] - ltx * lw)
    px, py = -math.sin(math.radians(left["ang"])), math.cos(math.radians(left["ang"]))
    chord = 2.0 + bold * 1.6
    out.append(leaf((base[0] + px * chord, base[1] + py * chord),
                    (base[0] - px * chord, base[1] - py * chord),
                    left["ang"], left["length"] * leaf_scale,
                    left["half_hi"] * leaf_scale + bold, left["half_lo"] * leaf_scale + bold))
    return out


def mark_bbox(paths):
    nums = [(float(a), float(b)) for a, b in re.findall(r"([-\d.]+) ([-\d.]+)", " ".join(paths))]
    xs = [n[0] for n in nums]
    ys = [n[1] for n in nums]
    return min(xs), min(ys), max(xs), max(ys)


def squircle(size, n=5.0, steps=180):
    """超椭圆近似的 macOS 底板。"""
    r = size / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        pts.append((r + r * math.copysign(abs(ct) ** (2 / n), ct),
                    r + r * math.copysign(abs(st) ** (2 / n), st)))
    return _poly(pts)


# —— 交付物 ————————————————————————————————————————————————

MARK_PAD = 2.0
VB = None       # (x, y, w, h) 由 write_mark 计算
PATH_DATA = []  # 已生成的路径，供后续文件复用


def vbattr(vb=None):
    x, y, w, h = vb or VB
    return f"{x:.2f} {y:.2f} {w:.2f} {h:.2f}"


def icon_transform(vb, size=ICON_SIZE, pad=ICON_PAD, ratio=MARK_RATIO):
    plate = size - 2 * pad
    mh = ratio * plate
    mw = mh * vb[2] / vb[3]
    mx = (size - mw) / 2
    my = (size - mh) / 2 + plate * 0.012      # 视觉重心略上移
    return mx, my, mh / vb[3]


def write_mark():
    global VB, PATH_DATA
    PATH_DATA = build_mark()
    x0, y0, x1, y1 = mark_bbox(PATH_DATA)
    VB = (x0 - MARK_PAD, y0 - MARK_PAD, (x1 - x0) + 2 * MARK_PAD, (y1 - y0) + 2 * MARK_PAD)
    body = "".join(f'  <path d="{d}"/>\n' for d in PATH_DATA)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vbattr()}" '
           f'width="{VB[2]:.0f}" height="{VB[3]:.0f}" role="img" aria-label="知枝 Sprig">\n'
           f'  <title>知枝 Sprig</title>\n'
           f'  <g fill="currentColor">\n{body}  </g>\n</svg>\n')
    _write("sprig-mark.svg", svg)


def write_icon(name, bg, fg):
    mx, my, k = icon_transform(VB)
    body = "".join(f'      <path d="{d}"/>\n' for d in PATH_DATA)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{ICON_SIZE}" height="{ICON_SIZE}" '
           f'viewBox="0 0 {ICON_SIZE} {ICON_SIZE}">\n'
           f'  <title>知枝 Sprig</title>\n'
           f'  <path d="{squircle(ICON_SIZE - 2 * ICON_PAD)}" transform="translate({ICON_PAD},{ICON_PAD})" fill="{bg}"/>\n'
           f'  <g fill="{fg}" transform="translate({mx:.2f},{my:.2f}) scale({k:.4f}) '
           f'translate({-VB[0]:.2f},{-VB[1]:.2f})">\n{body}  </g>\n</svg>\n')
    _write(name, svg)


def menubar_parts():
    """菜单栏模板：18pt 画布，几何加粗、留白更紧，纯黑由系统按模板染色。"""
    mpaths = build_mark(w0=6.0, w1=4.2, leaf_scale=1.08, bold=0.5)
    x0, y0, x1, y1 = mark_bbox(mpaths)
    w, h = x1 - x0, y1 - y0
    box = 16.0                       # 标记最长边占 16pt，四周留 1pt
    k = box / max(w, h)
    mw, mh = w * k, h * k
    mx, my = (18 - mw) / 2, (18 - mh) / 2
    transform = f"translate({mx:.2f},{my:.2f}) scale({k:.5f}) translate({-x0:.2f},{-y0:.2f})"
    # 等价仿射：x' = k*x + tx, y' = k*y + ty（给 App 侧画矢量图用）
    flat = (k, mx - k * x0, my - k * y0)
    return mpaths, transform, flat


def write_menubar():
    mpaths, transform, _ = menubar_parts()
    body = "".join(f'  <path d="{d}"/>\n' for d in mpaths)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">\n'
           f'  <title>知枝</title>\n'
           f'  <g fill="#000" transform="{transform}">\n{body}  </g>\n</svg>\n')
    _write("sprig-menubar.svg", svg)


def write_swift():
    """生成 Sources/Sprig/BrandMark.swift：菜单栏图标直接用矢量画，避免位图 alpha 问题。"""
    mpaths, _, (k, tx, ty) = menubar_parts()
    # 指令字母后补空格，Swift 侧按空格切分
    data = " ".join(mpaths).replace('"', "")
    data = re.sub(r"([MLCZ])", r"\1 ", data)
    swift = f'''// 由 assets/logo/build.py 生成，请勿手改；要改几何请改 build.py 后重新生成。
import AppKit

/// 菜单栏品牌图标：一枝两叶。18×18 画布，模板图，随菜单栏深浅自动反色。
enum BrandMark {{
    /// 路径指令：M x y / L x y / C c1x c1y c2x c2y x y / Z，坐标为 64 网格
    private static let data = """
{data}
"""

    private static let scale: CGFloat = {k:.5f}
    private static let offsetX: CGFloat = {tx:.3f}
    private static let offsetY: CGFloat = {ty:.3f}

    static func image() -> NSImage {{
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) {{ _ in
            NSColor.black.setFill()
            for path in paths() {{ path.fill() }}
            return true
        }}
        image.isTemplate = true
        image.accessibilityDescription = "知枝"
        return image
    }}

    private static func paths() -> [NSBezierPath] {{
        var result: [NSBezierPath] = []
        var current: NSBezierPath?
        let tokens = data.split(whereSeparator: {{ $0 == " " || $0.isNewline }}).map(String.init)
        var i = 0

        func next() -> CGFloat {{
            defer {{ i += 1 }}
            return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0
        }}
        func point() -> NSPoint {{
            let x = next() * scale + offsetX
            let y = next() * scale + offsetY
            return NSPoint(x: x, y: y)
        }}

        while i < tokens.count {{
            switch tokens[i] {{
            case "M":
                i += 1
                let path = NSBezierPath()
                path.move(to: point())
                current = path
            case "L":
                i += 1
                current?.line(to: point())
            case "C":
                i += 1
                let c1 = point(), c2 = point(), end = point()
                current?.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            case "Z":
                i += 1
                current?.close()
                if let path = current {{ result.append(path) }}
                current = nil
            default:
                i += 1
            }}
        }}
        return result
    }}
}}
'''
    path = os.path.join(HERE, "..", "..", "Sources", "Sprig", "BrandMark.swift")
    with open(os.path.abspath(path), "w") as fh:
        fh.write(swift)
    print("wrote Sources/Sprig/BrandMark.swift")


def _write(name, content):
    path = os.path.join(HERE, name)
    with open(path, "w") as fh:
        fh.write(content)
    print("wrote", os.path.relpath(path))


if __name__ == "__main__":
    write_mark()
    write_icon("sprig-icon.svg", PAPER, INK)
    write_icon("sprig-icon-dark.svg", INK, PAPER)
    write_menubar()
    import preview
    write_swift()
    preview.write(os.path.join(HERE, "preview.html"), VB, PATH_DATA, INK, PAPER, squircle, _write,
                  menubar=menubar_parts()[:2])
    x0, y0, x1, y1 = mark_bbox(PATH_DATA)
    print(f"mark bbox {x0:.1f},{y0:.1f} → {x1:.1f},{y1:.1f}  ratio {(x1 - x0) / (y1 - y0):.3f}")
