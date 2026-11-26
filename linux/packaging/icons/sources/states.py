# The top bar icon's states, on a 16-pixel grid: the lens alone, as the Mac's menu bar icon and Finder's sidebar
# symbol are (DESIGN.md, the icon family), in one colour (symbolic, the default, recoloured by the desktop; also Files'
# sidebar and notifications, dev.hviid.Verso-symbolic.svg) and in full colour (`tray.colour`: the ring in Immich's five
# colours; faded states lose the colours). Unmounted has a pause badge; unreachable is faded and struck through; signed
# out is faded, with a key badge. A badge sits at the foot on the right, as the Mac's, a disc with its sign cut out and a
# clear gap round it. Plain shapes only, as GTK recolours a symbolic icon's every fill. Needs Shapely. Writes
# dev.hviid.Verso[-<state>]-symbolic.svg and dev.hviid.Verso-tray[-<state>].svg into the folder given:
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

CX = CY = 8.0
OUTER, INNER = 7.4, 5.5  # the ring, in five segments with the gap at the top
RIM_OUT, RIM_IN = 3.75, 3.0  # the glass's rim
ring_segments = [segments(CX, CY, OUTER, INNER, 5, 0.95).intersection(
    Polygon([(CX, CY)] + [(CX + 9 * math.cos(math.radians(-90 + 72 * k + 72 * i / 8)), CY + 9 * math.sin(math.radians(-90 + 72 * k + 72 * i / 8))) for i in range(9)]))
    for k in range(5)]
rim = Point(CX, CY).buffer(RIM_OUT, quad_segs=32).difference(Point(CX, CY).buffer(RIM_IN, quad_segs=32))
light = Point(CX - 1.05, CY - 1.05).buffer(0.75, quad_segs=16)
barrel = Point(CX, CY).buffer(OUTER + 0.3, quad_segs=32)
glass = Point(CX, CY).buffer(RIM_OUT, quad_segs=32)
lens = unary_union(ring_segments + [rim, light])

BX = BY = 12.35
BR = 3.45
disc = Point(BX, BY).buffer(BR, quad_segs=24)
clear = disc.buffer(0.85, quad_segs=24)
K = BR / 3.9  # the signs, drawn for a 3.9 badge
key = unary_union([Point(BX - 1.1 * K, BY - 1.1 * K).buffer(1.25 * K, quad_segs=16).difference(Point(BX - 1.1 * K, BY - 1.1 * K).buffer(0.5 * K, quad_segs=12)),
                   line((BX - 0.4 * K, BY - 0.4 * K), (BX + 2.0 * K, BY + 2.0 * K), 0.85 * K), line((BX + 1.1 * K, BY + 1.1 * K), (BX + 0.35 * K, BY + 1.85 * K), 0.75 * K),
                   line((BX + 1.8 * K, BY + 1.8 * K), (BX + 1.05 * K, BY + 2.55 * K), 0.75 * K)])
signs = {
    "paused": unary_union([box(BX - 1.45 * K, BY - 1.7 * K, BX - 0.45 * K, BY + 1.7 * K), box(BX + 0.45 * K, BY - 1.7 * K, BX + 1.45 * K, BY + 1.7 * K)]),
    "key": key,
}
SLASH = ((2.85, 2.85), (13.15, 13.15))
FIVE = ["#FA2921", "#ED79B5", "#FFB400", "#1E83F7", "#18C249"]  # the app icon's ring, from the top clockwise
BADGE = {"paused": "#5e5c64", "key": "#5e5c64"}

def p(fill, geom, op=1.0):
    d = path(geom)
    # `fill-opacity`, as Adwaita's symbolic icons fade their parts: themes recolour the fill and keep it.
    return f'  <path fill="{fill}"{f" fill-opacity={chr(34)}{op}{chr(34)}" if op < 1 else ""} fill-rule="evenodd" d="{d}"/>\n' if d else ""

def wrap(body, note):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n  <!-- {note} -->\n{body}</svg>\n'

def mono(faded, badge=None, strike=False):
    shape, marks = lens, None
    if strike:
        shape, marks = shape.difference(line(*SLASH, 2.8)), line(*SLASH, 1.3).intersection(barrel)
    if badge:
        shape, marks = shape.difference(clear), disc.difference(signs[badge])
    return p("#000000", shape, 0.4 if faded else 1.0) + (p("#000000", marks) if marks is not None else "")

def colour(faded, badge=None, strike=False):
    cut = unary_union([line(*SLASH, 2.8)] if strike else []).union(clear if badge else Polygon())
    keep = lambda geom: geom.difference(cut) if not cut.is_empty else geom
    op = 0.55 if faded else 1.0
    grey = lambda c: "#9a9996" if faded else c
    # The barrel's dark rim round the ring, the ring's five colours, the glass and its light, as the app icon's lens.
    body = p("#241f31", keep(barrel.difference(unary_union(ring_segments + [glass]))), op)
    for segment, c in zip(ring_segments, FIVE):
        body += p(grey(c), keep(segment), op)
    body += p("#1c3b63" if not faded else "#5e5c64", keep(glass), op)
    body += p("#99c1f1" if not faded else "#deddda", keep(rim.union(light)), op)
    if strike:
        body += p("#f6f5f4", line(*SLASH, 1.3).intersection(barrel))
    if badge:
        # The sign in white on the badge's grey.
        body += p(BADGE[badge], disc) + p("#ffffff", signs[badge].intersection(disc))
    return body

# Each icon: its file, how it is drawn, and what it says: each state in one colour and in colour.
ICONS = [
    ("dev.hviid.Verso-symbolic.svg", mono, dict(faded=False),
     "Verso's symbolic icon: the lens alone, as the Mac's menu bar icon and Finder's sidebar symbol. The top bar while connected, Files' sidebar and notifications. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-unmounted-symbolic.svg", mono, dict(faded=False, badge="paused"),
     "Verso's top bar icon while Verso Drive is switched on and unmounted: paused. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-offline-symbolic.svg", mono, dict(faded=True, strike=True),
     "Verso's top bar icon while the server cannot be reached: faded, struck through. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-signed-out-symbolic.svg", mono, dict(faded=True, badge="key"),
     "Verso's top bar icon while the server refuses the sign-in: faded, with a key. Recoloured by the desktop. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray.svg", colour, dict(faded=False),
     "Verso's top bar icon in colour (tray.colour): the lens, its ring in Immich's five colours. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray-unmounted.svg", colour, dict(faded=False, badge="paused"),
     "Verso's top bar icon in colour while Verso Drive is switched on and unmounted: paused. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray-offline.svg", colour, dict(faded=True, strike=True),
     "Verso's top bar icon in colour while the server cannot be reached: the colours gone, struck through. Drawn by sources/states.py."),
    ("dev.hviid.Verso-tray-signed-out.svg", colour, dict(faded=True, badge="key"),
     "Verso's top bar icon in colour while the server refuses the sign-in: the colours gone, with a key. Drawn by sources/states.py."),
]
for name, draw, args, note in ICONS:
    (out / name).write_text(wrap(draw(**args), note))
