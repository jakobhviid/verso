#!/usr/bin/env python3
"""Verso on the Apple TV's icons (DESIGN.md, the icon family): tvOS's layered app icon, whose layers the remote's
focus tilts apart as Apple's own icons do, and the Top Shelf images, the same picture flat and wider. Drawn from the
lens, the print and its back in linux/packaging/icons/dev.hviid.Verso.svg, the master every platform's icon comes
from. Writes the brand assets into ios/TV/Assets.xcassets. Needs rsvg-convert (librsvg2-tools; in the toolbox).

The designs, by name (the first is the app's):
  E2  Front and back: a print's back, Verso written on it by hand, behind the print's front with its lens, on Mist
  E3  E2 on a night sky
  B2  The print edge to edge, Verso on its strip, its corner turned over to Mist
  B3  B2 in the print's night colours

    ios/TV/make-tv-icons.py [--design NAME]
"""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MASTER = (ROOT / "linux/packaging/icons/dev.hviid.Verso.svg").read_text()
CATALOG = ROOT / "ios/TV/Assets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"
HEIGHT = 240  # every design is drawn 240 high, centred on x = 200 of an icon 400 wide

DEFS = MASTER[MASTER.index("<defs>") + len("<defs>"):MASTER.index("</defs>")]
PRINT = MASTER[MASTER.index("</defs>") + len("</defs>"):MASTER.rindex("</svg>")]
LENS = re.search(r'<use xlink:href="#lens"[^>]*/>', PRINT).group(0)
WORD = re.search(r'<g transform="translate\(22 94.3\) scale\(0.64\)".*?</g>', PRINT, re.S).group(0)
WORD_PATHS = WORD[WORD.index(">") + 1:WORD.rindex("</g>")]
# The master's print sits in a group that fills its 128 square; the lens is placed inside it.
PRINT_FRAME = '<g transform="translate(-9.142857 -9.142857) scale(1.142857)">'
MORE_DEFS = """
  <linearGradient id="mist" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#e6edf5"/><stop offset="1" stop-color="#c4d0de"/></linearGradient>
  <radialGradient id="night" cx="0.5" cy="0.45" r="0.75">
    <stop offset="0" stop-color="#27477a"/><stop offset="0.55" stop-color="#151f38"/><stop offset="1" stop-color="#0b0a12"/>
  </radialGradient>
  <filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="5"/><feOffset dy="5"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.28"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
"""
DAY = {"paper": ("#ffffff", "#e6e4e0"), "photo": ("#e6edf5", "#c4d0de"), "ink": "#6f7486", "under": "#c9d2de",
       "back": "url(#back)"}
NIGHT = {"paper": ("#4a4a4f", "#2f2f33"), "photo": ("#414d5c", "#262d37"), "ink": "#a9adbb", "under": "#1c1f26",
         "back": "#5d5749"}


def lens(cx, cy, diameter):
    return f'<use xlink:href="#lens" transform="translate({cx} {cy}) scale({diameter / 60:.4f})"/>'


def placed(cx, cy, height, rotate, inner, shadow=True):
    """Something drawn in the master's 128 square, `height` tall, centred at (cx, cy) and turned by `rotate`."""
    group = (f'<g transform="translate({cx} {cy}) rotate({rotate}) scale({height / 128:.4f}) translate(-64 -64)">'
             f'{inner}</g>')
    return f'<g filter="url(#drop)">{group}</g>' if shadow else group


def print_back(cx, cy, height, rotate):
    """A print seen from behind: its cream back, Verso written on it by hand as on an old photo's back."""
    return placed(cx, cy, height, rotate,
                  '<path d="M14,0 H114 Q128,0 128,14 V114 Q128,128 114,128 H14 Q0,128 0,114 V14 Q0,0 14,0 Z" '
                  'fill="url(#back)"/><g transform="translate(8 34) scale(0.95)" fill="none" stroke="#8a7f68" '
                  f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{WORD_PATHS}</g>')


def front_and_back(sky):
    """E: the back of one print behind the front of another, Verso written once, on the back."""
    paper = PRINT.replace(LENS, "").replace(WORD, "")
    return {
        "Back": f'<rect x="-1000" width="2400" height="{HEIGHT}" fill="url(#{sky})"/>',
        "Middle": print_back(128, 124, 160, -10),
        "Print": placed(262, 116, 170, 5, paper),
        "Front": placed(262, 116, 170, 5, f"{PRINT_FRAME}{LENS}</g>", shadow=False),
    }


def edge_to_edge(theme, corner=68):
    """B: the print filling the icon, in the back layer (the one tvOS keeps full bleed under a tilt), its corner cut
    away to what it lies on and turned over in a layer of its own."""
    (paper_top, paper_bottom), (photo_top, photo_bottom) = theme["paper"], theme["photo"]
    x, y = 400 - corner, HEIGHT - corner
    rounding = corner * 0.18
    return {
        "Back": (f'<linearGradient id="tpaper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{paper_top}"/>'
                 f'<stop offset="1" stop-color="{paper_bottom}"/></linearGradient>'
                 f'<linearGradient id="tphoto" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{photo_top}"/>'
                 f'<stop offset="1" stop-color="{photo_bottom}"/></linearGradient>'
                 f'<rect x="-1000" width="2400" height="{HEIGHT}" fill="{theme["under"]}"/>'
                 f'<path d="M-1000,0 H1400 V{HEIGHT} H{x + corner} V{y} L{x},{HEIGHT} H-1000 Z" fill="url(#tpaper)"/>'
                 '<rect x="24" y="22" width="352" height="150" rx="16" fill="url(#tphoto)"/>'
                 '<rect x="24.5" y="22.5" width="351" height="149" rx="15.5" fill="none" stroke="#000" '
                 'stroke-opacity="0.08"/>'
                 f'<g transform="translate(40 175) scale(1.25)" fill="none" stroke="{theme["ink"]}" '
                 f'stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round">{WORD_PATHS}</g>'),
        "Middle": (f'<path d="M400,{y} L{x},{HEIGHT} L{x},{y + rounding} Q{x},{y} {x + rounding},{y} Z" '
                   f'fill="{theme["back"]}" filter="url(#flapshadow)"/>'),
        "Front": lens(200, 97, 124),
    }


DESIGNS = {
    "E2": front_and_back("mist"),
    "E3": front_and_back("night"),
    "B2": edge_to_edge(DAY),
    "B3": edge_to_edge(NIGHT),
}
INFO = {"author": "xcode", "version": 1}


def svg(width, layers):
    """Layers drawn on a canvas `width` wide and HEIGHT high, the design centred in it."""
    shift = (width - 400) / 2
    body = "".join(layers)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{width:g}" '
            f'height="{HEIGHT}" viewBox="0 0 {width:g} {HEIGHT}"><defs>{DEFS}{MORE_DEFS}</defs>'
            f'<g transform="translate({shift:g} 0)">{body}</g></svg>')


def render(text, pixels_wide, pixels_high, work, name):
    source = work / f"{name}.svg"
    source.write_text(text)
    out = work / f"{name}.png"
    command = ["rsvg-convert", "-w", str(pixels_wide), "-h", str(pixels_high), str(source), "-o", str(out)]
    if shutil.which("rsvg-convert") is None:
        command = ["toolbox", "run", "-c", "verso", *command]
    subprocess.run(command, check=True)
    return out


def write(folder, contents):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def imagestack(name, sizes, idiom, design, work):
    """A layered icon, front first, at each (scale, width, height)."""
    stack = BRAND / f"{name}.imagestack"
    layers = list(reversed(design))
    write(stack, {"info": INFO, "layers": [{"filename": f"{layer}.imagestacklayer"} for layer in layers]})
    for layer in layers:
        folder = stack / f"{layer}.imagestacklayer" / "Content.imageset"
        write(folder.parent, {"info": INFO})
        images = []
        for scale, width, height in sizes:
            file = f"{layer.lower()}-{scale}.png"
            folder.mkdir(parents=True, exist_ok=True)
            shutil.copy(render(svg(400, [design[layer]]), width, height, work, f"{name}-{layer}-{scale}"),
                        folder / file)
            images.append({"idiom": idiom, "scale": scale, "filename": file})
        write(folder, {"images": images, "info": INFO})


def top_shelf(name, sizes, design, work):
    """The design flat, centred on its background, as wide as the Top Shelf."""
    folder = BRAND / f"{name}.imageset"
    images = []
    for scale, width, height in sizes:
        file = f"top-shelf-{scale}.png"
        folder.mkdir(parents=True, exist_ok=True)
        picture = svg(HEIGHT * width / height, list(design.values()))
        shutil.copy(render(picture, width, height, work, f"{name}-{scale}"), folder / file)
        images.append({"idiom": "tv", "scale": scale, "filename": file})
    write(folder, {"images": images, "info": INFO})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--design", choices=DESIGNS, default=next(iter(DESIGNS)))
    design = DESIGNS[parser.parse_args().design]
    if BRAND.exists():
        shutil.rmtree(BRAND)
    write(CATALOG, {"info": INFO})
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        imagestack("App Icon", [("1x", 400, 240), ("2x", 800, 480)], "tv", design, work)
        imagestack("App Icon - App Store", [("1x", 1280, 768)], "tv-marketing", design, work)
        top_shelf("Top Shelf Image", [("1x", 1920, 720), ("2x", 3840, 1440)], design, work)
        top_shelf("Top Shelf Image Wide", [("1x", 2320, 720), ("2x", 4640, 1440)], design, work)
    write(BRAND, {"info": INFO, "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ]})
    print(f"wrote {BRAND.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
