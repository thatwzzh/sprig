#!/usr/bin/env python3
"""生成 preview.html：单文件、无外部依赖，双击即可看标识在各场景下的样子。"""

def _vb(vb):
    return f"{vb[0]:.2f} {vb[1]:.2f} {vb[2]:.2f} {vb[3]:.2f}"


def _icon_core(paths, ink, paper, squircle, vb, size=1024, pad=100, ratio=0.62):
    plate = size - 2 * pad
    mh = ratio * plate
    mw = mh * vb[2] / vb[3]
    mx = (size - mw) / 2
    my = (size - mh) / 2 + plate * 0.012
    body = "".join(f'      <path d="{d}"/>\n' for d in paths)
    return (f'    <path d="{squircle(plate)}" transform="translate({pad},{pad})" fill="{paper}"/>\n'
            f'    <g fill="{ink}" transform="translate({mx:.2f},{my:.2f}) scale({mh / vb[3]:.4f}) '
            f'translate({-vb[0]:.2f},{-vb[1]:.2f})">\n{body}    </g>\n')


def write(path, vb, paths, ink, paper, squircle, _write, menubar=None):
    mark_paths = "".join(f'      <path d="{d}" fill="currentColor"/>\n' for d in paths)
    mark_paths_raw = "".join(f'<path d="{d}"/>' for d in paths)
    icon_body = _icon_core(paths, ink, paper, squircle, vb)
    icon_dark = _icon_core(paths, paper, ink, squircle, vb)

    # 构造网格：8 单位一格，覆盖标记的 viewBox
    gx0 = int(vb[0] // 8 * 8)
    gy0 = int(vb[1] // 8 * 8)
    gx1 = int(-(-(vb[0] + vb[2]) // 8) * 8)
    gy1 = int(-(-(vb[1] + vb[3]) // 8) * 8)

    sizes = "".join(
        f'<div class="size"><svg class="ico" style="width:{s}px;height:{s}px" viewBox="0 0 1024 1024">'
        f'<use href="#appicon"/></svg><span>{s}</span></div>'
        for s in (256, 128, 64, 32, 16))

    mb_svg = ""
    if menubar:
        mb_paths, mb_transform = menubar
        mb_body = "".join(f'<path d="{d}"/>' for d in mb_paths)
        mb_svg = (f'<svg class="ours" viewBox="0 0 18 18" style="fill:currentColor">'
                  f'<g transform="{mb_transform}">{mb_body}</g></svg>')

    def mark_svg(style="fill:currentColor", cls=""):
        return (f'<svg class="{cls}" viewBox="{_vb(vb)}" style="{style}">'
                f'<g>{mark_paths}</g></svg>')

    html = TEMPLATE
    for token, value in {
        "__VB__": _vb(vb),
        "__MARK_BRAND__": mark_svg("color:__INK__;fill:currentColor"),
        "__MARK_INK__": mark_svg("color:__INK__;fill:currentColor"),
        "__MARK_PAPER__": mark_svg("color:__PAPER__;fill:currentColor"),
        "__MARK_INK_ROT__": mark_svg("color:__INK__;fill:currentColor", cls="rot"),
        "__MARK_INK_STRETCH__": mark_svg("color:__INK__;fill:currentColor", cls="stretch"),
        "__MARK_INK_SHADOW__": mark_svg("color:__INK__;fill:currentColor", cls="shadow"),
        "__MARK_OURS__": mb_svg,
        "__MARK_PATHS_INLINE__": mark_paths,
        "__MARK_BAD__": (f'<svg viewBox="{_vb(vb)}"><defs>'
                         f'<linearGradient id="badg" x1="0" y1="0" x2="1" y2="1">'
                         f'<stop offset="0" stop-color="{"#1B4332"}"/>'
                         f'<stop offset="1" stop-color="{"#C9A227"}"/></linearGradient></defs>'
                         f'<g fill="url(#badg)">{mark_paths_raw}</g></svg>'),
        "__ICON_BODY__": icon_body,
        "__ICON_DARK_BODY__": icon_dark,
        "__SIZES__": sizes,
        "__INK__": ink,
        "__PAPER__": paper,
        "__GRID_X__": str(gx0),
        "__GRID_Y__": str(gy0),
        "__GRID_W__": str(gx1 - gx0),
        "__GRID_H__": str(gy1 - gy0),
        "__BBOX_X__": f"{vb[0]:.2f}",
        "__BBOX_Y__": f"{vb[1]:.2f}",
        "__BBOX_W__": f"{vb[2]:.2f}",
        "__BBOX_H__": f"{vb[3]:.2f}",
    }.items():
        html = html.replace(token, value)
    _write(path, html)


TEMPLATE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>知枝 Sprig · 标识</title>
<style>
  :root {
    --ink: __INK__;
    --paper: __PAPER__;
    --bg: #FBFAF6;
    --line: #E7E2D6;
    --text: #17251D;
    --muted: #6E7C74;
    --card: #FFFFFF;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 15px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  main { max-width: 920px; margin: 0 auto; padding: 0 32px 96px; }
  svg { display: block; }

  header.top {
    max-width: 920px; margin: 0 auto; padding: 28px 32px 20px;
    display: flex; align-items: center; justify-content: space-between;
  }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 600; letter-spacing: .01em; }
  .brand svg { width: 22px; height: 22px; color: var(--ink); }
  .brand span { color: var(--muted); font-weight: 500; }
  .meta { color: var(--muted); font-size: 12.5px; letter-spacing: .08em; }

  .hero {
    display: grid; grid-template-columns: 232px 1fr; gap: 48px; align-items: center;
    padding: 44px 0 64px; border-bottom: 1px solid var(--line);
  }
  .hero .plate { height: 232px; display: flex; align-items: center; }
  .hero .plate svg { width: 220px; height: 220px; }
  h1 { font-size: 30px; line-height: 1.3; margin: 0 0 14px; letter-spacing: .01em; }
  .hero p { margin: 0 0 12px; color: #3C4A42; }
  .hero p.quiet { color: var(--muted); font-size: 13.5px; }
  kbd {
    font: 12px/1 ui-monospace, SFMono-Regular, Menlo, monospace; padding: 3px 6px;
    border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 5px;
    background: #fff; color: var(--text);
  }

  section { padding: 56px 0 8px; }
  h2 {
    font-size: 12.5px; font-weight: 600; letter-spacing: .16em; text-transform: uppercase;
    color: var(--muted); margin: 0 0 22px;
  }
  h2 em { font-style: normal; text-transform: none; letter-spacing: 0; color: var(--text); margin-left: 10px; }

  .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
  .tile {
    margin: 0; border-radius: 16px; border: 1px solid var(--line); background: var(--card);
    aspect-ratio: 1; display: flex; flex-direction: column; justify-content: space-between;
    padding: 18px; overflow: hidden;
  }
  .tile svg { width: 100%; height: 62%; }
  .tile figcaption { font: 11.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); }
  .tile.on-paper { background: var(--paper); border-color: var(--paper); }
  .tile.on-ink { background: var(--ink); border-color: var(--ink); }
  .tile.on-ink figcaption { color: #A9C0B4; }
  .tile.on-dark { background: #101A15; border-color: #101A15; }
  .tile.on-dark figcaption { color: #7E9488; }

  .icon-row { display: flex; gap: 24px; align-items: flex-end; }
  .icon-row .big { width: 200px; height: 200px; }
  .sizes { display: flex; align-items: flex-end; gap: 40px; margin-top: 44px; padding-left: 4px; }
  .size { display: flex; flex-direction: column; align-items: center; gap: 10px; }
  .size span { font: 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); }
  .size svg { border-radius: 22.37%; }

  .bar-mock { display: flex; flex-direction: column; gap: 12px; }
  .bar {
    display: flex; align-items: center; gap: 18px; height: 34px; padding: 0 14px;
    border-radius: 8px; border: 1px solid var(--line); background: #F1EFE9;
  }
  .bar.dark { background: #211F1C; border-color: #211F1C; }
  .bar .glyph { width: 18px; height: 18px; color: #2A2A2A; opacity: .45; }
  .bar.dark .glyph { color: #EAE6DC; opacity: .5; }
  .bar .ours { width: 18px; height: 18px; color: #1A1A1A; }
  .bar.dark .ours { color: #F2F0EA; }
  .bar .spacer { flex: 1; }
  .bar .hint { font: 12px/1 -apple-system, sans-serif; color: #8A867C; }
  .bar.dark .hint { color: #6F6B62; }

  .swatches { display: grid; grid-template-columns: repeat(2, 1fr); gap: 14px; }
  .swatch { border-radius: 16px; border: 1px solid var(--line); overflow: hidden; }
  .swatch .chip { height: 96px; }
  .swatch .info {
    display: flex; justify-content: space-between; align-items: center; padding: 12px 16px;
    background: var(--card); font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .swatch .role { color: var(--muted); }
  .swatch .hex { color: var(--text); }

  .construct { display: grid; grid-template-columns: 300px 1fr; gap: 40px; align-items: center; }
  .construct .frame { border: 1px solid var(--line); border-radius: 16px; background: var(--card); padding: 18px; }
  .construct svg { width: 100%; height: auto; color: var(--ink); }
  .notes { margin: 0; padding-left: 18px; color: #3C4A42; }
  .notes li { margin-bottom: 10px; }
  .notes b { font-weight: 600; }

  .donts { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
  .dont {
    margin: 0; border-radius: 16px; border: 1px solid var(--line); background: var(--card);
    aspect-ratio: 1; display: flex; flex-direction: column; justify-content: space-between; padding: 18px;
    position: relative;
  }
  .dont::after {
    content: "×"; position: absolute; top: 10px; right: 14px; color: #C0574B; font-size: 14px;
  }
  .dont svg { width: 100%; height: 62%; color: var(--ink); }
  .dont figcaption { font-size: 12px; color: var(--muted); }
  .dont .rot { transform: rotate(-16deg); }
  .dont .stretch { transform: scaleX(1.75) scaleY(.85); }
  .dont .shadow { filter: drop-shadow(0 6px 6px rgba(0,0,0,.45)); }
  .dont .stroke { color: var(--ink); }

  footer {
    max-width: 920px; margin: 0 auto; padding: 28px 32px 60px; border-top: 1px solid var(--line);
    color: var(--muted); font-size: 12.5px; display: flex; justify-content: space-between;
  }
  @media (max-width: 760px) {
    .hero, .construct { grid-template-columns: 1fr; }
    .tiles, .donts { grid-template-columns: repeat(2, 1fr); }
  }
</style>
</head>
<body>

<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <symbol id="appicon" viewBox="0 0 1024 1024">
__ICON_BODY__
  </symbol>
  <symbol id="appicon-dark" viewBox="0 0 1024 1024">
__ICON_DARK_BODY__
  </symbol>
</svg>

<header class="top">
  <div class="brand">__MARK_BRAND__ 知枝 <span>Sprig</span></div>
  <div class="meta">标识规范 v1</div>
</header>

<main>
  <section class="hero" style="padding-top:0">
    <div class="plate"><svg viewBox="0 0 1024 1024" role="img" aria-label="知枝 图标"><use href="#appicon"/></svg></div>
    <div>
      <h1>一枝，两叶</h1>
      <p>知枝是一个 <kbd>⌥Space</kbd> 唤起的问答面板：问一句就有答案，答案里的任意文字都能选中追问，
         每次追问都在右侧知识树里长出一张子卡。</p>
      <p class="quiet">标识只画这个动作本身——一条向上分叉的枝；叶片是一次回答，枝是追问的路径。</p>
    </div>
  </section>

  <section>
    <h2>标记<em>Mark</em></h2>
    <div class="tiles">
      <figure class="tile on-paper">
        __MARK_INK__
        <figcaption>纸底 · 墨绿</figcaption>
      </figure>
      <figure class="tile on-ink">
        __MARK_PAPER__
        <figcaption>墨绿底 · 反白</figcaption>
      </figure>
      <figure class="tile">
        __MARK_INK__
        <figcaption>白底 · 墨绿</figcaption>
      </figure>
      <figure class="tile on-dark">
        __MARK_PAPER__
        <figcaption>深色模式 · 反白</figcaption>
      </figure>
    </div>
  </section>

  <section>
    <h2>图标<em>App icon</em></h2>
    <div class="icon-row">
      <svg class="big" viewBox="0 0 1024 1024"><use href="#appicon"/></svg>
      <svg class="big" viewBox="0 0 1024 1024"><use href="#appicon-dark"/></svg>
    </div>
    <div class="sizes">__SIZES__</div>
  </section>

  <section>
    <h2>菜单栏<em>Menu bar · 18pt</em></h2>
    <div class="bar-mock">
      <div class="bar">
        <span class="hint">菜单栏右侧</span>
        <span class="spacer"></span>
        __MARK_OURS__
        <svg class="glyph" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="9" opacity=".35"/><circle cx="12" cy="12" r="4"/></svg>
        <svg class="glyph" viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="9" width="16" height="6" rx="2" opacity=".35"/><rect x="3" y="9" width="11" height="6" rx="2"/></svg>
      </div>
      <div class="bar dark">
        <svg class="glyph" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="9" opacity=".35"/><circle cx="12" cy="12" r="4"/></svg>
        <span class="spacer"></span>
        <div class="text">⌥Space</div>
        __MARK_OURS__
        <svg class="glyph" viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="9" width="16" height="6" rx="2" opacity=".35"/><rect x="3" y="9" width="11" height="6" rx="2"/></svg>
      </div>
    </div>
  </section>

  <section>
    <h2>色彩<em>2 colors</em></h2>
    <div class="swatches">
      <div class="swatch">
        <div class="chip" style="background:__INK__"></div>
        <div class="info"><span class="role">墨绿 · 枝</span><span class="hex">__INK__</span></div>
      </div>
      <div class="swatch">
        <div class="chip" style="background:__PAPER__"></div>
        <div class="info"><span class="role">纸色 · 底</span><span class="hex">__PAPER__</span></div>
      </div>
    </div>
  </section>

  <section>
    <h2>构造<em>Construction</em></h2>
    <div class="construct">
      <div class="frame">
        <svg viewBox="__VB__">
          <defs>
            <pattern id="g8" width="8" height="8" patternUnits="userSpaceOnUse" x="__GRID_X__" y="__GRID_Y__">
              <path d="M8 0H0V8" fill="none" stroke="__INK__" stroke-opacity=".12" stroke-width=".25"/>
            </pattern>
          </defs>
          <rect x="__BBOX_X__" y="__BBOX_Y__" width="__BBOX_W__" height="__BBOX_H__" fill="url(#g8)"/>
          <g fill="currentColor">__MARK_PATHS_INLINE__</g>
          <rect x="__BBOX_X__" y="__BBOX_Y__" width="__BBOX_W__" height="__BBOX_H__"
                fill="none" stroke="__INK__" stroke-opacity=".35" stroke-width=".3" stroke-dasharray="1.6 1.6"/>
        </svg>
      </div>
      <ul class="notes">
        <li><b>三笔</b>：枝身（根部斜切、向上收细）、顶叶（接住枝梢，所以看不到断口）、侧叶（贴在枝的左侧）。</li>
        <li><b>方向</b>：整体朝右上生长，和面板里知识树向右展开的方向一致。</li>
        <li><b>留白</b>：标记外框 = 图形外接矩形 + 2 单位边距；图标里标记占底板高度 62%。</li>
        <li><b>最小尺寸</b>：界面里不小于 16px；菜单栏另用加粗版，避免细笔在 18pt 下糊掉。</li>
      </ul>
    </div>
  </section>

  <section>
    <h2>别这样用<em>Don'ts</em></h2>
    <div class="donts">
      <figure class="dont">
        __MARK_INK_ROT__
        <figcaption>不要旋转、镜像</figcaption>
      </figure>
      <figure class="dont">
        __MARK_INK_STRETCH__
        <figcaption>不要拉伸变形</figcaption>
      </figure>
      <figure class="dont">
        __MARK_INK_SHADOW__
        <figcaption>不要加投影、渐变</figcaption>
      </figure>
      <figure class="dont">
        __MARK_BAD__
        <figcaption>保持两色，不要加第三种颜色</figcaption>
      </figure>
    </div>
  </section>
</main>

<footer>
  <span>知枝 Sprig · 标识由 assets/logo/build.py 生成</span>
  <span>墨绿 __INK__ / 纸色 __PAPER__</span>
</footer>

</body>
</html>
"""
