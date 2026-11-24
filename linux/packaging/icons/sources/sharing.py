# Verso's icons for how far an album or a link reaches: the globe with a padlock (a link with a password), two people
# (an album shared with people on the server) and a padlock (private), on a 16-pixel grid in one solid colour (GTK
# recolours it), as verso-globe-symbolic.svg, whose globe is redrawn here. Needs Shapely. Writes
# verso-globe-lock-symbolic.svg, verso-people-symbolic.svg and verso-private-symbolic.svg into the folder given:
# python3 linux/packaging/icons/sources/sharing.py linux/packaging/icons
import sys, pathlib
from shapely.geometry import Point, box, MultiPolygon
from shapely.affinity import scale
from shapely.ops import unary_union

out = pathlib.Path(sys.argv[1])
C = (8.0, 8.0)

def f(v): return f"{v:.3f}".rstrip("0").rstrip(".")

def disk(cx, cy, r): return Point(cx, cy).buffer(r, 96)

def ellipse(cx, cy, rx, ry): return scale(Point(cx, cy).buffer(1, 96), rx, ry)

def rounded(l, t, r, b, rad): return box(l + rad, t + rad, r - rad, b - rad).buffer(rad, 32)

def path(geom):
    polys = list(geom.geoms) if isinstance(geom, MultiPolygon) else [geom]
    rings = []
    for poly in polys:
        for ring in [poly.exterior, *poly.interiors]:
            xs = list(ring.coords)[:-1]
            rings.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in xs) + " Z")
    return " ".join(rings)

def svg(geom, note):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\n  <!-- {note} -->\n'
            f'  <path fill="#000000" fill-rule="evenodd" d="{path(geom)}"/>\n</svg>\n')

def globe(cx=8.0, cy=8.0, r=7.2, w=1.24):
    """Verso's globe: a ring, the equator, a meridian and a lens of two more."""
    outer = disk(cx, cy, r)
    ring = outer.difference(disk(cx, cy, r - w))
    lens = ellipse(cx, cy, r * 0.448, r).difference(ellipse(cx, cy, r * 0.448 - w, r - w))
    lines = box(cx - r, cy - w / 2, cx + r, cy + w / 2).union(box(cx - w / 2, cy - r, cx + w / 2, cy + r))
    return unary_union([ring, lens, lines]).intersection(outer)

def lock(l, t, r, b, shackle_w, rad=0.9, hole=True):
    """A padlock: a body from l, t to r, b, and a shackle above it, shackle_w thick."""
    cx = (l + r) / 2
    body = rounded(l, t, r, b, rad)
    half = (r - l) / 2 - 0.9
    top = t - half * 1.15
    arc = disk(cx, top + half, half).difference(disk(cx, top + half, half - shackle_w)).intersection(box(0, 0, 16, top + half))
    legs = box(cx - half, top + half, cx - half + shackle_w, t + 0.5).union(box(cx + half - shackle_w, top + half, cx + half, t + 0.5))
    shape = unary_union([body, arc, legs])
    if hole:
        kh = (b - t) * 0.16
        keyhole = disk(cx, t + (b - t) * 0.42, kh).union(box(cx - kh * 0.55, t + (b - t) * 0.42, cx + kh * 0.55, t + (b - t) * 0.75))
        shape = shape.difference(keyhole)
    return shape

def badge(base, mark, gap=1.0):
    """`base` with `mark` set into it, cut clear by `gap`."""
    return base.difference(mark.buffer(gap, 32)).union(mark)

def person(hx, hy, hr, sx, sy, sr, foot):
    """A head of radius hr at hx, hy, and shoulders: the top of a circle at sx, sy, cut flat at `foot`."""
    return disk(hx, hy, hr).union(disk(sx, sy, sr).intersection(box(0, 0, 16, foot)))

icons = {}
# A link with a password: the globe with a small padlock set into its lower right, cut clear of it.
icons["verso-globe-lock-symbolic.svg"] = (badge(globe(), lock(9.6, 10.9, 15.3, 15.3, 1.0, hole=False)),
    "A link with a password (an album shared so, its card and its page; a link's card): the globe with a padlock. Drawn by sources/sharing.py.")
# Shared with people: two people, one behind the other's shoulder, as a group is drawn.
front = person(6.0, 5.6, 2.45, 6.0, 15.4, 5.4, 15.2)
back = person(11.4, 4.2, 2.1, 11.6, 13.4, 4.3, 12.6)
icons["verso-people-symbolic.svg"] = (unary_union([front, back.difference(front.buffer(1.0, 32))]),
    "Shared with people on the server (an album's page): two people, one behind the other. Drawn by sources/sharing.py.")
# Private: a padlock in the weight of Verso's globe, with a keyhole.
icons["verso-private-symbolic.svg"] = (lock(2.8, 7.2, 13.2, 15.2, 1.4, rad=1.4, hole=True),
    "Private, only you (an album's page): a padlock in the globe's weight. Drawn by sources/sharing.py.")
for name, (geom, note) in icons.items():
    (out / name).write_text(svg(geom, note))
