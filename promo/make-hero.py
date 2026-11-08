#!/usr/bin/env python3
"""生成 README 头图：Apple 首页 + Grabi 的截图覆盖层。

    python3 promo/make-hero.py

输出 promo/assets/hero-capture.png。

覆盖层的每一档数值都抄自 app 里的设计常量，不是随手调的：

  Sources/Grabi/Support/Design.swift   dimSelect  = 黑 32%
                                       badge      = 黑 75%
  Sources/Grabi/Capture/ShotOverlay.swift
                                       1px 蓝色描边 + 四角白色角标（白 3pt，底衬黑 55%）

所以头图和真机截出来的图是同一套视觉，改了 app 里的常量这里也要跟着改。
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "promo/assets/apple-home.png"
OUTPUT = ROOT / "promo/assets/hero-capture.png"

# 画布 = 一块 1600×1000 的屏幕（点）。Apple 首页铺满，选中的「浏览器窗口」
# 是中间那块 1040×640 的区域，正好和角标上的尺寸对得上。
CANVAS = (1600, 1000)
HOLE = (280, 190, 1320, 830)

DIM_ALPHA = 0.32
BADGE_ALPHA = 0.75
FRAME_COLOR = (22, 128, 243)

HIRAGINO = "/System/Library/Fonts/Hiragino Sans GB.ttc"
SYMBOLS = "/System/Library/Fonts/Apple Symbols.ttf"


def font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    index = 2 if weight == "bold" else 0
    return ImageFont.truetype(HIRAGINO, size, index=index)


def draw_rich(draw: ImageDraw.ImageDraw, xy: tuple[int, int], parts) -> int:
    """按片段画一行字，返回整行宽度。

    中文和英文走 Hiragino，⏎ 这种符号 Hiragino 里没有，交给 Apple Symbols，
    否则会渲染成豆腐块。
    """
    x, y = xy
    for text, f, fill in parts:
        draw.text((x, y), text, font=f, fill=fill)
        x += draw.textlength(text, font=f)
    return int(x - xy[0])


def main() -> None:
    base = Image.open(SOURCE).convert("RGB")
    if base.size != CANVAS:
        base = base.resize(CANVAS, Image.LANCZOS)

    canvas = Image.blend(base, Image.new("RGB", CANVAS, (0, 0, 0)), DIM_ALPHA)
    canvas.paste(base.crop(HOLE), HOLE[:2])

    draw = ImageDraw.Draw(canvas)
    x0, y0, x1, y1 = HOLE

    # 1px 描边
    draw.rectangle((x0, y0, x1 - 1, y1 - 1), outline=FRAME_COLOR, width=1)

    # 四角角标：先用半透明黑压一道粗线，再压白色细线 —— 和 ShotOverlay 一样，
    # 白色角标落在亮背景上也分得出来。
    arm, tick = 26, 3
    for cx, cy, dx, dy in (
        (x0, y0, 1, 1),
        (x1 - 1, y0, -1, 1),
        (x0, y1 - 1, 1, -1),
        (x1 - 1, y1 - 1, -1, -1),
    ):
        for horizontal in (True, False):
            end = (cx + dx * arm, cy) if horizontal else (cx, cy + dy * arm)
            draw.line((cx, cy, *end), fill=(0, 0, 0, 140), width=int(tick + 2.5))
            draw.line((cx, cy, *end), fill=(255, 255, 255), width=tick)

    # 选区尺寸角标，贴在选区左下角外侧
    label_big = font(13, "bold")
    label_small = font(12)
    enter = ImageFont.truetype(SYMBOLS, 12)

    pad_x, pad_y, radius = 16, 9, 8
    second = [
        ("1040 × 640", label_small, (255, 255, 255, 235)),
        ("   ", label_small, None),
        ("单击或 ", label_small, (255, 255, 255, 215)),
        ("⏎", enter, (255, 255, 255, 235)),
        (" 截取该窗口", label_small, (255, 255, 255, 215)),
    ]
    width = max(int(draw.textlength("窗口", font=label_big)),
                sum(int(draw.textlength(t, font=f)) for t, f, _ in second)) + pad_x * 2
    height = 13 + 12 + pad_y * 2 + 12
    bx, by = x0, y1 + 14

    badge = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    badge_draw = ImageDraw.Draw(badge)
    badge_draw.rounded_rectangle((0, 0, width - 1, height - 1), radius=radius,
                                 fill=(0, 0, 0, int(BADGE_ALPHA * 255)))
    badge_draw.text((pad_x, pad_y), "窗口", font=label_big, fill=(255, 255, 255, 255))
    draw_rich(badge_draw, (pad_x, pad_y + 22), [p for p in second if p[2] is not None])
    canvas.paste(badge, (bx, by), badge)

    canvas.save(OUTPUT)
    print(OUTPUT)


if __name__ == "__main__":
    main()
