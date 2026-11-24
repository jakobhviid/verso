#!/usr/bin/env python3
"""Verso's menu bar icons: the lens alone, as Finder's sidebar and Messages show Verso, the same in the Dev build (its
app icon tells the two apart). Each in one colour, as menu bar icons are drawn: a template image, which macOS draws in
the menu bar's own black or white, the lens as Finder's sidebar symbol draws it (make-symbol.py); and in colour,
which Settings offers, as Linux offers its top bar icon (`tray.colour`): the lens of the app icon's drawing on a dark
picture (linux/packaging/icons/dev.hviid.Verso-dark.svg, the `lens` group, its barrel the lens's own dark, as
make-icons.py's small icons have it), its five colours round its glass. One for each of the
Linux tray's states, as its icons show them (dev.hviid.Verso[-<state>]-symbolic.svg, dev.hviid.Verso-tray[-<state>].svg):

- MenuBarIcon: connected
- MenuBarIconUnmounted: Verso Drive switched on and not mounted, a pause badge
- MenuBarIconOffline: the server cannot be reached, faded (in colour, the colours gone) and struck through
- MenuBarIconSignedOut: the server refuses the sign-in, faded (in colour, the colours gone), with a key badge

and the same names with `Colour` after them in colour. What a state adds is cut clear of the lens. A colour image is
drawn as it is, so in colour the badges and the stroke are mid-grey with white on it, which shows on a light bar and
a dark one alike; in one colour, the badges' glyphs are cut out of them. Writes PNGs at the size menu bar icons have,
18 points with a 16-point lens, at 1x and 2x, into Verso/Assets.xcassets beside this script. Needs rsvg-convert;
make-icons.py runs it; on its own:

    mac/Verso/make-menu-bar-icon.py
"""

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = ROOT / "linux" / "packaging" / "icons" / "dev.hviid.Verso-dark.svg"
CATALOG = HERE / "Verso" / "Assets.xcassets"
SYMBOL_SCRIPT = HERE / "make-symbol.py"

BOX = 18.0
LENS = 8.0  # the lens's radius: a 16-point lens in the 18-point box
SCALES = (1, 2)
# The drawing's lens is 30 round, and its ring carries these five colours.
LENS_RADIUS = 30.0
RING_COLOURS = ("#FA2921", "#ED79B5", "#FFB400", "#1E83F7", "#18C249")
# The colours gone, as the Linux tray's: the ring one grey, the whole faded. In one colour, faded as the Linux symbolic
# icons are.
GREY_RING = "#9a9996"
FADED = 0.55
FADED_TEMPLATE = 0.4
# The sidebar symbol's stroke width the one-colour lens is drawn at: between its Regular and its Bold, as menu bar
# icons are a little heavier than a sidebar's.
TEMPLATE_WIDTH = 7.5
# What a state adds: a grey that shows on a light menu bar and a dark one, white on it, and the clear gap round it.
MARK = "#77767b"
MARK_INK = "#ffffff"
GAP = 1.0
# The badge, in the lens's lower right, within the box.
BADGE_X = BADGE_Y = 13.9
BADGE_RADIUS = 3.9

STATES = {
    "MenuBarIcon": "connected",
    "MenuBarIconUnmounted": "Verso Drive unmounted: paused",
    "MenuBarIconOffline": "the server cannot be reached: the colours gone, struck through",
    "MenuBarIconSignedOut": "signed out: the colours gone, with a key",
}


def fmt(value):
    return f"{value:.3f}".rstrip("0").rstrip(".")


def lens_drawing():
    """The drawing's glass gradient and its lens group's body, centred on 0, 0."""
    source = SOURCE.read_text()
    glass = re.search(r'<radialGradient id="glass".*?</radialGradient>', source, flags=re.S).group(0)
    lens = re.search(r'<g id="lens">(.*?)</g>', source, flags=re.S).group(1).strip()
    return glass, lens


def symbol_lens():
    """The sidebar symbol's lens, in one colour, filling the lens's circle on the 18-point box."""
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location("make_symbol", SYMBOL_SCRIPT)
    symbol = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(symbol)
    layers, advance = symbol.glyph(TEMPLATE_WIDTH)
    radius = advance / 2 - symbol.SIDE_BEARING
    centre_x, centre_y = symbol.SIDE_BEARING + radius, -symbol.CAP / 2
    return (f'<g transform="translate({fmt(BOX / 2)} {fmt(BOX / 2)}) scale({fmt(LENS / radius)}) '
            f'translate({fmt(-centre_x)} {fmt(-centre_y)})"><path fill="#000000" d="{" ".join(layers)}"/></g>')


def badge(glyph, colour):
    """A badge in the lens's lower right (its glyph in the badge's own coordinates, its centre at 0, 0): in colour the
    grey disc with its glyph in white; in one colour the disc with its glyph cut out."""
    place = f'translate({fmt(BADGE_X)} {fmt(BADGE_Y)})'
    if colour:
        return f'<g transform="{place}"><circle r="{fmt(BADGE_RADIUS)}" fill="{MARK}"/>{glyph}</g>'
    return f'<g transform="{place}" mask="url(#glyph)"><circle r="{fmt(BADGE_RADIUS)}" fill="#000000"/></g>'


def glyph_mask(glyph):
    """The mask that cuts a badge's glyph out of its disc, in the badge's coordinates."""
    cut = glyph.replace(f'fill="{MARK_INK}"', 'fill="#000000"')
    return (f'<mask id="glyph" maskUnits="userSpaceOnUse" x="{fmt(-BADGE_RADIUS)}" y="{fmt(-BADGE_RADIUS)}" '
            f'width="{fmt(2 * BADGE_RADIUS)}" height="{fmt(2 * BADGE_RADIUS)}">'
            f'<circle r="{fmt(BADGE_RADIUS)}" fill="#ffffff"/>{cut}</mask>')


PAUSE = (f'<rect x="-1.75" y="-1.75" width="1.25" height="3.5" rx="0.3" fill="{MARK_INK}"/>'
         f'<rect x="0.5" y="-1.75" width="1.25" height="3.5" rx="0.3" fill="{MARK_INK}"/>')
# A key, its bow at the upper left and its bit at the lower right, as a key lies in a hand.
KEY = (f'<g transform="rotate(45)" fill="{MARK_INK}">'
       f'<path fill-rule="evenodd" d="M-0.55 0 A1.25 1.25 0 1 1 -3.05 0 A1.25 1.25 0 1 1 -0.55 0 Z '
       f'M-1.35 0 A0.45 0.45 0 1 0 -2.25 0 A0.45 0.45 0 1 0 -1.35 0 Z"/>'
       f'<rect x="-0.7" y="-0.42" width="3.4" height="0.84"/>'
       f'<rect x="1.55" y="0.3" width="0.6" height="1.0"/><rect x="2.1" y="0.3" width="0.6" height="0.75"/></g>')
STRIKE_FROM, STRIKE_TO = (3.2, 3.2), (14.8, 14.8)
STRIKE_WIDTH = 1.5


def icon(state, colour):
    """One state's SVG on the 18-point box, in colour or in one colour."""
    faded = state in ("MenuBarIconOffline", "MenuBarIconSignedOut")
    defs = ""
    if colour:
        glass, lens = lens_drawing()
        defs += glass
        if faded:
            for ring_colour in RING_COLOURS:
                lens = lens.replace(f'stroke="{ring_colour}"', f'stroke="{GREY_RING}"')
            defs += ('<filter id="grey" x="0" y="0" width="1" height="1">'
                     '<feColorMatrix type="saturate" values="0"/></filter>')
        centre = BOX / 2
        lens_group = (f'<g transform="translate({fmt(centre)} {fmt(centre)}) scale({fmt(LENS / LENS_RADIUS)})"'
                      + (' filter="url(#grey)"' if faded else "") + f">{lens}</g>")
    else:
        lens_group = symbol_lens()
    mark_colour = MARK if colour else "#000000"
    # What the state adds, and the clear gap cut from the lens round it.
    if state == "MenuBarIconOffline":
        line = (f'x1="{fmt(STRIKE_FROM[0])}" y1="{fmt(STRIKE_FROM[1])}" x2="{fmt(STRIKE_TO[0])}" '
                f'y2="{fmt(STRIKE_TO[1])}" stroke-linecap="round"')
        cut = f'<line {line} stroke="#000000" stroke-width="{fmt(STRIKE_WIDTH + 2 * GAP)}"/>'
        mark = f'<line {line} stroke="{mark_colour}" stroke-width="{fmt(STRIKE_WIDTH)}"/>'
    elif state in ("MenuBarIconUnmounted", "MenuBarIconSignedOut"):
        cut = (f'<circle cx="{fmt(BADGE_X)}" cy="{fmt(BADGE_Y)}" r="{fmt(BADGE_RADIUS + GAP)}" '
               f'fill="#000000"/>')
        glyph = PAUSE if state == "MenuBarIconUnmounted" else KEY
        mark = badge(glyph, colour)
        if not colour:
            defs += glyph_mask(glyph)
    else:
        cut = mark = ""
    if cut:
        defs += (f'<mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="{fmt(BOX)}" height="{fmt(BOX)}">'
                 f'<rect width="{fmt(BOX)}" height="{fmt(BOX)}" fill="#ffffff"/>{cut}</mask>')
    body = f'<g opacity="{FADED if colour else FADED_TEMPLATE}">{lens_group}</g>' if faded else lens_group
    if cut:
        body = f'<g mask="url(#cut)">{body}</g>'
    source = "the lens in linux/packaging/icons/dev.hviid.Verso-dark.svg" if colour else "make-symbol.py's lens"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{fmt(BOX)}" height="{fmt(BOX)}" '
            f'viewBox="0 0 {fmt(BOX)} {fmt(BOX)}">\n'
            f"  <!-- Verso's menu bar icon, {STATES[state]}, {'in colour' if colour else 'in one colour'}. Written by "
            f"mac/Verso/make-menu-bar-icon.py from {source}. -->\n"
            f"  <defs>{defs}</defs>\n  {body}{mark}\n</svg>\n")


def icons():
    """Each image set's SVG and whether it is in colour, by name: in one colour, then in colour."""
    return {**{state: (icon(state, False), False) for state in STATES},
            **{f"{state}Colour": (icon(state, True), True) for state in STATES}}


def main():
    sets = icons()
    for name, (svg, colour) in sets.items():
        folder = CATALOG / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        for stale in folder.iterdir():
            stale.unlink()
        images = []
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "icon.svg"
            source.write_text(svg)
            for scale in SCALES:
                file_name = f"{name}@{scale}x.png"
                pixels = str(round(BOX * scale))
                subprocess.run(["rsvg-convert", "-w", pixels, "-h", pixels, str(source), "-o",
                                str(folder / file_name)], check=True)
                images.append({"filename": file_name, "idiom": "universal", "scale": f"{scale}x"})
        contents = {
            "images": images,
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "original" if colour else "template"},
        }
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print("wrote " + ", ".join(f"{name}.imageset" for name in sets))


if __name__ == "__main__":
    main()
