#!/usr/bin/env python3
"""Make Verso's Linux app icons from its drawing, dev.hviid.Verso.svg (Mist, the app's design): the print edge to
edge, as Linux shows icons. Writes dev.hviid.Verso.png (512) and hicolor/<size>/dev.hviid.Verso.png beside this
script; and Verso Drive's icon, the same with a drive's badge in its corner, so the drive in a dock or a file manager
is not taken for the app (hicolor/<size>/dev.hviid.Verso.Drive.png). The other looks Preferences offers are
installed as their SVGs. Needs rsvg-convert (the Fedora toolbox has it) and Pillow (the toolbox has none: a virtual
environment's `pip install pillow`); run from the repository's root:

    python3 linux/packaging/icons/linux-app-icon.py

With --sheet <file.png> it writes nothing else but a sheet of the 28 looks (sources/app-icon.py), a design to a column
and a look to a row, each large and at 48 and 16 pixels (16 also enlarged, pixel for pixel), on a light and on a dark
background, for looking at them side by side.
"""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "dev.hviid.Verso.svg"
SIZES = (16, 32, 64, 128, 256, 512)


def drawing(side: int, source: Path = SOURCE) -> Image.Image:
    """The drawing rendered at `side` pixels square."""
    with tempfile.TemporaryDirectory() as folder:
        png = Path(folder) / "icon.png"
        subprocess.run(["rsvg-convert", "-w", str(side), "-h", str(side), str(source), "-o", str(png)], check=True)
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


# The sheet's backgrounds: GNOME's light and dark window backgrounds, and the text on each.
SHEET_BACKGROUNDS = (((0xFA, 0xFA, 0xFB), (0x33, 0x33, 0x33)), ((0x22, 0x22, 0x26), (0xDD, 0xDD, 0xDD)))
LARGE, ENLARGED = 192, 4


def sheet(target: Path) -> None:
    """Every look, large and at 48 and 16 pixels, on a light and on a dark background: a design to a column, a look
    (Day and Night, in colour and in graphite) to a row."""
    specification = importlib.util.spec_from_file_location("app_icon", HERE / "sources" / "app-icon.py")
    looks = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(looks)
    designs = list(looks.DESIGNS)
    rows = [(night, graphite) for graphite in (False, True) for night in (False, True)]
    panel_width = 10 + LARGE + 12 + 48 + 12 + 16 + 12 + 16 * ENLARGED + 10
    panel_height = LARGE + 20
    label_height = 34
    cell_width, cell_height = panel_width + 10, label_height + 2 * panel_height + 10
    page = Image.new("RGBA", (cell_width * len(designs) + 10, cell_height * len(rows) + 10), (0xC8, 0xC8, 0xC8, 255))
    draw = ImageDraw.Draw(page)
    font = ImageFont.load_default(size=20)
    for column, design in enumerate(designs):
        for row, (night, graphite) in enumerate(rows):
            name = looks.look_name(design, night, graphite)
            source = HERE / ("dev.hviid.Verso.svg" if name == looks.DEFAULT else f"dev.hviid.Verso-{name}.svg")
            left, top = 10 + column * cell_width, 10 + row * cell_height
            draw.text((left + 4, top + 6), name, fill=(0x20, 0x20, 0x20), font=font)
            large, middle, small = drawing(LARGE, source), drawing(48, source), drawing(16, source)
            enlarged = small.resize((16 * ENLARGED, 16 * ENLARGED), Image.NEAREST)
            for index, (background, _) in enumerate(SHEET_BACKGROUNDS):
                panel_top = top + label_height + index * panel_height
                draw.rectangle((left, panel_top, left + panel_width - 1, panel_top + panel_height - 1), fill=background)
                x = left + 10
                for picture in (large, middle, small, enlarged):
                    page.alpha_composite(picture, (x, panel_top + (panel_height - picture.height) // 2))
                    x += picture.width + 12
    target.parent.mkdir(parents=True, exist_ok=True)
    page.convert("RGB").save(target)
    print(f"wrote {target}")


def main() -> None:
    if sys.argv[1:2] == ["--sheet"] and len(sys.argv) == 3:
        sheet(Path(sys.argv[2]).resolve())
        return
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
