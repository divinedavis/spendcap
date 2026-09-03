#!/usr/bin/env python3
"""Compose App Store screenshots from the signed-in captures.

Input:  the PNGs `capture_screenshots.sh` exports (raw 1320x2868 frames from an
        iPhone 17 Pro Max simulator), renamed by their attachment names.
Output: build/asc-screenshots/{1..5}.png at 1290x2796 — the 6.7" slot Apple's
        API accepts (APP_IPHONE_67); a 1320x2868 canvas is rejected there.

Style follows the portfolio-wide direction: five panels, alternating brand
colour and white, one short lowercase headline per panel, the screen inside a
rounded device-like frame. Brand green is the app's AccentColor; the ink is the
icon's near-black.

    python3 scripts/asc_make_screenshots.py [--raw build.nosync/screenshots-raw]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "build" / "asc-screenshots"
CANVAS = (1290, 2796)
GREEN = (52, 199, 69)      # AccentColor (0.204, 0.780, 0.271)
INK = (26, 26, 26)
WHITE = (255, 255, 255)
SOFT = (110, 110, 115)

# (raw capture name, headline lines, background, subline)
PANELS = [
    ("02-trends",       "one number.\nnever over.",       GREEN, "Set a daily cap. Get a push at 80% and 100%."),
    ("07-months",       "the whole\nyear, honest.",       WHITE, "Twelve months of totals against your cap."),
    ("06-activity",     "every dollar,\nas it posts.",    GREEN, "Money in and money out, newest first."),
    ("08-debt",         "what goes out\nevery month.",    WHITE, "Planned beside paid, grouped your way."),
    ("11-trip-detail",  "trips don't\nblow the cap.",     GREEN, "A hotel booking never fires a false alarm."),
]


def load_font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/Library/Fonts/Arial Bold.ttf",
    ]
    for p in candidates:
        if pathlib.Path(p).exists():
            try:
                f = ImageFont.truetype(p, size=size)
                # SFNS.ttf is a variable font; pick the heavy instance.
                try:
                    f.set_variation_by_name("Bold" if bold else "Regular")
                except Exception:
                    pass
                return f
            except OSError:
                continue
    return ImageFont.load_default()


def rename_raw(raw_dir: pathlib.Path) -> dict[str, pathlib.Path]:
    """Map attachment names (02-trends, …) to files, via the export manifest."""
    manifest = raw_dir / "manifest.json"
    named: dict[str, pathlib.Path] = {}
    if manifest.exists():
        for grp in json.loads(manifest.read_text()):
            for a in grp["attachments"]:
                key = a["suggestedHumanReadableName"].split("_0_")[0]
                src = raw_dir / a["exportedFileName"]
                if src.exists():
                    named[key] = src
    for p in raw_dir.glob("*.png"):
        named.setdefault(p.stem, p)
    return named


def composite(raw: Image.Image, headline: str, subline: str, bg: tuple, out: pathlib.Path) -> None:
    canvas = Image.new("RGB", CANVAS, bg)
    draw = ImageDraw.Draw(canvas)
    ink = INK if bg == WHITE else WHITE
    sub_ink = SOFT if bg == WHITE else (225, 245, 228)

    font = load_font(150)
    x, y = 96, 170
    for line in headline.split("\n"):
        draw.text((x, y), line, fill=ink, font=font)
        y = draw.textbbox((x, y), line, font=font)[3] + 6
    y += 26
    draw.text((x, y), subline, fill=sub_ink, font=load_font(46, bold=False))
    y += 46 + 70

    # Device-like frame: dark rounded rect with the screen inset.
    side = 120
    frame_w = CANVAS[0] - 2 * side
    bezel = 18
    screen_w = frame_w - 2 * bezel
    scale = screen_w / raw.width
    screen_h = int(raw.height * scale)
    frame_h = screen_h + 2 * bezel
    if y + frame_h > CANVAS[1] + 400:
        pass  # the bottom of the phone is meant to run off the canvas
    frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, frame_w, frame_h), radius=110, fill=INK)
    screen = raw.resize((screen_w, screen_h), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (screen_w, screen_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen_w, screen_h), radius=92, fill=255)
    screen.putalpha(mask)
    frame.paste(screen, (bezel, bezel), screen)
    canvas.paste(frame, (side, y), frame)

    # Small wordmark in the corner of accent panels.
    if bg != WHITE:
        draw.text((CANVAS[0] - 96 - 230, 84), "spendcap", fill=WHITE, font=load_font(44))

    canvas.save(out, format="PNG", optimize=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=str(ROOT / "build.nosync" / "screenshots-raw"))
    args = ap.parse_args()
    raw_dir = pathlib.Path(args.raw)
    named = rename_raw(raw_dir)
    if not named:
        raise SystemExit(f"no captures in {raw_dir} — run scripts/capture_screenshots.sh first")

    if OUT_DIR.exists():
        shutil.rmtree(OUT_DIR)
    OUT_DIR.mkdir(parents=True)
    made = 0
    for i, (key, headline, bg, subline) in enumerate(PANELS, start=1):
        src = named.get(key)
        if not src:
            print(f"  ! no capture named {key}; skipping panel {i}")
            continue
        out = OUT_DIR / f"{i}.png"
        composite(Image.open(src).convert("RGB"), headline, subline, bg, out)
        print(f"  ✓ {out.name}  ← {key}")
        made += 1
    print(f"{made} panel(s) in {OUT_DIR}")
    return 0 if made else 1


if __name__ == "__main__":
    sys.exit(main())
