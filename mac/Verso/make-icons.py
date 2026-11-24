#!/usr/bin/env python3
"""Verso's macOS app icon, from Verso's own drawing (linux/packaging/icons/dev.hviid.Verso.svg, Mist, the app's design):
the print, the lens with its five-colour ring in its picture, Verso written by hand on its strip and its corner turned
over, filling Apple's rounded square. Writes, beside this script:

- Verso/Assets.xcassets/AppIcon.appiconset: every size its Contents.json lists, for macOS 14 and 15, on Apple's 1024
  grid (the square 824 wide at 100, 100, with the drop shadow macOS icons carry), rendered with rsvg-convert
- Verso/AppIcon.icon: the Icon Composer document macOS 26 and later show, the same drawing in layers the system
  lights, with a light and a dark appearance; tinted and clear are the system's, made from these
- Verso/Assets.xcassets/SidebarSymbol.symbolset: Finder's sidebar symbol for Verso Drive, the lens (make-symbol.py)
- Verso/Assets.xcassets/MenuBarIcon*.imageset: the menu bar icon in each of its states, the lens in colour
  (make-menu-bar-icon.py)
- ios/Verso/Assets.xcassets/AppIconImage.imageset: the icon's rounded square alone, without the Mac's shadow and edge,
  light and dark, at 2x and 3x of 120 points: the picture the iOS app shows of its own icon (its sign-in's welcome,
  About and the App Icon choice), since reading an app icon back with UIImage(named:) is no API and can fail
- ios/Messages/Assets.xcassets/MessagesIcon.stickersiconset: Verso's icon in Messages' row of apps, which asks for
  its own sizes, most of them 4:3 (Verso in Messages, ios/Messages), and shows its apps' icons in a circle: the lens
  alone, its five colours round its glass, filling that circle on its barrel's own dark, so the crop shows the lens and
  nothing else; square where Settings and the App Store ask for a square. Opaque, as the App Store wants it, and
  square-cornered: the system rounds it
- ios/Widgets/Assets.xcassets/Lens.imageset: backing up's Live Activity's lens (ios/Widgets), the lens alone, its five
  colours round its glass, without its barrel's dark rim, which the Dynamic Island's black would swallow, so the
  colours reach the image's edge; at 1x, 2x and 3x of the largest size the activity draws it (LENS_POINTS): a Live
  Activity's image may be no larger than where it shows. The same into ios/Verso/Assets.xcassets/Lens.imageset, for
  Verso's own small marks in the iPhone app (the heading of Verso's notifications in the account's sheet)
- with --dev, the development build's app icon instead: the release's in every colour but the turned corner's back,
  which is blue with DEV on it in white, into AppIconDev.appiconset, AppIconDev.icon and AppIconDevImage.imageset.
  The small icons, the lens alone (the sidebar symbol, the menu bar's, Messages'), are the same in the Dev build: its
  app icon and its name tell the two apart
- with --design <name>, the app icon with another of the picture's designs (DESIGNS, drawn by
  linux/packaging/icons/sources/app-icon.py as dev.hviid.Verso-<name>.svg), release or Dev, an alternate icon of the
  apps (ARCHITECTURE.md, "The app icon's designs on the Mac, the iPhone and the iPad"), under the same names with
  -<Name> after them: the Mac's AppIcon-Sand.appiconset, which Settings puts in the Dock; the iOS app's
  ios/Verso/Assets.xcassets/AppIcon-Sand.appiconset, one opaque 1024 picture edge to edge, light and dark, which iOS
  rounds and makes its tinted and clear icons from (an Icon Composer document as an alternate icon compiles to three
  flattened 1024 pictures for each of the iPhone and the iPad, twelve times the size); and AppIcon-SandImage.imageset,
  the picture the iOS app's choice shows; or AppIconDev-Sand.appiconset and so on with --dev. The small icons are not
  written: they are the same for every design
- with --preview <file.png>, a sheet of both icons (of the design given, else Mist) at 1024, 128, 32 and 16 pixels,
  light and dark, the sidebar symbol, and the menu bar icons on a light and a dark menu bar, for looking at them; it
  writes nothing else

What changes from the Linux drawing, so the print sits in the Mac's shape:
- The print takes Apple's rounded square and its corners; the picture's corners grow to stay concentric with them.
- The turned corner keeps its place and size. The square's own corner beyond the fold shows what the print lies on,
  in grey (the transparent corner of the Linux icon, which macOS 26 would fill), and the flap is that corner folded
  over, its tip rounded by half the square's corner.
- At 16 and 32 pixels the word is written with a broader pen, so the strip still shows a line of writing.

The small icons take the lens from a dark picture's drawing (dev.hviid.Verso-dark.svg, LENS_SOURCE), its barrel as
dark as the lens has it on its own: a light picture lightens the barrel only against itself.

The PNGs are committed, since the Mac has no SVG renderer to make them. Needs python3 and rsvg-convert (the Fedora
toolbox has both); run it again when the drawing changes:

    mac/Verso/make-icons.py
    mac/Verso/make-icons.py --dev
    mac/Verso/make-icons.py --design sand [--dev]
    mac/Verso/make-icons.py --preview mac/Verso/build/icon-preview.png [--design sand]
    mac/Verso/make-icons.py --lens          the Live Activity's lens alone, as the release run also writes it
"""

import base64
import importlib.util
import json
import math
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DRAWINGS = ROOT / "linux" / "packaging" / "icons"
# The picture's designs, as linux/packaging/icons/sources/app-icon.py draws them: Mist, the app's, first.
DESIGNS = ("mist", "sand", "dark", "paper", "frame", "slate", "sky")
DEFAULT_DESIGN = "mist"
# The lens of the small icons: a dark picture's, whose barrel is the lens's own dark.
LENS_SOURCE = DRAWINGS / "dev.hviid.Verso-dark.svg"
CATALOG = HERE / "Verso" / "Assets.xcassets"
IOS_CATALOG = ROOT / "ios" / "Verso" / "Assets.xcassets"
MESSAGES_CATALOG = ROOT / "ios" / "Messages" / "Assets.xcassets"
WIDGETS_CATALOG = ROOT / "ios" / "Widgets" / "Assets.xcassets"
# The largest the Live Activity draws its lens, in points: inside its ring on the Lock Screen.
LENS_POINTS = 42
SYMBOL_SCRIPT = HERE / "make-symbol.py"
MENU_BAR_SCRIPT = HERE / "make-menu-bar-icon.py"

# Apple's grid for a macOS icon: a 1024 canvas, the rounded square 824 wide at 100, 100, its corners 185 round.
CANVAS = 1024
TILE_LEFT, TILE_SIDE, TILE_RADIUS = 100, 824, 185
# Every size the asset catalog lists, in points, at 1x and 2x.
POINT_SIZES = (16, 32, 128, 256, 512)
# Up to this many pixels the small drawing is used: the word written with a broader pen.
SMALL_PIXELS = 32
# Every image of Messages' icon set, as Xcode's iMessage App Icon lists them: its idiom, its size in points (width by
# height) and its scales, and its platform where the catalog names one.
MESSAGES_IMAGES = (
    ("iphone", (29, 29), (2, 3), None),  # Settings
    ("iphone", (60, 45), (2, 3), None),  # Messages
    ("ipad", (29, 29), (2,), None),
    ("ipad", (67, 50), (2,), None),
    ("ipad", (74, 55), (2,), None),
    ("ios-marketing", (1024, 1024), (1,), None),  # the App Store
    ("universal", (27, 20), (2, 3), "ios"),  # Messages' smaller places
    ("universal", (32, 24), (2, 3), "ios"),
    ("ios-marketing", (1024, 768), (1,), "ios"),  # the App Store for iMessage
)
# The lens's barrel's radius in its own drawing (the `lens` group), whose colour (`Drawing.barrel`) Messages' icon fills
# around it; and the outer edge of its five colours (the ring at 23.7, 7.8 wide), where the Live Activity's lens ends.
LENS_RADIUS = 30
LENS_COLOURS_RADIUS = 27.6

PALETTE = {
    # The print's paper, its back, and what it lies on under the turned corner, as gradients (top, bottom).
    "release": {
        "light": {"paper": ("#ffffff", "#e6e4e0"), "back": ("#f6efdf", "#d8ccb0"), "under": ("#9a9996", "#c0bfbc"),
                  "ink": "#6f7486"},
        "dark": {"paper": ("#525155", "#333236"), "back": ("#b5ab94", "#857a62"), "under": ("#1d1c20", "#2c2b2f"),
                 "ink": "#c4c8d4"},
    },
}
# The development build is the release in every colour but one (the maintainer's choice): the turned
# corner's back is blue, with DEV on it in white. What shows beneath the corner and its shadow stay the release's.
PALETTE["dev"] = {
    "light": {**PALETTE["release"]["light"], "back": ("#8ec5ff", "#3f8cf0")},
    "dark": {**PALETTE["release"]["dark"], "back": ("#1f4f99", "#14356b")},
}
DEV_LETTERS = "#ffffff"
# The turned corner's tip, rounded by half the square's corner: rounder than the Linux drawing's, in the Mac's way, but
# not the whole corner mirrored, which made the flap and what shows beneath it one lemon shape.
FLAP_TIP = 0.5
# How far what shows beneath the corner reaches in under the flap, so no seam of paper shows along the fold.
UNDER_OVERLAP = 0.25


class Drawing:
    """The parts of the Linux drawing this icon is made from, read from its SVG, in its own coordinates: the print
    runs from 8 to 120 on a 128 grid."""

    def __init__(self, source):
        defs = re.search(r"<defs>(.*?)</defs>", source, flags=re.S).group(1)
        self.gradients = {name: re.search(rf'<(linear|radial)Gradient id="{name}".*?</\1Gradient>', defs,
                                          flags=re.S).group(0)
                          for name in ("glass", "photo")}
        lens = re.search(r'<g id="lens">(.*?)</g>', defs, flags=re.S).group(1).strip()
        glass_start = lens.index('<circle r="18"')
        self.lens_ring, self.lens_glass = lens[:glass_start], lens[glass_start:]
        self.barrel = re.search(rf'<circle r="{LENS_RADIUS}" fill="(#[0-9a-fA-F]+)"/>', lens).group(1)
        print_path = re.search(r'<path d="(M[^"]*)" fill="url\(#paper\)"', source).group(1)
        numbers = [float(number) for number in re.findall(r"-?\d+(?:\.\d+)?", print_path)]
        self.print_left, self.print_right = min(numbers), max(numbers)
        # The fold runs from the right edge (V<fold>) to the bottom edge.
        self.fold = self.print_right - float(re.search(r"V(\d+(?:\.\d+)?) L", print_path).group(1))
        photo = re.search(r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)" rx="([\d.]+)" '
                          r'fill="url\(#photo\)"', source).groups()
        self.photo_x, self.photo_y, self.photo_width, self.photo_height, self.photo_radius = map(float, photo)
        # The line inside a light picture's edge, which holds it apart from the paper: its colour, opacity and width.
        edge = re.search(r'fill="url\(#photo\)"/><rect [^>]*fill="none" stroke="(#[0-9a-fA-F]+)" '
                         r'stroke-opacity="([\d.]+)" stroke-width="([\d.]+)"/>', source)
        self.photo_edge = (edge.group(1), edge.group(2), float(edge.group(3))) if edge else None
        lens_place =re.search(r'<use xlink:href="#lens" transform="translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\)',
                               source).groups()
        self.lens_x, self.lens_y, self.lens_scale = map(float, lens_place)
        word = re.search(r'<g transform="translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\)" fill="none" '
                         r'stroke="#[0-9a-fA-F]+" stroke-width="([\d.]+)"[^>]*>(.*?)</g>', source, flags=re.S)
        self.word_x, self.word_y, self.word_scale, self.word_stroke = map(float, word.groups()[:4])
        self.word_paths = re.findall(r'<path d="([^"]+)"/>', word.group(5))

    @property
    def side(self):
        return self.print_right - self.print_left


def fmt(value):
    return f"{value:.3f}".rstrip("0").rstrip(".")


def gradient(name, colours, x2=0, y2=1):
    return (f'<linearGradient id="{name}" x1="0" y1="0" x2="{x2}" y2="{y2}"><stop offset="0" stop-color="{colours[0]}"/>'
            f'<stop offset="1" stop-color="{colours[1]}"/></linearGradient>')


class Parts:
    """The icon's parts as SVG, in the drawing's coordinates, for one build (release or dev), appearance (light or
    dark) and size (small or not)."""

    def __init__(self, drawing, build, appearance, small=False):
        self.drawing = drawing
        self.build = build
        self.colours = PALETTE[build][appearance]
        self.small = small
        # Apple's corner in the drawing's units: the print is the rounded square.
        self.radius = TILE_RADIUS / TILE_SIDE * drawing.side

    def under_path(self):
        """The square's corner beyond the fold, where what the print lies on shows: the triangle, which the square's
        own shape (the clip here, the system's for the Icon Composer layers) rounds."""
        right = bottom = self.drawing.print_right
        reach = self.drawing.fold + UNDER_OVERLAP
        return f"M{fmt(right)} {fmt(bottom - reach)} V{fmt(bottom)} H{fmt(right - reach)} Z"

    def flap_path(self, offset=0.0):
        """The corner folded over the print, its tip rounded (FLAP_TIP). `offset` moves it up and left, for its
        shadow."""
        right = bottom = self.drawing.print_right
        fold, tip = self.drawing.fold, self.radius * FLAP_TIP
        apex = (right - fold - offset, bottom - fold - offset)
        points = [(right - offset, bottom - fold - offset), (right - fold - offset, bottom - offset),
                  (apex[0], apex[1] + tip), (apex[0] + tip, apex[1])]
        return (f"M{fmt(points[0][0])} {fmt(points[0][1])} L{fmt(points[1][0])} {fmt(points[1][1])} "
                f"L{fmt(points[2][0])} {fmt(points[2][1])} A{fmt(tip)} {fmt(tip)} 0 0 1 "
                f"{fmt(points[3][0])} {fmt(points[3][1])} Z")

    def under(self):
        defs = gradient("under", self.colours["under"], x2=1, y2=1)
        return defs, f'<path d="{self.under_path()}" fill="url(#under)"/>'

    def flap(self, filtered):
        """The flap and its shadow on the print, up and to the left of it, as the Linux drawing has it: a blurred
        shadow where the renderer is rsvg-convert, three steps of a translucent one in the Icon Composer layers."""
        defs = gradient("back", self.colours["back"], x2=1, y2=1)
        if filtered:
            defs += ('<filter id="flapshadow" x="-40%" y="-40%" width="180%" height="180%">'
                     '<feGaussianBlur in="SourceAlpha" stdDeviation="1.6"/><feOffset dx="-1.2" dy="-1.2"/>'
                     '<feComponentTransfer><feFuncA type="linear" slope="0.30"/></feComponentTransfer>'
                     '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
            body = f'<path d="{self.flap_path()}" fill="url(#back)" filter="url(#flapshadow)"/>'
        else:
            shadow = "".join(f'<path d="{self.flap_path(offset)}" fill="#000000" fill-opacity="0.07"/>'
                             for offset in (1.8, 1.2, 0.6))
            body = shadow + f'<path d="{self.flap_path()}" fill="url(#back)"/>'
        if self.build == "dev":
            body += self.dev_letters()
        return defs, body

    def dev_letters(self):
        """DEV on the turned corner's back, where a lab stamps a print: letters drawn rather than set in a font, so
        every renderer draws them alike, along the fold."""
        right = bottom = self.drawing.print_right
        fold = self.drawing.fold
        # Along the fold, a little in from it, where the flap is widest; the letters' tops toward its tip.
        depth = fold * 0.16
        centre = (right + bottom - fold - depth * math.sqrt(2)) / 2
        height = fold * 0.175
        width = height * 2.35
        scale = height / 100
        letters = "M0 0 V100 H38 A50 50 0 0 0 38 0 Z M150 0 H100 V100 H150 M100 50 H140 M175 0 L205 100 L235 0"
        return (f'<g transform="translate({fmt(centre)} {fmt(centre)}) rotate(-45) '
                f'translate({fmt(-width / 2)} {fmt(-height / 2)}) scale({scale:.5f})" fill="none" '
                f'stroke="{DEV_LETTERS}" stroke-width="17" stroke-linejoin="round" stroke-linecap="round">'
                f'<path d="{letters}"/></g>')

    def photo(self):
        drawing = self.drawing
        # The picture's corners concentric with the square's: the paper around it is as wide as in the drawing.
        inset = drawing.photo_x - drawing.print_left
        radius = max(drawing.photo_radius, self.radius - inset)
        body = (f'<rect x="{fmt(drawing.photo_x)}" y="{fmt(drawing.photo_y)}" width="{fmt(drawing.photo_width)}" '
                f'height="{fmt(drawing.photo_height)}" rx="{fmt(radius)}" fill="url(#photo)"/>')
        if drawing.photo_edge:
            # A light picture's edge, inside it as the drawing has it, its corners following the picture's.
            colour, opacity, width = drawing.photo_edge
            half = width / 2
            body += (f'<rect x="{fmt(drawing.photo_x + half)}" y="{fmt(drawing.photo_y + half)}" '
                     f'width="{fmt(drawing.photo_width - width)}" height="{fmt(drawing.photo_height - width)}" '
                     f'rx="{fmt(radius - half)}" fill="none" stroke="{colour}" stroke-opacity="{opacity}" '
                     f'stroke-width="{fmt(width)}"/>')
        return drawing.gradients["photo"], body

    def lens(self, part):
        """The lens's ring (its barrel and the five colours) or its glass, where the drawing places it."""
        drawing = self.drawing
        body = drawing.lens_ring if part == "ring" else drawing.lens_glass
        defs = drawing.gradients["glass"] if part == "glass" else ""
        return defs, (f'<g transform="translate({fmt(drawing.lens_x)} {fmt(drawing.lens_y)}) '
                      f'scale({drawing.lens_scale})">{body}</g>')

    def word(self):
        drawing = self.drawing
        stroke = drawing.word_stroke * (1.8 if self.small else 1)
        paths = "".join(f'<path d="{path}"/>' for path in drawing.word_paths)
        return "", (f'<g transform="translate({fmt(drawing.word_x)} {fmt(drawing.word_y)}) '
                    f'scale({drawing.word_scale})" fill="none" stroke="{self.colours["ink"]}" '
                    f'stroke-width="{fmt(stroke)}" stroke-linecap="round" stroke-linejoin="round">{paths}</g>')

    def tile_path(self, folded=False):
        """Apple's rounded square in the drawing's coordinates; `folded`, the paper of the print: the square without
        its corner beyond the fold."""
        left, right, radius = self.drawing.print_left, self.drawing.print_right, self.radius
        fold = self.drawing.fold
        corner = (f"V{fmt(right - fold)} L{fmt(right - fold)} {fmt(right)}" if folded else
                  f"V{fmt(right - radius)} A{fmt(radius)} {fmt(radius)} 0 0 1 {fmt(right - radius)} {fmt(right)}")
        return (f"M{fmt(left + radius)} {fmt(left)} H{fmt(right - radius)} "
                f"A{fmt(radius)} {fmt(radius)} 0 0 1 {fmt(right)} {fmt(left + radius)} {corner} H{fmt(left + radius)} "
                f"A{fmt(radius)} {fmt(radius)} 0 0 1 {fmt(left)} {fmt(right - radius)} V{fmt(left + radius)} "
                f"A{fmt(radius)} {fmt(radius)} 0 0 1 {fmt(left + radius)} {fmt(left)} Z")

    def stacked(self, filtered):
        """Every part in one drawing, back to front, as the Icon Composer layers stack them over the paper."""
        pieces = [(gradient("paper", self.colours["paper"]), f'<path d="{self.tile_path(folded=True)}" fill="url(#paper)"/>'),
                  self.photo(), self.lens("ring"), self.lens("glass"), self.word()]
        under_defs, under_body = self.under()
        pieces.append((under_defs + f'<clipPath id="tile"><path d="{self.tile_path()}"/></clipPath>',
                       f'<g clip-path="url(#tile)">{under_body}</g>'))
        pieces.append(self.flap(filtered))
        return "".join(piece[0] for piece in pieces), "\n".join(piece[1] for piece in pieces)


def placement(drawing, left, side):
    """The transform that puts the drawing's print on a square `side` wide at (`left`, `left`)."""
    scale = side / drawing.side
    offset = left - drawing.print_left * scale
    return f"translate({fmt(offset)} {fmt(offset)}) scale({scale:.6f})"


def flat_icon(drawing, build, appearance="light", small=False):
    """The whole icon as one SVG on Apple's 1024 grid, with the drop shadow and edge macOS 14 and 15 icons carry: the
    shadow alone, so no edge of another colour shows round the corner beyond the fold."""
    parts = Parts(drawing, build, appearance, small)
    defs, body = parts.stacked(filtered=True)
    transform = placement(drawing, TILE_LEFT, TILE_SIDE)
    edge = TILE_SIDE / drawing.side
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
<defs>{defs}
  <filter id="lift" x="-10%" y="-10%" width="120%" height="125%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="10"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.3"/></feComponentTransfer>
  </filter>
</defs>
<rect x="{TILE_LEFT}" y="{TILE_LEFT}" width="{TILE_SIDE}" height="{TILE_SIDE}" rx="{TILE_RADIUS}" filter="url(#lift)"/>
<g transform="{transform}">
{body}
<path d="{parts.tile_path()}" fill="none" stroke="#000000" stroke-opacity="0.12" stroke-width="{2 / edge:.4f}"/>
</g>
</svg>
"""


def picture(drawing, build, appearance):
    """The icon's rounded square alone, filling its canvas, without the shadow and edge the Mac's icons carry: what
    iOS shows of the icon, for the iOS app's own picture of it."""
    defs, body = Parts(drawing, build, appearance).stacked(filtered=True)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{TILE_SIDE}" height="{TILE_SIDE}" '
            f'viewBox="0 0 {TILE_SIDE} {TILE_SIDE}">\n<defs>{defs}</defs>\n'
            f'<g transform="{placement(drawing, 0, TILE_SIDE)}">{body}</g>\n</svg>\n')


def alternate_icon(drawing, build, appearance):
    """The icon as an iOS app icon set takes it: the square edge to edge, the paper filling it as it is the Icon
    Composer document's background, and what shows beneath the turned corner reaching the square's corner, which the
    system rounds, as it rounds the document's layers."""
    parts = Parts(drawing, build, appearance)
    pieces = [parts.photo(), parts.lens("ring"), parts.lens("glass"), parts.word(), parts.under(),
              parts.flap(filtered=True)]
    left, side = drawing.print_left, drawing.side
    defs = gradient("paper", parts.colours["paper"]) + "".join(piece[0] for piece in pieces)
    body = (f'<rect x="{fmt(left)}" y="{fmt(left)}" width="{fmt(side)}" height="{fmt(side)}" fill="url(#paper)"/>\n'
            + "\n".join(piece[1] for piece in pieces))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">\n<defs>{defs}</defs>\n'
            f'<g transform="{placement(drawing, 0, CANVAS)}">{body}</g>\n</svg>\n')


def messages_icon(drawing, aspect):
    """Messages' icon at `aspect` (width over height): the lens alone, round as Messages shows its apps' icons (in a
    circle as tall as the icon, in its middle), filling that circle on the barrel's own colour, which fills the rest."""
    height = 2.0 * LENS_RADIUS
    width = height * aspect
    lens = f'<g transform="translate({fmt(width / 2)} {fmt(height / 2)})">{drawing.lens_ring}{drawing.lens_glass}</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fmt(width)} {fmt(height)}">\n'
            f'<defs>{drawing.gradients["glass"]}</defs>\n'
            f'<rect width="{fmt(width)}" height="{fmt(height)}" fill="{drawing.barrel}"/>\n{lens}\n</svg>\n')


def lens_alone(drawing):
    """The lens alone, its colours and glass filling its square on nothing, the barrel's dark rim cut away: the Live
    Activity's."""
    side = 2.0 * LENS_COLOURS_RADIUS
    lens = f'<g transform="translate({fmt(side / 2)} {fmt(side / 2)})">{drawing.lens_ring}{drawing.lens_glass}</g>'
    clip = f'<clipPath id="colours"><circle cx="{fmt(side / 2)}" cy="{fmt(side / 2)}" r="{fmt(LENS_COLOURS_RADIUS)}"/></clipPath>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fmt(side)} {fmt(side)}">\n'
            f'<defs>{drawing.gradients["glass"]}{clip}</defs>\n<g clip-path="url(#colours)">{lens}</g>\n</svg>\n')


def write_lens_set(drawing, folder):
    """The Live Activity's lens: an image set at 1x, 2x and 3x of LENS_POINTS, transparent."""
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    catalog_contents = folder.parent / "Contents.json"
    if not catalog_contents.exists():
        catalog_contents.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    images = []
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "lens.svg"
        source.write_text(lens_alone(drawing))
        for scale in (1, 2, 3):
            name = f"Lens@{scale}x.png"
            pixels = LENS_POINTS * scale
            subprocess.run(["rsvg-convert", "-w", str(pixels), "-h", str(pixels), str(source), "-o", str(folder / name)],
                           check=True)
            images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                                                     indent=2) + "\n")


def layer(drawing, defs_and_body):
    """One Icon Composer layer: the drawing's print filling the 1024 canvas, which the system shapes."""
    defs, body = defs_and_body
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">\n<defs>{defs}</defs>\n'
            f'<g transform="{placement(drawing, 0, CANVAS)}">{body}</g>\n</svg>\n')


def composer_assets(drawing, build):
    """The Icon Composer document's layers, by file name: those that change with the appearance in both."""
    assets = {}
    for appearance in ("light", "dark"):
        suffix = "" if appearance == "light" else "-dark"
        parts = Parts(drawing, build, appearance)
        assets[f"corner{suffix}.svg"] = layer(drawing, parts.flap(filtered=False))
        assets[f"under{suffix}.svg"] = layer(drawing, parts.under())
        assets[f"word{suffix}.svg"] = layer(drawing, parts.word())
    parts = Parts(drawing, build, "light")
    assets["photo.svg"] = layer(drawing, parts.photo())
    assets["lens-ring.svg"] = layer(drawing, parts.lens("ring"))
    assets["lens-glass.svg"] = layer(drawing, parts.lens("glass"))
    return assets


def srgb(hex_colour):
    red, green, blue = (int(hex_colour[index:index + 2], 16) / 255 for index in (1, 3, 5))
    return f"srgb:{red:.5f},{green:.5f},{blue:.5f},1.00000"


def by_appearance(name, file):
    return {"name": name, "image-name-specializations": [
        {"value": f"{file}.svg"}, {"appearance": "dark", "value": f"{file}-dark.svg"}], "glass": False}


def composer_document(build):
    """icon.json: the paper is the document's background, in a light and a dark gradient; the turned corner, the
    lens, the print's picture and word, and what shows beneath the corner are groups over it, front first. The lens's
    glass is a glass layer, so the system's glass and lighting play on it."""
    def paper(appearance):
        colours = PALETTE[build][appearance]["paper"]
        value = {"linear-gradient": [srgb(colours[0]), srgb(colours[1])],
                 "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}
        return {"value": value} if appearance == "light" else {"appearance": appearance, "value": value}

    flat = {"shadow": {"kind": "none", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}}
    return {
        "fill-specializations": [paper("light"), paper("dark")],
        "groups": [
            {"name": "Corner", "layers": [by_appearance("Flap", "corner")], **flat},
            {
                "name": "Lens",
                "layers": [
                    {"name": "Glass", "image-name": "lens-glass.svg", "glass": True},
                    {"name": "Ring", "image-name": "lens-ring.svg", "glass": False},
                ],
                "lighting": "individual",
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": False, "value": 0.5},
            },
            {"name": "Print", "layers": [by_appearance("Word", "word"),
                                         {"name": "Picture", "image-name": "photo.svg", "glass": False}], **flat},
            {"name": "Beneath", "layers": [by_appearance("Beneath", "under")], **flat},
        ],
        "supported-platforms": {"squares": "shared"},  # macOS and iOS
    }


def render(svg_text, pixels, target):
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "icon.svg"
        source.write_text(svg_text)
        subprocess.run(["rsvg-convert", "-w", str(pixels), "-h", str(pixels), str(source), "-o", str(target)],
                       check=True)


def write_icon_set(drawing, build, folder):
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    images = []
    for points in POINT_SIZES:
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            render(flat_icon(drawing, build, small=pixels <= SMALL_PIXELS), pixels, folder / name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_picture_set(drawing, build, folder):
    """The iOS app's picture of its icon, light and dark, at 2x and 3x of the 120 points its welcome shows it at."""
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    catalog_contents = folder.parent / "Contents.json"
    if not catalog_contents.exists():
        catalog_contents.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    images = []
    for appearance in ("light", "dark"):
        for scale in (2, 3):
            name = f"{folder.stem}{'-dark' if appearance == 'dark' else ''}@{scale}x.png"
            render(picture(drawing, build, appearance), 120 * scale, folder / name)
            image = {"filename": name, "idiom": "universal", "scale": f"{scale}x"}
            if appearance == "dark":
                image["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
            images.append(image)
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_alternate_set(drawing, build, folder):
    """An alternate app icon of the iOS app: one opaque 1024 picture, light and dark, which the system draws at every
    size and makes its tinted and clear icons from."""
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    images = []
    for appearance in ("light", "dark"):
        name = f"{folder.stem}{'-dark' if appearance == 'dark' else ''}.png"
        render(alternate_icon(drawing, build, appearance), CANVAS, folder / name)
        write_opaque(folder / name)
        image = {"filename": name, "idiom": "universal", "platform": "ios", "size": f"{CANVAS}x{CANVAS}"}
        if appearance == "dark":
            image = {"appearances": [{"appearance": "luminosity", "value": "dark"}], **image}
        images.append(image)
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_messages_set(drawing, folder):
    """Messages' icon set: every size MESSAGES_IMAGES lists, opaque."""
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    catalog_contents = folder.parent / "Contents.json"
    if not catalog_contents.exists():
        catalog_contents.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    images = []
    for idiom, (width, height), scales, platform in MESSAGES_IMAGES:
        for scale in scales:
            pixels = (width * scale, height * scale)
            name = f"{folder.stem}-{width}x{height}@{scale}x.png"
            svg = messages_icon(drawing, width / height)
            with tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / "icon.svg"
                source.write_text(svg)
                subprocess.run(["rsvg-convert", "-w", str(pixels[0]), "-h", str(pixels[1]), str(source),
                                "-o", str(folder / name)], check=True)
            write_opaque(folder / name)
            image = {"filename": name, "idiom": idiom}
            if platform:
                image["platform"] = platform
            image.update({"scale": f"{scale}x", "size": f"{width}x{height}"})
            images.append(image)
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_opaque(target):
    """The PNG again without its alpha channel, over white where anything shows through: the App Store refuses an
    iMessage app's icon with one. rsvg-convert writes an image with nothing see-through as RGB already."""
    data = target.read_bytes()
    if data[25] != 6:  # the colour type: 6 is RGBA
        return
    rows = png_pixels(data)
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for red, green, blue, alpha in row:
            raw.extend(round(channel * alpha / 255 + 255 * (1 - alpha / 255)) for channel in (red, green, blue))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0)
    target.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
                       + chunk(b"IEND", b""))


def write_composer_document(drawing, build, target):
    if target.exists():
        shutil.rmtree(target)
    (target / "Assets").mkdir(parents=True)
    for name, text in composer_assets(drawing, build).items():
        (target / "Assets" / name).write_text(text)
    (target / "icon.json").write_text(json.dumps(composer_document(build), indent=2) + "\n")


def write_symbol(folder):
    """The sidebar symbol's set, without a rendering intent, so a renderer that draws in colour may (multicolor), and
    one that draws in one colour, as Finder's sidebar does, gets the same shape."""
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    name = "SidebarSymbol.svg"
    subprocess.run([sys.executable, str(SYMBOL_SCRIPT), str(folder / name)], check=True)
    contents = {"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": name, "idiom": "universal"}]}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def composed_appearance(drawing, build, appearance):
    """The Icon Composer document's layers stacked in one SVG on Apple's grid, roughly as the system shows them, but
    without its glass and lighting: for the preview's dark rows, since only a Mac renders the document itself."""
    defs, body = Parts(drawing, build, appearance).stacked(filtered=False)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} '
            f'{CANVAS}"><defs>{defs}</defs><g transform="{placement(drawing, TILE_LEFT, TILE_SIDE)}">{body}</g></svg>')


def png_pixels(data):
    """The pixels of a PNG that rsvg-convert wrote (8-bit RGBA, not interlaced), as rows of (red, green, blue,
    alpha): the preview draws the small sizes enlarged from them, square by square, as rsvg-convert scales an
    embedded image smoothly."""
    position, compressed, width = 8, b"", 0
    while position < len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        chunk = data[position + 8:position + 8 + length]
        if kind == b"IHDR":
            width = struct.unpack(">I", chunk[:4])[0]
        elif kind == b"IDAT":
            compressed += chunk
        position += 12 + length
    raw = zlib.decompress(compressed)
    stride = width * 4
    rows, previous = [], bytearray(stride)
    for start in range(0, len(raw), stride + 1):
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for index in range(stride):
            left = line[index - 4] if index >= 4 else 0
            up = previous[index]
            up_left = previous[index - 4] if index >= 4 else 0
            if kind == 1:
                line[index] = (line[index] + left) & 255
            elif kind == 2:
                line[index] = (line[index] + up) & 255
            elif kind == 3:
                line[index] = (line[index] + (left + up) // 2) & 255
            elif kind == 4:
                estimate = left + up - up_left
                distances = (abs(estimate - left), abs(estimate - up), abs(estimate - up_left))
                nearest = (left, up, up_left)[distances.index(min(distances))]
                line[index] = (line[index] + nearest) & 255
        rows.append([tuple(line[index:index + 4]) for index in range(0, stride, 4)])
        previous = line
    return rows


def enlarged(data, left, top, factor):
    """A small PNG drawn `factor` times larger, a square per pixel."""
    squares = []
    for row_index, row in enumerate(png_pixels(data)):
        for column_index, (red, green, blue, alpha) in enumerate(row):
            if alpha:
                squares.append(f'<rect x="{left + column_index * factor}" y="{top + row_index * factor}" '
                               f'width="{factor}" height="{factor}" fill="#{red:02x}{green:02x}{blue:02x}" '
                               f'fill-opacity="{alpha / 255:.3f}"/>')
    return "".join(squares)


def script_module(script):
    """One of the other generators beside this one, loaded for its drawings."""
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location(script.stem.replace("-", "_"), script)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


# The sidebar symbol's layers in colour, for the preview: the system colours its layers ask for (make-symbol.py,
# LAYER_COLOURS), as macOS draws them in the light appearance, the accent the default blue.
SYMBOL_PREVIEW_COLOURS = {"systemRedColor": "#ff3b30", "systemPinkColor": "#ff2d55", "systemYellowColor": "#ffcc00",
                          "systemBlueColor": "#007aff", "systemGreenColor": "#34c759", "tintColor": "#007aff"}


def symbol_svg(symbol, widths, colour=None):
    """The sidebar symbol's glyphs at the given stroke widths, side by side, in one colour or, without one, each layer
    in the colour it asks for, and its width."""
    groups, offset = [], 0.0
    for width in widths:
        layers, advance = symbol.glyph(width)
        paths = "".join(f'<path fill="{colour or SYMBOL_PREVIEW_COLOURS[name]}" d="{layer}"/>'
                        for layer, name in zip(layers, symbol.LAYER_COLOURS))
        groups.append(f'<g transform="translate({fmt(offset)} {fmt(symbol.CAP / 2 + 42)})">{paths}</g>')
        offset += advance + 12
    width = offset - 12
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{fmt(width)}" height="84" '
            f'viewBox="0 0 {fmt(width)} 84">' + "".join(groups) + "</svg>"), width


def write_preview(drawing, target):
    """A sheet for looking at the icons: per build and appearance, the icon at 1024, 128, 32 and 16 pixels (the small
    ones also enlarged, pixel for pixel); the sidebar symbol's three weights and at the sidebar's size, in one colour
    and in colour; and the menu bar icons on a light and a dark menu bar."""
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)

        def png(svg_text, name, width, height):
            """The SVG rendered at the given size, as the PNG's bytes."""
            path, source = folder / f"{name}-{width}x{height}.png", folder / f"{name}.svg"
            source.write_text(svg_text)
            subprocess.run(["rsvg-convert", "-w", str(width), "-h", str(height), str(source), "-o", str(path)],
                           check=True)
            return path.read_bytes()

        def image(data, left, top, width, height):
            encoded = base64.b64encode(data).decode()
            return (f'<image x="{left}" y="{top}" width="{width}" height="{height}" '
                    f'href="data:image/png;base64,{encoded}"/>')

        cells = []
        cell_width, cell_height = 1500, 1120
        for row, build in enumerate(("release", "dev")):
            for column, appearance in enumerate(("light", "dark")):
                x, y = column * cell_width, row * cell_height
                background, text = ("#ececec", "#333333") if appearance == "light" else ("#1e1e20", "#dddddd")
                cells.append(f'<rect x="{x}" y="{y}" width="{cell_width}" height="{cell_height}" fill="{background}"/>')
                source = "the PNG set" if appearance == "light" else "the Icon Composer layers, without the system's glass"
                cells.append(f'<text x="{x + 30}" y="{y + 50}" font-family="sans-serif" font-size="30" fill="{text}">'
                             f'{"Release" if build == "release" else "Dev"}, {appearance}: {source}</text>')
                for pixels, place_x, place_y in ((1024, 0, 70), (128, 1060, 120), (32, 1220, 120), (16, 1290, 120)):
                    if appearance == "light":
                        svg_text = flat_icon(drawing, build, small=pixels <= SMALL_PIXELS)
                    else:
                        svg_text = composed_appearance(drawing, build, appearance)
                    data = png(svg_text, f"{build}-{appearance}", pixels, pixels)
                    cells.append(image(data, x + place_x, y + place_y, pixels, pixels))
                    if pixels <= 32:
                        cells.append(enlarged(data, x + 1060 + (0 if pixels == 32 else 300), y + 300, 8))
                cells.append(f'<text x="{x + 1060}" y="{y + 290}" font-family="sans-serif" font-size="22" '
                             f'fill="{text}">32 and 16, enlarged 8 times</text>')
        symbols_y = 2 * cell_height
        symbol = script_module(SYMBOL_SCRIPT)
        rows = [f'<rect x="0" y="{symbols_y}" width="{2 * cell_width}" height="420" fill="#f5f5f5"/>',
                f'<text x="30" y="{symbols_y + 50}" font-family="sans-serif" font-size="30" fill="#333333">'
                f'Finder sidebar symbol: Ultralight, Regular and Black, then Regular at the sidebar\'s size, light and '
                f'dark; in one colour, as Finder draws it, and in colour (multicolor)</text>']
        regular_width = symbol.WEIGHTS["Regular-S"][1]
        for coloured, offset in ((False, 0), (True, cell_width)):
            kind = "colour" if coloured else "one"
            weights, weights_width = symbol_svg(symbol, [width for _, width in symbol.WEIGHTS.values()],
                                                None if coloured else "#3c3c43")
            shown_width = round(weights_width * 240 / 84)
            rows.append(image(png(weights, f"symbol-{kind}", shown_width, 240), offset + 30, symbols_y + 80,
                              shown_width, 240))
            for index, (background, sidebar_colour) in enumerate((("#e8e8ea", "#3c3c43"), ("#2a2a2d", "#dcdce0"))):
                regular, regular_width_units = symbol_svg(symbol, [regular_width], None if coloured else sidebar_colour)
                place_x = offset + 900 + index * 290
                rows.append(f'<rect x="{place_x}" y="{symbols_y + 80}" width="270" height="250" fill="{background}"/>')
                for size_index, pixels in enumerate((16, 18, 22)):
                    width = round(regular_width_units * pixels / 84)
                    rows.append(image(png(regular, f"regular-{kind}-{index}", width, pixels),
                                      place_x + 20 + size_index * 40, symbols_y + 100, width, pixels))
                width = round(regular_width_units * 18 / 84)
                rows.append(enlarged(png(regular, f"regular-{kind}-{index}", width, 18), place_x + 20,
                                     symbols_y + 140, 9))
        menu_y = symbols_y + 420
        rows.append(f'<rect x="0" y="{menu_y}" width="{2 * cell_width}" height="440" fill="#f5f5f5"/>')
        rows.append(f'<text x="30" y="{menu_y + 50}" font-family="sans-serif" font-size="30" fill="#333333">'
                    f'Menu bar icons, on a light and a dark menu bar, in one colour and in colour: 1x, 2x, and 1x '
                    f'enlarged 8 times</text>')
        # A template image is drawn in the menu bar's text colour: dark on a light bar, white on a dark one.
        rows.append('<filter id="white"><feColorMatrix type="matrix" '
                    'values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 1 0"/></filter>')
        icons = script_module(MENU_BAR_SCRIPT).icons()
        for index, name in enumerate(name for name in icons if not name.endswith("Colour")):
            place_x = 30 + index * 740
            rows.append(f'<text x="{place_x}" y="{menu_y + 100}" font-family="sans-serif" font-size="24" '
                        f'fill="#333333">{name}</text>')
            for bar_index, bar_colour in enumerate(("#e9e9eb", "#2b2b2e")):
                top = menu_y + 115 + bar_index * 155
                rows.append(f'<rect x="{place_x}" y="{top}" width="700" height="150" fill="{bar_colour}"/>')
                for variant, offset in ((name, 0), (f"{name}Colour", 350)):
                    svg_text, colour = icons[variant]
                    tint = "" if colour or bar_index == 0 else ' filter="url(#white)"'
                    small, large = png(svg_text, variant, 18, 18), png(svg_text, variant, 36, 36)
                    rows.append(f'<g{tint}>' + image(small, place_x + offset + 20, top + 66, 18, 18)
                                + image(large, place_x + offset + 50, top + 57, 36, 36)
                                + enlarged(small, place_x + offset + 100, top + 3, 8) + "</g>")
        width, height = 2 * cell_width, menu_y + 440
        sheet = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
                 f'viewBox="0 0 {width} {height}">' + "".join(cells) + "".join(rows) + "</svg>")
        sheet_path = folder / "sheet.svg"
        sheet_path.write_text(sheet)
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["rsvg-convert", str(sheet_path), "-o", str(target)], check=True)


def design_source(design):
    """The drawing of one of the picture's designs: Mist's is the app icon's own, the others' carry their names."""
    return DRAWINGS / ("dev.hviid.Verso.svg" if design == DEFAULT_DESIGN else f"dev.hviid.Verso-{design}.svg")


def main():
    arguments = sys.argv[1:]
    design = DEFAULT_DESIGN
    if "--design" in arguments:
        at = arguments.index("--design")
        if arguments[at + 1:at + 2] == [] or arguments[at + 1] not in DESIGNS:
            sys.exit(__doc__)
        design = arguments[at + 1]
        del arguments[at:at + 2]
    drawing = Drawing(design_source(design).read_text())
    lens = Drawing(LENS_SOURCE.read_text())
    if arguments == ["--lens"]:
        write_lens_set(lens, WIDGETS_CATALOG / "Lens.imageset")
        write_lens_set(lens, IOS_CATALOG / "Lens.imageset")
        print("wrote Lens.imageset, the widgets' and the app's")
        return
    if arguments[:1] == ["--preview"] and len(arguments) == 2:
        write_preview(drawing, Path(arguments[1]).resolve())
        print(f"wrote {arguments[1]}")
        return
    if arguments not in ([], ["--dev"]):
        sys.exit(__doc__)
    build = "dev" if arguments == ["--dev"] else "release"
    # AppIcon, AppIconDev; another design's with its name after them, AppIcon-Sand.
    name = ("AppIconDev" if build == "dev" else "AppIcon") + ("" if design == DEFAULT_DESIGN else f"-{design.title()}")
    write_icon_set(drawing, build, CATALOG / f"{name}.appiconset")
    write_picture_set(drawing, build, IOS_CATALOG / f"{name}Image.imageset")
    if design == DEFAULT_DESIGN:
        write_composer_document(drawing, build, HERE / "Verso" / f"{name}.icon")
        print(f"wrote {name}.appiconset, {name}.icon and {name}Image.imageset")
    else:
        # An alternate icon: the Mac's PNG set for the Dock, the iOS app's own set beside its picture.
        write_alternate_set(drawing, build, IOS_CATALOG / f"{name}.appiconset")
        print(f"wrote {name}.appiconset, the Mac's and the iOS app's, and {name}Image.imageset")
    if build == "release" and design == DEFAULT_DESIGN:
        # The small icons, the lens alone, have no Dev variant, and are the same for every design.
        write_symbol(CATALOG / "SidebarSymbol.symbolset")
        write_messages_set(lens, MESSAGES_CATALOG / "MessagesIcon.stickersiconset")
        write_lens_set(lens, WIDGETS_CATALOG / "Lens.imageset")
        write_lens_set(lens, IOS_CATALOG / "Lens.imageset")
        print("wrote SidebarSymbol.symbolset, MessagesIcon.stickersiconset and Lens.imageset, the widgets' and the app's")
        subprocess.run([sys.executable, str(MENU_BAR_SCRIPT)], check=True)


if __name__ == "__main__":
    main()
