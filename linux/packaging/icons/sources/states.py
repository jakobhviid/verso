# The top bar icon's states, on a 16-pixel grid: in one colour (symbolic, the default, recoloured by the desktop) and in
# full colour (`tray.colour`: the lens's ring in Immich's five colours, as the app icon has it; faded states lose the
# colours). Connected is the print as it is (in one colour, dev.hviid.Verso-symbolic.svg, from symbolic.py); unmounted
# has a pause badge; unreachable is faded and struck through; signed out is faded, with a key badge. A badge sits at the
# foot on the left, over the word, the least of the print, as a disc with its sign cut out. Needs Shapely. Writes
# dev.hviid.Verso-<state>-symbolic.svg and dev.hviid.Verso-tray[-<state>].svg into the folder given:
# python3 linux/packaging/icons/sources/states.py linux/packaging/icons
import math, sys, pathlib
from shapely.geometry import Polygon, Point, LineString, box
from shapely.ops import unary_union
out = pathlib.Path(sys.argv[1])

def f(v): return f"{v:.3f}".rstrip("0").rstrip(".")
def rounded(l, t, r, b, rad): return box(l + rad, t + rad, r - rad, b - rad).buffer(rad, quad_segs=16)
def folded(l, t, r, b, rad, fold): return rounded(l, t, r, b, rad).difference(Polygon([(r - fold, b), (r, b - fold), (r + 2, b + 2)]))
def segments(cx, cy, outer, inner, n, gap, start=-90.0):
    ring = Point(cx, cy).buffer(outer, quad_segs=32).difference(Point(cx, cy).buffer(inner, quad_segs=32))
    cuts = [LineString([(cx, cy), (cx + (outer + 1) * math.cos(math.radians(start + 360 / n * k)), cy + (outer + 1) * math.sin(math.radians(start + 360 / n * k)))]).buffer(gap / 2, cap_style="flat") for k in range(n)]
    return ring.difference(unary_union(cuts))
def scribble(x, y, w, h=0.85, waves=1.5, amp=0.55):
    pts = [(x + w * i / 40, y + amp * math.sin(2 * math.pi * waves * i / 40) - 0.5 * (i / 40) ** 2) for i in range(41)]
    return LineString(pts).buffer(h / 2, cap_style="round", quad_segs=4)
def line(a, b, width): return LineString([a, b]).buffer(width / 2, cap_style="round", quad_segs=6)

def path(geom):
    if geom.is_empty: return ""
    polys = [geom] if geom.geom_type == "Polygon" else [p for p in getattr(geom, "geoms", []) if p.geom_type == "Polygon"]
    return " ".join("M" + " L".join(f"{f(x)} {f(y)}" for x, y in list(ring.coords)[:-1]) + " Z" for poly in polys for ring in [poly.exterior, *poly.interiors])

tile = folded(0.5, 0.5, 15.5, 15.5, 3, 4.2)
r, b, fold, g = 15.5, 15.5, 4.2, 0.8
a = (r - fold - g, b - fold - g)
gap = Polygon([a, (r, a[1]), (r, b - fold), (r - fold, b), (a[0], b)])
tri = Polygon([(r, b - fold), (r - fold, b), (r - fold, b - fold)])
LX, LY = 8, 6.6
ring_segments = [segments(LX, LY, 4.4, 2.8, 5, 0.8).intersection(
    Polygon([(LX, LY)] + [(LX + 9 * math.cos(math.radians(-90 + 72 * k + 72 * i / 8)), LY + 9 * math.sin(math.radians(-90 + 72 * k + 72 * i / 8))) for i in range(9)]))
    for k in range(5)]
dot = Point(LX, LY).buffer(1.15, quad_segs=16)
lens_disc = Point(LX, LY).buffer(4.4 + 0.0, quad_segs=32)
word = scribble(2.6, 13.1, 6.4)
m6 = tile.difference(unary_union(ring_segments + [dot, word, gap])).union(tri)

BX, BY, BR = 4.7, 11.3, 3.9
disc = Point(BX, BY).buffer(BR, quad_segs=24)
clear = disc.buffer(0.9, quad_segs=24)
key = unary_union([Point(BX - 1.1, BY - 1.1).buffer(1.25, quad_segs=16).difference(Point(BX - 1.1, BY - 1.1).buffer(0.5, quad_segs=12)),
                   line((BX - 0.4, BY - 0.4), (BX + 2.0, BY + 2.0), 0.85), line((BX + 1.1, BY + 1.1), (BX + 0.35, BY + 1.85), 0.75),
                   line((BX + 1.8, BY + 1.8), (BX + 1.05, BY + 2.55), 0.75)])
signs = {
    "paused": unary_union([box(BX - 1.45, BY - 1.7, BX - 0.45, BY + 1.7), box(BX + 0.45, BY - 1.7, BX + 1.45, BY + 1.7)]),
    "key": key,
}
SLASH = ((1.6, 1.6), (14.0, 14.0))
FIVE = ["#FA2921", "#ED79B5", "#FFB400", "#1E83F7", "#18C249"]  # the app icon's ring, from the top clockwise
BADGE = {"paused": "#5e5c64", "key": "#5e5c64"}

def p(fill, geom, op=1.0):
    d = path(geom)
    # `fill-opacity`, as Adwaita's symbolic icons fade their parts: themes recolour the fill and keep it.
    return f'  <path fill="{fill}"{f" fill-opacity={chr(34)}{op}{chr(34)}" if op < 1 else ""} fill-rule="evenodd" d="{d}"/>\n' if d else ""

def wrap(body, note):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n  <!-- {note} -->\n{body}</svg>\n'

def mono(faded, badge=None, strike=False):
    shape, marks = m6, None
    if strike:
        shape, marks = shape.difference(line(*SLASH, 2.8)), line(*SLASH, 1.3).intersection(tile.union(tri))
    if badge:
        shape, marks = shape.difference(clear), disc.difference(signs[badge])
    return p("#000000", shape, 0.4 if faded else 1.0) + (p("#000000", marks) if marks is not None else "")

def colour(faded, badge=None, strike=False):
    cut = unary_union([line(*SLASH, 2.8)] if strike else []).union(clear if badge else Polygon())
    keep = lambda geom: geom.difference(cut) if not cut.is_empty else geom
    op = 0.55 if faded else 1.0
    grey = lambda c: "#9a9996" if faded else c
    body = p("#f6f5f4" if not faded else "#c0bfbc", keep(tile.difference(unary_union([lens_disc, word, gap]))), op)
    # A thin edge, so the paper holds on a light panel too.
    body += p("#77767b", keep(tile.difference(tile.buffer(-0.55)).difference(gap).difference(lens_disc)), op)
    body += p("#3d3846", keep(word), op)
    body += p("#241f31", keep(lens_disc.difference(unary_union(ring_segments + [dot]))), op)
    for segment, c in zip(ring_segments, FIVE):
        body += p(grey(c), keep(segment), op)
    body += p("#99c1f1" if not faded else "#deddda", keep(dot), op)
    body += p("#d8ccb0" if not faded else "#9a9996", keep(tri), op)
    if strike:
        body += p("#f6f5f4", line(*SLASH, 1.3).intersection(tile.union(tri)))
    if badge:
        # The sign in white on the badge's grey.
        body += p(BADGE[badge], disc) + p("#ffffff", signs[badge].intersection(disc))
    return body

# Each icon: its file, how it is drawn, and what it says. A state's icon in one colour and in colour, but connected's
# in colour only: in one colour it is the symbolic icon itself.
ICONS = [
    ("dev.hviid.Verso-unmounted-symbolic.svg", mono, dict(faded=False, badge="paused"),
     "Verso's top bar icon while Verso Drive is switched on and unmounted: paused. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-offline-symbolic.svg", mono, dict(faded=True, strike=True),
     "Verso's top bar icon while the server cannot be reached: faded, struck through. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-signed-out-symbolic.svg", mono, dict(faded=True, badge="key"),
     "Verso's top bar icon while the server refuses the sign-in: faded, with a key. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray.svg", colour, dict(faded=False),
     "Verso's top bar icon in colour (tray.colour): the print, the lens's ring in Immich's five colours. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray-unmounted.svg", colour, dict(faded=False, badge="paused"),
     "Verso's top bar icon in colour while Verso Drive is switched on and unmounted: paused. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray-offline.svg", colour, dict(faded=True, strike=True),
     "Verso's top bar icon in colour while the server cannot be reached: the colours gone, struck through. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray-signed-out.svg", colour, dict(faded=True, badge="key"),
     "Verso's top bar icon in colour while the server refuses the sign-in: the colours gone, with a key. Drawn by sources/states.py."),
]
for name, draw, args, note in ICONS:
    (out / name).write_text(wrap(draw(**args), note))
