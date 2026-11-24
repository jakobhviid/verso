#!/usr/bin/env python3
"""Make Verso's Linux app icons from its drawing, dev.hviid.Verso.svg (Mist, the app's design): the print edge to
edge, as Linux shows icons. Writes dev.hviid.Verso.png (512) and hicolor/<size>/dev.hviid.Verso.png beside this
script; and Verso Drive's icon, the same with a drive's badge in its corner, so the drive in a dock or a file manager
is not taken for the app (hicolor/<size>/dev.hviid.Verso.Drive.png). The other designs Preferences offers are
installed as their SVGs. Needs rsvg-convert (the Fedora toolbox has it) and Pillow (the toolbox has none: a virtual
environment's `pip install pillow`); run from the repository's root:

    python3 linux/packaging/icons/linux-app-icon.py
"""

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "dev.hviid.Verso.svg"
SIZES = (16, 32, 64, 128, 256, 512)


def drawing(side: int) -> Image.Image:
    """The drawing rendered at `side` pixels square."""
    with tempfile.TemporaryDirectory() as folder:
        png = Path(folder) / "icon.png"
        subprocess.run(["rsvg-convert", "-w", str(side), "-h", str(side), str(SOURCE), "-o", str(png)], check=True)
        return Image.open(png).convert("RGBA")


def badged(square: Image.Image) -> Image.Image:
    """The square with a drive's badge in its lower right corner: a dark disc ringed in white, and in it a drive in
    white, its body and its light. Drawn four times larger and then reduced, so its edges are smooth."""
    side = square.width * 4
    badge = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(badge)
    centre, radius = side * 0.745, side * 0.235
    ring = side * 0.022
    draw.ellipse((centre - radius - ring, centre - radius - ring, centre + radius + ring, centre + radius + ring), fill=(255, 255, 255, 255))
    draw.ellipse((centre - radius, centre - radius, centre + radius, centre + radius), fill=(46, 52, 64, 255))
    width, height, line = radius * 1.12, radius * 0.62, side * 0.016
    left, top = centre - width / 2, centre - height / 2
    draw.rounded_rectangle((left, top, left + width, top + height), radius=height * 0.28, outline=(255, 255, 255, 255), width=round(line))
    draw.line((left + line, top + height * 0.5, left + width - line, top + height * 0.5), fill=(255, 255, 255, 255), width=round(line * 0.8))
    light = height * 0.11
    light_x, light_y = left + width * 0.78, top + height * 0.74
    draw.ellipse((light_x - light, light_y - light, light_x + light, light_y + light), fill=(87, 227, 137, 255))
    drive = square.copy()
    drive.alpha_composite(badge.resize(square.size, Image.LANCZOS))
    return drive


def main() -> None:
    square = drawing(1024)
    drive = badged(square)
    for size in SIZES:
        folder = HERE / "hicolor" / str(size)
        folder.mkdir(parents=True, exist_ok=True)
        square.resize((size, size), Image.LANCZOS).save(folder / "dev.hviid.Verso.png", optimize=True)
        drive.resize((size, size), Image.LANCZOS).save(folder / "dev.hviid.Verso.Drive.png", optimize=True)
    square.resize((512, 512), Image.LANCZOS).save(HERE / "dev.hviid.Verso.png", optimize=True)
    print(f"from {SOURCE.name}; and the drive's, badged")


if __name__ == "__main__":
    main()
