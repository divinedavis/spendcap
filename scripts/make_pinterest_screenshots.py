#!/usr/bin/env python3
"""Compose App Store screenshots in the Pinterest product-page style.

Five 1320x2868 panels (the APP_IPHONE_67 slot; Apple scales the rest):

  1. brand panel  — pale tint field, app icon + name centred near the top, then a
                    two-column masonry of cropped UI cards that bleeds off the
                    left, right and bottom edges (Pinterest's opening grid).
  2-5. feature    — one solid pastel/deep field each, a single sentence-case
                    headline centred near the top, and the real screen as a
                    frameless rounded card that bleeds off the bottom. The last
                    panel gets a few floating emoji stickers.

Config is a JSON file (see --example). Fonts: SF Pro (SFNS.ttf) + Apple Color
Emoji, both stock on macOS.

    python3 pinterest_panels.py marketing/asc-pinterest.json
"""
from __future__ import annotations

import colorsys
import json
import math
import pathlib
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1320, 2868
SF = "/System/Library/Fonts/SFNS.ttf"
EMOJI = "/System/Library/Fonts/Apple Color Emoji.ttc"

EXAMPLE = {
    "name": "Milepost",
    "icon": "Milepost/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    "brand": "#FF5C1A",
    "raw_dir": "marketing/raw",
    "out_dir": "marketing/asc-screenshots",
    "masonry": ["map-route.png", "route-detail.png", "you-totals.png", "activities-list.png"],
    "panels": [
        ["map-route.png", "Press start. That's it."],
        ["route-recording.png", "See your pace live"],
        ["route-detail.png", "Every run, mapped"],
        ["you-totals.png", "Watch the miles add up"],
    ],
    "stickers": ["🏃", "🗺️", "⛰️", "🔥"],
    "palette": None,
}


# ---------- colour ----------

def hex_to_rgb(s: str) -> tuple[int, int, int]:
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def hsl(h: float, s: float, l: float) -> tuple[int, int, int]:
    r, g, b = colorsys.hls_to_rgb(h % 1.0, l, s)
    return int(r * 255), int(g * 255), int(b * 255)


def dominant_hue(icon: Image.Image) -> float:
    small = icon.convert("RGB").resize((64, 64))
    buckets: dict[int, int] = {}
    raw = small.tobytes()
    for i in range(0, len(raw), 3):
        r, g, b = raw[i], raw[i + 1], raw[i + 2]
        h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        if s < 0.35 or l < 0.12 or l > 0.92:
            continue
        buckets[int(h * 24)] = buckets.get(int(h * 24), 0) + 1
    if not buckets:
        return 0.0
    return (max(buckets, key=buckets.get) + 0.5) / 24


def build_palette(hue: float) -> list[dict]:
    """Five fields + ink, spread around the wheel like Pinterest's set
    (red brand -> blush, peach, deep purple, lavender, pale yellow)."""
    return [
        {"bg": hsl(hue, 0.55, 0.965), "ink": hsl(hue, 0.65, 0.18)},
        {"bg": hsl(hue + 0.04, 0.95, 0.84), "ink": hsl(hue + 0.30, 0.55, 0.16)},
        {"bg": hsl(hue - 0.10, 0.80, 0.17), "ink": (255, 255, 255)},
        {"bg": hsl(hue - 0.22, 0.90, 0.87), "ink": hsl(hue - 0.22, 0.60, 0.16)},
        {"bg": hsl(hue + 0.12, 0.85, 0.91), "ink": hsl(hue + 0.12, 0.55, 0.15)},
    ]


# ---------- drawing helpers ----------

def font(size: int, weight: str = "Semibold") -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(SF, size)
    f.set_variation_by_name(weight)
    return f


def rounded(img: Image.Image, radius: int) -> Image.Image:
    img = img.convert("RGBA")
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    img.putalpha(mask)
    return img


def wrap(draw: ImageDraw.ImageDraw, text: str, f: ImageFont.FreeTypeFont, max_w: int) -> list[str]:
    if "\n" in text:
        return text.split("\n")
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=f) <= max_w or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    lines.append(cur)
    return lines


def headline(canvas: Image.Image, text: str, ink: tuple, center_y: int) -> None:
    draw = ImageDraw.Draw(canvas)
    size = 108
    while True:
        f = font(size, "Medium")
        lines = wrap(draw, text, f, int(W * 0.86))
        if len(lines) <= 2 or size <= 72:
            break
        size -= 6
    line_h = int(size * 1.15)
    y = center_y - (line_h * len(lines)) // 2
    for line in lines:
        tw = draw.textlength(line, font=f)
        draw.text(((W - tw) / 2, y), line, font=f, fill=ink)
        y += line_h


def screen_card(raw: Image.Image, width: int) -> Image.Image:
    h = int(raw.height * width / raw.width)
    return rounded(raw.resize((width, h), Image.LANCZOS), radius=int(width * 0.075))


def emoji(ch: str, size: int) -> Image.Image:
    f = ImageFont.truetype(EMOJI, 160)
    im = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
    ImageDraw.Draw(im).text((20, 20), ch, font=f, embedded_color=True)
    im = im.crop(im.getbbox() or (0, 0, 200, 200))
    scale = size / max(im.size)
    return im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))), Image.LANCZOS)


def shadowed(base: Image.Image, card: Image.Image, xy: tuple[int, int]) -> None:
    """Soft drop shadow under a card, then the card."""
    from PIL import ImageFilter
    x, y = xy
    pad = 60
    sh = Image.new("RGBA", (card.width + pad * 2, card.height + pad * 2), (0, 0, 0, 0))
    a = card.split()[3].point(lambda v: int(v * 0.22))
    sh.paste((0, 0, 0, 255), (pad, pad + 18), a)
    sh = sh.filter(ImageFilter.GaussianBlur(28))
    base.alpha_composite(sh, (x - pad, y - pad))
    base.alpha_composite(card, (x, y))


def best_band(src: Image.Image, th: int, used: set) -> Image.Image:
    """The most visually busy horizontal band of height th below the status
    bar, skipping bands already used from this screenshot."""
    import statistics
    y_min, y_max = 170, max(170, src.height - th - 40)
    candidates = list(range(y_min, y_max + 1, 120)) or [y_min]
    small = src.convert("L").resize((src.width // 8, src.height // 8))
    best, best_score = candidates[0], -1.0
    for y0 in candidates:
        if any(abs(y0 - u) < th * 0.6 for u in used):
            continue
        band = small.crop((0, y0 // 8, small.width, (y0 + th) // 8))
        px = list(band.tobytes())
        score = statistics.pstdev(px) if len(px) > 1 else 0.0
        if score > best_score:
            best, best_score = y0, score
    used.add(best)
    return src.crop((0, best, src.width, best + th))


# ---------- panels ----------

def brand_panel(cfg: dict, pal: dict, icon: Image.Image, shots: list[Image.Image], out: pathlib.Path) -> None:
    canvas = Image.new("RGBA", (W, H), pal["bg"] + (255,))
    # icon + name, centred like the Pinterest wordmark
    ic = rounded(icon.resize((150, 150), Image.LANCZOS), radius=34)
    f = font(104, "Bold")
    draw = ImageDraw.Draw(canvas)
    name = cfg["name"]
    tw = draw.textlength(name, font=f)
    gap = 36
    total = ic.width + gap + tw
    x0 = int((W - total) / 2)
    cy = int(H * 0.095)
    canvas.alpha_composite(ic, (x0, cy - ic.height // 2))
    draw.text((x0 + ic.width + gap, cy - 62), name, font=f, fill=pal["ink"])

    # masonry: three columns — the centre one whole, the outer two bleeding
    # off the left/right edges, all three running off the bottom.
    col_w = int(W * 0.40)
    gutter = 26
    cx = (W - col_w) // 2
    xs = [cx - gutter - col_w, cx, cx + col_w + gutter]
    top = int(H * 0.2)
    offsets = [140, 0, 300]
    heights = [1500, 1100, 1800, 1250, 1650, 1000, 1400]
    scale = col_w / shots[0].width
    tiles = []
    used: dict[int, set] = {}
    k = 0
    for c in range(3):
        y = top + offsets[c]
        while y < H + 40:
            si = k % len(shots)
            src = shots[si]
            th = min(heights[k % len(heights)], src.height - 210)
            crop = best_band(src, th, used.setdefault(si, set()))
            crop = crop.resize((col_w, int(crop.height * col_w / src.width)), Image.LANCZOS)
            tiles.append((xs[c], y, rounded(crop, 40)))
            y += crop.height + gutter
            k += 1
    for x, y, tile in tiles:
        shadowed(canvas, tile, (x, y))
    canvas.convert("RGB").save(out, optimize=True)


def feature_panel(text: str, pal: dict, raw: Image.Image, stickers: list[str], out: pathlib.Path) -> None:
    canvas = Image.new("RGBA", (W, H), pal["bg"] + (255,))
    headline(canvas, text, pal["ink"], center_y=int(H * 0.095))
    card = screen_card(raw, int(W * 0.84))
    x = (W - card.width) // 2
    y = int(H * 0.195)
    shadowed(canvas, card, (x, y))
    if stickers:
        big, small = 250, 190
        spots = [(x + card.width - 150, y - 90, -14, big),          # top-right corner, over the edge
                 (x - 120, y + int(card.height * 0.30), 12, small),  # left edge
                 (x + card.width - 90, y + int(card.height * 0.46), 18, small),  # right edge
                 (x - 60, H - 380, -10, big),                          # bottom-left cluster
                 (x + card.width - 260, H - 330, 10, big),            # bottom-right cluster
                 (x + 220, H - 260, 20, small)]
        for i, ch in enumerate(stickers[:6]):
            sx, sy, rot, size = spots[i]
            em = emoji(ch, size).rotate(rot, expand=True, resample=Image.BICUBIC)
            canvas.alpha_composite(em, (int(sx), int(sy)))
    canvas.convert("RGB").save(out, optimize=True)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    if sys.argv[1] == "--example":
        print(json.dumps(EXAMPLE, indent=2, ensure_ascii=False))
        return 0
    cfg_path = pathlib.Path(sys.argv[1]).resolve()
    cfg = json.loads(cfg_path.read_text())
    root = cfg_path.parent.parent if cfg_path.parent.name == "marketing" else cfg_path.parent
    raw_dir = root / cfg["raw_dir"]
    out_dir = root / cfg["out_dir"]
    icon = Image.open(root / cfg["icon"]).convert("RGBA")
    if cfg.get("palette"):
        pal = [{"bg": hex_to_rgb(p["bg"]), "ink": hex_to_rgb(p["ink"])} for p in cfg["palette"]]
    else:
        hue = colorsys.rgb_to_hls(*[c / 255 for c in hex_to_rgb(cfg["brand"])])[0] if cfg.get("brand") else dominant_hue(icon)
        pal = build_palette(hue)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    load = lambda n: Image.open(raw_dir / n).convert("RGB")  # noqa: E731
    shots = [load(n) for n in cfg.get("masonry") or [p[0] for p in cfg["panels"]]]
    brand_panel(cfg, pal[0], icon, shots, out_dir / "01-brand.png")
    print("  ✓ 01-brand.png")
    for i, (file, text) in enumerate(cfg["panels"][:4], start=2):
        stickers = cfg.get("stickers") or [] if i == 5 else []
        out = out_dir / f"{i:02d}-{pathlib.Path(file).stem}.png"
        feature_panel(text, pal[i - 1], load(file), stickers, out)
        print(f"  ✓ {out.name}  “{text}”")
    print(f"5 panels in {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
