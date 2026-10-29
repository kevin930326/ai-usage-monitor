#!/usr/bin/env python3
"""產生瀏海「總覽」分頁的自訂 SF Symbol「角色的臉」（SF Symbols 3 範本，ADR-0008）。

圓框（線條）加兩顆實心膠囊眼睛：眼距（中心到中心）約直徑的 30%、眼睛高約為寬的 2 倍（同角色 shared/mascot-anim.json 的 hero.eye）。
給 Ultralight-S、Regular-S、Black-S 三個字重，Xcode 內插出其他字重與大小；三組路徑的指令與點數必須一樣才能內插。

用法：scripts/make-face-symbol.py（覆寫 Assets.xcassets 裡的 notch.face.symbolset）
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "apple/MacMenuBar/AIUsageMenuBar/Assets.xcassets/notch.face.symbolset"
K = 0.5522847498  # 四段三次貝茲近似圓
CAP = 70.459  # 範本的大寫字高（Capline-S 到 Baseline-S）
MID = 33.0  # 圓框線條中心的半徑（和 gearshape 等分頁圖示差不多大）
# 字重：(圓框線寬, 眼睛寬, 眼睛高, 範本裡的左邊界 x)。眼睛比角色的 0.27R×0.52R 略大，11pt 時才看得出是眼睛
WEIGHTS = {
    "Ultralight-S": (2.4, 8.0, 16.0, 400.0),
    "Regular-S": (7.2, 11.5, 23.0, 1850.0),
    "Black-S": (13.0, 14.0, 26.0, 2850.0),
}
EYE_GAP = 22.0  # 眼睛中心距離：約直徑（Regular 73）的 30%


def n(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def circle(cx: float, cy: float, r: float, clockwise: bool) -> str:
    k = r * K
    if clockwise:  # 上 → 右 → 下 → 左（SVG 的 y 往下）
        pts = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
        ctl = [((cx + k, cy - r), (cx + r, cy - k)), ((cx + r, cy + k), (cx + k, cy + r)),
               ((cx - k, cy + r), (cx - r, cy + k)), ((cx - r, cy - k), (cx - k, cy - r))]
    else:  # 上 → 左 → 下 → 右
        pts = [(cx, cy - r), (cx - r, cy), (cx, cy + r), (cx + r, cy)]
        ctl = [((cx - k, cy - r), (cx - r, cy - k)), ((cx - r, cy + k), (cx - k, cy + r)),
               ((cx + k, cy + r), (cx + r, cy + k)), ((cx + r, cy - k), (cx + k, cy - r))]
    d = f"M{n(pts[0][0])} {n(pts[0][1])}"
    for i in range(4):
        (a, b), end = ctl[i], pts[(i + 1) % 4]
        d += f"C{n(a[0])} {n(a[1])} {n(b[0])} {n(b[1])} {n(end[0])} {n(end[1])}"
    return d + "Z"


def capsule(cx: float, cy: float, w: float, h: float) -> str:
    r = w / 2
    k = r * K
    top, bot = cy - h / 2, cy + h / 2
    return (f"M{n(cx - r)} {n(top + r)}"
            f"C{n(cx - r)} {n(top + r - k)} {n(cx - k)} {n(top)} {n(cx)} {n(top)}"
            f"C{n(cx + k)} {n(top)} {n(cx + r)} {n(top + r - k)} {n(cx + r)} {n(top + r)}"
            f"L{n(cx + r)} {n(bot - r)}"
            f"C{n(cx + r)} {n(bot - r + k)} {n(cx + k)} {n(bot)} {n(cx)} {n(bot)}"
            f"C{n(cx - k)} {n(bot)} {n(cx - r)} {n(bot - r + k)} {n(cx - r)} {n(bot - r)}Z")


def glyph(stroke: float, ew: float, eh: float) -> tuple[str, float]:
    outer = MID + stroke / 2
    cx, cy = outer, -CAP / 2  # 以基線左端為原點，垂直置中在大寫字高的一半
    d = circle(cx, cy, outer, True) + circle(cx, cy, MID - stroke / 2, False)
    d += capsule(cx - EYE_GAP / 2, cy, ew, eh) + capsule(cx + EYE_GAP / 2, cy, ew, eh)
    return d, outer * 2


def main() -> None:
    guides, symbols = [], []
    line = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
    for name, (stroke, ew, eh, left) in WEIGHTS.items():
        d, width = glyph(stroke, ew, eh)
        symbols.append(f'  <g id="{name}" transform="matrix(1 0 0 1 {n(left)} 696)">\n   <path d="{d}"/>\n  </g>')
        for side, x in (("left", left), ("right", left + width)):
            guides.append(f'  <line id="{side}-margin-{name}" {line} x1="{n(x)}" x2="{n(x)}" y1="600.785" y2="720.121"/>')
    base = []
    for scale, y in (("S", 696), ("M", 1126), ("L", 1556)):
        base.append(f'  <line id="Baseline-{scale}" {line} x1="263" x2="3036" y1="{y}" y2="{y}"/>')
        base.append(f'  <line id="Capline-{scale}" {line} x1="263" x2="3036" y1="{n(y - CAP)}" y2="{n(y - CAP)}"/>')
    svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!-- 由 scripts/make-face-symbol.py 產生，不要手改 -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 2952 1933)">Template v.3.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 2952 1953)">notch.face</text>
 </g>
 <g id="Guides">
{chr(10).join(base + guides)}
 </g>
 <g id="Symbols">
{chr(10).join(symbols)}
 </g>
</svg>
"""
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "notch.face.svg").write_text(svg)
    (OUT / "Contents.json").write_text('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
                                       '  "symbols" : [\n    {\n      "filename" : "notch.face.svg",\n'
                                       '      "idiom" : "universal"\n    }\n  ]\n}\n')


if __name__ == "__main__":
    main()
