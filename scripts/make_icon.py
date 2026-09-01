#!/usr/bin/env python3
"""Draw the Spendcap mark and write every raster the project needs.

The mark is three spending bars rising toward a hard cap rule. It is defined
once here as SVG so the app icon, the README art and any marketing asset are
literally the same geometry rather than three drifting copies.

Outputs (paths relative to the repo root):

    Spendcap/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
    marketing/logo.svg          full-bleed mark, for the web
    marketing/logo-1024.png     same, rasterised
    marketing/logo-mono.svg     single-colour mark on transparency

Requires `rsvg-convert` (brew install librsvg) and Pillow. The App Store icon
is flattened onto an opaque field with no alpha channel — App Store Connect
rejects a 1024 icon that carries one.

Usage:
    python3 scripts/make_icon.py [--check]

--check re-renders into a temp dir, diffs against the committed files, and
verifies that `SpendcapMark.Geometry` in Swift still describes the same
drawing. run_tests.sh runs it, so an icon edited in one place and not the other
fails the sweep rather than shipping two different logos.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops

ROOT = pathlib.Path(__file__).resolve().parent.parent
APPICON = ROOT / "Spendcap/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
MARKETING = ROOT / "marketing"

# Palette — the app's AccentColor green, the 80%-threshold amber, and the
# near-black field. Changing these means changing Assets.xcassets too.
GREEN_LIGHT = "#3ADB59"
GREEN_DARK = "#1E9E43"
AMBER = "#FF9F0A"
FIELD_TOP = "#161C25"
FIELD_BOTTOM = "#0B0E13"

# Geometry on a 1024 canvas. Bars ascend left to right and the tallest stops
# just short of the cap rule: at the limit, not over it.
BAR_W = 132
BAR_GAP = 60
BAR_R = 38
BASELINE = 754
BAR_TOPS = (570, 452, 344)
RULE_Y = 268
RULE_H = 48
RULE_OVERHANG = 46

BARS_SPAN = 3 * BAR_W + 2 * BAR_GAP
BARS_X = (1024 - BARS_SPAN) // 2
RULE_W = BARS_SPAN + 2 * RULE_OVERHANG
RULE_X = (1024 - RULE_W) // 2


def bars(fill: str) -> str:
    out = []
    for i, top in enumerate(BAR_TOPS):
        x = BARS_X + i * (BAR_W + BAR_GAP)
        out.append(
            f'<rect x="{x}" y="{top}" width="{BAR_W}" height="{BASELINE - top}" '
            f'rx="{BAR_R}" fill="{fill}"/>'
        )
    return "\n    ".join(out)


def rule(fill: str) -> str:
    return (
        f'<rect x="{RULE_X}" y="{RULE_Y}" width="{RULE_W}" height="{RULE_H}" '
        f'rx="{RULE_H // 2}" fill="{fill}"/>'
    )


def svg(*, field: bool, mono: str | None = None) -> str:
    """Full-colour mark, or a single-colour one on transparency for `mono`."""
    if mono:
        body = f"{rule(mono)}\n    {bars(mono)}"
        defs = background = ""
    else:
        body = f"{rule(AMBER)}\n    {bars('url(#barFill)')}"
        defs = f"""
  <defs>
    <linearGradient id="field" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{FIELD_TOP}"/>
      <stop offset="1" stop-color="{FIELD_BOTTOM}"/>
    </linearGradient>
    <linearGradient id="barFill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{GREEN_LIGHT}"/>
      <stop offset="1" stop-color="{GREEN_DARK}"/>
    </linearGradient>
  </defs>"""
        background = '<rect width="1024" height="1024" fill="url(#field)"/>' if field else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{defs}
    {background}
    {body}
</svg>
"""


def render(source: str, dest: pathlib.Path, *, flatten: bool) -> None:
    """Rasterise at 4x and downsample, which antialiases the rounded corners
    far better than rsvg's own 1x output."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        svg_path = pathlib.Path(tmp) / "mark.svg"
        big_path = pathlib.Path(tmp) / "big.png"
        svg_path.write_text(source)
        subprocess.run(
            ["rsvg-convert", "-w", "4096", "-h", "4096", "-o", str(big_path), str(svg_path)],
            check=True,
        )
        img = Image.open(big_path).resize((1024, 1024), Image.LANCZOS)
        if flatten:
            # App Store Connect rejects an icon with an alpha channel.
            field = Image.new("RGB", img.size, FIELD_BOTTOM)
            field.paste(img, mask=img.split()[-1] if img.mode == "RGBA" else None)
            img = field
        img.save(dest)


def build(app_icon: pathlib.Path, marketing: pathlib.Path) -> None:
    render(svg(field=True), app_icon, flatten=True)
    marketing.mkdir(parents=True, exist_ok=True)
    (marketing / "logo.svg").write_text(svg(field=True))
    (marketing / "logo-mono.svg").write_text(svg(field=False, mono="currentColor"))
    render(svg(field=True), marketing / "logo-1024.png", flatten=False)


SWIFT_MARK = ROOT / "Spendcap/App/SpendcapMark.swift"

# Swift constant name -> value here. The Swift view redraws the mark as vectors
# for the sign-in and Settings screens; if it drifts, the logo in the app stops
# being the logo on the home screen.
SWIFT_GEOMETRY = {
    "unit": 1024,
    "barWidth": BAR_W,
    "barGap": BAR_GAP,
    "barRadius": BAR_R,
    "baseline": BASELINE,
    "ruleY": RULE_Y,
    "ruleHeight": RULE_H,
    "ruleOverhang": RULE_OVERHANG,
}


def swift_drift() -> list[str]:
    """Names of geometry constants that disagree between here and Swift."""
    if not SWIFT_MARK.exists():
        return [f"missing {SWIFT_MARK.name}"]
    source = SWIFT_MARK.read_text()
    problems = []
    for name, expected in SWIFT_GEOMETRY.items():
        found = re.search(rf"static let {name}: CGFloat = ([\d.]+)", source)
        if not found:
            problems.append(f"{name}: not found in {SWIFT_MARK.name}")
        elif float(found.group(1)) != float(expected):
            problems.append(f"{name}: swift {found.group(1)} != script {expected}")
    tops = re.search(r"static let barTops: \[CGFloat\] = \[([^\]]+)\]", source)
    if not tops:
        problems.append(f"barTops: not found in {SWIFT_MARK.name}")
    elif tuple(float(v) for v in tops.group(1).split(",")) != tuple(float(v) for v in BAR_TOPS):
        problems.append(f"barTops: swift [{tops.group(1)}] != script {list(BAR_TOPS)}")
    return problems


def differs(committed: pathlib.Path, fresh: pathlib.Path) -> bool:
    """Has the art actually changed?

    PNGs are compared by pixel, not by byte. The question this check exists to
    ask is whether the committed raster still shows what the source geometry
    draws — and a Pillow upgrade re-encodes an identical image into different
    bytes, which byte comparison reports as a stale icon and blocks a ship over
    nothing. That happened on 2026-08-31: both PNGs came back stale with every
    pixel identical and only the encoder's output size changed.

    SVGs stay byte-exact. They are generated text, so any difference there is a
    real one.
    """
    if committed.suffix != ".png":
        return committed.read_bytes() != fresh.read_bytes()
    with Image.open(committed) as a, Image.open(fresh) as b:
        left, right = a.convert("RGBA"), b.convert("RGBA")
        if left.size != right.size:
            return True
        return ImageChops.difference(left, right).getbbox() is not None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="diff against committed files")
    args = parser.parse_args()

    if not shutil.which("rsvg-convert"):
        print("rsvg-convert not found — brew install librsvg", file=sys.stderr)
        return 1

    if not args.check:
        build(APPICON, MARKETING)
        print(f"wrote {APPICON.relative_to(ROOT)} and {MARKETING.relative_to(ROOT)}/")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp)
        build(out / "icon-1024.png", out / "marketing")
        stale = [
            name
            for name, fresh in (
                (APPICON, out / "icon-1024.png"),
                (MARKETING / "logo.svg", out / "marketing/logo.svg"),
                (MARKETING / "logo-mono.svg", out / "marketing/logo-mono.svg"),
                (MARKETING / "logo-1024.png", out / "marketing/logo-1024.png"),
            )
            if not name.exists() or differs(name, fresh)
        ]
    for path in stale:
        print(f"stale: {path.relative_to(ROOT)} — re-run scripts/make_icon.py", file=sys.stderr)
    drift = swift_drift()
    for problem in drift:
        print(f"drift: {problem}", file=sys.stderr)
    if not stale and not drift:
        print("icon art and SpendcapMark.Geometry agree")
    return 1 if (stale or drift) else 0


if __name__ == "__main__":
    raise SystemExit(main())
