#!/usr/bin/env python3
"""Verso on the Apple TV's icons (DESIGN.md, the icon family): tvOS's layered app icon in three layers, which the
remote's focus tilts apart as Apple's own icons do: Mist at the back, Verso's print in the middle (its paper, its
picture, the word and the turned corner; linux/packaging/icons/dev.hviid.Verso.svg, the master every platform's icon is
drawn from) and the print's lens alone at the front, in its place on the print; and the Top Shelf images, the print on
Mist. Writes the brand assets into
ios/TV/Assets.xcassets. Needs rsvg-convert (librsvg2-tools; in the toolbox) and Pillow.

    ios/TV/make-tv-icons.py
"""
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SVG = ROOT / "linux/packaging/icons/dev.hviid.Verso.svg"
CATALOG = ROOT / "ios/TV/Assets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"
MIST = ((0xE6, 0xED, 0xF5), (0xC4, 0xD0, 0xDE))  # top to bottom
SHARE = 0.70  # the print's height in the icon's: the TV shows icons small in its rows


LENS_USE = re.compile(r'<use xlink:href="#lens"[^>]*/>')


def part(which):
    """The master's SVG as a whole ("print"), without its lens ("paper"), or with the lens alone ("lens"), each in the
    print's own place, so the layers line up."""
    source = SVG.read_text()
    lens = LENS_USE.search(source).group(0)
    if which == "paper":
        return source.replace(lens, "")
    if which == "lens":
        start = source.index("</defs>") + len("</defs>")
        outer = re.search(r'<g transform="[^"]*">', source[start:]).group(0)
        return source[:start] + f"\n{outer}{lens}</g>\n</svg>\n"
    return source


def render(size, work, which="print"):
    """The print, or a part of it, at `size` pixels square, transparent around it."""
    svg = work / f"{which}.svg"
    svg.write_text(part(which))
    out = work / f"{which}-{size}.png"
    command = ["rsvg-convert", "-w", str(size), "-h", str(size), str(svg), "-o", str(out)]
    if shutil.which("rsvg-convert") is None:
        command = ["toolbox", "run", "-c", "verso", *command]
    subprocess.run(command, check=True)
    return Image.open(out).convert("RGBA")


def mist(width, height):
    top, bottom = MIST
    image = Image.new("RGB", (width, height))
    for y in range(height):
        t = y / max(1, height - 1)
        row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        image.paste(row, (0, y, width, y + 1))
    return image


def front(width, height, share, work, which="print"):
    """The print, or a part of it, centred on a transparent layer, `share` of the layer's height."""
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    size = round(height * share)
    picture = render(size, work, which)
    layer.alpha_composite(picture, ((width - size) // 2, (height - size) // 2))
    return layer


def write(folder, contents):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


INFO = {"author": "xcode", "version": 1}


def imagestack(name, sizes, idiom, work):
    """A layered icon: the lens over the print's paper over Mist, at each (scale, width, height)."""
    stack = BRAND / f"{name}.imagestack"
    layers = ("Front", "Middle", "Back")
    write(stack, {"info": INFO, "layers": [{"filename": f"{layer}.imagestacklayer"} for layer in layers]})
    for layer in layers:
        layer_folder = stack / f"{layer}.imagestacklayer"
        write(layer_folder, {"info": INFO})
        images = []
        for scale, width, height in sizes:
            file = f"{layer.lower()}-{scale}.png"
            if layer == "Back":
                picture = mist(width, height)
            else:
                picture = front(width, height, SHARE, work, "lens" if layer == "Front" else "paper")
            (layer_folder / "Content.imageset").mkdir(parents=True, exist_ok=True)
            picture.save(layer_folder / "Content.imageset" / file)
            images.append({"idiom": idiom, "scale": scale, "filename": file})
        write(layer_folder / "Content.imageset", {"images": images, "info": INFO})


def top_shelf(name, sizes, work):
    folder = BRAND / f"{name}.imageset"
    images = []
    for scale, width, height in sizes:
        file = f"top-shelf-{scale}.png"
        picture = mist(width, height).convert("RGBA")
        picture.alpha_composite(front(width, height, 0.62, work))
        folder.mkdir(parents=True, exist_ok=True)
        picture.convert("RGB").save(folder / file)
        images.append({"idiom": "tv", "scale": scale, "filename": file})
    write(folder, {"images": images, "info": INFO})


def main():
    if BRAND.exists():
        shutil.rmtree(BRAND)
    write(CATALOG, {"info": INFO})
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        imagestack("App Icon", [("1x", 400, 240), ("2x", 800, 480)], "tv", work)
        imagestack("App Icon - App Store", [("1x", 1280, 768)], "tv-marketing", work)
        top_shelf("Top Shelf Image", [("1x", 1920, 720), ("2x", 3840, 1440)], work)
        top_shelf("Top Shelf Image Wide", [("1x", 2320, 720), ("2x", 4640, 1440)], work)
    write(BRAND, {"info": INFO, "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ]})
    print(f"wrote {BRAND.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
